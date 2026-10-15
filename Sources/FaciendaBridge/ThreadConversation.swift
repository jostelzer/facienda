import Foundation
import FaciendaCore

public enum ThreadConversation {
    public static func read(_ response: JSONValue, threadId: String) throws -> CodexConversation {
        let thread = response["thread"]
        guard thread["id"].string == threadId, let turns = thread["turns"].array else {
            throw StoreError.invalid("Codex did not return the requested conversation.")
        }
        let conversationTurns = try turns.map { turn in
            guard let id = turn["id"].string, let status = turn["status"].string,
                  let items = turn["items"].array else { throw StoreError.invalid("Codex returned incomplete conversation data.") }
            // Internal reasoning and injected hook instructions are not public chat messages.
            let publicItems = items.filter { !["reasoning", "hookPrompt"].contains($0["type"].string ?? "") }
            return CodexConversationTurn(id: id, status: status,
                startedAt: turn["startedAt"].number.map { Date(timeIntervalSince1970: $0) },
                completedAt: turn["completedAt"].number.map { Date(timeIntervalSince1970: $0) },
                error: turn["error"], items: publicItems)
        }
        return CodexConversation(threadId: threadId, title: thread["name"].string ?? "Codex chat", turns: conversationTurns)
    }
}
