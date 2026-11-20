import Foundation

public struct MemoryUserMessage: Sendable {
    public var id: String
    public var turnID: String
    public var text: String
    public var at: Date
    public var precedingReply: String?
}

/// Reads source metadata rather than treating every public user-role item as something the person wrote.
public enum MemoryUserMessages {
    /// What an agent app writes into the person's turn that they did not write: a slash command and its output,
    /// background notices, another session's message, and the JSON that carries an answer back to a question.
    private static let envelopes = ["<task-notification", "<system-reminder", "<local-command", "<command-name", "<command-message", "<command-args",
                                    "<bash-", "<cross-session", "<send_user_message_question_reply", "<in-app-browser-context"]

    public static func isEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return envelopes.contains { trimmed.hasPrefix($0) }
    }

    /// Codex's composer puts what the app adds ahead of what the person typed: the page open in its browser, attached
    /// files, the text they pointed at. Their words follow the last "## My request:" line, with empty image tags after them.
    static func typed(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## My request:" }) else { return text }
        return lines[(header + 1)...].joined(separator: "\n").replacing(/<image\b[^>]*>\s*<\/image>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What opens a message the agent app wrote whole in the person's place: the summary that carries a long session
    /// on, a scheduled run, an interruption, and what Codex tells a new chat about the Mac.
    private static let machineOpenings = ["This session is being continued from a previous conversation", "[Request interrupted", "<heartbeat",
                                          "<turn_aborted", "<environment_context", "<user_instructions", "<subagent_notification"]

    /// The person's own words in a user-role chat message, or nil when the agent app wrote all of it. What the app
    /// only put around their words (a reminder, the open page, attached files, a question's JSON) is taken off.
    public static func words(in text: String) -> String? {
        let said = (answers(in: text) ?? typed(text)).replacing(/<system-reminder>.*?<\/system-reminder>/.dotMatchesNewlines(), with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !isEnvelope(said), !machineOpenings.contains(where: { said.hasPrefix($0) }) else { return nil }
        return characterReferences(said).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex's composer writes a space at a line's end as `&#x20;`. Only characters one can see are put back.
    private static func characterReferences(_ text: String) -> String {
        text.replacing(/&#(?:x([0-9A-Fa-f]{1,6})|([0-9]{1,7}));/) { match in
            let value = match.output.1.flatMap { UInt32($0, radix: 16) } ?? match.output.2.flatMap { UInt32($0) }
            guard let scalar = value.flatMap(Unicode.Scalar.init), ![.control, .format, .surrogate, .privateUse, .unassigned].contains(scalar.properties.generalCategory)
            else { return String(match.output.0) }
            return String(Character(scalar))
        }
    }

    /// A question's answer comes back as JSON that holds the question too. Only the answer is the person's words.
    private static func answers(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.range(of: "<send_user_message_question_reply>"), open.lowerBound == trimmed.startIndex,
              let close = trimmed.range(of: "</send_user_message_question_reply>", options: .backwards), open.upperBound <= close.lowerBound,
              let items = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed[open.upperBound..<close.lowerBound].utf8)).array else { return nil }
        return items.compactMap { $0["answer"].string }.joined(separator: "\n")
    }

    public static func codex(_ data: Data) -> [MemoryUserMessage] {
        var messages: [MemoryUserMessage] = [], precedingReply: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  record["type"].string == "response_item" else { continue }
            let item = record["payload"]
            guard item["type"].string == "message" else { continue }
            if item["role"].string == "assistant", item["phase"].string != "commentary" {
                precedingReply = (item["content"].array ?? []).filter { $0["type"].string == "output_text" }.compactMap { $0["text"].string }.joined(separator: "\n")
                continue
            }
            guard item["role"].string == "user", let id = item["id"].string else { continue }
            let metadata = item["internal_chat_message_metadata_passthrough"]
            guard let turnID = metadata["turn_id"].string, let kinds = metadata["content_item_kinds"].array,
                  let blocks = item["content"].array, kinds.count == blocks.count else { continue }
            let text = zip(kinds, blocks).compactMap { kind, block -> String? in
                guard kind.string == "user.text", block["type"].string == "input_text" else { return nil }
                return block["text"].string
            }.joined(separator: "\n")
            let said = answers(in: text) ?? typed(text)
            guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isEnvelope(said),
                  !machineOpenings.contains(where: { said.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0) }) else { continue }
            messages.append(.init(id: id, turnID: turnID, text: said,
                                  at: Date(timeIntervalSince1970: metadata["create_time"].number ?? 0), precedingReply: precedingReply))
        }
        return messages
    }

    public static func claude(_ data: Data) -> [MemoryUserMessage] {
        var messages: [MemoryUserMessage] = [], precedingReply: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  record["isSidechain"].bool != true, record["isMeta"].bool != true, record["faciendaSource"].string != "dispatch" else { continue }
            let message = record["message"], blocks = message["content"].array ?? []
            if record["type"].string == "assistant" {
                let reply = blocks.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
                if !reply.isEmpty { precedingReply = reply }
                continue
            }
            guard record["type"].string == "user", let id = record["uuid"].string,
                  record["origin"]["kind"].string.map({ $0 == "human" }) ?? true,
                  !blocks.contains(where: { $0["type"].string == "tool_result" }) else { continue }
            let text = message["content"].string ?? blocks.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
            // A session carried on from a summary, and the reminders an app puts around a message, are not the
            // person's words. Memory learned from two hundred such summaries as if they had said them.
            guard record["isCompactSummary"].bool != true, let said = words(in: text) else { continue }
            messages.append(.init(id: id, turnID: id, text: said, at: MemoryText.parseDate(record["timestamp"].string) ?? .distantPast,
                                  precedingReply: precedingReply))
        }
        return messages
    }
}

extension FaciendaStore {
    public func captureUserMessages(_ messages: [MemoryUserMessage], threadID: String, provider: AgentProvider) throws {
        guard try memorySettings().enabled,
              let link = try links().first(where: { $0.threadId == threadID && $0.provider == provider }) else { return }
        let space = try memorySpace(forTask: link.taskId).id
        let deliveries = try dispatches().filter { $0.taskId == link.taskId }.map(\.id)
        let kind: MemorySourceKind = provider == .codex ? .codexUser : .claudeUser
        // Older deliveries have a user-role envelope. Their recorded dispatch identity identifies the machine
        // source; the original user request and replies are captured separately from Facienda's events.
        let kept = messages.filter { message in !deliveries.contains(where: { message.text.contains("Facienda dispatch: \($0)") }) }
        // A whole transcript is read again each time it changes, so its messages share a few transactions.
        try enqueueMemoryDocuments(kept.map { message in
            PreparedMemoryDocument(id: "thread-\(threadID)-turn-\(message.turnID)-item-\(message.id)", content: message.text,
                                   source: "\(provider.name) thread \(threadID), turn \(message.turnID), message \(message.id)",
                                   at: message.at, spaceID: space, sourceKind: kind, taskID: link.taskId)
        }, utterances: kept.compactMap { message in
            PreparedUtterance(id: "thread-\(threadID)-turn-\(message.turnID)-item-\(message.id)", text: message.text,
                              source: "\(provider.name) thread \(threadID), turn \(message.turnID), message \(message.id)", kind: kind,
                              taskID: link.taskId, spaceID: space, at: message.at, priorResult: message.precedingReply)
        })
    }
}
