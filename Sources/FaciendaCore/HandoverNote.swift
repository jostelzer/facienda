import Foundation

/// What a task's new chat reads first when the user moves the task there from another one, often in the other app:
/// the old chat's last answer and its conversation, the user's words and the agent's replies without tool output.
/// Facienda writes it from what it already keeps, so it works even when the old agent can no longer answer.
public enum HandoverNote {
    static let eventKind = "thread.handover.note"
    /// Enough for a long conversation's recent part; older messages are left out first.
    static let limit = 60_000

    /// Where the note is and which chats it came from, kept on the task until its new chat takes it.
    public struct Record: Codable, Equatable, Sendable {
        public var file: String
        public var from: [ChatCandidate]
    }

    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: date)
    }

    public static func link(_ chat: ChatCandidate) -> String {
        chat.provider == .claude ? "claude://code/continue?session=" + chat.threadId : "codex://threads/" + chat.threadId
    }

    static func text(task: FaciendaTask, chats: [(link: ThreadLink, conversation: CodexConversation?)], lastAnswer: String?,
                     dispatches: [NativeDispatch], to choice: TaskModelChoice, at date: Date) -> String {
        let from = chats.map { chat in
            let name = chat.link.title.isEmpty ? "" : " “\(chat.link.title)”"
            return "\(chat.link.provider.name) chat\(name) (\(link(ChatCandidate(threadId: chat.link.threadId, provider: chat.link.provider, title: ""))))"
        }.joined(separator: " and ")
        var head = """
        # Handover

        The user moved this task from \(from) to a new \(choice.provider.name) chat on \(choice.name), \(date.formatted(.iso8601)).
        The task, its brief and next action, its answers and its memory stay with Facienda. Below is what the old chat knew.

        """
        if let lastAnswer, !lastAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            head += "\n## Its last saved answer\n\n\(lastAnswer.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        var lines: [String] = []
        for chat in chats {
            guard let conversation = chat.conversation else { continue }
            let agent = chat.link.provider.name
            for turn in conversation.turns {
                for message in turn.messages(originalRequest: task.title, dispatches: dispatches) where message.role != .automation && !message.isCommentary {
                    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    lines.append("**\(message.role == .user ? "User" : agent):**\n\(text)\n")
                }
            }
        }
        guard !lines.isEmpty else {
            return head + "\n## The conversation\n\nFacienda had no copy of the old chat's conversation. Open it with the link above if you need it.\n"
        }
        // Newest messages matter most to carry on, so the oldest give way when the note runs long.
        var kept: [String] = [], size = head.count
        for line in lines.reversed() {
            guard size + line.count <= limit || kept.isEmpty else { break }
            kept.insert(String(line.prefix(limit)), at: 0); size += line.count
        }
        let cut = kept.count < lines.count ? "\nThe \(lines.count - kept.count) earliest messages are left out.\n" : ""
        return head + "\n## The conversation, oldest first\n" + cut + "\n" + kept.joined(separator: "\n")
    }

    /// The start prompt's part for a task that moved here from another chat.
    static func prompt(_ record: Record) -> String {
        let chats = record.from.map { ($0.title.isEmpty ? "" : "“\($0.title)”, ") + "\($0.provider.name): " + link($0) }.joined(separator: "; ")
        return """
        HANDOVER: The user moved this task here from another chat (\(chats)). Carry on where it left off rather than starting over. Read the handover note first: \(record.file). It holds that chat's last answer and its conversation. The task's Brief and Next action lines above say where the work stood. Before changing files, look at the working folder's branch and uncommitted changes (git status, git diff): they may be the old chat's unfinished work, so build on them and keep them. That chat no longer carries the task: never message it or continue it.
        """
    }
}
