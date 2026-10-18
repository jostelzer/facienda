import Foundation
import GRDB

/// A workspace's memory: its rules, its notes and what it learned, in a bank of its own. Every workspace has exactly
/// one, made with it and named after it. Nothing crosses between memories.
public struct MemorySpace: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Hashable, Sendable {
    public static let databaseTableName = "memorySpaces"
    public var id: String
    public var name: String
    public var bankId: String
    public var position: Int
    public var createdAt: Date
    /// The Hindsight endpoint this bank was last configured on.
    public var configuredEndpoint: String?
}

extension FaciendaStore {
    public func memorySpaces() throws -> [MemorySpace] {
        try db.read { try MemorySpace.fetchAll($0, sql: "SELECT * FROM memorySpaces ORDER BY position, createdAt") }
    }

    public func memorySpace(_ id: String) throws -> MemorySpace {
        try db.read { db in try Self.memorySpace(db, id) }
    }

    static func memorySpace(_ db: Database, _ id: String) throws -> MemorySpace {
        guard let space = try MemorySpace.fetchOne(db, key: id) else { throw StoreError.invalid("This memory no longer exists.") }
        return space
    }

    public func memorySpace(forWorkspace id: String) throws -> MemorySpace {
        try db.read { db in try Self.memorySpace(db, try Self.workspace(db, id).memorySpaceId) }
    }

    public func memorySpace(forTask id: String) throws -> MemorySpace {
        try db.read { db in try Self.memorySpace(db, try Self.spaceID(db, taskID: id)) }
    }

    static func spaceID(_ db: Database, taskID: String) throws -> String {
        guard let space = try String.fetchOne(db, sql: "SELECT w.memorySpaceId FROM tasks t JOIN workspaces w ON w.id = t.workspaceId WHERE t.id = ?", arguments: [taskID]) else {
            throw StoreError.notFound
        }
        return space
    }

    /// The memory to read or write: the one named, or the scoped workspace's own. Never a guess.
    func resolveSpace(_ db: Database, _ explicit: String?) throws -> String {
        if let explicit { return try Self.memorySpace(db, explicit).id }
        guard let workspaceID else { throw StoreError.invalid("Choose which memory to use.") }
        return try Self.workspace(db, workspaceID).memorySpaceId
    }

    /// The memory named, or the scoped workspace's own.
    public func resolvedMemorySpace(_ id: String?) throws -> MemorySpace {
        try db.read { db in try Self.memorySpace(db, try resolveSpace(db, id)) }
    }

    /// A new workspace's memory, named after it.
    static func createMemorySpace(_ db: Database, name: String) throws -> MemorySpace {
        let position = try Self.nextPosition(db, in: "memorySpaces")
        let space = MemorySpace(id: UUID().uuidString, name: name, bankId: "facienda-" + UUID().uuidString.lowercased(), position: position, createdAt: Date())
        try space.insert(db)
        return space
    }

    public func markSpaceConfigured(_ spaceID: String, endpoint: String) throws {
        try write { try $0.execute(sql: "UPDATE memorySpaces SET configuredEndpoint = ? WHERE id = ?", arguments: [endpoint, spaceID]) }
    }

    // MARK: One memory per workspace

    /// Workspaces used to be able to share a memory. Now each has its own: a shared memory is copied for every workspace
    /// but the first, whole, so each keeps everything it knew and learns on alone. The copy gets the workspace's own task
    /// sources and a bank of its own, which Hindsight fills again from them. Every memory then takes its workspace's name.
    static func registerOwnMemories(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("own_memories") { db in
            if !(try db.columns(in: "memoryUnits").contains { $0.name == "forgottenAt" }) {
                try db.execute(sql: "ALTER TABLE memoryUnits ADD COLUMN forgottenAt DATETIME")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, memorySpaceId FROM workspaces WHERE removedAt IS NULL ORDER BY position, createdAt")
            var users: [String: [(id: String, name: String)]] = [:], order: [String] = []
            for row in rows {
                let space: String = row["memorySpaceId"]
                if users[space] == nil { order.append(space) }
                users[space, default: []].append((row["id"], row["name"]))
            }
            let hindsight = try String.fetchOne(db, sql: "SELECT engine FROM memorySettings WHERE id = 1") == "hindsight"
            for space in order {
                for workspace in users[space]!.dropFirst() {
                    let copy = try createMemorySpace(db, name: workspace.name)
                    try copyMemory(db, from: space, to: copy.id)
                    try db.execute(sql: "UPDATE workspaces SET memorySpaceId = ? WHERE id = ?", arguments: [copy.id, workspace.id])
                    try moveTaskSources(db, ofWorkspace: workspace.id, to: copy.id, relearn: hindsight)
                }
            }
            try db.execute(sql: """
                UPDATE memorySpaces SET name = (SELECT w.name FROM workspaces w WHERE w.memorySpaceId = memorySpaces.id AND w.removedAt IS NULL ORDER BY w.position, w.createdAt LIMIT 1)
                WHERE EXISTS (SELECT 1 FROM workspaces w WHERE w.memorySpaceId = memorySpaces.id AND w.removedAt IS NULL)
                """)
        }
    }

    /// Everything one memory holds, under new identities in another: notes with their corrections, learned units with
    /// their search text, entities, links and history.
    static func copyMemory(_ db: Database, from source: String, to target: String) throws {
        let notes = try Row.fetchAll(db, sql: "SELECT * FROM memoryFacts WHERE spaceId = ?", arguments: [source])
        let noteIDs = Dictionary(uniqueKeysWithValues: notes.map { ($0["id"] as String, UUID().uuidString) })
        try copyRows(db, table: "memoryFacts", rows: notes) { column, value in
            switch column {
            case "id": return String.fromDatabaseValue(value).flatMap { noteIDs[$0] } ?? value
            case "spaceId": return target
            case "supersededBy": return String.fromDatabaseValue(value).flatMap { noteIDs[$0] }
            default: return value
            }
        }
        let units = try Row.fetchAll(db, sql: "SELECT * FROM memoryUnits WHERE spaceId = ?", arguments: [source])
        // A note's unit keeps the note's new identity, so the sync recognises it.
        let unitIDs = Dictionary(uniqueKeysWithValues: units.map { row -> (String, String) in
            let id: String = row["id"]
            return (id, id.hasPrefix("note-") ? "note-" + (noteIDs[String(id.dropFirst(5))] ?? UUID().uuidString) : UUID().uuidString)
        })
        func remapped(_ json: String?) -> String? {
            guard let json, let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)),
                  let data = try? JSONEncoder().encode(ids.map { unitIDs[$0] ?? $0 }) else { return json }
            return String(decoding: data, as: UTF8.self)
        }
        try copyRows(db, table: "memoryUnits", rows: units) { column, value in
            switch column {
            case "id": return String.fromDatabaseValue(value).flatMap { unitIDs[$0] } ?? value
            case "spaceId": return target
            case "sourceIds": return remapped(String.fromDatabaseValue(value))
            default: return value
            }
        }
        for (old, new) in unitIDs {
            if let body = try String.fetchOne(db, sql: "SELECT body FROM memoryUnitSearch WHERE unitId = ?", arguments: [old]) {
                try db.execute(sql: "INSERT INTO memoryUnitSearch (unitId, body) VALUES (?, ?)", arguments: [new, body])
            }
        }
        let entities = try Row.fetchAll(db, sql: "SELECT * FROM memoryEntities WHERE spaceId = ?", arguments: [source])
        let entityIDs = Dictionary(uniqueKeysWithValues: entities.map { ($0["id"] as String, UUID().uuidString) })
        try copyRows(db, table: "memoryEntities", rows: entities) { column, value in
            switch column {
            case "id": return String.fromDatabaseValue(value).flatMap { entityIDs[$0] } ?? value
            case "spaceId": return target
            default: return value
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT ue.unitId, ue.entityId FROM memoryUnitEntities ue JOIN memoryUnits u ON u.id = ue.unitId WHERE u.spaceId = ?", arguments: [source]) {
            guard let unit = unitIDs[row["unitId"]], let entity = entityIDs[row["entityId"]] else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO memoryUnitEntities (unitId, entityId) VALUES (?, ?)", arguments: [unit, entity])
        }
        for row in try Row.fetchAll(db, sql: "SELECT p.* FROM memoryEntityPairs p JOIN memoryEntities e ON e.id = p.a WHERE e.spaceId = ?", arguments: [source]) {
            guard let a = entityIDs[row["a"]], let b = entityIDs[row["b"]] else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO memoryEntityPairs (a, b, count, lastSeen) VALUES (?, ?, ?, ?)", arguments: [a, b, row["count"] as Int, row["lastSeen"] as Date])
        }
        for row in try Row.fetchAll(db, sql: "SELECT l.* FROM memoryLinks l JOIN memoryUnits u ON u.id = l.fromId WHERE u.spaceId = ?", arguments: [source]) {
            guard let from = unitIDs[row["fromId"]], let to = unitIDs[row["toId"]] else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO memoryLinks (fromId, toId, kind, weight) VALUES (?, ?, ?, ?)", arguments: [from, to, row["kind"] as String, row["weight"] as Double])
        }
        for row in try Row.fetchAll(db, sql: "SELECT h.* FROM memoryObservationHistory h JOIN memoryUnits u ON u.id = h.observationId WHERE u.spaceId = ?", arguments: [source]) {
            guard let observation = unitIDs[row["observationId"]] else { continue }
            try db.execute(sql: "INSERT INTO memoryObservationHistory (id, observationId, text, sourceIds, changedAt) VALUES (?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, observation, row["text"] as String, remapped(row["sourceIds"]), row["changedAt"] as Date])
        }
    }

    /// Inserts copies of rows into their own table, with each column's value passed through `map`.
    private static func copyRows(_ db: Database, table: String, rows: [Row], map: (String, DatabaseValue) -> DatabaseValueConvertible?) throws {
        guard let first = rows.first else { return }
        let columns = first.columnNames.map { String($0) }
        let sql = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
        for row in rows {
            var values: [DatabaseValueConvertible?] = []
            for column in columns { values.append(map(column, row[column])) }
            try db.execute(sql: sql, arguments: StatementArguments(values))
        }
    }

    /// A workspace's own task sources go to its memory. With Hindsight, the new bank has to learn them again.
    private static func moveTaskSources(_ db: Database, ofWorkspace workspace: String, to target: String, relearn: Bool) throws {
        try db.execute(sql: """
            UPDATE memoryDocuments SET spaceId = ? WHERE id IN (
              SELECT 'task-' || id FROM tasks WHERE workspaceId = ?
              UNION SELECT 'event-' || e.id FROM events e JOIN tasks t ON t.id = e.taskId WHERE t.workspaceId = ?
              UNION SELECT 'decision-' || d.id FROM decisions d JOIN tasks t ON t.id = d.taskId WHERE t.workspaceId = ?)
            """, arguments: [target, workspace, workspace, workspace])
        try db.execute(sql: "UPDATE memoryRetained SET spaceId = ? WHERE documentId IN (SELECT id FROM memoryDocuments WHERE spaceId = ?)", arguments: [target, target])
        try db.execute(sql: "UPDATE memoryChunks SET spaceId = ? WHERE documentId IN (SELECT id FROM memoryDocuments WHERE spaceId = ?)", arguments: [target, target])
        guard relearn else { return }
        for id in try String.fetchAll(db, sql: "SELECT id FROM memoryDocuments WHERE spaceId = ?", arguments: [target]) {
            try db.execute(sql: "UPDATE memoryDocuments SET state = 'pending', operationId = ?, leaseUntil = NULL, attempts = 0, nextAttempt = ?, error = NULL WHERE id = ?", arguments: [UUID().uuidString, Date(), id])
        }
    }

    // MARK: Notes and rules

    /// The kinds a note can have. A rule is a standing instruction: once the user confirms it, every task is told it word
    /// for word; before that it is a proposal.
    public static let noteKinds = ["fact", "preference", "person", "procedure", "rule"]
    public static let ruleKind = "rule"

    /// Current notes of one memory: the one named, or the scoped workspace's.
    public func memory(search: String = "", spaceID: String? = nil) throws -> [MemoryFact] {
        try db.read { db in
            var query = MemoryFact.filter(Column("supersededBy") == nil).filter(Column("forgottenAt") == nil).filter(Column("spaceId") == (try resolveSpace(db, spaceID)))
            if !search.isEmpty { query = query.filter(Column("text").like(Self.likePattern(search), escape: "\\")) }
            return try query.order(Column("createdAt").desc).fetchAll(db)
        }
    }
    public func allMemory(spaceID: String? = nil) throws -> [MemoryFact] { try memory(spaceID: spaceID) }
    /// The workspace's rules in the order they were made: the confirmed ones, which every task is told.
    public func rules(spaceID: String? = nil) throws -> [MemoryFact] {
        try memory(spaceID: spaceID).filter { $0.kind == Self.ruleKind && $0.confirmedAt != nil }.sorted { $0.createdAt < $1.createdAt }
    }
    /// A note joins the memory it names, else its task's memory, else the scoped workspace's. Nothing is filed by guesswork.
    public func remember(_ fact: MemoryFact, source: EventSource = .mcp) throws {
        guard !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !fact.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Memory needs both text and a source.") }
        guard fact.originScope == "workspace", Self.noteKinds.contains(fact.kind) else { throw StoreError.invalid("Use a valid memory kind: \(Self.noteKinds.joined(separator: ", ")). New memory belongs to this workspace.") }
        try write { db in
            var fact = fact
            fact.text = MemoryRedaction.redact(fact.text)
            fact.source = MemoryRedaction.redact(fact.source)
            if source == .mcp { fact.confirmedAt = nil; fact.supersededBy = nil }
            if let spaceId = fact.spaceId { _ = try Self.memorySpace(db, spaceId) }
            else if let taskId = fact.taskId, workspaceID == nil { fact.spaceId = try Self.spaceID(db, taskID: taskId) }
            else { fact.spaceId = try resolveSpace(db, nil) }
            try fact.insert(db)
            try TaskEvent(taskId: fact.taskId, source: source, kind: "memory.remembered", payload: fact.id).insert(db)
        }
    }
    /// Moves a note to another workspace's memory, for one that was saved in the wrong place.
    public func moveMemory(_ id: String, toSpace spaceID: String) throws {
        try write { db in
            guard var fact = try MemoryFact.fetchOne(db, key: id), fact.supersededBy == nil else { throw StoreError.notFound }
            fact.spaceId = try Self.memorySpace(db, spaceID).id
            try fact.update(db)
            try TaskEvent(source: .user, kind: "memory.moved", payload: id).insert(db)
        }
    }
    public func confirmMemory(_ id: String) throws {
        try write { db in
            guard var fact = try MemoryFact.fetchOne(db, key: id), fact.supersededBy == nil else { throw StoreError.notFound }
            fact.confirmedAt = Date(); try fact.update(db)
            try TaskEvent(source: .user, kind: "memory.confirmed", payload: id).insert(db)
        }
    }
    public func correctMemory(_ id: String, text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Memory cannot be empty.") }
        try write { db in
            guard var old = try MemoryFact.fetchOne(db, key: id), old.supersededBy == nil else { throw StoreError.conflict }
            var replacement = MemoryFact(kind: old.kind, text: MemoryRedaction.redact(text), taskId: old.taskId, source: MemoryRedaction.redact("User correction of \(old.id); original source: \(old.source)"))
            replacement.originScope = old.originScope; replacement.spaceId = old.spaceId
            // A corrected rule keeps its place in the list.
            if old.kind == Self.ruleKind { replacement.createdAt = old.createdAt }
            replacement.confirmedAt = Date(); try replacement.insert(db)
            old.supersededBy = replacement.id; try old.update(db)
            try TaskEvent(source: .user, kind: "memory.corrected", payload: replacement.id).insert(db)
        }
    }
    /// Removes a note, or a proposal, for good. Its earlier wordings go with it; the next sync drops its searchable copy.
    public func forgetMemory(_ id: String) throws {
        try write { db in
            guard try MemoryFact.fetchOne(db, key: id) != nil else { throw StoreError.notFound }
            var ids = [id]
            while let earlier = try String.fetchOne(db, sql: "SELECT id FROM memoryFacts WHERE supersededBy = ?", arguments: [ids.last!]) { ids.append(earlier) }
            for id in ids.reversed() { try db.execute(sql: "DELETE FROM memoryFacts WHERE id = ?", arguments: [id]) }
            try TaskEvent(source: .user, kind: "memory.forgotten", payload: id).insert(db)
        }
    }
}
