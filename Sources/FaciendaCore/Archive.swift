import Foundation
import GRDB

/// A task that was still open when its group or workspace was archived, with what it was doing then. Archiving closes
/// it like any task the user archives, which clears its dates, closes its questions and drops the step the user took on.
/// This keeps them, so Restore reopens exactly these tasks, as they were.
struct ArchivedTask: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "archivedTasks"
    var taskId: String
    /// The group archived with it, or nil when its workspace was.
    var groupId: String?
    var workspaceId: String?
    var state: TaskState
    var returnAt: Date?
    var checkAt: Date?
    var checkPaused: Bool?
    var checkPinned: Bool?
    /// The questions that were waiting for the user, one ID per line.
    var decisionIds: String
    var ownStep: String?
    var ownStepAt: Date?
    var archivedAt: Date
}

extension FaciendaStore {
    static func registerArchive(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("archive") { db in
            // Archived workspaces use the tombstone they always had, now reversible. Groups get a mark of their own.
            try db.execute(sql: """
            ALTER TABLE taskGroups ADD COLUMN archivedAt DATETIME;
            CREATE TABLE archivedTasks (
              taskId TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
              groupId TEXT, workspaceId TEXT,
              state TEXT NOT NULL, returnAt DATETIME, checkAt DATETIME, checkPaused BOOLEAN, checkPinned BOOLEAN,
              decisionIds TEXT NOT NULL, ownStep TEXT, ownStepAt DATETIME,
              archivedAt DATETIME NOT NULL
            );
            CREATE INDEX archived_tasks_group ON archivedTasks(groupId);
            CREATE INDEX archived_tasks_workspace ON archivedTasks(workspaceId);
            """)
        }
    }

    // MARK: Groups

    /// The scoped workspace's archived groups, latest first.
    public func archivedGroups() throws -> [TaskGroup] {
        try db.read { db in
            guard let workspaceID else { return try TaskGroup.fetchAll(db, sql: "SELECT * FROM taskGroups WHERE archivedAt IS NOT NULL ORDER BY archivedAt DESC") }
            return try TaskGroup.fetchAll(db, sql: "SELECT * FROM taskGroups WHERE workspaceId = ? AND archivedAt IS NOT NULL ORDER BY archivedAt DESC",
                                          arguments: [workspaceID])
        }
    }

    /// Every task in an archived group, open or not, which leaves the board with it.
    public func archivedGroupTasks() throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT m.taskId FROM taskGroupMembers m JOIN taskGroups g ON g.id = m.groupId WHERE g.archivedAt IS NOT NULL"))
        }
    }

    /// Takes a group off the board with everything in it. Its open tasks are archived along, and their agents stop.
    public func archiveGroup(_ id: String, now: Date = Date()) throws {
        try write { db in
            guard var group = try TaskGroup.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard group.archivedAt == nil else { return }
            group.archivedAt = now
            try group.update(db)
            let open = try FaciendaTask.fetchAll(db, sql: """
                SELECT t.* FROM tasks t JOIN taskGroupMembers m ON m.taskId = t.id
                WHERE m.groupId = ? AND t.state NOT IN ('done', 'dropped')
                """, arguments: [id])
            for task in open { try archive(db, task, groupID: id, workspaceID: nil, now: now) }
        }
    }

    /// Puts an archived group back on the board, and the tasks archived with it back where they were.
    public func restoreGroup(_ id: String, now: Date = Date()) throws {
        try write { db in
            guard var group = try TaskGroup.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard group.archivedAt != nil else { return }
            if let workspace = group.workspaceId, try Self.workspace(db, workspace).removedAt != nil {
                throw StoreError.invalid("Its workspace is archived. Restore the workspace first.")
            }
            // It comes back to the place on the board it left.
            group.archivedAt = nil
            try group.update(db)
            for record in try ArchivedTask.fetchAll(db, sql: "SELECT * FROM archivedTasks WHERE groupId = ?", arguments: [id]) {
                try restore(db, record, now: now)
            }
        }
    }

    // MARK: Workspaces

    public func archivedWorkspaces() throws -> [Workspace] {
        try db.read { db in try Workspace.fetchAll(db, sql: "SELECT * FROM workspaces WHERE removedAt IS NOT NULL ORDER BY removedAt DESC") }
    }

    /// Hides a workspace with everything in it: its groups, tasks, memory and picture stay in the library. Its open tasks
    /// are archived along, and their agents stop.
    public func archiveWorkspace(_ id: String, now: Date = Date()) throws {
        try write { db in
            var workspace = try Self.workspace(db, id)
            guard workspace.removedAt == nil else { return }
            let others = try Int.fetchOne(db, sql: "SELECT count(*) FROM workspaces WHERE removedAt IS NULL AND id != ?", arguments: [id]) ?? 0
            guard others > 0 else { throw StoreError.invalid("Keep at least one workspace. Create another before archiving this one.") }
            workspace.removedAt = now
            try workspace.update(db)
            let open = try FaciendaTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE workspaceId = ? AND state NOT IN ('done', 'dropped')", arguments: [id])
            for task in open { try archive(db, task, groupID: nil, workspaceID: id, now: now) }
        }
    }

    /// Brings an archived workspace back where it was, with the tasks archived with it. Groups the user archived on their
    /// own stay archived.
    public func restoreWorkspace(_ id: String, now: Date = Date()) throws {
        try write { db in
            var workspace = try Self.workspace(db, id)
            guard workspace.removedAt != nil else { return }
            workspace.removedAt = nil
            try workspace.update(db)
            for record in try ArchivedTask.fetchAll(db, sql: "SELECT * FROM archivedTasks WHERE workspaceId = ?", arguments: [id]) {
                try restore(db, record, now: now)
            }
        }
    }

    // MARK: Tasks

    private func archive(_ db: Database, _ task: FaciendaTask, groupID: String?, workspaceID: String?, now: Date) throws {
        let plan = try CheckPlan.fetchOne(db, key: task.id), step = try OwnStep.fetchOne(db, key: task.id)
        let asks = try String.fetchAll(db, sql: "SELECT id FROM decisions WHERE taskId = ? AND state = 'pending'", arguments: [task.id])
        try ArchivedTask(taskId: task.id, groupId: groupID, workspaceId: workspaceID, state: task.state, returnAt: task.returnAt, checkAt: task.checkAt,
                         checkPaused: plan?.paused, checkPinned: plan?.pinned, decisionIds: asks.joined(separator: "\n"),
                         ownStep: step?.text, ownStepAt: step?.createdAt, archivedAt: now).save(db)
        try update(db, task.id) { $0.state = .dropped }
    }

    /// Reopens a task as it was. One that was running comes back as needing the user, since its agent was stopped. A
    /// task the user reopened or finished in the meantime is left as it is.
    private func restore(_ db: Database, _ record: ArchivedTask, now: Date) throws {
        _ = try ArchivedTask.deleteOne(db, key: record.taskId)
        guard let task = try FaciendaTask.fetchOne(db, key: record.taskId), task.state == .dropped else { return }
        try update(db, task.id) { task in
            switch record.state {
            case .waiting where record.checkAt != nil && task.waitingOn?.isEmpty == false:
                task.state = .waiting; task.checkAt = record.checkAt
            case .scheduled where record.returnAt != nil:
                task.state = .scheduled; task.returnAt = record.returnAt
            case .inbox:
                task.state = .inbox
            default:
                // A task needing the user keeps when it came back to them.
                task.state = .needsMe; task.returnAt = record.returnAt
            }
        }
        if let paused = record.checkPaused, let pinned = record.checkPinned {
            try db.execute(sql: "UPDATE checkPlans SET paused = ?, pinned = ?, revision = revision + 1 WHERE taskId = ?", arguments: [paused, pinned, task.id])
        }
        let asks = record.decisionIds.split(whereSeparator: \.isNewline).map(String.init)
        if !asks.isEmpty {
            try db.execute(sql: "UPDATE decisions SET state = 'pending', answeredAt = NULL WHERE state = 'closed' AND id IN (\(asks.map { _ in "?" }.joined(separator: ", ")))",
                           arguments: StatementArguments(asks))
        }
        if let text = record.ownStep { try OwnStep(taskId: task.id, text: text, createdAt: record.ownStepAt ?? now).save(db) }
    }
}
