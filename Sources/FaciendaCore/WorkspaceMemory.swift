import Foundation
import CryptoKit
import GRDB

/// Library-wide memory service settings. Each memory has its own bank on this service.
public struct WorkspaceMemorySettings: Codable, FetchableRecord, Sendable, Equatable {
    public var endpoint: String
    public var enabled: Bool
    public var workerModel: String?
    public var workerReasoningEffort: String = "high"
    /// `native` learns inside Facienda; `hindsight` uses the optional local Hindsight service.
    public var engine: String = "native"
    public var usesHindsight: Bool { engine == "hindsight" }

    public var baseURL: URL {
        get throws {
            guard let url = URL(string: endpoint), url.scheme == "https",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                throw StoreError.invalid("Use a local Hindsight address, such as https://127.0.0.1:8888.")
            }
            return url
        }
    }
}

public struct MemoryDocument: Codable, FetchableRecord, Sendable {
    public var id: String
    public var content: String
    public var digest: String
    public var source: String
    public var at: Date
    public var operationId: String
    public var state: String
    public var attempts: Int
    public var error: String?
    /// The memory whose bank receives this source.
    public var spaceId: String?
    /// The document ID Hindsight knows, when it differs from the local one.
    public var externalId: String?
    public var documentID: String { externalId ?? id }
}

public struct WorkspaceMemoryStatus: Codable, Equatable, Sendable {
    public var pending: Int
    public var processing: Int
    public var completed: Int
    public var error: String?
}

extension FaciendaStore {
    public func memorySettings() throws -> WorkspaceMemorySettings {
        try db.read { try WorkspaceMemorySettings.fetchOne($0, sql: "SELECT * FROM memorySettings WHERE id = 1")! }
    }

    public func saveMemorySettings(endpoint: String, enabled: Bool, workerModel: String?, workerReasoningEffort: String = "high", engine: String? = nil) throws {
        var settings = try memorySettings()
        settings.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = engine ?? settings.engine
        guard ["native", "hindsight"].contains(engine) else { throw StoreError.invalid("Choose built-in memory or Hindsight.") }
        if engine == "hindsight" { _ = try settings.baseURL }
        guard ["low", "medium", "high", "xhigh", "max", "ultra"].contains(workerReasoningEffort) else {
            throw StoreError.invalid("Choose a supported reasoning effort.")
        }
        let model = workerModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        try write { db in
            let old = try WorkspaceMemorySettings.fetchOne(db, sql: "SELECT * FROM memorySettings WHERE id = 1")!
            try db.execute(sql: "UPDATE memorySettings SET endpoint = ?, enabled = ?, workerModel = ?, workerReasoningEffort = ?, engine = ? WHERE id = 1", arguments: [settings.endpoint, enabled, model?.isEmpty == false ? model : nil, workerReasoningEffort, engine])
            if old.endpoint != settings.endpoint {
                // A new service needs every memory's sources, with fresh operation identities. Its banks are configured again.
                for doc in try MemoryDocument.fetchAll(db, sql: "SELECT * FROM memoryDocuments") {
                    try db.execute(sql: "UPDATE memoryDocuments SET state = 'pending', operationId = ?, leaseUntil = NULL, attempts = 0, nextAttempt = ?, error = NULL WHERE id = ?", arguments: [UUID().uuidString, Date(), doc.id])
                }
            }
        }
    }

    /// Immutable source records are retained locally even when the service is unavailable.
    /// A changed source follows its task into the memory it belongs to now.
    public func enqueueMemoryDocument(id: String, content: String, source: String, at: Date, spaceID: String, externalID: String? = nil) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO memoryDocuments(id, content, digest, source, at, operationId, state, nextAttempt, spaceId, externalId)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET content = excluded.content, digest = excluded.digest,
                  source = excluded.source, at = excluded.at, operationId = excluded.operationId, spaceId = excluded.spaceId,
                  state = 'pending', leaseUntil = NULL, attempts = 0, nextAttempt = excluded.nextAttempt, error = NULL
                WHERE memoryDocuments.digest != excluded.digest
                """, arguments: [id, content, digest, source, at, UUID().uuidString, Date(), spaceID, externalID])
        }
    }

    /// Gathers sources for every memory. Each source goes to the memory of the workspace its task is in.
    public func captureWorkspaceMemory() throws {
        guard try memorySettings().enabled else { return }
        let sources = try db.read { db -> [(String, String, String, Date, String)] in
            let spaces = Dictionary(try Row.fetchAll(db, sql: "SELECT t.id, w.memorySpaceId FROM tasks t JOIN workspaces w ON w.id = t.workspaceId").map {
                ($0["id"] as String, $0["memorySpaceId"] as String)
            }, uniquingKeysWith: { first, _ in first })
            var result: [(String, String, String, Date, String)] = try FaciendaTask.fetchAll(db).compactMap { task in
                spaces[task.id].map { ("task-\(task.id)", "User's original request: \(task.title)\nIntention: \(task.intention)\nCompletion condition: \(task.definitionOfDone)", "Facienda task \(task.id)", task.createdAt, $0) }
            }
            let events = try TaskEvent.fetchAll(db, sql: "SELECT * FROM events WHERE kind IN ('user.reply', 'codex.result') AND NOT EXISTS (SELECT 1 FROM memoryDocuments WHERE id = 'event-' || events.id)")
            result += events.compactMap { event in
                event.taskId.flatMap { spaces[$0] }.map {
                    ("event-\(event.id)", "\(event.kind == "codex.result" ? "Assistant report, not independently verified" : "User statement"): \(event.payload)", "Facienda event \(event.id), task \(event.taskId ?? "none"), thread \(event.threadId ?? "unrecorded")", event.at, $0)
                }
            }
            for decision in try Decision.fetchAll(db, sql: "SELECT * FROM decisions WHERE state = 'answered' AND NOT EXISTS (SELECT 1 FROM memoryDocuments WHERE id = 'decision-' || decisions.id)") {
                guard let space = spaces[decision.taskId] else { continue }
                result.append(("decision-\(decision.id)", "Question: \(decision.question)\nUser answer: \(decision.answer ?? "")", "Facienda decision \(decision.id), task \(decision.taskId)", decision.answeredAt ?? decision.createdAt, space))
            }
            return result
        }
        for (id, content, source, at, space) in sources { try enqueueMemoryDocument(id: id, content: content, source: source, at: at, spaceID: space) }
        for space in try memorySpaces() {
            let notes = try memory(spaceID: space.id), id = Self.curatedNotesID(space.id)
            let existing = try db.read { try Row.fetchOne($0, sql: "SELECT externalId FROM memoryDocuments WHERE id = ?", arguments: [id]) }
            let externalID: String? = existing.flatMap { $0["externalId"] as String? }
            // A memory whose last note moved away says so, rather than keeping the old notes in Hindsight.
            guard !notes.isEmpty || existing != nil else { continue }
            let content = notes.isEmpty ? "There are currently no user-confirmed notes in this memory." : notes.sorted { $0.id < $1.id }.map {
                "[\($0.confirmedAt == nil ? "Unconfirmed agent contribution" : "Explicit user-confirmed fact; takes precedence over inferred summaries")] \($0.text)\nSource: \($0.source)\nRecord: \($0.id)"
            }.joined(separator: "\n\n")
            try enqueueMemoryDocument(id: id, content: content, source: "Current Facienda memory notes; supersedes earlier versions of this document",
                                      at: notes.map(\.createdAt).max() ?? Date(), spaceID: space.id, externalID: externalID)
        }
    }

    public func claimMemoryDocument(now: Date = Date()) throws -> MemoryDocument? {
        try db.write { db in
            guard let doc = try MemoryDocument.fetchOne(db, sql: "SELECT * FROM memoryDocuments WHERE state IN ('pending', 'processing') AND nextAttempt <= ? AND (leaseUntil IS NULL OR leaseUntil <= ?) ORDER BY nextAttempt, at LIMIT 1", arguments: [now, now]) else { return nil }
            try db.execute(sql: "UPDATE memoryDocuments SET leaseUntil = ? WHERE id = ?", arguments: [now.addingTimeInterval(90), doc.id])
            return doc
        }
    }

    public func finishMemoryAttempt(_ doc: MemoryDocument, state: String, error: String? = nil, retryOperation: Bool = false, now: Date = Date()) throws {
        let delay = error == nil ? 15.0 : min(3600, 30 * pow(2, Double(min(doc.attempts, 7))))
        try write { db in
            try db.execute(sql: "UPDATE memoryDocuments SET state = ?, error = ?, attempts = attempts + ?, nextAttempt = ?, leaseUntil = NULL, operationId = ? WHERE id = ? AND digest = ? AND operationId = ?", arguments: [state, error, error == nil ? 0 : 1, now.addingTimeInterval(delay), retryOperation ? UUID().uuidString : doc.operationId, doc.id, doc.digest, doc.operationId])
        }
    }

    /// Progress of one memory's sources: the one named, the scoped workspace's, or every memory's.
    public func workspaceMemoryStatus(spaceID: String? = nil) throws -> WorkspaceMemoryStatus {
        try db.read { db in
            let space = try spaceID ?? workspaceID.map { try Self.workspace(db, $0).memorySpaceId }
            let filter = space == nil ? "" : " AND spaceId = ?"
            func count(_ state: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memoryDocuments WHERE state = ?" + filter, arguments: StatementArguments([state] + (space.map { [$0] } ?? []))) ?? 0
            }
            return try .init(pending: count("pending"), processing: count("processing"), completed: count("completed"),
                             error: String.fetchOne(db, sql: "SELECT error FROM memoryDocuments WHERE error IS NOT NULL" + filter + " ORDER BY nextAttempt DESC LIMIT 1", arguments: StatementArguments(space.map { [$0] } ?? [])))
        }
    }
}
