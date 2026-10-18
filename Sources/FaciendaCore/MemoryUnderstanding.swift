import Foundation
import GRDB

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
        try db.write { db in
            _ = try Self.memorySpace(db, spaceID)
            try db.execute(sql: "INSERT OR IGNORE INTO memoryReasoningState(spaceId) VALUES (?)", arguments: [spaceID])
            let utterances = try MemoryUtterance.fetchAll(db, sql: "SELECT * FROM memoryUtterances WHERE spaceId = ? ORDER BY at", arguments: [spaceID])
            let entries = try MemoryEntry.fetchAll(db, sql: "SELECT * FROM memoryEntries WHERE spaceId = ? AND state = 'live'", arguments: [spaceID])
            var changed = false
            var present = Set<String>()
            func add(_ sourceId: String, text: String, source: String, at: Date) throws {
                present.insert(sourceId)
                let chunks = MemoryChunker.split(MemoryRedaction.redact(text), limit: 3000)
                let old = try MemoryEvidence.fetchAll(db, sql: "SELECT * FROM memoryEvidence WHERE spaceId = ? AND sourceId = ? AND active = 1", arguments: [spaceID, sourceId])
                var ids = Set<String>()
                for (index, chunk) in chunks.enumerated() {
                    let id = MemoryChunker.digest(spaceID + "\n" + sourceId + "\n\(index)\n" + chunk)
                    ids.insert(id)
                    if let current = try MemoryEvidence.fetchOne(db, key: id) {
                        if !current.active {
                            try db.execute(sql: "UPDATE memoryEvidence SET active = 1, processedAt = NULL, nextAttempt = NULL WHERE id = ?", arguments: [id]); changed = true
                        }
                    } else {
                        try MemoryEvidence(id: id, spaceId: spaceID, sourceId: sourceId, source: MemoryRedaction.redact(source), text: chunk,
                                           at: at, active: true, processedAt: nil, embedding: Data()).insert(db)
                        changed = true
                    }
                }
                for item in old where !ids.contains(item.id) {
                    try db.execute(sql: "UPDATE memoryEvidence SET active = 0 WHERE id = ?", arguments: [item.id]); changed = true
                }
            }
            for utterance in utterances where [.userRequest, .userReply, .userDecision, .codexUser, .claudeUser].contains(utterance.sourceKind) {
                try add("utterance:" + utterance.id, text: utterance.text, source: utterance.source, at: utterance.at)
            }
            for entry in entries { try add("entry:" + entry.id, text: entry.text, source: "User-written or accepted entry: " + entry.subject, at: entry.updatedAt) }
            for item in try MemoryUnderstanding.fetchAll(db, sql: "SELECT * FROM memoryUnderstanding WHERE spaceId = ? AND state = 'reviewed'", arguments: [spaceID]) {
                try add("reviewed:" + item.id, text: item.summary, source: "Understanding reviewed or corrected by the user: " + item.subject, at: item.updatedAt)
            }
            for old in try MemoryEvidence.fetchAll(db, sql: "SELECT * FROM memoryEvidence WHERE spaceId = ? AND active = 1", arguments: [spaceID]) where !present.contains(old.sourceId) {
                try db.execute(sql: "UPDATE memoryEvidence SET active = 0 WHERE id = ?", arguments: [old.id]); changed = true
            }
            if changed { try db.execute(sql: "UPDATE memoryReasoningState SET revision = revision + 1 WHERE spaceId = ?", arguments: [spaceID]) }
        }
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
