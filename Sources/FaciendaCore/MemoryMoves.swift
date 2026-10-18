import Foundation
import GRDB

public struct MemoryUtterance: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memoryUtterances"
    public var id: String
    public var spaceId: String
    public var taskId: String?
    public var text: String
    public var source: String
    public var sourceKind: MemorySourceKind
    public var at: Date
    /// Context for recognising a situation, never input to the keeper as the user's words.
    public var priorResult: String?
    public var situationId: String?
    public var embedding: Data?
    public var moveId: String?
    public var keptAt: Date?
}

public struct MemoryMove: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "memoryMoves"
    public enum Stage: String, Codable, Sendable { case noticed, offered, accepted, archived }
    public var id: String
    public var spaceId: String?
    public var situationId: String
    public var text: String
    public var stage: Stage
    public var isYourStep: Bool
    public var seen: Int
    public var offered: Int
    public var used: Int
    public var ignored: Int
    public var embedding: Data
    public var createdAt: Date
    public var updatedAt: Date
}

public struct MemorySituation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memorySituations"
    public var id: String
    public var spaceId: String?
    public var name: String
    public var description: String
    public var embedding: Data

    static let core: [(String, String, String)] = [
        ("build", "Checks passed", "The implementation is complete. The build and automated tests passed."),
        ("preview", "A preview is ready", "Designs, mockups or a visual preview are ready for the user to inspect."),
        ("explanation", "Steps explained", "The assistant explained how to do something and described the next steps."),
        ("quote", "A quote arrived", "A supplier provided a price quote or estimate for the requested work."),
        ("report", "An update arrived", "A progress report describes what has happened and what remains."),
        ("question", "A choice is needed", "The assistant asks the user a question or presents options for a decision.")
    ]
}

extension FaciendaStore {
    static func registerMemoryMoves(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("memory_moves") { db in
            try db.execute(sql: """
                CREATE TABLE memoryUtterances (
                    id TEXT PRIMARY KEY, spaceId TEXT NOT NULL REFERENCES memorySpaces(id), taskId TEXT,
                    text TEXT NOT NULL, source TEXT NOT NULL, sourceKind TEXT NOT NULL, at DATETIME NOT NULL,
                    priorResult TEXT, situationId TEXT, embedding BLOB, moveId TEXT, keptAt DATETIME
                );
                CREATE INDEX utterances_pending ON memoryUtterances(spaceId, keptAt, at);
                CREATE TABLE memorySituations (id TEXT PRIMARY KEY, spaceId TEXT, name TEXT NOT NULL, description TEXT NOT NULL, embedding BLOB NOT NULL);
                CREATE TABLE memoryMoves (
                    id TEXT PRIMARY KEY, spaceId TEXT, situationId TEXT NOT NULL, text TEXT NOT NULL, stage TEXT NOT NULL,
                    isYourStep BOOLEAN NOT NULL DEFAULT 0, seen INTEGER NOT NULL, offered INTEGER NOT NULL DEFAULT 0,
                    used INTEGER NOT NULL DEFAULT 0, ignored INTEGER NOT NULL DEFAULT 0, embedding BLOB NOT NULL,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
                );
                CREATE INDEX moves_situation ON memoryMoves(spaceId, situationId, stage);
                CREATE TABLE memoryMoveOffers (
                    moveId TEXT NOT NULL REFERENCES memoryMoves(id), taskId TEXT NOT NULL REFERENCES tasks(id),
                    eventId TEXT NOT NULL, used BOOLEAN NOT NULL DEFAULT 0, PRIMARY KEY(moveId, taskId, eventId)
                );
                CREATE TABLE taskMoveContexts (taskId TEXT PRIMARY KEY REFERENCES tasks(id), eventId TEXT NOT NULL, situationId TEXT NOT NULL);
                """)
        }
        // Slash commands and question replies were counted as things the person says again and again.
        migrator.registerMigration("memory_moves_without_envelopes") { try removeEnvelopeMoves($0) }
    }

    /// Drops what was learned from text the person did not write. Their other words, which a move may also have
    /// gathered, go back to be learned again.
    static func removeEnvelopeMoves(_ db: Database) throws {
        let moves = try MemoryMove.fetchAll(db, sql: "SELECT * FROM memoryMoves WHERE text LIKE '<%'").filter { MemoryUserMessages.isEnvelope($0.text) }
        let utterances = try MemoryUtterance.fetchAll(db, sql: "SELECT * FROM memoryUtterances WHERE text LIKE '<%'").filter { MemoryUserMessages.isEnvelope($0.text) }
        for utterance in utterances { try db.execute(sql: "DELETE FROM memoryUtterances WHERE id = ?", arguments: [utterance.id]) }
        for move in moves {
            try db.execute(sql: "UPDATE memoryUtterances SET moveId = NULL, situationId = NULL WHERE moveId = ?", arguments: [move.id])
            try db.execute(sql: "DELETE FROM memoryMoveOffers WHERE moveId = ?", arguments: [move.id])
            try db.execute(sql: "DELETE FROM memoryMoves WHERE id = ?", arguments: [move.id])
        }
    }

    func captureUtterance(id: String, text: String, source: String, kind: MemorySourceKind, taskID: String?, spaceID: String, at: Date, priorResult: String? = nil) throws {
        guard [.userRequest, .userReply, .userDecision, .codexUser, .claudeUser].contains(kind), !MemoryUserMessages.isEnvelope(text) else { return }
        try db.write { db in
            let previous = try priorResult ?? taskID.flatMap { id in
                try String.fetchOne(db, sql: "SELECT payload FROM events WHERE taskId = ? AND kind = 'codex.result' AND at < ? ORDER BY at DESC LIMIT 1", arguments: [id, at])
            }
            let clean = MemoryRedaction.redact(text)
            try db.execute(sql: """
                INSERT INTO memoryUtterances (id, spaceId, taskId, text, source, sourceKind, at, priorResult)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET priorResult = coalesce(excluded.priorResult, memoryUtterances.priorResult)
                """, arguments: [id, spaceID, taskID, clean, MemoryRedaction.redact(source), kind.rawValue, at,
                                   previous.map { String(MemoryRedaction.redact($0).prefix(4000)) }])
        }
    }

    public func memoryMoves(spaceID: String, includeArchived: Bool = false) throws -> [MemoryMove] {
        try db.read { db in
            try MemoryMove.fetchAll(db, sql: """
                SELECT * FROM memoryMoves WHERE (spaceId = ? OR (spaceId IS NULL AND stage = 'accepted'))
                \(includeArchived ? "" : "AND stage != 'archived'") ORDER BY used DESC, seen DESC, updatedAt DESC
                """, arguments: [spaceID])
        }
    }

    public func situationName(_ id: String) throws -> String {
        try db.read { try String.fetchOne($0, sql: "SELECT name FROM memorySituations WHERE id = ?", arguments: [id]) ?? "After a similar result" }
    }

    public func acceptMove(_ id: String, spaceID: String, isYourStep: Bool = false) throws {
        try write { db in
            guard var move = try MemoryMove.fetchOne(db, key: id), move.spaceId == spaceID || move.spaceId == nil else { throw StoreError.notFound }
            move.stage = .accepted; move.isYourStep = isYourStep; move.updatedAt = Date(); try move.update(db)
        }
    }

    public func setMoveArchived(_ id: String, spaceID: String, archived: Bool) throws {
        try write { db in
            guard var move = try MemoryMove.fetchOne(db, key: id), move.spaceId == spaceID || move.spaceId == nil else { throw StoreError.notFound }
            move.stage = archived ? .archived : .offered; move.updatedAt = Date(); try move.update(db)
        }
    }

    /// Moves for the situation of the task's latest result only. Ones read from an earlier result answer what was already answered.
    public func suggestedMoves(taskID: String) throws -> [MemoryMove] {
        let space = try memorySpace(forTask: taskID).id
        return try db.read { db in
            guard let situation = try String.fetchOne(db, sql: """
                SELECT situationId FROM taskMoveContexts WHERE taskId = ? AND eventId = (SELECT id FROM events WHERE rowid = (\(Self.latestSourceID("?"))))
                """, arguments: [taskID, taskID]) else { return [] }
            return try MemoryMove.fetchAll(db, sql: """
                SELECT * FROM memoryMoves WHERE (spaceId = ? OR (spaceId IS NULL AND stage = 'accepted')) AND situationId = ?
                AND stage IN ('offered', 'accepted') AND (stage = 'accepted' OR ignored < 5) ORDER BY (stage = 'accepted') DESC,
                  (used * 3.0 + seen) / (1 + ignored) / (1 + max(0, julianday('now') - julianday(updatedAt)) / 90) DESC LIMIT 2
                """, arguments: [space, situation])
        }
    }

    /// The library page may show these to the user; task tools never expose an unaccepted shared move.
    public func sharedMoveProposals() throws -> [MemoryMove] {
        try db.read { try MemoryMove.fetchAll($0, sql: "SELECT * FROM memoryMoves WHERE spaceId IS NULL AND stage = 'offered' ORDER BY seen DESC") }
    }

    public func editMove(_ id: String, spaceID: String, text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Write something, or forget this move.") }
        try write { db in
            guard var move = try MemoryMove.fetchOne(db, key: id), move.spaceId == spaceID || move.spaceId == nil else { throw StoreError.notFound }
            move.text = MemoryRedaction.redact(text); move.embedding = Data(); move.updatedAt = Date(); try move.update(db)
        }
    }

    public func moveSituations(spaceID: String) throws -> [MemorySituation] {
        let learned = try db.read { try MemorySituation.fetchAll($0, sql: "SELECT * FROM memorySituations WHERE spaceId = ? ORDER BY name", arguments: [spaceID]) }
        return MemorySituation.core.map { .init(id: $0.0, spaceId: nil, name: $0.1, description: $0.2, embedding: Data()) } + learned
    }

    public func writeMemoryMove(spaceID: String, situationID: String, text: String, isYourStep: Bool) throws {
        let text = MemoryRedaction.redact(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, try moveSituations(spaceID: spaceID).contains(where: { $0.id == situationID }) else { throw StoreError.invalid("Choose a situation and write your move.") }
        try write { db in
            try MemoryMove(id: UUID().uuidString, spaceId: spaceID, situationId: situationID, text: text, stage: .accepted,
                           isYourStep: isYourStep, seen: 0, offered: 0, used: 0, ignored: 0, embedding: Data(), createdAt: Date(), updatedAt: Date()).insert(db)
        }
    }

    public func recordMoveUse(_ moveID: String, taskID: String) throws {
        let space = try memorySpace(forTask: taskID).id
        try db.write { db in
            guard let move = try MemoryMove.fetchOne(db, key: moveID), move.spaceId == space || move.spaceId == nil,
                  move.stage == .accepted else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE memoryMoves SET used = used + 1, updatedAt = ? WHERE id = ?", arguments: [Date(), moveID])
            try db.execute(sql: "UPDATE memoryMoveOffers SET used = 1 WHERE moveId = ? AND taskId = ? AND eventId = (SELECT eventId FROM taskMoveContexts WHERE taskId = ?)", arguments: [moveID, taskID, taskID])
        }
    }
}

/// Situation and reply matching stay on-device. The stored instruction is always an actual user utterance.
public struct MemoryMoveLearner: Sendable {
    public let store: FaciendaStore
    public let models: MemoryModels
    public init(store: FaciendaStore, models: MemoryModels = .shared) { self.store = store; self.models = models }

    func situations(spaceID: String) async throws -> [MemorySituation] {
        let missing = try await store.db.read { db in try MemorySituation.core.filter { try !MemorySituation.exists(db, key: $0.0) } }
        if !missing.isEmpty {
            let vectors = try await models.embed(missing.map(\.2))
            try await store.db.write { db in
                for (item, vector) in zip(missing, vectors) {
                    try MemorySituation(id: item.0, spaceId: nil, name: item.1, description: item.2, embedding: MemoryVector.encode(vector)).insert(db, onConflict: .ignore)
                }
            }
        }
        return try await store.db.read { try MemorySituation.fetchAll($0, sql: "SELECT * FROM memorySituations WHERE spaceId IS NULL OR spaceId = ?", arguments: [spaceID]) }
    }

    func classify(_ text: String, spaceID: String) async throws -> String {
        let candidates = try await situations(spaceID: spaceID), vector = try await models.embed([text])[0]
        if let best = candidates.map({ ($0, MemoryVector.dot(vector, MemoryVector.decode($0.embedding))) }).max(by: { $0.1 < $1.1 }), best.1 >= 0.45 { return best.0.id }
        let situation = MemorySituation(id: UUID().uuidString, spaceId: spaceID, name: "After a similar result", description: "A recurring situation in this workspace", embedding: MemoryVector.encode(vector))
        try await store.db.write { try situation.insert($0) }
        return situation.id
    }

    public func learnPending(limit: Int = 24) async throws {
        let edited = try await store.db.read { try MemoryMove.fetchAll($0, sql: "SELECT * FROM memoryMoves WHERE length(embedding) = 0 AND stage != 'archived' LIMIT ?", arguments: [limit]) }
        if !edited.isEmpty {
            let vectors = try await models.embed(edited.map(\.text))
            try await store.db.write { db in
                for (move, vector) in zip(edited, vectors) {
                    try db.execute(sql: "UPDATE memoryMoves SET embedding = ? WHERE id = ? AND text = ?", arguments: [MemoryVector.encode(vector), move.id, move.text])
                }
            }
        }
        let pending = try await store.db.read { try MemoryUtterance.fetchAll($0, sql: "SELECT * FROM memoryUtterances WHERE moveId IS NULL AND priorResult IS NOT NULL ORDER BY at LIMIT ?", arguments: [limit]) }
        for utterance in pending {
            try Task.checkCancellation()
            let situation = try await classify(utterance.priorResult ?? "", spaceID: utterance.spaceId)
            let vector = try await models.embed([utterance.text])[0]
            let candidates = try store.memoryMoves(spaceID: utterance.spaceId).filter { $0.situationId == situation && $0.spaceId == utterance.spaceId }
            var match = candidates.first { Self.normalized($0.text) == Self.normalized(utterance.text) }
            if match == nil, let best = candidates.map({ ($0, MemoryVector.dot(vector, MemoryVector.decode($0.embedding))) }).max(by: { $0.1 < $1.1 }), best.1 >= 0.85 {
                let scores = try await models.rerank(utterance.text, [best.0.text])
                if scores.first.map({ $0 > 0 }) == true { match = best.0 }
            }
            let matched = match
            try await store.db.write { db in
                guard try String.fetchOne(db, sql: "SELECT moveId FROM memoryUtterances WHERE id = ?", arguments: [utterance.id]) == nil else { return }
                var move = try matched.flatMap { try MemoryMove.fetchOne(db, key: $0.id) } ?? MemoryMove(id: UUID().uuidString, spaceId: utterance.spaceId, situationId: situation, text: utterance.text,
                                              stage: .noticed, isYourStep: false, seen: 0, offered: 0, used: 0, ignored: 0,
                                              embedding: MemoryVector.encode(vector), createdAt: utterance.at, updatedAt: utterance.at)
                move.seen += 1; move.updatedAt = utterance.at
                if move.seen >= 3 && move.stage == .noticed { move.stage = .offered }
                try move.save(db)
                try db.execute(sql: "UPDATE memoryUtterances SET moveId = ?, situationId = ?, embedding = ? WHERE id = ?",
                               arguments: [move.id, situation, MemoryVector.encode(vector), utterance.id])
                if move.stage != .accepted,
                   let wording = try String.fetchOne(db, sql: "SELECT text FROM memoryUtterances WHERE moveId = ? GROUP BY text ORDER BY count(*) DESC, max(at) DESC LIMIT 1", arguments: [move.id]) {
                    try db.execute(sql: "UPDATE memoryMoves SET text = ? WHERE id = ?", arguments: [wording, move.id])
                }
                if let taskID = utterance.taskId {
                    try db.execute(sql: "UPDATE memoryMoveOffers SET used = 1 WHERE moveId = ? AND taskId = ? AND used = 0 AND eventId = (SELECT eventId FROM taskMoveContexts WHERE taskId = ?)", arguments: [move.id, taskID, taskID])
                    if db.changesCount > 0 { try db.execute(sql: "UPDATE memoryMoves SET used = used + 1 WHERE id = ?", arguments: [move.id]) }
                }
            }
        }
        try await proposeSharedMoves()
    }

    private func proposeSharedMoves() async throws {
        var moves = try await store.db.read { try MemoryMove.fetchAll($0, sql: "SELECT * FROM memoryMoves WHERE (spaceId IS NULL OR stage != 'archived') AND seen >= 2 ORDER BY updatedAt DESC LIMIT 300") }
        let local = moves.filter { $0.spaceId != nil }
        var handled = Set<String>()
        for move in local where !handled.contains(move.id) && MemorySituation.core.contains(where: { $0.0 == move.situationId }) {
            let candidates = local.filter { $0.spaceId != move.spaceId && $0.situationId == move.situationId && MemoryVector.dot(MemoryVector.decode($0.embedding), MemoryVector.decode(move.embedding)) >= 0.85 }
            guard let other = candidates.first else { continue }
            let scores = try await models.rerank(move.text, [other.text])
            guard (scores.first ?? -.infinity) > 0 else { continue }
            handled.insert(other.id)
            guard !moves.contains(where: { $0.spaceId == nil && $0.situationId == move.situationId && MemoryVector.dot(MemoryVector.decode($0.embedding), MemoryVector.decode(move.embedding)) >= 0.85 }) else { continue }
            var shared = move; shared.id = UUID().uuidString; shared.spaceId = nil; shared.stage = .offered
            shared.seen += other.seen; shared.offered = 0; shared.used = 0; shared.ignored = 0
            let proposal = shared
            try await store.db.write { try proposal.insert($0) }
            moves.append(proposal)
            handled.insert(move.id)
        }
    }

    /// Local suggestions are prepared before the optional worker is asked to curate wording.
    public func offerPending(limit: Int = 8) async throws {
        let contexts = try await store.db.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT taskId, eventId FROM taskMoveContexts").map { ($0["taskId"] as String, $0["eventId"] as String) }, uniquingKeysWith: { first, _ in first })
        }
        // Finished tasks never get suggestions, so they are left out before the limit, or they would take it every time.
        let open = Set(try store.tasks().filter(\.state.isOpen).map(\.id))
        let pending = try store.latestResults().filter { open.contains($0.taskId) && contexts[$0.taskId] != $0.eventId }.sorted { $0.at > $1.at }.prefix(limit)
        for result in pending {
            try await offer(taskID: result.taskId, eventID: result.eventId, result: result.excerpt)
        }
    }

    /// Brings one task's suggestions up to its latest result, so an open popover does not wait for the next sweep.
    public func offerLatest(taskID: String) async throws {
        let current = try await store.db.read { try String.fetchOne($0, sql: "SELECT eventId FROM taskMoveContexts WHERE taskId = ?", arguments: [taskID]) }
        guard let result = try store.latestResults().first(where: { $0.taskId == taskID }), result.eventId != current else { return }
        try await offer(taskID: taskID, eventID: result.eventId, result: result.excerpt)
    }

    public func offer(taskID: String, eventID: String, result: String) async throws {
        let space = try store.memorySpace(forTask: taskID).id, situation = try await classify(result, spaceID: space)
        try await store.db.write { db in
            guard try FaciendaStore.spaceID(db, taskID: taskID) == space else { throw StoreError.conflict }
            let previous = try String.fetchOne(db, sql: "SELECT eventId FROM taskMoveContexts WHERE taskId = ?", arguments: [taskID])
            if let previous, previous != eventID {
                try db.execute(sql: "UPDATE memoryMoves SET ignored = ignored + 1 WHERE id IN (SELECT moveId FROM memoryMoveOffers WHERE taskId = ? AND eventId = ? AND used = 0)", arguments: [taskID, previous])
            }
            try db.execute(sql: "INSERT INTO taskMoveContexts VALUES (?, ?, ?) ON CONFLICT(taskId) DO UPDATE SET eventId = excluded.eventId, situationId = excluded.situationId", arguments: [taskID, eventID, situation])
        }
        for move in try store.suggestedMoves(taskID: taskID) {
            try await store.db.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO memoryMoveOffers (moveId, taskId, eventId) VALUES (?, ?, ?)", arguments: [move.id, taskID, eventID])
                if db.changesCount == 1 { try db.execute(sql: "UPDATE memoryMoves SET offered = offered + 1 WHERE id = ?", arguments: [move.id]) }
            }
        }
    }

    static func normalized(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
