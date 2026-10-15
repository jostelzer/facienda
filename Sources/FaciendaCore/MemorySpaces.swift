import Foundation
import GRDB

/// A memory of its own: a separate Hindsight bank and separate confirmed notes.
/// Workspaces that share a memory share what they learn; nothing crosses between memories.
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

    @discardableResult public func createMemorySpace(name: String) throws -> MemorySpace {
        let name = try Self.validatedName(name, "memory")
        return try write { db in
            try Self.requireUniqueSpaceName(db, name, except: nil)
            let position = try Self.nextPosition(db, in: "memorySpaces")
            let space = MemorySpace(id: UUID().uuidString, name: name, bankId: "facienda-" + UUID().uuidString.lowercased(), position: position, createdAt: Date())
            try space.insert(db)
            return space
        }
    }

    public func renameMemorySpace(_ id: String, to name: String) throws {
        let name = try Self.validatedName(name, "memory")
        try write { db in
            var space = try Self.memorySpace(db, id)
            try Self.requireUniqueSpaceName(db, name, except: id)
            space.name = name
            try space.update(db)
        }
    }

    private static func requireUniqueSpaceName(_ db: Database, _ name: String, except id: String?) throws {
        let taken = try Int.fetchOne(db, sql: "SELECT count(*) FROM memorySpaces WHERE name = ? COLLATE NOCASE AND id != ?", arguments: [name, id ?? ""]) ?? 0
        guard taken == 0 else { throw StoreError.invalid("You already have a memory called “\(name)”.") }
    }

    /// Deletes a memory nobody uses, with its confirmed notes, its sources and everything it learned.
    public func deleteMemorySpace(_ id: String) throws {
        try write { db in
            let space = try Self.memorySpace(db, id)
            let users = try String.fetchAll(db, sql: "SELECT name FROM workspaces WHERE memorySpaceId = ? AND removedAt IS NULL", arguments: [id])
            guard users.isEmpty else {
                throw StoreError.invalid("“\(space.name)” is still used by \(users.joined(separator: ", ")). Choose another memory for \(users.count == 1 ? "it" : "them") first.")
            }
            let fallback = try Self.defaultWorkspace(db).memorySpaceId
            try db.execute(sql: "UPDATE workspaces SET memorySpaceId = ? WHERE memorySpaceId = ?", arguments: [fallback, id])
            try db.execute(sql: "UPDATE memoryFacts SET supersededBy = NULL WHERE supersededBy IN (SELECT id FROM memoryFacts WHERE spaceId = ?)", arguments: [id])
            try db.execute(sql: "DELETE FROM memoryFacts WHERE spaceId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memoryDocuments WHERE spaceId = ?", arguments: [id])
            try Self.clearNativeMemory(db, spaceID: id)
            _ = try MemorySpace.deleteOne(db, key: id)
        }
    }

    /// From now on the workspace learns into and recalls from this memory. Earlier learning stays where it was.
    public func setMemorySpace(workspaceID: String, spaceID: String) throws {
        try write { db in
            var workspace = try Self.workspace(db, workspaceID)
            _ = try Self.memorySpace(db, spaceID)
            guard workspace.memorySpaceId != spaceID else { return }
            workspace.memorySpaceId = spaceID
            try workspace.update(db)
        }
    }

    public func markSpaceConfigured(_ spaceID: String, endpoint: String) throws {
        try write { try $0.execute(sql: "UPDATE memorySpaces SET configuredEndpoint = ? WHERE id = ?", arguments: [endpoint, spaceID]) }
    }

    // MARK: Notes

    /// Current notes of one memory: the one named, or the scoped workspace's.
    public func memory(search: String = "", spaceID: String? = nil) throws -> [MemoryFact] {
        try db.read { db in
            var query = MemoryFact.filter(Column("supersededBy") == nil).filter(Column("spaceId") == (try resolveSpace(db, spaceID)))
            if !search.isEmpty { query = query.filter(Column("text").like(Self.likePattern(search), escape: "\\")) }
            return try query.order(Column("createdAt").desc).fetchAll(db)
        }
    }
    public func allMemory(spaceID: String? = nil) throws -> [MemoryFact] { try memory(spaceID: spaceID) }
    /// A note joins the memory it names, else its task's memory, else the scoped workspace's. Nothing is filed by guesswork.
    public func remember(_ fact: MemoryFact, source: EventSource = .mcp) throws {
        guard !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !fact.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Memory needs both text and a source.") }
        guard fact.originScope == "workspace", ["fact", "preference", "person", "procedure"].contains(fact.kind) else { throw StoreError.invalid("Use a valid memory kind. New memory belongs to this workspace.") }
        try write { db in
            var fact = fact
            if source == .mcp { fact.confirmedAt = nil; fact.supersededBy = nil }
            if let spaceId = fact.spaceId { _ = try Self.memorySpace(db, spaceId) }
            else if let taskId = fact.taskId, workspaceID == nil { fact.spaceId = try Self.spaceID(db, taskID: taskId) }
            else { fact.spaceId = try resolveSpace(db, nil) }
            try fact.insert(db)
            try TaskEvent(taskId: fact.taskId, source: source, kind: "memory.remembered", payload: fact.id).insert(db)
        }
    }
    /// Moves a note to another memory, for one that was saved in the wrong place.
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
            var replacement = MemoryFact(kind: old.kind, text: text, taskId: old.taskId, source: "User correction of \(old.id); original source: \(old.source)")
            replacement.originScope = old.originScope; replacement.spaceId = old.spaceId
            replacement.confirmedAt = Date(); try replacement.insert(db)
            old.supersededBy = replacement.id; try old.update(db)
            try TaskEvent(source: .user, kind: "memory.corrected", payload: replacement.id).insert(db)
        }
    }
}
