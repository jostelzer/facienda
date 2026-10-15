import Foundation
import GRDB

/// A folder the user linked to a group, usually a repository: the group's tasks do their work inside it.
public struct GroupFolder: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "groupFolders"
    public var groupId: String
    public var path: String
    /// The folder's place in the group. The first one is the primary folder.
    public var position: Int
}

/// Reading linked folders straight from disk, without running git.
public enum LinkedFolder {
    /// What linking a picked folder links: the repository it sits in, or the folder itself outside one.
    public static func root(of path: String) -> String {
        let picked = URL(fileURLWithPath: path).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var folder = picked
        while folder.path != "/" && folder.path != home {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) { return folder.path }
            folder = folder.deletingLastPathComponent()
        }
        return picked.path
    }

    public static func name(of path: String) -> String { URL(fileURLWithPath: path, isDirectory: true).lastPathComponent }

    static func exists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

extension FaciendaStore {
    static func registerGroupFolders(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("group_folders") { db in
            try db.execute(sql: """
            CREATE TABLE groupFolders (
              groupId TEXT NOT NULL REFERENCES taskGroups(id) ON DELETE CASCADE, path TEXT NOT NULL, position INTEGER NOT NULL,
              PRIMARY KEY (groupId, path)
            );
            ALTER TABLE taskGroups ADD COLUMN codexProjectId TEXT;
            ALTER TABLE taskGroups ADD COLUMN codexProjectOwned BOOLEAN;
            ALTER TABLE tasks ADD COLUMN folders TEXT;
            """)
        }
    }

    /// Each group's linked folders in order, for the scoped workspace or the whole library. Groups without links are absent.
    public func groupFolders() throws -> [String: [String]] {
        try db.read { db in
            let rows = try workspaceID.map {
                try GroupFolder.fetchAll(db, sql: "SELECT f.* FROM groupFolders f JOIN taskGroups g ON g.id = f.groupId WHERE g.workspaceId = ? ORDER BY f.position", arguments: [$0])
            } ?? GroupFolder.fetchAll(db, sql: "SELECT * FROM groupFolders ORDER BY position")
            return Dictionary(grouping: rows, by: \.groupId).mapValues { $0.map(\.path) }
        }
    }

    public func folders(groupId: String) throws -> [String] {
        try db.read { try Self.folders($0, groupId: groupId) }
    }

    static func folders(_ db: Database, groupId: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT path FROM groupFolders WHERE groupId = ? ORDER BY position", arguments: [groupId])
    }

    /// Links a folder to a group, after the ones already linked. A folder inside a repository links the whole repository.
    /// A Google Drive folder becomes a source the tasks read instead: anything written there syncs to other people at once.
    /// Returns the folder actually linked.
    @discardableResult public func linkFolder(_ path: String, groupId: String) throws -> String {
        let root = LinkedFolder.root(of: path)
        guard LinkedFolder.exists(root) else { throw StoreError.invalid("Link a folder that exists on this Mac.") }
        if LinkedSource.isCloudDrive(root) { return try linkSource(root, groupId: groupId).address }
        guard !isFaciendaFolder(root) else { throw StoreError.invalid("That is one of Facienda’s own folders. Link a project folder instead.") }
        try write { db in
            guard try TaskGroup.fetchOne(db, key: groupId) != nil else { throw StoreError.notFound }
            let linked = try Self.folders(db, groupId: groupId)
            guard !linked.contains(root) else { return }
            try GroupFolder(groupId: groupId, path: root, position: linked.count).insert(db)
        }
        return root
    }

    public func unlinkFolder(_ path: String, groupId: String) throws {
        try write { db in
            let rest = try Self.folders(db, groupId: groupId).filter { $0 != path }
            try Self.order(db, groupId: groupId, rest)
        }
    }

    /// Moves a linked folder to the front: new chats for the group's tasks start from it.
    public func makePrimaryFolder(_ path: String, groupId: String) throws {
        try write { db in
            let linked = try Self.folders(db, groupId: groupId)
            guard linked.contains(path) else { throw StoreError.notFound }
            try Self.order(db, groupId: groupId, [path] + linked.filter { $0 != path })
        }
    }

    private static func order(_ db: Database, groupId: String, _ paths: [String]) throws {
        try db.execute(sql: "DELETE FROM groupFolders WHERE groupId = ?", arguments: [groupId])
        for (position, path) in paths.enumerated() { try GroupFolder(groupId: groupId, path: path, position: position).insert(db) }
    }

    /// The Codex project covering the group's folders. Owned means Facienda made it, so Facienda may change its folders.
    public func setCodexProject(groupId: String, id: String?, owned: Bool) throws {
        try write { db in
            try db.execute(sql: "UPDATE taskGroups SET codexProjectId = ?, codexProjectOwned = ? WHERE id = ?", arguments: [id, id == nil ? nil : owned, groupId])
        }
    }

    /// The group's Codex project, when the task still works in exactly the folders the group links now.
    static func linkedProjectId(_ db: Database, task: FaciendaTask) throws -> String? {
        guard let folders = task.folders, !folders.isEmpty,
              let group = try String.fetchOne(db, sql: "SELECT groupId FROM taskGroupMembers WHERE taskId = ?", arguments: [task.id]),
              try Set(Self.folders(db, groupId: group)) == Set(folders) else { return nil }
        return try String.fetchOne(db, sql: "SELECT codexProjectId FROM taskGroups WHERE id = ?", arguments: [group])
    }

    public func linkedProjectId(task: FaciendaTask) throws -> String? {
        try db.read { try Self.linkedProjectId($0, task: task) }
    }

    /// Settles where a starting task works. A folder the user chose, or a task that already has a chat, stays as it is.
    /// Otherwise the task takes its group's linked folders: it works in a single one directly, and from its own folder
    /// across several. A task in a group without links gets its own folder, as before.
    @discardableResult public func prepareWorkingFolder(taskId: String) throws -> FaciendaTask {
        var task = try self.task(taskId)
        let automatic = task.cwd.map { isAutomaticWorkingDirectory($0, taskID: task.id) } ?? true
        if automatic, task.folders == nil {
            let linked = try db.read { db -> [String] in
                guard try ThreadLink.filter(Column("taskId") == taskId).fetchCount(db) == 0,
                      let group = try String.fetchOne(db, sql: "SELECT groupId FROM taskGroupMembers WHERE taskId = ?", arguments: [taskId]) else { return [] }
                return try Self.folders(db, groupId: group)
            }
            if let missing = linked.first(where: { !LinkedFolder.exists($0) }) {
                throw StoreError.invalid("The folder “\(LinkedFolder.name(of: missing))” linked to this task’s group is unavailable. Reconnect it, or unlink it from the group.")
            }
            if !linked.isEmpty {
                task = try update(task.id) { $0.folders = linked; if linked.count == 1 { $0.cwd = linked[0] } }
            }
        }
        // Task folders are this account's alone, like the data folder they sit in.
        if task.cwd == nil {
            let folder = taskFolder(task.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            task = try update(task.id) { $0.cwd = folder.path }
        } else if automatic, !FileManager.default.fileExists(atPath: task.cwd!) {
            // Its own folder was cleared to free space: it starts again empty.
            try FileManager.default.createDirectory(atPath: task.cwd!, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if !FileManager.default.fileExists(atPath: task.cwd!) {
            throw StoreError.invalid("This task’s working folder is unavailable. Choose another folder in Edit task.")
        }
        return task
    }
}
