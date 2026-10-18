import Foundation
import GRDB

/// One request that came in, beside what became of it. The Feed shows them newest first, each with its own words,
/// the reading Facienda made and who made it, so nothing that came in is lost or changed without a trace.
public struct IntakeEntry: Equatable, Sendable, Identifiable {
    /// Who settled what the request meant: a fixed rule, the reading model, or the person choosing among readings.
    public enum Decider: String, Codable, Sendable { case rule, model, you }

    public let id: String
    public let at: Date
    public let text: String
    /// What Return did, as the bar said it, such as "Reply · Deed transfer".
    public let reading: String
    public let decidedBy: Decider
    /// The task it went to or became, if any.
    public let taskId: String?
}

extension FaciendaStore {
    static let intakeKind = "intake.read"
    static let fromBar = "bar"

    static func registerUnifiedIntake(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("unified_intake") { db in
            // Keep old requests in the feed, with their original words and event IDs, after retiring the companion.
            try db.execute(sql: """
                UPDATE events SET kind = 'intake.read', payload = json_object(
                    'text', coalesce((SELECT c.payload FROM events c
                        WHERE c.taskId = events.taskId AND c.kind = 'task.created' AND c.source = 'user'
                        ORDER BY c.at, c.rowid LIMIT 1), ''),
                    'reading', 'New task · Inbox', 'by', 'rule',
                    'workspace', (SELECT t.workspaceId FROM tasks t WHERE t.id = events.taskId))
                WHERE kind = 'mobile.received' AND source = 'user' AND payload = taskId
                """)
        }
    }

    private struct IntakePayload: Codable {
        var text: String
        var reading: String
        var by: IntakeEntry.Decider
        var workspace: String?
        /// Where it was typed. Only the top bar records requests now; before, a group's + did too, without saying so.
        var from: String?
    }

    /// Records one request from the top bar and what Return did with it. Requests that touch no task, such as a note
    /// remembered or a question answered, belong to the workspace the bar was over. A task written on a group's + is
    /// not a request and is never recorded.
    public func recordIntake(text: String, reading: String, decidedBy: IntakeEntry.Decider, taskId: String?, at: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let payload = IntakePayload(text: String(text.prefix(4000)), reading: String(reading.prefix(300)), by: decidedBy, workspace: workspaceID, from: Self.fromBar)
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try write { db in
            // A task deleted since is no longer referred to; the request itself stays.
            let task = try taskId.flatMap { try FaciendaTask.fetchOne(db, key: $0) == nil ? nil : $0 }
            try TaskEvent(taskId: task, source: .user, kind: Self.intakeKind, payload: json, at: at).insert(db)
        }
    }

    /// The scoped workspace's requests, newest first.
    public func intake(limit: Int = 200) throws -> [IntakeEntry] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.at, e.payload, e.taskId
                FROM events e LEFT JOIN tasks t ON t.id = e.taskId
                WHERE e.source = 'user' AND e.kind = ?
                AND (? IS NULL OR t.workspaceId = ? OR (json_valid(e.payload) AND json_extract(e.payload, '$.workspace') = ?))
                ORDER BY e.at DESC, e.rowid DESC LIMIT ?
                """, arguments: [Self.intakeKind, workspaceID, workspaceID, workspaceID, limit])
            return rows.compactMap { row -> IntakeEntry? in
                guard let id: String = row["id"], let at: Date = row["at"] else { return nil }
                let taskId: String? = row["taskId"]
                let raw: String = row["payload"] ?? ""
                guard let payload = try? JSONDecoder().decode(IntakePayload.self, from: Data(raw.utf8)) else { return nil }
                return IntakeEntry(id: id, at: at, text: payload.text, reading: payload.reading, decidedBy: payload.by, taskId: taskId)
            }
        }
    }
}

/// A request as the Feed shows it: what came in, and what it became now, wherever that is. It points at its task rather
/// than keeping a copy, so the Feed always shows the task's live state, as the board does.
public struct FeedArrival: Equatable, Sendable, Identifiable {
    public let entry: IntakeEntry
    public var id: String { entry.id }
    /// The workspace it landed in, or the one the bar was over for a request that touched no task.
    public let workspaceId: String?
    /// The task it went to or became, as it is now. Nil for a note remembered or a question answered in place.
    public let task: FaciendaTask?
    /// The group that task is filed in, if any.
    public let groupId: String?
    public let groupName: String?
    /// Its task came back since you last opened it, as the board's blue dot says.
    public let isNew: Bool
}

extension FaciendaStore {
    /// Every request typed in the top bar, newest first, each with the workspace, group and live task it went to. The
    /// bar is the window's, not a workspace's, so the Feed reads across all of them. Requests recorded before the bar
    /// said where they came from may have been written on a group's +, so they stay out.
    public func feed(limit: Int = 300) throws -> [FeedArrival] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.at, e.payload, t.id AS taskId,
                       coalesce(t.workspaceId, CASE WHEN json_valid(e.payload) THEN json_extract(e.payload, '$.workspace') END) AS workspaceId,
                       g.id AS groupId, g.name AS groupName
                FROM events e
                LEFT JOIN tasks t ON t.id = e.taskId
                LEFT JOIN taskGroupMembers m ON m.taskId = t.id
                LEFT JOIN taskGroups g ON g.id = m.groupId
                WHERE e.source = 'user' AND e.kind = ? AND json_valid(e.payload) AND json_extract(e.payload, '$.from') = ?
                ORDER BY e.at DESC, e.rowid DESC LIMIT ?
                """, arguments: [Self.intakeKind, Self.fromBar, limit])
            let ids = rows.compactMap { $0["taskId"] as String? }
            let tasks = ids.isEmpty ? [:] : Dictionary(try FaciendaTask.fetchAll(db, keys: Set(ids)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let marks = ids.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT id, finishedAt, seenAt FROM tasks WHERE id IN (\(Set(ids).map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments(Array(Set(ids)))).map { ($0["id"] as String, TaskReadMark(finishedAt: $0["finishedAt"], seenAt: $0["seenAt"])) })
            return rows.compactMap { row -> FeedArrival? in
                guard let id: String = row["id"], let at: Date = row["at"],
                      let payload = try? JSONDecoder().decode(IntakePayload.self, from: Data((row["payload"] as String? ?? "").utf8)) else { return nil }
                let taskId: String? = row["taskId"]
                let task = taskId.flatMap { tasks[$0] }
                // New as the board counts it: open, not running, and back since it was last opened.
                let isNew = task.map { [.needsMe, .waiting, .scheduled, .inbox].contains($0.state) && marks[$0.id]?.isNew == true } ?? false
                return FeedArrival(entry: IntakeEntry(id: id, at: at, text: payload.text, reading: payload.reading, decidedBy: payload.by, taskId: taskId),
                                   workspaceId: row["workspaceId"], task: task, groupId: row["groupId"], groupName: row["groupName"], isNew: isNew)
            }
        }
    }
}
