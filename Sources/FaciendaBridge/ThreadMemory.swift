import Foundation
import FaciendaCore

/// Captures only public messages from completed turns in explicitly linked task chats.
public enum ThreadMemory {
    public static func capture(_ response: JSONValue, threadId: String, store: FaciendaStore) throws {
        guard try store.memorySettings().enabled,
              let link = try store.links().first(where: { $0.codexThreadId == threadId }),
              response["thread"]["id"].string == threadId else { return }
        // Messages join the memory of the workspace the chat's task is in now.
        let space = try store.memorySpace(forTask: link.taskId).id
        // The dispatch already has a separately captured original request, so the shared
        // extraction never feeds retrieved memories, tool instructions or generated prompts back in.
        for message in PublicChatMessages.extract(response) where message.turnCompleted {
            let content = message.role == .user ? "User statement: \(message.text)" : "Assistant report, not independently verified: \(message.text)"
            try store.enqueueMemoryDocument(id: "thread-\(threadId)-turn-\(message.turnId)-item-\(message.itemId)", content: content,
                                            source: "Codex thread \(threadId), turn \(message.turnId), message \(message.itemId)", at: message.at, spaceID: space)
        }
    }
}
