import Foundation

/// A chat as Codex lists it. `updatedAt` is Codex's own timestamp in seconds.
public struct ChatListing: Sendable, Equatable {
    public var threadId: String
    public var title: String
    public var cwd: String
    public var updatedAt: Double
    public init(threadId: String, title: String, cwd: String, updatedAt: Double) {
        self.threadId = threadId; self.title = title; self.cwd = cwd; self.updatedAt = updatedAt
    }
}

/// The chats that belong to one workspace: those linked to its tasks, and those Codex
/// ran in one of its tasks' folders.
public struct ChatScope: Sendable, Equatable {
    public var threadIds: Set<String>
    public var directories: [String]
    public init(threadIds: Set<String>, directories: [String]) {
        self.threadIds = threadIds
        self.directories = directories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
    public func contains(threadId: String, cwd: String) -> Bool {
        if threadIds.contains(threadId) { return true }
        guard !cwd.isEmpty else { return false }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return directories.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

/// One indexed message: the user's own words or Codex's final reply.
public struct ChatText: Sendable, Equatable {
    public enum Role: String, Sendable { case user, codex }
    /// "turnId:itemId", the same identity the conversation view uses.
    public var messageId: String
    public var role: Role
    public var at: Date?
    public var text: String
    public init(messageId: String, role: Role, at: Date?, text: String) {
        self.messageId = messageId; self.role = role; self.at = at; self.text = text
    }
}

public struct ChatMatch: Sendable, Equatable, Identifiable {
    public var messageId: String
    public var role: ChatText.Role
    public var at: Date?
    /// Highlighted terms are wrapped in ChatIndex.highlightStart/End.
    public var snippet: String
    public var id: String { messageId }
}

public struct ChatHit: Sendable, Equatable, Identifiable {
    public var threadId: String
    public var title: String
    public var cwd: String
    public var updatedAt: Date
    public var titleMatched: Bool
    public var matches: [ChatMatch]
    public var id: String { threadId }
}

/// A whole message, for answering a question from the user's chats.
public struct ChatPassage: Sendable, Equatable {
    public var threadId: String
    public var title: String
    public var messageId: String
    public var role: ChatText.Role
    public var at: Date?
    public var text: String
}

public struct ChatIndexProgress: Sendable, Equatable {
    public var known: Int
    public var indexed: Int
    public var failed: Int
    public var listingComplete: Bool
    public var building: Bool { !listingComplete || indexed + failed < known }
    public init(known: Int, indexed: Int, failed: Int, listingComplete: Bool) {
        self.known = known; self.indexed = indexed; self.failed = failed; self.listingComplete = listingComplete
    }
}
