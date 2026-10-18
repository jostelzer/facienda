import Foundation
import GRDB

extension FaciendaStore {
    /// Save the destination before queue/add. A crash afterwards can inspect that exact chat without resending.
    /// Linking before the app wakes also lets the agent resolve its task on its very first tool call.
    public func prepareCodexQueue(_ id: String, runnerId: String, threadId: String) throws {
        guard !threadId.isEmpty else { throw StoreError.invalid("A native chat ID is required.") }
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.runnerId == runnerId,
                  item.agent == .codex, item.state == "dispatching", item.availableAt == nil,
                  item.codexQueueId == nil, let task = try FaciendaTask.fetchOne(db, key: item.taskId) else { throw StoreError.conflict }
            if let expected = item.threadId, expected != threadId { throw StoreError.conflict }
            if let link = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [threadId]) {
                guard link.taskId == item.taskId else { throw StoreError.conflict }
            } else {
                try ThreadLink(taskId: item.taskId, codexThreadId: threadId, linkedBy: "native runner", title: task.displayTitle ?? task.displayName, provider: .codex).insert(db)
            }
            item.threadId = threadId; item.codexQueuePreparedAt = Date(); try item.update(db)
        }
    }

    /// Acceptance is not execution. Keep the entry pending until its marker appears in the native conversation.
    public func recordCodexQueue(_ id: String, runnerId: String, queuedSubmissionId: String) throws {
        guard !queuedSubmissionId.isEmpty else { throw StoreError.invalid("A Codex queue receipt is required.") }
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.runnerId == runnerId,
                  item.agent == .codex, item.state == "dispatching", item.threadId != nil,
                  item.availableAt == nil else { throw StoreError.conflict }
            if let receipt = item.codexQueueId, receipt != queuedSubmissionId { throw StoreError.conflict }
            item.codexQueueId = queuedSubmissionId; try item.update(db)
        }
    }

    public func codexQueuedDeliveries(runnerId: String) throws -> [NativeDispatch] {
        try db.read { try NativeDispatch.fetchAll($0, sql: "SELECT * FROM dispatches WHERE runnerId = ? AND state = 'dispatching' AND availableAt IS NULL AND codexQueueId IS NOT NULL ORDER BY requestedAt", arguments: [runnerId]) }
    }
}
