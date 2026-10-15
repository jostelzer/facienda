import Foundation
import FaciendaCore

/// Completed assistant messages, excluding tool output and internal reasoning.
public struct AgentReply: Sendable {
    public let text: String
    public let isFinal: Bool

    public init?(item: JSONValue) {
        guard item["type"].string == "agentMessage", let text = item["text"].string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text
        // Older servers omit phase; their completed assistant message is still useful output.
        isFinal = item["phase"].string != "commentary"
    }

    public static func latestResult(in response: JSONValue) -> AgentReply? {
        for turn in (response["thread"]["turns"].array ?? []).reversed() where turn["status"].string == "completed" {
            for item in (turn["items"].array ?? []).reversed() {
                if let reply = AgentReply(item: item), reply.isFinal { return reply }
            }
        }
        return nil
    }

    /// The first thing you asked. A chat an agent started opens with a turn of its own work, so the request
    /// can sit in a later turn, as in Codex's own preview.
    public static func originalRequest(in response: JSONValue) -> String? {
        for turn in response["thread"]["turns"].array ?? [] {
            for item in turn["items"].array ?? [] where item["type"].string == "userMessage" {
                let text = (item["content"].array ?? []).filter { $0["type"].string == "text" }
                    .compactMap { $0["text"].string }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
        }
        return nil
    }
}
