import Foundation
import GRDB
import Synchronization

/// A redacted, typed source. Conclusions refer to these records rather than citing themselves.
public struct MemoryEvidence: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memoryEvidence"
    public var id: String
    public var spaceId: String
    public var sourceId: String
    public var source: String
    public var text: String
    public var at: Date
    public var active: Bool
    public var processedAt: Date?
    public var embedding: Data

    var forInference: Self { var copy = self; copy.embedding = Data(); return copy }
}

/// An interpretation, never an instruction or an authorization. The evidence and earlier interpretations stay inspectable.
public struct MemoryUnderstanding: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "memoryUnderstanding"
    public enum Kind: String, Codable, CaseIterable, Sendable { case thing, process, pattern }
    public enum State: String, Codable, Sendable { case inferred, reviewed, dismissed }
    public struct Citation: Codable, Sendable, Equatable {
        public var evidenceId: String
        public var quote: String
        public init(evidenceId: String, quote: String) { self.evidenceId = evidenceId; self.quote = quote }
    }
    public struct Step: Codable, Sendable, Equatable {
        public var action: String
        public var why: String
        public var check: String
        public init(action: String, why: String, check: String) { self.action = action; self.why = why; self.check = check }
    }
    public struct Connection: Codable, Sendable, Equatable {
        public var targetId: String
        public var relation: String
        public init(targetId: String, relation: String) { self.targetId = targetId; self.relation = relation }
    }
    public var id: String
    public var spaceId: String
    public var kind: Kind
    public var subject: String
    public var subjectKey: String
    public var summary: String
    public var explanation: String
    public var appliesWhen: String
    public var exceptions: [String]
    public var steps: [Step]
    public var questions: [String]
    public var citations: [Citation]
    public var connections: [Connection]
    public var confidence: String
    public var state: State
    public var revision: Int
    public var sourceRevision: Int
    public var model: String
    public var updatedAt: Date
    public var embedding: Data

    public var searchText: String { subject + ": " + summary + " " + appliesWhen + " " + steps.map(\.action).joined(separator: " ") }
    var forInference: Self { var copy = self; copy.embedding = Data(); return copy }
}

public struct MemoryUnderstandingVersion: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memoryUnderstandingHistory"
    public var id: String
    public var understandingId: String
    public var snapshot: MemoryUnderstanding
    public var at: Date
}

public struct MemoryLearningProgress: Codable, Sendable {
    public var sources: Int
    public var processed: Int
    public var pending: Int
    public var retrying: Int
    public var understanding: Int
    public var lastRun: Date?
    public var error: String?
}

extension FaciendaStore {
    static func registerMemoryUnderstanding(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("memory_understanding") { db in
            try db.execute(sql: """
                CREATE TABLE memoryEvidence (
                    id TEXT PRIMARY KEY, spaceId TEXT NOT NULL REFERENCES memorySpaces(id), sourceId TEXT NOT NULL,
                    source TEXT NOT NULL, text TEXT NOT NULL, at DATETIME NOT NULL, active BOOLEAN NOT NULL,
                    processedAt DATETIME, embedding BLOB NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                    nextAttempt DATETIME, error TEXT
                );
                CREATE INDEX evidence_pending ON memoryEvidence(spaceId, active, processedAt, nextAttempt, at);
                CREATE TABLE memoryUnderstanding (
                    id TEXT PRIMARY KEY, spaceId TEXT NOT NULL REFERENCES memorySpaces(id), kind TEXT NOT NULL,
                    subject TEXT NOT NULL, subjectKey TEXT NOT NULL, summary TEXT NOT NULL, explanation TEXT NOT NULL,
                    appliesWhen TEXT NOT NULL, exceptions TEXT NOT NULL, steps TEXT NOT NULL, questions TEXT NOT NULL,
                    citations TEXT NOT NULL, connections TEXT NOT NULL, confidence TEXT NOT NULL, state TEXT NOT NULL,
                    revision INTEGER NOT NULL, sourceRevision INTEGER NOT NULL, model TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL, embedding BLOB NOT NULL, UNIQUE(spaceId, kind, subjectKey)
                );
                CREATE TABLE memoryUnderstandingHistory (
                    id TEXT PRIMARY KEY, understandingId TEXT NOT NULL REFERENCES memoryUnderstanding(id), snapshot TEXT NOT NULL, at DATETIME NOT NULL
                );
                CREATE TABLE memoryReasoningState (
                    spaceId TEXT PRIMARY KEY REFERENCES memorySpaces(id), revision INTEGER NOT NULL DEFAULT 0,
                    reviewedRevision INTEGER NOT NULL DEFAULT 0, leaseOwner TEXT, leaseUntil DATETIME, lastRun DATETIME, error TEXT
                );
                """)
        }
    }

    /// Rebuildable from sources. Old captures are included, so an upgraded library gains understanding without re-importing it.
    public func prepareMemoryEvidence(spaceID: String) throws {
        // This runs for every memory on every sync and almost always finds nothing new. Looking in a read first keeps
        // the library's write lock free for the app, the helpers and the runner.
        guard try db.read({ try Self.syncMemoryEvidence($0, spaceID: spaceID, apply: false) }) else { return }
        try db.write { _ = try Self.syncMemoryEvidence($0, spaceID: spaceID, apply: true) }
    }

    /// Each source's redacted chunks and their evidence ids, kept for the life of the process. Redacting every message
    /// again on each 30-second sync took seconds of CPU once a library held a few thousand of them.
    private static let evidencePieces = Mutex<[String: [(id: String, text: String)]]>([:])

    private static func pieces(spaceID: String, sourceId: String, text: String) -> [(id: String, text: String)] {
        let key = spaceID + "\n" + sourceId + "\n" + text
        if let known = evidencePieces.withLock({ $0[key] }) { return known }
        let pieces = MemoryChunker.split(MemoryRedaction.redact(text), limit: 3000).enumerated().map { index, chunk in
            (id: MemoryChunker.digest(spaceID + "\n" + sourceId + "\n\(index)\n" + chunk), text: chunk)
        }
        evidencePieces.withLock { cache in
            // Edited and removed sources leave stale keys behind; starting over now and then keeps that bounded.
            if cache.count > 50_000 { cache.removeAll() }
            cache[key] = pieces
        }
        return pieces
    }

    /// Returns whether the evidence differs from its sources, and with `apply` brings it in line.
    private static func syncMemoryEvidence(_ db: Database, spaceID: String, apply: Bool) throws -> Bool {
        _ = try memorySpace(db, spaceID)
        var changed = false
        if apply {
            try db.execute(sql: "INSERT OR IGNORE INTO memoryReasoningState(spaceId) VALUES (?)", arguments: [spaceID])
        } else if try Int.fetchOne(db, sql: "SELECT 1 FROM memoryReasoningState WHERE spaceId = ?", arguments: [spaceID]) == nil {
            return true
        }
        // One look at what this memory already holds, without the embeddings, instead of a query per source and chunk.
        // Evidence ids include the space and the source, so no source can touch another's rows during the pass.
        var known: [String: Bool] = [:], activeBySource: [String: [String]] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT id, sourceId, active FROM memoryEvidence WHERE spaceId = ?", arguments: [spaceID])
        while let row = try rows.next() {
            let id: String = row["id"], active: Bool = row["active"]
            known[id] = active
            if active { activeBySource[row["sourceId"], default: []].append(id) }
        }
        var present = Set<String>()
        func add(_ sourceId: String, text: String, source: String, at: Date) throws {
            present.insert(sourceId)
            let pieces = Self.pieces(spaceID: spaceID, sourceId: sourceId, text: text)
            let ids = Set(pieces.map(\.id))
            for piece in pieces {
                if let active = known[piece.id] {
                    if !active {
                        changed = true
                        if apply { try db.execute(sql: "UPDATE memoryEvidence SET active = 1, processedAt = NULL, nextAttempt = NULL WHERE id = ?", arguments: [piece.id]) }
                    }
                } else {
                    changed = true
                    if apply {
                        try MemoryEvidence(id: piece.id, spaceId: spaceID, sourceId: sourceId, source: MemoryRedaction.redact(source), text: piece.text,
                                           at: at, active: true, processedAt: nil, embedding: Data()).insert(db)
                    }
                }
            }
            for id in activeBySource[sourceId] ?? [] where !ids.contains(id) {
                changed = true
                if apply { try db.execute(sql: "UPDATE memoryEvidence SET active = 0 WHERE id = ?", arguments: [id]) }
            }
        }
        let kinds = utteranceKinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let utterances = try Row.fetchCursor(db, sql: "SELECT id, text, source, at FROM memoryUtterances WHERE spaceId = ? AND sourceKind IN (\(kinds)) ORDER BY at", arguments: [spaceID])
        while let row = try utterances.next() {
            try add("utterance:" + (row["id"] as String), text: row["text"], source: row["source"], at: row["at"])
        }
        for entry in try MemoryEntry.fetchAll(db, sql: "SELECT * FROM memoryEntries WHERE spaceId = ? AND state = 'live'", arguments: [spaceID]) {
            try add("entry:" + entry.id, text: entry.text, source: "User-written or accepted entry: " + entry.subject, at: entry.updatedAt)
        }
        for item in try MemoryUnderstanding.fetchAll(db, sql: "SELECT * FROM memoryUnderstanding WHERE spaceId = ? AND state = 'reviewed'", arguments: [spaceID]) {
            try add("reviewed:" + item.id, text: item.summary, source: "Understanding reviewed or corrected by the user: " + item.subject, at: item.updatedAt)
        }
        for (sourceId, ids) in activeBySource where !present.contains(sourceId) {
            changed = true
            if apply { for id in ids { try db.execute(sql: "UPDATE memoryEvidence SET active = 0 WHERE id = ?", arguments: [id]) } }
        }
        if changed && apply { try db.execute(sql: "UPDATE memoryReasoningState SET revision = revision + 1 WHERE spaceId = ?", arguments: [spaceID]) }
        return changed
    }

    public func memoryUnderstanding(spaceID: String, includeDismissed: Bool = false) throws -> [MemoryUnderstanding] {
        try db.read { try MemoryUnderstanding.fetchAll($0, sql: "SELECT * FROM memoryUnderstanding WHERE spaceId = ? \(includeDismissed ? "" : "AND state != 'dismissed'") ORDER BY updatedAt DESC, id", arguments: [spaceID]) }
    }

    public func memoryEvidence(_ ids: [String], spaceID: String, includeInactive: Bool = false) throws -> [MemoryEvidence] {
        guard !ids.isEmpty else { return [] }
        return try db.read { db in
            try MemoryEvidence.fetchAll(db, sql: "SELECT * FROM memoryEvidence WHERE spaceId = ? AND id IN (\(ids.map { _ in "?" }.joined(separator: ","))) \(includeInactive ? "" : "AND active = 1") ORDER BY at", arguments: StatementArguments([spaceID] + ids))
        }
    }

    public func memoryUnderstandingHistory(_ id: String, spaceID: String) throws -> [MemoryUnderstandingVersion] {
        try db.read { try MemoryUnderstandingVersion.fetchAll($0, sql: "SELECT h.* FROM memoryUnderstandingHistory h JOIN memoryUnderstanding u ON u.id = h.understandingId WHERE u.id = ? AND u.spaceId = ? ORDER BY h.at DESC", arguments: [id, spaceID]) }
    }

    public func reviewMemoryUnderstanding(_ id: String, spaceID: String, summary: String? = nil, dismiss: Bool = false) throws {
        try write { db in
            guard var item = try MemoryUnderstanding.fetchOne(db, sql: "SELECT * FROM memoryUnderstanding WHERE id = ? AND spaceId = ?", arguments: [id, spaceID]) else { throw StoreError.notFound }
            try MemoryUnderstandingVersion(id: UUID().uuidString, understandingId: id, snapshot: item, at: Date()).insert(db)
            if let summary {
                guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Write the corrected understanding.") }
                item.summary = MemoryRedaction.redact(summary); item.embedding = Data()
            }
            item.state = dismiss ? .dismissed : .reviewed; item.revision += 1; item.updatedAt = Date()
            try item.update(db)
        }
    }

    public func memoryLearningProgress(spaceID: String) throws -> MemoryLearningProgress {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT count(*) n, coalesce(sum(processedAt IS NOT NULL),0) processed, coalesce(sum(processedAt IS NULL AND attempts > 0),0) retrying FROM memoryEvidence WHERE spaceId = ? AND active = 1", arguments: [spaceID])!
            let status = try Row.fetchOne(db, sql: "SELECT lastRun, error FROM memoryReasoningState WHERE spaceId = ?", arguments: [spaceID])
            let n: Int = row["n"], processed: Int = row["processed"]
            return .init(sources: n, processed: processed, pending: n - processed, retrying: row["retrying"],
                         understanding: try Int.fetchOne(db, sql: "SELECT count(*) FROM memoryUnderstanding WHERE spaceId = ? AND state != 'dismissed'", arguments: [spaceID]) ?? 0,
                         lastRun: status?["lastRun"], error: status?["error"])
        }
    }

    public func retryMemoryLearning(spaceID: String) throws {
        try write { try $0.execute(sql: "UPDATE memoryEvidence SET nextAttempt = NULL, error = NULL WHERE spaceId = ? AND processedAt IS NULL", arguments: [spaceID]) }
    }

    func understandingRevision(spaceID: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT revision FROM memoryReasoningState WHERE spaceId = ?", arguments: [spaceID]) ?? 0 }
    }

    func claimMemoryReasoning(spaceID: String, owner: String, now: Date = Date()) throws -> Bool {
        try db.write { db in
            try db.execute(sql: "UPDATE memoryReasoningState SET leaseOwner = ?, leaseUntil = ? WHERE spaceId = ? AND (leaseUntil IS NULL OR leaseUntil < ?)", arguments: [owner, now.addingTimeInterval(1800), spaceID, now])
            return db.changesCount == 1
        }
    }

    func releaseMemoryReasoning(spaceID: String, owner: String) throws {
        try db.write { try $0.execute(sql: "UPDATE memoryReasoningState SET leaseOwner = NULL, leaseUntil = NULL WHERE spaceId = ? AND leaseOwner = ?", arguments: [spaceID, owner]) }
    }

    func renewMemoryReasoning(spaceID: String, owner: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE memoryReasoningState SET leaseUntil = ? WHERE spaceId = ? AND leaseOwner = ?", arguments: [Date().addingTimeInterval(1800), spaceID, owner])
            guard db.changesCount == 1 else { throw StoreError.conflict }
        }
    }
}
