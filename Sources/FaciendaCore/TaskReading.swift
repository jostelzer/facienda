import Foundation
import GRDB

/// When a task last came back finished and when the user last opened it. A task is new while the first is later.
public struct TaskReadMark: Equatable, Sendable {
    public var finishedAt: Date?
    public var seenAt: Date?
    public init(finishedAt: Date? = nil, seenAt: Date? = nil) { self.finishedAt = finishedAt; self.seenAt = seenAt }
    public var isNew: Bool { finishedAt.map { $0 > (seenAt ?? .distantPast) } ?? false }
}

extension FaciendaStore {
    static func registerReading(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("task_reading") { db in
            // Kept out of the task record, so writing a task never overwrites them and other edits never make a task new.
            try db.execute(sql: """
            ALTER TABLE tasks ADD COLUMN finishedAt DATETIME;
            ALTER TABLE tasks ADD COLUMN seenAt DATETIME;
            -- Work comes back: a run ends, a question is asked, a wait returns.
            CREATE TRIGGER task_finished_state AFTER UPDATE OF state ON tasks
              WHEN NEW.state = 'needsMe' AND OLD.state IN ('running', 'waiting', 'scheduled') BEGIN
              UPDATE tasks SET finishedAt = NEW.updatedAt WHERE id = NEW.id;
            END;
            CREATE TRIGGER task_finished_insert AFTER INSERT ON tasks
              WHEN NEW.state = 'needsMe' AND NEW.finishedAt IS NULL BEGIN
              UPDATE tasks SET finishedAt = NEW.updatedAt WHERE id = NEW.id;
            END;
            -- A further result or question for a task already waiting on the user.
            CREATE TRIGGER task_finished_event AFTER INSERT ON events
              WHEN NEW.kind IN ('codex.result', 'decision.requested', 'check.review') AND NEW.taskId IS NOT NULL BEGIN
              UPDATE tasks SET finishedAt = NEW.at WHERE id = NEW.taskId AND state = 'needsMe';
            END;
            UPDATE tasks SET finishedAt = coalesce(
              (SELECT max(at) FROM events WHERE taskId = tasks.id AND kind IN ('codex.result', 'decision.requested', 'check.review')),
              updatedAt) WHERE state = 'needsMe';
            """)
        }
    }

    /// The scoped workspace's read marks, by task ID.
    public func readMarks() throws -> [String: TaskReadMark] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, finishedAt, seenAt FROM tasks WHERE (finishedAt IS NOT NULL OR seenAt IS NOT NULL)" + (workspaceID == nil ? "" : " AND workspaceId = ?"),
                                        arguments: StatementArguments(workspaceID.map { [$0] } ?? []))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, TaskReadMark(finishedAt: $0["finishedAt"], seenAt: $0["seenAt"])) })
        }
    }

    /// Records that the user opened these tasks. An earlier time never replaces a later one.
    public func markSeen(_ seen: [String: Date]) throws {
        guard !seen.isEmpty else { return }
        try write { db in
            for (id, at) in seen {
                try db.execute(sql: "UPDATE tasks SET seenAt = ? WHERE id = ? AND (seenAt IS NULL OR seenAt < ?)", arguments: [at, id, at])
            }
        }
    }

    /// Open tasks that came back finished since the user last opened them, by workspace ID. Work still underway is left out.
    public func newCounts() throws -> [String: Int] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT workspaceId, count(*) AS count FROM tasks
                WHERE state NOT IN ('done', 'dropped', 'running') AND workspaceId IS NOT NULL
                  AND finishedAt IS NOT NULL AND (seenAt IS NULL OR seenAt < finishedAt)
                  AND id NOT IN (SELECT taskId FROM dispatches WHERE state IN ('queued', 'claimed', 'dispatching'))
                GROUP BY workspaceId
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["workspaceId"] as String, $0["count"] as Int) })
        }
    }

    /// Tasks for review in each workspace, as the board files them: open, and neither underway nor parked.
    public func reviewCounts() throws -> [String: Int] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT workspaceId, count(*) AS count FROM tasks
                WHERE state IN ('inbox', 'needsMe') AND workspaceId IS NOT NULL
                  AND id NOT IN (SELECT taskId FROM dispatches WHERE state IN ('queued', 'claimed', 'dispatching'))
                GROUP BY workspaceId
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["workspaceId"] as String, $0["count"] as Int) })
        }
    }
}
