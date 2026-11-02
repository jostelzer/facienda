import Foundation
import GRDB

/// A folder the user linked to a workspace, usually a repository: the workspace's tasks do their work inside it.
public struct WorkspaceFolder: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "workspaceFolders"
    public var workspaceId: String
    public var path: String
    /// The folder's place in the workspace. The first one is the primary folder.
    public var position: Int
}

/// One of its workspace's folders a group chose to work in, instead of where the workspace works.
public struct GroupFolder: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "groupFolders"
    public var groupId: String
    public var path: String
    /// The folder's place in the group's choice. The first one is the primary folder.
    public var position: Int
}

/// Where a group's tasks work.
public enum GroupWorkPlace: Equatable, Sendable {
    /// Where the workspace works: its folder when it has exactly one, otherwise each task's own folder.
    case workspace
    /// Each task in its own folder, even when the workspace has a folder.
    case own
    /// These of the workspace's folders, the first being primary.
    case folders([String])
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

    /// Folders and sources belong to the workspace now. Each group's folders join its workspace's list; a group keeps
    /// them as its own choice unless they are simply the workspace's one folder. Its sources join the workspace's, where a
    /// link wins over a dismissal and a dismissal over a proposal. A source the workspace now works in is put away.
    static func registerWorkspacePlaces(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("workspace_places") { db in
            try db.execute(sql: """
            CREATE TABLE workspaceFolders (
              workspaceId TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE, path TEXT NOT NULL, position INTEGER NOT NULL,
              PRIMARY KEY (workspaceId, path)
            );
            ALTER TABLE taskGroups ADD COLUMN ownFolders BOOLEAN;
            """)
            let rows = try Row.fetchAll(db, sql: """
                SELECT g.workspaceId AS workspace, f.groupId AS groupId, f.path AS path FROM groupFolders f
                JOIN taskGroups g ON g.id = f.groupId WHERE g.workspaceId IS NOT NULL ORDER BY g.position, f.position
                """)
            var linked: [String: [String]] = [:]
            for row in rows {
                let workspace: String = row["workspace"], path: String = row["path"]
                if linked[workspace, default: []].contains(path) { continue }
                try WorkspaceFolder(workspaceId: workspace, path: path, position: linked[workspace, default: []].count).insert(db)
                linked[workspace, default: []].append(path)
            }
            for (workspace, paths) in linked where paths.count == 1 {
                try db.execute(sql: "DELETE FROM groupFolders WHERE path = ? AND groupId IN (SELECT id FROM taskGroups WHERE workspaceId = ?)", arguments: [paths[0], workspace])
            }
            let rank = ["linked": 2, "dismissed": 1, "proposed": 0]
            let sources = try Row.fetchAll(db, sql: """
                SELECT s.id AS id, s.address AS address, s.state AS state, g.workspaceId AS workspace FROM groupSources s
                JOIN taskGroups g ON g.id = s.groupId WHERE g.workspaceId IS NOT NULL ORDER BY g.position, s.position
                """)
            for source in sources {
                let id: String = source["id"], address: String = source["address"], state: String = source["state"], workspace: String = source["workspace"]
                if let kept = try Row.fetchOne(db, sql: "SELECT id, state FROM groupSources WHERE workspaceId = ? AND address = ?", arguments: [workspace, address]) {
                    let keptState: String = kept["state"]
                    if rank[state, default: 0] > rank[keptState, default: 0] {
                        try db.execute(sql: "UPDATE groupSources SET state = ? WHERE id = ?", arguments: [state, kept["id"] as String])
                    }
                    try db.execute(sql: "DELETE FROM groupSources WHERE id = ?", arguments: [id])
                    continue
                }
                let position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM groupSources WHERE workspaceId = ?", arguments: [workspace]) ?? -1) + 1
                try db.execute(sql: "UPDATE groupSources SET workspaceId = ?, groupId = NULL, position = ? WHERE id = ?", arguments: [workspace, position, id])
            }
            // Sources of groups without a workspace have nowhere to go.
            try db.execute(sql: "DELETE FROM groupSources WHERE groupId IS NOT NULL")
            for (workspace, paths) in linked {
                for path in paths {
                    try db.execute(sql: "UPDATE groupSources SET state = 'dismissed' WHERE workspaceId = ? AND (address = ? OR address LIKE ? ESCAPE '\\')",
                                   arguments: [workspace, path, Self.likePrefix(path + "/")])
                }
            }
        }
    }

    /// A LIKE pattern matching everything that starts with `prefix`, whatever it holds.
    static func likePrefix(_ prefix: String) -> String {
        prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// The workspace an action is for: the one named, else the scoped one, else the library's first.
    static func workspaceID(_ db: Database, _ id: String?, scope: String?) throws -> String {
        if let id = id ?? scope { return try Self.workspace(db, id).id }
        return try Self.defaultWorkspace(db).id
    }

    // MARK: The workspace's folders

    /// The scoped workspace's folders in order, the primary one first.
    public func workspaceFolders(workspaceID: String? = nil) throws -> [String] {
        try db.read { db in try Self.workspaceFolders(db, workspaceID: Self.workspaceID(db, workspaceID, scope: self.workspaceID)) }
    }

    static func workspaceFolders(_ db: Database, workspaceID: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT path FROM workspaceFolders WHERE workspaceId = ? ORDER BY position", arguments: [workspaceID])
    }

    /// Links a folder for the workspace's tasks to work in, after the ones already linked. A folder inside a repository links
    /// the whole repository. A Google Drive folder becomes a source the tasks read instead: anything written there syncs to
    /// other people at once. Returns the folder actually linked.
    @discardableResult public func linkFolder(_ path: String, workspaceID: String? = nil) throws -> String {
        let root = LinkedFolder.root(of: path)
        guard LinkedFolder.exists(root) else { throw StoreError.invalid("Link a folder that exists on this Mac.") }
        let workspace = try db.read { try Self.workspaceID($0, workspaceID, scope: self.workspaceID) }
        if LinkedSource.isCloudDrive(root) { return try linkWorkspaceSource(root, workspaceID: workspace).address }
        guard !isFaciendaFolder(root) else { throw StoreError.invalid("That is one of Facienda’s own folders. Link a project folder instead.") }
        try write { db in
            let linked = try Self.workspaceFolders(db, workspaceID: workspace)
            guard !linked.contains(root) else { return }
            try WorkspaceFolder(workspaceId: workspace, path: root, position: linked.count).insert(db)
            // Reading it as a source too would only repeat it.
            try db.execute(sql: "UPDATE groupSources SET state = 'dismissed' WHERE workspaceId = ? AND state = 'proposed' AND (address = ? OR address LIKE ? ESCAPE '\\')",
                           arguments: [workspace, root, Self.likePrefix(root + "/")])
        }
        return root
    }

    /// Groups that chose the folder stop working in it; a group left with no choice works where the workspace does.
    public func unlinkFolder(_ path: String, workspaceID: String? = nil) throws {
        try write { db in
            let workspace = try Self.workspaceID(db, workspaceID, scope: self.workspaceID)
            let rest = try Self.workspaceFolders(db, workspaceID: workspace).filter { $0 != path }
            try Self.order(db, workspace: workspace, rest)
            try db.execute(sql: "DELETE FROM groupFolders WHERE path = ? AND groupId IN (SELECT id FROM taskGroups WHERE workspaceId = ?)", arguments: [path, workspace])
        }
    }

    /// Moves a linked folder to the front: with several, it is the one offered first.
    public func makePrimaryFolder(_ path: String, workspaceID: String? = nil) throws {
        try write { db in
            let workspace = try Self.workspaceID(db, workspaceID, scope: self.workspaceID)
            let linked = try Self.workspaceFolders(db, workspaceID: workspace)
            guard linked.contains(path) else { throw StoreError.notFound }
            try Self.order(db, workspace: workspace, [path] + linked.filter { $0 != path })
        }
    }

    private static func order(_ db: Database, workspace: String, _ paths: [String]) throws {
        try db.execute(sql: "DELETE FROM workspaceFolders WHERE workspaceId = ?", arguments: [workspace])
        for (position, path) in paths.enumerated() { try WorkspaceFolder(workspaceId: workspace, path: path, position: position).insert(db) }
    }

    // MARK: Where a group works

    public func workPlace(groupId: String) throws -> GroupWorkPlace {
        try db.read { try Self.workPlace($0, groupId: groupId) }
    }

    static func workPlace(_ db: Database, groupId: String) throws -> GroupWorkPlace {
        if try Bool.fetchOne(db, sql: "SELECT ownFolders FROM taskGroups WHERE id = ?", arguments: [groupId]) == true { return .own }
        let chosen = try String.fetchAll(db, sql: "SELECT path FROM groupFolders WHERE groupId = ? ORDER BY position", arguments: [groupId])
        return chosen.isEmpty ? .workspace : .folders(chosen)
    }

    /// Where the group's tasks work from now on. Chosen folders must be among the workspace's.
    public func setWorkPlace(_ place: GroupWorkPlace, groupId: String) throws {
        try write { db in
            guard let group = try TaskGroup.fetchOne(db, key: groupId) else { throw StoreError.notFound }
            try db.execute(sql: "DELETE FROM groupFolders WHERE groupId = ?", arguments: [groupId])
            try db.execute(sql: "UPDATE taskGroups SET ownFolders = ? WHERE id = ?", arguments: [place == .own ? true : nil, groupId])
            guard case .folders(let paths) = place else { return }
            let linked = try group.workspaceId.map { try Self.workspaceFolders(db, workspaceID: $0) } ?? []
            guard !paths.isEmpty, paths.allSatisfy(linked.contains) else { throw StoreError.invalid("Link the folder to the workspace first.") }
            for (position, path) in paths.enumerated() { try GroupFolder(groupId: groupId, path: path, position: position).insert(db) }
        }
    }

    /// The folders a group's tasks work in: the ones it chose, or the workspace's when it has exactly one. Empty means each
    /// task works in its own folder. Several folders are a choice only: a task never works across all of a workspace's repositories by default.
    static func folders(_ db: Database, groupId: String) throws -> [String] {
        guard let workspace = try String.fetchOne(db, sql: "SELECT workspaceId FROM taskGroups WHERE id = ?", arguments: [groupId]) else { return [] }
        switch try workPlace(db, groupId: groupId) {
        case .own: return []
        case .folders(let chosen): return chosen
        case .workspace: return try defaultFolders(db, workspaceID: workspace)
        }
    }

    /// Where tasks in the workspace work unless their group says otherwise: its one folder, or each task's own.
    static func defaultFolders(_ db: Database, workspaceID: String) throws -> [String] {
        let linked = try workspaceFolders(db, workspaceID: workspaceID)
        return linked.count == 1 ? linked : []
    }

    public func folders(groupId: String) throws -> [String] {
        try db.read { try Self.folders($0, groupId: groupId) }
    }

    /// Where each group's tasks work, for the scoped workspace or the whole library. Groups whose tasks work in their own folders are absent.
    public func groupFolders() throws -> [String: [String]] {
        try db.read { db in
            let ids = try workspaceID.map { try String.fetchAll(db, sql: "SELECT id FROM taskGroups WHERE workspaceId = ?", arguments: [$0]) }
                ?? String.fetchAll(db, sql: "SELECT id FROM taskGroups")
            var result: [String: [String]] = [:]
            for id in ids { let folders = try Self.folders(db, groupId: id); if !folders.isEmpty { result[id] = folders } }
            return result
        }
    }

    /// The Codex project covering the group's folders. Owned means Facienda made it, so Facienda may change its folders.
    public func setCodexProject(groupId: String, id: String?, owned: Bool) throws {
        try write { db in
            try db.execute(sql: "UPDATE taskGroups SET codexProjectId = ?, codexProjectOwned = ? WHERE id = ?", arguments: [id, id == nil ? nil : owned, groupId])
        }
    }

    /// The group's Codex project, when the task still works in exactly the folders the group works in now.
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
    /// Otherwise the task takes the folders its group works in, or its workspace's one folder when it has no group: it works
    /// in a single one directly, and from its own folder across several. Without either it gets its own folder, as before.
    @discardableResult public func prepareWorkingFolder(taskId: String) throws -> FaciendaTask {
        var task = try self.task(taskId)
        let automatic = task.cwd.map { isAutomaticWorkingDirectory($0, taskID: task.id) } ?? true
        if automatic, task.folders == nil {
            let workspace = task.workspaceId
            let linked = try db.read { db -> [String] in
                guard try ThreadLink.filter(Column("taskId") == taskId).fetchCount(db) == 0 else { return [] }
                if let group = try String.fetchOne(db, sql: "SELECT groupId FROM taskGroupMembers WHERE taskId = ?", arguments: [taskId]) {
                    return try Self.folders(db, groupId: group)
                }
                return try workspace.map { try Self.defaultFolders(db, workspaceID: $0) } ?? []
            }
            if let missing = linked.first(where: { !LinkedFolder.exists($0) }) {
                throw StoreError.invalid("The folder “\(LinkedFolder.name(of: missing))” linked to this workspace is unavailable. Reconnect it, or unlink it on the Memory page.")
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
