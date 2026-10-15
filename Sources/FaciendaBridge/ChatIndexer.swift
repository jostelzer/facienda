import Foundation
import FaciendaCore

/// The public part of a chat: the user's own messages and Codex's final replies.
/// Reasoning, tool output, progress commentary and Facienda dispatch prompts are left out.
public struct PublicChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, codex }
    public let turnId: String
    public let itemId: String
    public let role: Role
    public let text: String
    public let at: Date
    public let turnCompleted: Bool
    public var messageId: String { turnId + ":" + itemId }
}

public enum PublicChatMessages {
    public static func extract(_ response: JSONValue) -> [PublicChatMessage] {
        let thread = response["thread"]
        return (thread["turns"].array ?? []).flatMap { turn -> [PublicChatMessage] in
            guard let turnId = turn["id"].string else { return [] }
            let at = Date(timeIntervalSince1970: turn["completedAt"].number ?? turn["startedAt"].number ?? thread["createdAt"].number ?? 0)
            let completed = turn["status"].string == "completed"
            return (turn["items"].array ?? []).compactMap { item in
                guard let itemId = item["id"].string else { return nil }
                if item["type"].string == "userMessage" {
                    let text = (item["content"].array ?? []).filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
                    // Dispatch prompts carry retrieved memory and runner instructions, not the user's words.
                    guard !text.contains("Facienda dispatch:"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return PublicChatMessage(turnId: turnId, itemId: itemId, role: .user, text: text, at: at, turnCompleted: completed)
                }
                guard let reply = AgentReply(item: item), reply.isFinal else { return nil }
                return PublicChatMessage(turnId: turnId, itemId: itemId, role: .codex, text: reply.text, at: at, turnCompleted: completed)
            }
        }
    }
}

extension ChatListing {
    public init(_ thread: CodexThread) {
        self.init(threadId: thread.id, title: thread.title, cwd: thread.cwd, updatedAt: thread.updatedAt)
    }
}

extension CodexThread {
    /// A chat known from the index, for importing or linking it without another listing.
    public init(id: String, title: String, cwd: String, updatedAt: Date) {
        self.init(id: id, name: title, preview: "", cwd: cwd, updatedAt: updatedAt.timeIntervalSince1970, status: .null)
    }
}

/// Keeps the chat index current in small steps: the newest listing page, one older page while
/// the first walk runs, then a few changed chats. Reads only; never touches a chat.
public actor ChatIndexer {
    public let bridge: CodexBridge
    public let index: ChatIndex
    private var listedAt = Date.distantPast

    public init(bridge: CodexBridge, index: ChatIndex) {
        self.bridge = bridge; self.index = index
    }

    @discardableResult public func step(reads: Int = 3, relistAfter: TimeInterval = 60) async throws -> ChatIndexProgress {
        var state = try index.listingState()
        if Date().timeIntervalSince(listedAt) >= relistAfter {
            let newest = try await bridge.listThreads()
            try index.record(newest.data.map(ChatListing.init))
            listedAt = Date()
            if !state.complete && state.cursor == nil {
                if let next = newest.nextCursor { try index.setListingState(cursor: next, complete: false) }
                else { try index.setListingState(cursor: nil, complete: true) }
                state = try index.listingState()
            }
        }
        if !state.complete, let cursor = state.cursor {
            let page = try await bridge.listThreads(cursor: cursor)
            try index.record(page.data.map(ChatListing.init))
            // A server that hands back the same cursor has nothing older.
            let next = page.nextCursor.flatMap { $0 == cursor ? nil : $0 }
            try index.setListingState(cursor: next, complete: next == nil)
        }
        for chat in try index.pending(limit: reads) {
            try Task.checkCancellation()
            do {
                let response = try await bridge.request("thread/read", params: .object(["threadId": .string(chat.threadId), "includeTurns": .bool(true)]), timeout: .seconds(90))
                guard response["thread"]["id"].string == chat.threadId else { throw BridgeError.server("Codex returned a different chat.") }
                let messages = PublicChatMessages.extract(response).map {
                    ChatText(messageId: $0.messageId, role: $0.role == .user ? .user : .codex, at: $0.at, text: $0.text)
                }
                try index.replace(threadId: chat.threadId, messages: messages, updatedAt: chat.updatedAt)
            } catch let error as BridgeError {
                if case .disconnected = error { throw error }
                try index.fail(threadId: chat.threadId, error: error.localizedDescription)
            }
        }
        return try index.progress()
    }
}
