import Foundation
import GRDB

/// A command the user allowed once in Facienda, for their Claude task's session. Claude's own permission check never
/// takes a reply Facienda relays as the user's approval, since it arrives from another session. So the agent asks here
/// with the exact command, the user reads it in full and allows it, and Facienda's hook lets that identical command
/// through, once, within the hour. Claude's deny and ask rules and its own safety checks still apply.
public struct ClaudeCommandGrant: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "claudeCommandGrants"
    public var decisionId: String
    public var taskId: String
    public var command: String
    public var usedAt: Date?
}

extension FaciendaStore {
    /// The only answer that allows a command. Anything else, a written answer too, leaves it to Claude's own check.
    public static let allowOnce = "Allow once"
    public static let dontAllow = "Don't allow"
    /// How long an allowed command waits to be run.
    public static let commandGrantLifetime: TimeInterval = 3600
    static let commandLimit = 8000

    static func registerClaudeCommandGrants(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("claude_command_grants") { db in
            try db.execute(sql: """
                CREATE TABLE claudeCommandGrants (decisionId TEXT PRIMARY KEY NOT NULL, taskId TEXT NOT NULL, command TEXT NOT NULL, usedAt DATETIME);
                CREATE INDEX claudeCommandGrantsTask ON claudeCommandGrants(taskId, command);
                """)
        }
    }

    /// Asks the user to allow one Bash command for the task's Claude session. The options are always the same two.
    @discardableResult public func requestCommandPermission(taskId: String, question: String, context: String, command: String) throws -> Decision {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.count <= Self.commandLimit else {
            throw StoreError.invalid("command is the exact Bash command, at most \(Self.commandLimit) characters.")
        }
        let claude = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM claudeSessions WHERE taskId = ?", arguments: [taskId]) ?? 0 > 0 }
        guard claude else { throw StoreError.invalid("Only a Claude task's session can ask to run a command; Codex asks through its own approvals.") }
        // A question waiting with the same words is returned as it is, so it must not stand for another command.
        let waiting = try db.read { try String.fetchOne($0, sql: """
            SELECT g.command FROM decisions d JOIN claudeCommandGrants g ON g.decisionId = d.id
            WHERE d.taskId = ? AND d.question = ? AND d.state = 'pending'
            """, arguments: [taskId, question]) }
        if let waiting, waiting != command { throw StoreError.invalid("A permission question with these words waits for another command; word this one differently.") }
        let decision = try requestDecision(Decision(taskId: taskId, question: question, context: context, recommendation: Self.allowOnce,
                                                    options: [Self.allowOnce, Self.dontAllow], kind: "permission"))
        try write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO claudeCommandGrants (decisionId, taskId, command) VALUES (?, ?, ?)", arguments: [decision.id, taskId, command])
        }
        return decision
    }

    /// The command a permission question asks to run, if it asks for one.
    public func commandGrant(decisionId: String) throws -> ClaudeCommandGrant? {
        try db.read { try ClaudeCommandGrant.fetchOne($0, key: decisionId) }
    }

    /// Spends an allowed, unused grant for exactly this command in the session's task, and says whether there was one.
    public func useClaudeCommandGrant(cliSessionId: String, command: String, now: Date = Date()) throws -> Bool {
        guard !cliSessionId.isEmpty, !command.isEmpty else { return false }
        return try write { db in
            guard let taskId = try String.fetchOne(db, sql: "SELECT taskId FROM claudeSessions WHERE lower(cliSessionId) = lower(?) ORDER BY linkedAt DESC LIMIT 1",
                                                   arguments: [cliSessionId]) else { return false }
            // Exact text, compared byte for byte: a command changed in any way is Claude's to judge again.
            guard let id = try String.fetchOne(db, sql: """
                SELECT g.decisionId FROM claudeCommandGrants g JOIN decisions d ON d.id = g.decisionId
                WHERE g.taskId = ? AND d.taskId = g.taskId AND g.command = ? AND g.usedAt IS NULL
                  AND d.kind = 'permission' AND d.state = 'answered' AND d.answer = ? AND d.answeredAt > ?
                ORDER BY d.answeredAt LIMIT 1
                """, arguments: [taskId, command, Self.allowOnce, now.addingTimeInterval(-Self.commandGrantLifetime)]) else { return false }
            try db.execute(sql: "UPDATE claudeCommandGrants SET usedAt = ? WHERE decisionId = ?", arguments: [now, id])
            try TaskEvent(taskId: taskId, source: .hook, kind: "permission.used", payload: id).insert(db)
            return true
        }
    }
}
