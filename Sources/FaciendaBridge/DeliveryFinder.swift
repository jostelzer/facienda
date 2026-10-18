import Foundation
import FaciendaCore

/// Looks for the chat that received an uncertain delivery by its exact marker line.
/// Reads only; never sends to or changes a chat.
public enum DeliveryFinder {
    public struct Result: Equatable, Sendable {
        /// Chats that hold this delivery's marker.
        public var chats: [CodexThread]
        /// Every chat active since the delivery was requested was read.
        public var complete: Bool
    }

    /// The runner's own chat is skipped: its create/send call carries the same marker.
    public static func find(_ dispatch: NativeDispatch, runnerThreadId: String?, bridge: CodexBridge, maxPages: Int = 5) async throws -> Result {
        // A minute of slack covers clock skew between the store and Codex. Only turns since then are read.
        let sent = dispatch.requestedAt.addingTimeInterval(-60)
        if let owner = dispatch.threadId {
            // A follow-up can only have gone to the chat it was addressed to.
            let conversation = try await ThreadConversation.recent(owner, since: sent, bridge: bridge)
            let thread = CodexThread(id: owner, title: conversation.title, cwd: "", updatedAt: Date())
            if conversation.containsDelivery(dispatch.id) { return Result(chats: [thread], complete: true) }
            // An accepted queued message can still start. Absence from history alone never permits "send again".
            let pending = try await CodexAppDelivery.queued(dispatch, bridge: bridge)
            return Result(chats: [], complete: pending == nil && dispatch.codexQueuePreparedAt == nil)
        }
        // Listing is newest first.
        let since = sent.timeIntervalSince1970
        var candidates: [CodexThread] = [], cursor: String?, complete = false
        for _ in 0..<maxPages {
            let page = try await bridge.listThreads(cursor: cursor)
            candidates += page.data.filter { $0.updatedAt >= since && $0.id != runnerThreadId }
            if page.data.contains(where: { $0.updatedAt < since }) || page.nextCursor == nil || page.nextCursor == cursor { complete = true; break }
            cursor = page.nextCursor
        }
        var found: [CodexThread] = []
        for thread in candidates {
            try Task.checkCancellation()
            do {
                if try await ThreadConversation.recent(thread.id, since: sent, bridge: bridge).containsDelivery(dispatch.id) { found.append(thread) }
            } catch let error as BridgeError {
                if case .disconnected = error { throw error }
                complete = false
            } catch { complete = false }
        }
        return Result(chats: found, complete: complete)
    }
}
