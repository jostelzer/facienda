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

    /// The chat's newest turns, back to the first one that started before `since`, in Codex's summary form: each
    /// turn's user messages and final answer. A full read of a long chat can run to hundreds of megabytes, which
    /// Codex deprecates, and one such read held the shared connection so long that no other delivery got through.
    public static func recent(_ threadId: String, since: Date, bridge: CodexBridge, pageSize: Int = 20, maxPages: Int = 10) async throws -> CodexConversation {
        var turns: [JSONValue] = [], cursor: String?
        for _ in 0..<maxPages {
            var params: [String: JSONValue] = ["threadId": .string(threadId), "limit": .number(Double(pageSize)),
                                               "sortDirection": .string("desc"), "itemsView": .string("summary")]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await bridge.request("thread/turns/list", params: .object(params))
            guard let data = page["data"].array else { throw StoreError.invalid("Codex did not return the requested conversation.") }
            turns += data
            // Pages run newest first, so a turn that started before `since` holds nothing sent after it.
            let next = page["nextCursor"].string
            if next == nil || next == cursor || data.contains(where: { ($0["startedAt"].number ?? .infinity) < since.timeIntervalSince1970 }) { break }
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
