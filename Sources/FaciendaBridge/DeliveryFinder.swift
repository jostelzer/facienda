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
        if let owner = dispatch.threadId {
            // A follow-up can only have gone to the chat it was addressed to.
            let response = try await bridge.readThread(owner)
            let conversation = try ThreadConversation.read(response, threadId: owner)
            let thread = CodexThread(id: owner, title: conversation.title, cwd: response["thread"]["cwd"].string ?? "", updatedAt: Date())
            return Result(chats: conversation.containsDelivery(dispatch.id) ? [thread] : [], complete: true)
        }
        // Listing is newest first; a minute of slack covers clock skew between the store and Codex.
        let since = dispatch.requestedAt.timeIntervalSince1970 - 60
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
                if try ThreadConversation.read(await bridge.readThread(thread.id), threadId: thread.id).containsDelivery(dispatch.id) { found.append(thread) }
            } catch let error as BridgeError {
                if case .disconnected = error { throw error }
                complete = false
            } catch { complete = false }
        }
        return Result(chats: found, complete: complete)
    }
}
