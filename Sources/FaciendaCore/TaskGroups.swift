import Foundation
import GRDB

public struct TaskGroup: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "taskGroups"
    public var id: String
    public var name: String
    public var position: Int
    public var createdAt: Date
    /// The dashboard column the user put this group in; nil until they arrange it.
    public var lane: Int?
    /// The group's place in that column, counted from the top.
    public var row: Int?
    /// The painting style Codex chose for this group's cover, kept so a repaint stays recognisable.
    public var coverStyle: String?
    /// nil until a cover has been painted. The image itself lives beside the database.
    public var coverPaintedAt: Date?
    /// The user's standing wishes for the cover ("more green", "no people"), one per line. Every repaint honours them.
    public var coverNotes: String?
    /// The workspace whose dashboard shows this group.
    public var workspaceId: String?
    /// The Codex project spanning the group's linked folders, nil while it has none.
    public var codexProjectId: String?
    /// True when Facienda made that project, so it may change its folders. The user's own projects are never changed.
    public var codexProjectOwned: Bool?
    public var coverNoteList: [String] { (coverNotes ?? "").split(whereSeparator: \.isNewline).map(String.init) }
}

/// A group's slot on the dashboard: a column and a grid row within it.
public struct GroupPlacement: Equatable, Sendable {
    public var id: String
    public var lane: Int
    public var row: Int
    public init(id: String, lane: Int, row: Int) { self.id = id; self.lane = lane; self.row = row }
}

public struct TaskGroupMember: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "taskGroupMembers"
    public var taskId: String
    public var groupId: String
    /// "user" placements are never replaced by a runner proposal.
    public var assignedBy: String
}

/// Where the user put a task on the board, smaller first. A task never placed sorts by when it was made, newest first,
/// on the same scale, so a new task arrives at the top of its card and nothing else moves on its own.
public struct TaskBoardPlace: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "taskBoardPlaces"
    public var taskId: String
    public var sortKey: Double
    public static func unplaced(_ task: FaciendaTask) -> Double { -task.createdAt.timeIntervalSince1970 }
}

extension FaciendaStore {
    static func registerTaskBoardPlaces(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("task_board_places") { db in
            // Beside the task, like membership, so reordering never changes a task's revision or activity date.
            try db.execute(sql: "CREATE TABLE taskBoardPlaces (taskId TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id), sortKey REAL NOT NULL)")
        }
    }

    /// The scoped workspace's placed tasks, by task ID.
    public func boardPlaces() throws -> [String: Double] {
        try db.read { db in
            let places = try workspaceID.map { try TaskBoardPlace.fetchAll(db, sql: "SELECT p.* FROM taskBoardPlaces p JOIN tasks t ON t.id = p.taskId WHERE t.workspaceId = ?", arguments: [$0]) }
                ?? TaskBoardPlace.fetchAll(db)
            return Dictionary(places.map { ($0.taskId, $0.sortKey) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Fixes one card's tasks in the given order, top first. The card keeps its place on the scale, so tasks made later still arrive above it.
    public func placeTasks(_ taskIDs: [String]) throws {
        try write { db in
            var keys: [Double] = []
            for id in taskIDs {
                guard let task = try FaciendaTask.fetchOne(db, key: id) else { throw StoreError.notFound }
                keys.append(try TaskBoardPlace.fetchOne(db, key: id)?.sortKey ?? TaskBoardPlace.unplaced(task))
            }
            guard let top = keys.min() else { return }
            for (offset, id) in taskIDs.enumerated() {
                let key = top + Double(offset) / 1000
                if keys[offset] != key { try TaskBoardPlace(taskId: id, sortKey: key).save(db) }
            }
        }
    }

    static func registerTaskGroups(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15_task_groups") { db in
            // Membership lives beside tasks so regrouping never changes a task's revision or activity date.
            try db.execute(sql: """
            CREATE TABLE taskGroups (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, position INTEGER NOT NULL, createdAt DATETIME NOT NULL);
            CREATE TABLE taskGroupMembers (
              taskId TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id),
              groupId TEXT NOT NULL REFERENCES taskGroups(id) ON DELETE CASCADE, assignedBy TEXT NOT NULL
            );
            CREATE INDEX group_members ON taskGroupMembers(groupId);
            """)
        }
        migrator.registerMigration("v16_group_lanes") { db in
            try db.execute(sql: "ALTER TABLE taskGroups ADD COLUMN lane INTEGER")
        }
        migrator.registerMigration("v17_group_covers") { db in
            try db.execute(sql: "ALTER TABLE taskGroups ADD COLUMN coverStyle TEXT; ALTER TABLE taskGroups ADD COLUMN coverPaintedAt DATETIME")
        }
        migrator.registerMigration("v18_group_cover_notes") { db in
            try db.execute(sql: "ALTER TABLE taskGroups ADD COLUMN coverNotes TEXT")
        }
        migrator.registerMigration("v18_group_rows") { db in
            try db.execute(sql: "ALTER TABLE taskGroups ADD COLUMN row INTEGER")
        }
    }

    private static func groupName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 48, !name.contains("\n") else { throw StoreError.invalid("Give this group a short name.") }
        return name
    }

    /// A new group joins the end of its workspace's dashboard.
    private static func insertGroup(_ db: Database, name: String, workspaceID: String?) throws -> TaskGroup {
        let workspace = try workspaceID.map { try Self.workspace(db, $0).id } ?? Self.defaultWorkspace(db).id
        let position = try Self.nextPosition(db, in: "taskGroups", workspaceID: workspace)
        let group = TaskGroup(id: UUID().uuidString, name: name, position: position, createdAt: Date(), lane: nil, row: nil, workspaceId: workspace)
        try group.insert(db)
        return group
    }

    /// The scoped workspace's groups, or every group in the library.
    public func groups() throws -> [TaskGroup] {
        try db.read { db in
            guard let workspaceID else { return try TaskGroup.fetchAll(db, sql: "SELECT * FROM taskGroups ORDER BY position, createdAt") }
            return try TaskGroup.fetchAll(db, sql: "SELECT * FROM taskGroups WHERE workspaceId = ? ORDER BY position, createdAt", arguments: [workspaceID])
        }
    }

    public func groupMembers() throws -> [TaskGroupMember] {
        try db.read { db in
            guard let workspaceID else { return try TaskGroupMember.fetchAll(db) }
            return try TaskGroupMember.fetchAll(db, sql: "SELECT m.* FROM taskGroupMembers m JOIN taskGroups g ON g.id = m.groupId WHERE g.workspaceId = ?", arguments: [workspaceID])
        }
    }

    @discardableResult public func createGroup(name: String) throws -> TaskGroup {
        let name = try Self.groupName(name)
        return try write { db in try Self.insertGroup(db, name: name, workspaceID: workspaceID) }
    }

    public func renameGroup(_ id: String, name: String) throws {
        let name = try Self.groupName(name)
        try write { db in
            guard var group = try TaskGroup.fetchOne(db, key: id) else { throw StoreError.notFound }
            group.name = name; try group.update(db)
        }
    }

    /// Pins groups to board slots. Groups left out keep their slot and follow the pinned ones in their old order.
    public func placeGroups(_ placements: [GroupPlacement]) throws {
        try write { db in
            let placed = placements.sorted { ($0.lane, $0.row) < ($1.lane, $1.row) }
            let pinned = Set(placed.map(\.id))
            let rest = try String.fetchAll(db, sql: "SELECT id FROM taskGroups \(workspaceID == nil ? "" : "WHERE workspaceId = ?") ORDER BY position, createdAt", arguments: StatementArguments(workspaceID.map { [$0] } ?? []))
                .filter { !pinned.contains($0) }
            for (position, place) in placed.enumerated() {
                try db.execute(sql: "UPDATE taskGroups SET lane = ?, row = ?, position = ? WHERE id = ?", arguments: [place.lane, place.row, position, place.id])
            }
            for (offset, id) in rest.enumerated() {
                try db.execute(sql: "UPDATE taskGroups SET position = ? WHERE id = ?", arguments: [placed.count + offset, id])
            }
        }
    }

    /// Tasks in a deleted group become ungrouped; the tasks themselves are untouched.
    /// A delete that can be undone keeps the cover until the app next opens, so the group comes back with its picture.
    public func deleteGroup(_ id: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM taskGroupMembers WHERE groupId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM groupFolders WHERE groupId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM groupSources WHERE groupId = ?", arguments: [id])
            _ = try TaskGroup.deleteOne(db, key: id)
        }
        guard UndoRecorder.current == nil else { return }
        try? FileManager.default.removeItem(at: coverURL(groupId: id))
        try? FileManager.default.removeItem(at: previousCoverURL(groupId: id))
    }

    /// A nil group removes the task from its group and keeps it in "Unsorted": the runner will not file it later.
    public func assignGroup(taskId: String, groupId: String?) throws {
        try write { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId) else { throw StoreError.notFound }
            guard let groupId else {
                _ = try TaskGroupMember.deleteOne(db, key: taskId)
                if try Self.keptUnsorted(db, taskId) == false { try TaskEvent(taskId: taskId, source: .user, kind: Self.unsortedKind).insert(db) }
                return
            }
            guard let group = try TaskGroup.fetchOne(db, key: groupId) else { throw StoreError.notFound }
            guard group.workspaceId == task.workspaceId else { throw StoreError.invalid("That group belongs to another workspace. Move the task there first.") }
            try TaskGroupMember(taskId: taskId, groupId: groupId, assignedBy: "user").save(db)
        }
        if groupId != nil { offerAttachments(of: taskId) }
    }

    static let unsortedKind = "group.unsorted"
    private static func keptUnsorted(_ db: Database, _ taskId: String) throws -> Bool {
        try TaskEvent.filter(Column("taskId") == taskId && Column("kind") == unsortedKind).fetchCount(db) > 0
    }

    /// The runner may file a task it is naming. It reuses a group with the same name and never moves a task that already has a group.
    @discardableResult public func proposeGroup(taskId: String, runnerID: String, name: String) throws -> TaskGroup? {
        let name = try Self.groupName(name)
        return try write { db in
            guard try Self.isRunner(db, runnerID) else { throw StoreError.invalid("This is not the configured runner.") }
            guard let task = try FaciendaTask.fetchOne(db, key: taskId) else { throw StoreError.notFound }
            guard try TaskGroupMember.fetchOne(db, key: taskId) == nil, try Self.keptUnsorted(db, taskId) == false else { return nil }
            // Filing stays inside the task's own workspace.
            let group = try TaskGroup.fetchOne(db, sql: "SELECT * FROM taskGroups WHERE name = ? COLLATE NOCASE AND workspaceId = ?", arguments: [name, task.workspaceId])
                ?? Self.insertGroup(db, name: name, workspaceID: task.workspaceId)
            try TaskGroupMember(taskId: taskId, groupId: group.id, assignedBy: "runner").insert(db)
            try TaskEvent(taskId: taskId, source: .mcp, kind: "group.proposed", payload: group.name, verified: false).insert(db)
            return group
        }
    }
}
