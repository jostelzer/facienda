import Foundation
import GRDB

/// When a task last came back finished and when the user last opened it. A task is new while the first is later.
public struct TaskReadMark: Equatable, Sendable {
    public var finishedAt: Date?
    public var seenAt: Date?
    public init(finishedAt: Date? = nil, seenAt: Date? = nil) { self.finishedAt = finishedAt; self.seenAt = seenAt }
    public var isNew: Bool { finishedAt.map { $0 > (seenAt ?? .distantPast) } ?? false }
}

/// What a chat's own app, Codex or Claude, says about it: when its latest turn ended, and whether the user has read it since.
public struct ChatReading: Equatable, Sendable {
    public var turnEndedAt: Date
    public var read: Bool
    public init(turnEndedAt: Date, read: Bool) { self.turnEndedAt = turnEndedAt; self.read = read }

    /// Claude has no read receipt; it records when the user last opened each session. Opened after its latest turn ended is read.
    public init(claude session: ClaudeDesktop.Session) {
        turnEndedAt = session.turnEndedAt
        read = session.focusedAt.map { $0 >= session.turnEndedAt } ?? false
    }
}

/// A new task and the chat its work came back in, where the user may already have read it.
public struct UnreadChat: Equatable, Sendable {
    public var taskId: String
    public var threadId: String
    public var provider: AgentProvider
    public var finishedAt: Date
    public init(taskId: String, threadId: String, provider: AgentProvider, finishedAt: Date) {
        self.taskId = taskId; self.threadId = threadId; self.provider = provider; self.finishedAt = finishedAt
    }

    /// How long before the task came back its chat's latest turn may have ended for that turn to be the news. Facienda notices a
    /// finished turn within a poll or two; a wait, date or blocker that brings a task back on its own comes long after the chat went quiet.
    public static let turnWindow: TimeInterval = 300
    /// Codex files a turn's read receipt just after the turn ends, so news is judged only once it is this old.
    public static let settling: TimeInterval = 30

    /// The user already read this news in the chat's own app: the chat's latest turn is the news, and it was read after that turn ended.
    public func wasRead(in chat: ChatReading, now: Date = Date()) -> Bool {
        chat.read && now.timeIntervalSince(finishedAt) >= Self.settling
            && chat.turnEndedAt >= finishedAt.addingTimeInterval(-Self.turnWindow)
    }
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

    /// New tasks in the scoped workspace, each with the chat its work came back in: the latest work chat, else the latest review chat.
    /// Work still underway is left out, as on the board.
    public func unreadChats() throws -> [UnreadChat] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tasks.id, tasks.finishedAt, threadLinks.codexThreadId, coalesce(threadLinks.provider, 'codex') AS provider
                FROM tasks JOIN threadLinks ON threadLinks.rowid = (
                  SELECT rowid FROM threadLinks WHERE taskId = tasks.id AND role IN ('work', 'review')
                  ORDER BY role = 'work' DESC, rowid DESC LIMIT 1)
                WHERE tasks.state NOT IN ('done', 'dropped', 'running')
                  AND tasks.finishedAt IS NOT NULL AND (tasks.seenAt IS NULL OR tasks.seenAt < tasks.finishedAt)
                  AND tasks.id NOT IN (SELECT taskId FROM dispatches WHERE state IN ('queued', 'claimed', 'dispatching'))
                """ + (workspaceID == nil ? "" : " AND tasks.workspaceId = ?"), arguments: StatementArguments(workspaceID.map { [$0] } ?? []))
            return rows.compactMap { row in
                guard let provider = AgentProvider(rawValue: row["provider"]) else { return nil }
                return UnreadChat(taskId: row["id"], threadId: row["codexThreadId"], provider: provider, finishedAt: row["finishedAt"])
            }
        }
    }

    /// Records that the user read these tasks' news in the chat's own app. Each is seen as of when it came back, and only if it has
    /// not come back again since, so work that returns later is new again.
    public func markReadInChat(_ chats: [UnreadChat]) throws {
        guard !chats.isEmpty else { return }
        try write { db in
            for chat in chats {
                guard let finishedAt = try Date.fetchOne(db, sql: "SELECT finishedAt FROM tasks WHERE id = ?", arguments: [chat.taskId]),
                      abs(finishedAt.timeIntervalSince(chat.finishedAt)) < 0.001 else { continue }
                try db.execute(sql: "UPDATE tasks SET seenAt = finishedAt WHERE id = ? AND (seenAt IS NULL OR seenAt < finishedAt)", arguments: [chat.taskId])
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

    /// Tasks in progress in each workspace, as the board's In progress files them: running, or open with a delivery
    /// underway. A parked task's check that has not gone out yet leaves it parked.
    public func runningCounts() throws -> [String: Int] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT workspaceId, count(*) AS count FROM tasks
                WHERE state NOT IN ('done', 'dropped') AND workspaceId IS NOT NULL
                  AND (state = 'running' OR EXISTS (
                    SELECT 1 FROM dispatches WHERE dispatches.taskId = tasks.id
                      AND (dispatches.state = 'dispatching' OR (dispatches.state IN ('queued', 'claimed')
                        AND NOT (dispatches.kind = 'check' AND tasks.state IN ('waiting', 'scheduled'))))))
                GROUP BY workspaceId
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["workspaceId"] as String, $0["count"] as Int) })
        }
    }
}
