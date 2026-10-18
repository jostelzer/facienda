import Foundation
import GRDB

/// A named set of tasks in the library. Every workspace has a memory of its own, made with it and named after it.
public struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Hashable, Sendable {
    public static let databaseTableName = "workspaces"
    public var id: String
    public var name: String
    public var memorySpaceId: String
    public var position: Int
    public var createdAt: Date
    public var nameUpdatedAt: Date
    /// Removed workspaces stay as tombstones so their IDs cannot be reused.
    public var removedAt: Date?
    /// The painting style Codex chose for the sidebar picture, kept so a repaint stays recognisable.
    public var coverStyle: String?
    /// nil until a picture has been painted. The image itself lives beside the library.
    public var coverPaintedAt: Date?
    /// The user's standing wishes for the picture, one per line. Every repaint honours them.
    public var coverNotes: String?
    public var coverNoteList: [String] { (coverNotes ?? "").split(whereSeparator: \.isNewline).map(String.init) }
}

extension FaciendaStore {
    static func registerLibrary(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("library_workspaces") { db in
            try db.execute(sql: """
            CREATE TABLE memorySpaces (
              id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, bankId TEXT NOT NULL UNIQUE,
              position INTEGER NOT NULL, createdAt DATETIME NOT NULL, configuredEndpoint TEXT
            );
            CREATE TABLE workspaces (
              id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, memorySpaceId TEXT NOT NULL REFERENCES memorySpaces(id),
              position INTEGER NOT NULL, createdAt DATETIME NOT NULL, nameUpdatedAt DATETIME NOT NULL,
              removedAt DATETIME, legacyDatabasePath TEXT
            );
            CREATE TABLE libraryState (id INTEGER PRIMARY KEY CHECK(id = 1), catalogAdoptedAt DATETIME);
            INSERT INTO libraryState(id) VALUES (1);
            CREATE TABLE libraryMerge (id INTEGER PRIMARY KEY CHECK(id = 1), libraryPath TEXT NOT NULL, state TEXT NOT NULL, at DATETIME NOT NULL);
            ALTER TABLE tasks ADD COLUMN workspaceId TEXT;
            ALTER TABLE taskGroups ADD COLUMN workspaceId TEXT;
            ALTER TABLE memoryFacts ADD COLUMN spaceId TEXT;
            ALTER TABLE memoryDocuments ADD COLUMN spaceId TEXT;
            ALTER TABLE memoryDocuments ADD COLUMN externalId TEXT;
            CREATE INDEX tasks_workspace ON tasks(workspaceId);
            CREATE INDEX groups_workspace ON taskGroups(workspaceId);
            CREATE INDEX memory_facts_space ON memoryFacts(spaceId);
            CREATE INDEX memory_documents_space ON memoryDocuments(spaceId, state);
            """)
            // Everything already here becomes the first workspace, keeping its memory bank.
            let settings = try Row.fetchOne(db, sql: "SELECT bankId, endpoint, configured FROM memorySettings WHERE id = 1")
            let now = Date(), space = UUID().uuidString, workspace = UUID().uuidString
            let bank: String = settings?["bankId"] ?? "facienda-" + UUID().uuidString.lowercased()
            let configured: Bool = settings?["configured"] ?? false
            let endpoint: String? = configured ? settings?["endpoint"] : nil
            try db.execute(sql: "INSERT INTO memorySpaces(id, name, bankId, position, createdAt, configuredEndpoint) VALUES (?, 'Personal', ?, 0, ?, ?)",
                           arguments: [space, bank, now, endpoint])
            try db.execute(sql: "INSERT INTO workspaces(id, name, memorySpaceId, position, createdAt, nameUpdatedAt) VALUES (?, 'My workspace', ?, 0, ?, ?)",
                           arguments: [workspace, space, now, now])
            try db.execute(sql: "UPDATE tasks SET workspaceId = ?", arguments: [workspace])
            try db.execute(sql: "UPDATE taskGroups SET workspaceId = ?", arguments: [workspace])
            try db.execute(sql: "UPDATE memoryFacts SET spaceId = ?", arguments: [space])
            try db.execute(sql: "UPDATE memoryDocuments SET spaceId = ?", arguments: [space])
            // Curated notes are one document per memory now. Hindsight keeps knowing it by its old ID.
            try db.execute(sql: "UPDATE memoryDocuments SET id = ?, externalId = 'curated-workspace-notes' WHERE id = 'curated-workspace-notes'",
                           arguments: [Self.curatedNotesID(space)])
            // Work created by older helpers or the runner lands in the first workspace rather than nowhere.
            try db.execute(sql: """
            CREATE TRIGGER task_default_workspace AFTER INSERT ON tasks WHEN new.workspaceId IS NULL BEGIN
              UPDATE tasks SET workspaceId = (SELECT id FROM workspaces WHERE removedAt IS NULL ORDER BY position, createdAt LIMIT 1) WHERE id = new.id;
            END;
            CREATE TRIGGER group_default_workspace AFTER INSERT ON taskGroups WHEN new.workspaceId IS NULL BEGIN
              UPDATE taskGroups SET workspaceId = (SELECT id FROM workspaces WHERE removedAt IS NULL ORDER BY position, createdAt LIMIT 1) WHERE id = new.id;
            END;
            """)
        }
    }

    static func registerWorkspaceCovers(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("workspace_covers") { db in
            try db.execute(sql: """
            ALTER TABLE workspaces ADD COLUMN coverStyle TEXT;
            ALTER TABLE workspaces ADD COLUMN coverPaintedAt DATETIME;
            ALTER TABLE workspaces ADD COLUMN coverNotes TEXT;
            """)
        }
    }

    static func curatedNotesID(_ spaceID: String) -> String { "curated-notes-" + spaceID }

    /// The place after the last row of a table, or of one workspace's rows. New things join the end.
    static func nextPosition(_ db: Database, in table: String, workspaceID: String? = nil) throws -> Int {
        guard let workspaceID else { return try Int.fetchOne(db, sql: "SELECT coalesce(max(position), -1) + 1 FROM \(table)") ?? 0 }
        return try Int.fetchOne(db, sql: "SELECT coalesce(max(position), -1) + 1 FROM \(table) WHERE workspaceId = ?", arguments: [workspaceID]) ?? 0
    }

    static func validatedName(_ raw: String, _ subject: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalid("Give your \(subject) a name.") }
        guard !name.contains(where: { $0.isNewline }), name.count <= 60 else { throw StoreError.invalid("Use a short, single-line name for the \(subject).") }
        return name
    }

    // MARK: Workspaces

    public func workspaces(includeRemoved: Bool = false) throws -> [Workspace] {
        try db.read { db in
            try Workspace.fetchAll(db, sql: "SELECT * FROM workspaces \(includeRemoved ? "" : "WHERE removedAt IS NULL") ORDER BY position, createdAt")
        }
    }

    public func workspace(_ id: String) throws -> Workspace {
        try db.read { db in try Self.workspace(db, id) }
    }

    static func workspace(_ db: Database, _ id: String) throws -> Workspace {
        guard let workspace = try Workspace.fetchOne(db, key: id) else { throw StoreError.invalid("This workspace is no longer in your library.") }
        return workspace
    }

    /// Where work goes when nothing names a workspace.
    public func defaultWorkspace() throws -> Workspace {
        try db.read { db in try Self.defaultWorkspace(db) }
    }

    static func defaultWorkspace(_ db: Database) throws -> Workspace {
        guard let workspace = try Workspace.fetchOne(db, sql: "SELECT * FROM workspaces WHERE removedAt IS NULL ORDER BY position, createdAt LIMIT 1") else {
            throw StoreError.invalid("Create a workspace to get started.")
        }
        return workspace
    }

    /// A new workspace starts with an empty memory of its own.
    @discardableResult public func createWorkspace(name: String, id: String = UUID().uuidString, nameUpdatedAt: Date = Date()) throws -> Workspace {
        let name = try Self.validatedName(name, "workspace")
        return try write { db in
            if let existing = try Workspace.fetchOne(db, key: id) { return existing }
            let space = try Self.createMemorySpace(db, name: name)
            let position = try Self.nextPosition(db, in: "workspaces")
            let workspace = Workspace(id: id, name: name, memorySpaceId: space.id, position: position, createdAt: Date(), nameUpdatedAt: nameUpdatedAt)
            try workspace.insert(db)
            return workspace
        }
    }

    /// Renaming changes only the display name; tasks, chats and memory stay where they are. The memory takes the new name.
    public func renameWorkspace(_ id: String, to name: String, updatedAt: Date = Date()) throws {
        let name = try Self.validatedName(name, "workspace")
        try write { db in
            var workspace = try Self.workspace(db, id)
            guard workspace.name != name else { return }
            workspace.name = name; workspace.nameUpdatedAt = updatedAt
            try workspace.update(db)
            try db.execute(sql: "UPDATE memorySpaces SET name = ? WHERE id = ?", arguments: [name, workspace.memorySpaceId])
        }
    }

    /// Hides a workspace. Its finished tasks stay in the library file; open work must move or finish first.
    public func removeWorkspace(_ id: String) throws {
        try write { db in
            var workspace = try Self.workspace(db, id)
            guard workspace.removedAt == nil else { return }
            let others = try Int.fetchOne(db, sql: "SELECT count(*) FROM workspaces WHERE removedAt IS NULL AND id != ?", arguments: [id]) ?? 0
            guard others > 0 else { throw StoreError.invalid("Keep at least one workspace. Create another before deleting this one.") }
            let open = try Int.fetchOne(db, sql: "SELECT count(*) FROM tasks WHERE workspaceId = ? AND state NOT IN ('done', 'dropped')", arguments: [id]) ?? 0
            guard open == 0 else {
                throw StoreError.invalid("“\(workspace.name)” still has \(open) open \(open == 1 ? "task" : "tasks"). Finish them or move them to another workspace first.")
            }
            workspace.removedAt = Date()
            try workspace.update(db)
        }
        try? FileManager.default.removeItem(at: coverURL(workspaceId: id))
        try? FileManager.default.removeItem(at: previousCoverURL(workspaceId: id))
    }

    // MARK: Moving work between workspaces

    /// A group moves whole: its tasks, their chats and history go with it and keep running.
    /// What was already learned stays in the memory it was learned in; new learning goes to the new one.
    public func moveGroup(_ groupID: String, toWorkspace targetID: String) throws {
        try write { db in
            guard var group = try TaskGroup.fetchOne(db, key: groupID) else { throw StoreError.notFound }
            let target = try Self.availableWorkspace(db, targetID)
            guard group.workspaceId != target.id else { return }
            group.workspaceId = target.id; group.lane = nil; group.row = nil
            group.position = try Self.nextPosition(db, in: "taskGroups", workspaceID: target.id)
            try group.update(db)
            let members = try String.fetchAll(db, sql: "SELECT taskId FROM taskGroupMembers WHERE groupId = ?", arguments: [groupID])
            for id in members { try Self.setWorkspace(db, taskID: id, to: target) }
        }
    }

    /// Removes a task and everything Facienda keeps about it, however stuck it is. The Codex chat itself is untouched,
    /// and memories learned from the task stay, just no longer tied to it.
    public func deleteTask(_ id: String) throws {
        let dispatchIDs = try write { db in
            guard try FaciendaTask.fetchOne(db, key: id) != nil else { throw StoreError.notFound }
            let dispatchIDs = try String.fetchAll(db, sql: "SELECT id FROM dispatches WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(sql: "UPDATE memoryFacts SET taskId = NULL WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "UPDATE events SET taskId = NULL WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM taskBlockers WHERE prerequisiteId = ?", arguments: [id])
            // Tables that hang off a dispatch go first, then every other table keyed by the task.
            try db.execute(sql: "DELETE FROM dispatchContext WHERE taskId = ? OR dispatchId IN (SELECT id FROM dispatches WHERE taskId = ?)", arguments: [id, id])
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'taskSearch%' AND name NOT LIKE 'threadSearch%'")
            for table in tables where !["tasks", "dispatchContext", "memoryFacts", "events"].contains(table) {
                let columns = try db.columns(in: table).map(\.name)
                if columns.contains("taskId") {
                    try db.execute(sql: "DELETE FROM \"\(table)\" WHERE taskId = ?", arguments: [id])
                }
            }
            try db.execute(sql: "DELETE FROM taskSearch WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
            return dispatchIDs
        }
        // The runner's files for the task go too, or a later request would follow the deleted task's receipt.
        // They are rebuilt from the database, so undoing the delete loses nothing.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: runnerHandoffDirectory.path)) ?? []
        let names = Set(["context-\(id).json"] + dispatchIDs.map { "-\($0).json" })
        for file in files where names.contains(where: { $0.hasPrefix("context-") ? file == $0 : file.hasSuffix($0) }) {
            try? FileManager.default.removeItem(at: runnerHandoffDirectory.appending(path: file))
        }
    }

    /// Discovery receipts and prepared deliveries the runner reads from disk.
    public var runnerHandoffDirectory: URL { url.deletingLastPathComponent().appending(path: "runner-handoffs") }

    private static func availableWorkspace(_ db: Database, _ id: String) throws -> Workspace {
        let workspace = try Self.workspace(db, id)
        guard workspace.removedAt == nil else { throw StoreError.invalid("That workspace is no longer available.") }
        return workspace
    }

    /// Moving never changes a task's revision or activity date, like regrouping.
    private static func setWorkspace(_ db: Database, taskID: String, to target: Workspace) throws {
        try db.execute(sql: "UPDATE tasks SET workspaceId = ? WHERE id = ?", arguments: [target.id, taskID])
        try TaskEvent(taskId: taskID, source: .user, kind: "task.moved", payload: target.name).insert(db)
    }
}
