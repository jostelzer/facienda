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

/// A memory source, redacted and digested before any transaction starts. Nil when nothing is left to keep.
struct PreparedMemoryDocument: Sendable {
    let id: String, content: String, digest: String, source: String, at: Date, spaceID: String
    let externalID: String?, sourceKind: MemorySourceKind, taskID: String?

    init?(id: String, content: String, source: String, at: Date, spaceID: String, externalID: String? = nil,
          sourceKind: MemorySourceKind, taskID: String? = nil) {
        let content = MemoryRedaction.redact(content)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.id = id; self.content = content; self.source = MemoryRedaction.redact(source); self.at = at; self.spaceID = spaceID
        self.externalID = externalID; self.sourceKind = sourceKind; self.taskID = taskID
        digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A user message for understanding, redacted before any transaction starts. Nil for a kind or envelope that is not kept.
struct PreparedUtterance: Sendable {
    let id: String, text: String, source: String, kind: MemorySourceKind, taskID: String?, spaceID: String, at: Date, priorResult: String?

    init?(id: String, text: String, source: String, kind: MemorySourceKind, taskID: String?, spaceID: String, at: Date, priorResult: String?) {
        guard FaciendaStore.utteranceKinds.contains(kind), !MemoryUserMessages.isEnvelope(text) else { return nil }
        self.id = id; self.text = MemoryRedaction.redact(text); self.source = MemoryRedaction.redact(source); self.kind = kind
        self.taskID = taskID; self.spaceID = spaceID; self.at = at; self.priorResult = priorResult
    }
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
        try enqueueMemoryDocuments([PreparedMemoryDocument(id: id, content: content, source: source, at: at, spaceID: spaceID,
                                                           externalID: externalID, sourceKind: sourceKind, taskID: taskID)])
    }

    /// Every sync offers each source again. Redacted beforehand, only the new or changed ones are written, in a few
    /// short transactions, so the library's single write lock is never held long enough for a helper or the runner
    /// to give up waiting. Utterances come before documents: a message's own earlier reply outranks the one found
    /// from events, and the first one kept stays.
    func enqueueMemoryDocuments(_ documents: [PreparedMemoryDocument?], utterances: [PreparedUtterance] = []) throws {
        typealias Capture = (needed: (Database) throws -> Bool, apply: (Database) throws -> Void)
        let captures: [Capture] = utterances.map { utterance in (
            { try Self.pendingUtterance($0, id: utterance.id, text: utterance.text, kind: utterance.kind, taskID: utterance.taskID,
                                        at: utterance.at, priorResult: utterance.priorResult).needed },
            { try Self.captureUtterance($0, id: utterance.id, text: utterance.text, source: utterance.source, kind: utterance.kind,
                                        taskID: utterance.taskID, spaceID: utterance.spaceID, at: utterance.at, priorResult: utterance.priorResult) }
        ) } + documents.compactMap { $0 }.map { document in ({ try Self.documentNeeded($0, document) }, { try Self.enqueue($0, document) }) }
        // Most syncs find everything already kept; looking in a read leaves the write lock alone.
        let pending = try db.read { db in try captures.filter { try $0.needed(db) } }
        for start in stride(from: 0, to: pending.count, by: 50) {
            try db.write { db in for capture in pending[start..<min(start + 50, pending.count)] { try capture.apply(db) } }
        }
    }

    private static func documentNeeded(_ db: Database, _ document: PreparedMemoryDocument) throws -> Bool {
        let kept = try Row.fetchOne(db, sql: "SELECT digest, sourceKind FROM memoryDocuments WHERE id = ?", arguments: [document.id])
        guard let kept, kept["digest"] as String? == document.digest, kept["sourceKind"] as String? == document.sourceKind.rawValue else { return true }
        return try pendingUtterance(db, id: document.id, text: document.content, kind: document.sourceKind, taskID: document.taskID,
                                    at: document.at, priorResult: nil).needed
    }

    /// Writes only a new or changed source; an unchanged one leaves the row alone.
    private static func enqueue(_ db: Database, _ document: PreparedMemoryDocument) throws {
        try db.execute(sql: """
            INSERT INTO memoryDocuments(id, content, digest, source, at, operationId, state, nextAttempt, spaceId, externalId, sourceKind, taskId)
            VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET content = excluded.content, digest = excluded.digest,
              source = excluded.source, at = excluded.at, operationId = excluded.operationId,
              sourceKind = excluded.sourceKind, taskId = excluded.taskId,
              state = 'pending', leaseUntil = NULL, attempts = 0, nextAttempt = excluded.nextAttempt, error = NULL
            WHERE memoryDocuments.digest != excluded.digest
              OR memoryDocuments.sourceKind != excluded.sourceKind
            """, arguments: [document.id, document.content, document.digest, document.source, document.at, UUID().uuidString, Date(),
                             document.spaceID, document.externalID, document.sourceKind.rawValue, document.taskID])
        let originalSpace = try String.fetchOne(db, sql: "SELECT spaceId FROM memoryDocuments WHERE id = ?", arguments: [document.id]) ?? document.spaceID
        try captureUtterance(db, id: document.id, text: document.content, source: document.source, kind: document.sourceKind,
                             taskID: document.taskID, spaceID: originalSpace, at: document.at)
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
        try enqueueMemoryDocuments(sources.map { id, content, source, at, space, kind, taskID in
            PreparedMemoryDocument(id: id, content: content, source: source, at: at, spaceID: space, sourceKind: kind, taskID: taskID)
        })
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
