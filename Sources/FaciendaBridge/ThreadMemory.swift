import Foundation
import FaciendaCore

/// Captures only public messages from completed turns in explicitly linked task chats.
public enum ThreadMemory {
    public static func capture(_ response: JSONValue, threadId: String, store: FaciendaStore) throws {
        guard try store.memorySettings().enabled,
              try store.links().contains(where: { $0.codexThreadId == threadId && $0.provider == .codex }),
              response["thread"]["id"].string == threadId else { return }
        // The public API flattens injected context into user messages. The rollout retains typed provenance.
        guard let file = CodexRollout.locate(threadId: threadId) else { return }
        let messages = MemoryUserMessages.codex(try Data(contentsOf: file, options: .mappedIfSafe))
        try store.captureUserMessages(messages, threadID: threadId, provider: .codex)
    }
}
