import Foundation
import GRDB

/// A model the user picked for a Codex chat that carries on, waiting for the dispatcher to set it. It applies from the
/// chat's next turn; the chat keeps its history and folder. What the task ran on before comes back if Codex refuses it.
public struct ChatModelChange: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "chatModelChanges"
    public var threadId: String
    public var taskId: String
    public var model: String
    public var effort: String
    public var serviceTier: String?
    public var previousModel: String?
    public var previousEffort: String?
    public var previousServiceTier: String?
    public var requestedAt: Date
}

extension FaciendaStore {
    static func registerChatModelChanges(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("chat_model_changes") { db in
            try db.execute(sql: """
            CREATE TABLE chatModelChanges (
              threadId TEXT PRIMARY KEY NOT NULL, taskId TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
              model TEXT NOT NULL, effort TEXT NOT NULL, serviceTier TEXT,
              previousModel TEXT, previousEffort TEXT, previousServiceTier TEXT, requestedAt DATETIME NOT NULL
            );
            ALTER TABLE claudeSessions ADD COLUMN changedAt DATETIME;
            """)
        }
    }

    /// The task's own chat carries on with `choice` from its next turn: the same chat, history and folder. Only a model
    /// of the chat's own app can take over there; another app's model needs a new chat, which `continueInNewChat` makes.
    /// Codex's dispatcher sets it on the chat, and the Claude runner on the session, as it does for a new one.
    public func changeChatModel(taskId: String, to choice: TaskModelChoice, now: Date = Date()) throws {
        let thread = try write { db -> String in
            guard var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.invalid("The task is closed or missing.") }
            guard let link = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? AND role = 'work' ORDER BY rowid DESC LIMIT 1", arguments: [taskId]) else {
                throw StoreError.invalid("This task has no chat yet. It starts on the model you pick.")
            }
            guard link.provider == choice.provider else {
                throw StoreError.invalid("\(link.provider.name) can’t run \(choice.name). Continue in a new chat to move the task to \(choice.provider.name).")
            }
            let before = (task.workerModel, task.workerReasoningEffort, task.workerServiceTier)
            task.workerModel = choice.model; task.workerReasoningEffort = choice.effort
            task.workerServiceTier = choice.serviceTier; task.workerProvider = choice.provider
            task.revision += 1; task.updatedAt = now
            try task.update(db)
            switch choice.provider {
            case .claude:
                var session = try ClaudeSession.fetchOne(db, key: link.threadId)
                    ?? ClaudeSession(threadId: link.threadId, taskId: taskId, linkedAt: now, fast: false, configureState: "skipped")
                session.model = choice.model; session.effort = choice.effort; session.fast = choice.serviceTier != nil
                session.configureState = "pending"; session.configureClaimedAt = nil; session.configureNote = nil
                session.changedAt = now
                try session.save(db)
            case .codex:
                // A second pick before the first was set replaces it, and the model to come back to stays the one Codex had.
                let earlier = try ChatModelChange.fetchOne(db, key: link.threadId)
                try ChatModelChange(threadId: link.threadId, taskId: taskId, model: choice.model, effort: choice.effort, serviceTier: choice.serviceTier,
                                    previousModel: earlier?.previousModel ?? before.0, previousEffort: earlier?.previousEffort ?? before.1,
                                    previousServiceTier: earlier == nil ? before.2 : earlier?.previousServiceTier, requestedAt: now).save(db)
            }
            try TaskEvent(taskId: taskId, threadId: link.threadId, source: .user, kind: "chat.model.changed", payload: choice.model, at: now).insert(db)
            return link.threadId
        }
        signalRunners(thread)
    }

    /// Model changes waiting for Codex, oldest first.
    public func chatModelChanges() throws -> [ChatModelChange] {
        try db.read { try ChatModelChange.fetchAll($0, sql: "SELECT * FROM chatModelChanges ORDER BY requestedAt") }
    }

    /// Whether a model change came in after `date`, so the dispatcher's wait ends for it rather than for a message.
    func chatModelChangeArrived(after date: Date) throws -> Bool {
        try db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM chatModelChanges WHERE requestedAt > ?)", arguments: [date]) } == true
    }

    /// Codex set the change, or refused it. A refused one puts back what the task ran on, so Facienda shows the model
    /// the chat still has. A newer pick made meanwhile stays to be set.
    public func finishChatModelChange(_ change: ChatModelChange, applied: Bool, note: String? = nil, now: Date = Date()) throws {
        try write { db in
            guard let current = try ChatModelChange.fetchOne(db, key: change.threadId), current == change else { return }
            try current.delete(db)
            if !applied, var task = try FaciendaTask.fetchOne(db, key: change.taskId), task.workerModel == change.model {
                task.workerModel = change.previousModel; task.workerReasoningEffort = change.previousEffort
                task.workerServiceTier = change.previousServiceTier
                task.revision += 1; task.updatedAt = now
                try task.update(db)
            }
            try TaskEvent(taskId: change.taskId, threadId: change.threadId, source: .appServer, kind: applied ? "chat.model.applied" : "chat.model.unchanged",
                          payload: applied ? change.model : String((note ?? "").prefix(500)), at: now).insert(db)
        }
    }
}
