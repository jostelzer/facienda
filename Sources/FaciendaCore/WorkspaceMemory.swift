import Foundation
import CryptoKit
import GRDB

/// Library-wide learning and task fallback settings. Memory has no network service.
public struct WorkspaceMemorySettings: Codable, FetchableRecord, Sendable, Equatable {
    public var enabled: Bool
    public var workerModel: String?
    public var workerReasoningEffort: String = "high"
    public var useAIWorker: Bool = true
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
    /// An older engine's document ID, retained only to read existing libraries.
    public var externalId: String?
    public var sourceKind: MemorySourceKind = .legacy
    public var taskId: String? = nil
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

    public func saveMemorySettings(enabled: Bool, workerModel: String?, workerReasoningEffort: String = "high") throws {
        guard ["low", "medium", "high", "xhigh", "max", "ultra"].contains(workerReasoningEffort) else {
            throw StoreError.invalid("Choose a supported reasoning effort.")
        }
        let model = workerModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        try write { db in
            try db.execute(sql: "UPDATE memorySettings SET enabled = ?, workerModel = ?, workerReasoningEffort = ?, engine = 'native' WHERE id = 1",
                           arguments: [enabled, model?.isEmpty == false ? model : nil, workerReasoningEffort])
        }
    }

    public func setMemoryAIWorker(_ enabled: Bool) throws {
        try write { try $0.execute(sql: "UPDATE memorySettings SET useAIWorker = ? WHERE id = 1", arguments: [enabled]) }
    }

    /// Immutable source records are retained locally even when the service is unavailable.
    /// A source stays in the workspace where it was first captured, even when its task moves.
    public func enqueueMemoryDocument(id: String, content: String, source: String, at: Date, spaceID: String, externalID: String? = nil,
                                      sourceKind: MemorySourceKind = .legacy, taskID: String? = nil) throws {
        let content = MemoryRedaction.redact(content), source = MemoryRedaction.redact(source)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO memoryDocuments(id, content, digest, source, at, operationId, state, nextAttempt, spaceId, externalId, sourceKind, taskId)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET content = excluded.content, digest = excluded.digest,
                  source = excluded.source, at = excluded.at, operationId = excluded.operationId,
                  sourceKind = excluded.sourceKind, taskId = excluded.taskId,
                  state = 'pending', leaseUntil = NULL, attempts = 0, nextAttempt = excluded.nextAttempt, error = NULL
                WHERE memoryDocuments.digest != excluded.digest
                  OR memoryDocuments.sourceKind != excluded.sourceKind
                """, arguments: [id, content, digest, source, at, UUID().uuidString, Date(), spaceID, externalID, sourceKind.rawValue, taskID])
        }
        let originalSpace = try db.read { try String.fetchOne($0, sql: "SELECT spaceId FROM memoryDocuments WHERE id = ?", arguments: [id]) } ?? spaceID
        try captureUtterance(id: id, text: content, source: source, kind: sourceKind, taskID: taskID, spaceID: originalSpace, at: at)
    }

    /// Gathers sources for every memory. Each source goes to the memory of the workspace its task is in.
    public func captureWorkspaceMemory() throws {
        guard try memorySettings().enabled else { return }
        let sources = try db.read { db -> [(String, String, String, Date, String, MemorySourceKind, String)] in
            let spaces = Dictionary(try Row.fetchAll(db, sql: "SELECT t.id, w.memorySpaceId FROM tasks t JOIN workspaces w ON w.id = t.workspaceId").map {
                ($0["id"] as String, $0["memorySpaceId"] as String)
            }, uniquingKeysWith: { first, _ in first })
            // Task fields can be edited by agents. The original user event is the evidence of authorship.
            let events = try TaskEvent.fetchAll(db, sql: "SELECT * FROM events WHERE source = 'user' AND kind IN ('task.created', 'user.reply')")
            var result: [(String, String, String, Date, String, MemorySourceKind, String)] = events.compactMap { event in
                guard let taskID = event.taskId, let space = spaces[taskID] else { return nil }
                let request = event.kind == "task.created"
                return (request ? "task-\(taskID)" : "event-\(event.id)", event.payload,
                        "Facienda event \(event.id), task \(taskID)", event.at, space, request ? .userRequest : .userReply, taskID)
            }
            for decision in try Decision.fetchAll(db, sql: "SELECT * FROM decisions WHERE state = 'answered' AND NOT EXISTS (SELECT 1 FROM memoryDocuments WHERE id = 'decision-' || decisions.id)") {
                guard let space = spaces[decision.taskId] else { continue }
                // The question is agent text. Retain the user's answer without attributing that question to them.
                guard let answer = decision.answer, !answer.isEmpty else { continue }
                result.append(("decision-\(decision.id)", answer, "Facienda decision \(decision.id), task \(decision.taskId)", decision.answeredAt ?? decision.createdAt, space, .userDecision, decision.taskId))
            }
            return result
        }
        for (id, content, source, at, space, kind, taskID) in sources {
            try enqueueMemoryDocument(id: id, content: content, source: source, at: at, spaceID: space, sourceKind: kind, taskID: taskID)
        }
        for space in try memorySpaces() {
            // Rules are instructions, not knowledge to learn from.
            let notes = try memory(spaceID: space.id).filter { $0.kind != Self.ruleKind && $0.confirmedAt != nil }, id = Self.curatedNotesID(space.id)
            let existing = try db.read { try Row.fetchOne($0, sql: "SELECT externalId FROM memoryDocuments WHERE id = ?", arguments: [id]) }
            let externalID: String? = existing.flatMap { $0["externalId"] as String? }
            // A memory whose last note moved away must not keep its earlier note snapshot.
            guard !notes.isEmpty || existing != nil else { continue }
            let content = notes.isEmpty ? "There are currently no user-confirmed notes in this memory." : notes.sorted { $0.id < $1.id }.map {
                "[\($0.confirmedAt == nil ? "Unconfirmed agent contribution" : "Explicit user-confirmed fact; takes precedence over inferred summaries")] \($0.text)\nSource: \($0.source)\nRecord: \($0.id)"
            }.joined(separator: "\n\n")
            try enqueueMemoryDocument(id: id, content: content, source: "Current Facienda memory notes; supersedes earlier versions of this document",
                                      at: notes.map(\.createdAt).max() ?? Date(), spaceID: space.id, externalID: externalID, sourceKind: .curatedNotes)
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
