import Foundation
import FaciendaCore

public enum ThreadConversation {
    public static func read(_ response: JSONValue, threadId: String) throws -> CodexConversation {
        let thread = response["thread"]
        guard thread["id"].string == threadId, let turns = thread["turns"].array else {
            throw StoreError.invalid("Codex did not return the requested conversation.")
        }
        return CodexConversation(threadId: threadId, title: thread["name"].string ?? "Codex chat", turns: try turns.map(turn))
    }

    /// Recaps and task status need the newest messages, not the chat's tools and images or its entire history.
    public static func latest(_ threadId: String, bridge: CodexBridge) async throws -> CodexConversation {
        let response = try await bridge.readThread(threadId)
        let conversation = try await recent(threadId, since: .distantPast, bridge: bridge, maxPages: 1)
        let turns = conversation.turns.map { turn in
            let items = turn.items.compactMap { item -> JSONValue? in
                if let reply = AgentReply(item: item), reply.isFinal { return item }
                guard item["type"].string == "userMessage", var fields = item.object else { return nil }
                fields["content"] = .array((item["content"].array ?? []).filter { $0["type"].string == "text" })
                return .object(fields)
            }
            return CodexConversationTurn(id: turn.id, status: turn.status, startedAt: turn.startedAt,
                                         completedAt: turn.completedAt, error: turn.error, items: items)
        }
        return CodexConversation(threadId: threadId, title: response["thread"]["name"].string ?? "Codex chat", turns: turns)
    }

    /// Imports keep the exact first request even when it is older than the recent messages or the preview is cut off.
    public static func originalRequest(_ threadId: String, bridge: CodexBridge) async throws -> String? {
        var cursor: String?
        for _ in 0..<10 {
            let page = try await summaryPage(threadId, bridge: bridge, cursor: cursor, sortDirection: "asc")
            let response: JSONValue = .object(["thread": .object(["turns": .array(page.turns)])])
            if let request = AgentReply.originalRequest(in: response) { return request }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return nil
    }

    static func summaryPage(_ threadId: String, bridge: CodexBridge, cursor: String? = nil,
                            sortDirection: String = "desc", limit: Int = 20) async throws -> (turns: [JSONValue], nextCursor: String?) {
        try Task.checkCancellation()
        var params: [String: JSONValue] = ["threadId": .string(threadId), "limit": .number(Double(limit)),
                                          "sortDirection": .string(sortDirection), "itemsView": .string("summary")]
        if let cursor { params["cursor"] = .string(cursor) }
        let page = try await bridge.request("thread/turns/list", params: .object(params))
        guard let data = page["data"].array else { throw BridgeError.server("Codex did not return the requested conversation.") }
        let next = page["nextCursor"].string
        guard next == nil || next != cursor else { throw BridgeError.server("Codex repeated a conversation page.") }
        return (data, next)
    }

    /// The chat's newest turns, back to the first one that started before `since`, in Codex's summary form: each
    /// turn's user messages and final answer. A full read of a long chat can run to hundreds of megabytes, which
    /// Codex deprecates, and one such read held the shared connection so long that no other delivery got through.
    public static func recent(_ threadId: String, since: Date, bridge: CodexBridge, pageSize: Int = 20, maxPages: Int = 10) async throws -> CodexConversation {
        var turns: [JSONValue] = [], cursor: String?
        for _ in 0..<maxPages {
            let page = try await summaryPage(threadId, bridge: bridge, cursor: cursor, limit: pageSize)
            turns += page.turns
            // Pages run newest first, so a turn that started before `since` holds nothing sent after it.
            let next = page.nextCursor
            if next == nil || page.turns.contains(where: { ($0["startedAt"].number ?? .infinity) < since.timeIntervalSince1970 }) { break }
            cursor = next
        }
        return CodexConversation(threadId: threadId, title: "Codex chat", turns: try turns.reversed().map(turn))
    }

    private static func turn(_ turn: JSONValue) throws -> CodexConversationTurn {
        guard let id = turn["id"].string, let status = turn["status"].string,
              let items = turn["items"].array else { throw StoreError.invalid("Codex returned incomplete conversation data.") }
        // Internal reasoning and injected hook instructions are not public chat messages.
        let publicItems = items.filter { !["reasoning", "hookPrompt"].contains($0["type"].string ?? "") }
        return CodexConversationTurn(id: id, status: status,
            startedAt: turn["startedAt"].number.map { Date(timeIntervalSince1970: $0) },
            completedAt: turn["completedAt"].number.map { Date(timeIntervalSince1970: $0) },
            error: turn["error"], items: publicItems)
    }
}
