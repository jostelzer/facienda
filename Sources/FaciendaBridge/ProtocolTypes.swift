import Foundation
import FaciendaCore

public struct ThreadStartRequest: Encodable, Sendable {
    public let cwd: String
    public let developerInstructions: String
    public let approvalPolicy = "on-request"
    public let approvalsReviewer = "user"
    public let sandbox: String
    public let config: [String: JSONValue]
    public let ephemeral: Bool
    /// `mcpEnvironment` reaches the helper only, for probes that serve it a test library.
    public init(cwd: String, developerInstructions: String, scope: AutomationScope, mcpPath: String, mcpArguments: [String] = [], mcpEnvironment: [String: String] = [:], ephemeral: Bool = false, automaticReporting: Bool = true) {
        self.cwd = cwd; self.developerInstructions = developerInstructions
        self.ephemeral = ephemeral
        self.sandbox = scope == .autonomous ? "workspace-write" : "read-only"
        var server: [String: JSONValue] = [
            "command": .string(mcpPath), "args": .array(mcpArguments.map(JSONValue.string)), "required": .bool(true),
            "default_tools_approval_mode": .string("prompt"),
            "tools": .object(Dictionary(uniqueKeysWithValues: Self.reportingTools.map {
                ($0, .object(["approval_mode": .string(automaticReporting ? "approve" : "prompt")]))
            }))
        ]
        if !mcpEnvironment.isEmpty { server["env"] = .object(mcpEnvironment.mapValues(JSONValue.string)) }
        self.config = ["mcp_servers": .object(["facienda": .object(server)])]
    }
    // Only local reports and requests for human decisions. Other tools retain their policy.
    public static let reportingTools = ["facienda_current_task", "facienda_task_search", "facienda_memory_recall", "facienda_chat_search", "facienda_task_update", "facienda_request_decision", "facienda_schedule_followup", "facienda_propose_completion"]
}
public struct ThreadStartResponse: Decodable, Sendable { public let thread: CodexThread }
public struct ThreadIDRequest: Encodable, Sendable { public let threadId: String; public init(_ id: String) { threadId = id } }
public struct TurnStartRequest: Encodable, Sendable {
    public struct TextInput: Encodable, Sendable { let type = "text"; let text: String; let text_elements: [String] = [] }
    public let threadId: String
    public let input: [TextInput]
    public init(threadId: String, text: String) { self.threadId = threadId; input = [TextInput(text: text)] }
}
public struct TurnStartResponse: Decodable, Sendable {
    public struct Turn: Decodable, Sendable { public let id: String }
    public let turn: Turn
}

/// Codex routes MCP tool confirmations through the elicitation channel. Support
/// confirmation-only forms explicitly; forms needing input and URL flows remain
/// unsupported rather than being accepted with missing or invented answers.
public struct MCPToolApproval: Sendable {
    public let threadID: String
    public let serverName: String
    public let message: String
    public let arguments: JSONValue
    public let toolTitle: String
    public let supportsSessionApproval: Bool

    public init?(params: JSONValue) {
        guard params["mode"].string == "form",
              params["_meta"]["codex_approval_kind"].string == "mcp_tool_call",
              params["requestedSchema"]["type"].string == "object",
              params["requestedSchema"]["properties"].object?.isEmpty == true,
              (params["requestedSchema"]["required"].array ?? []).isEmpty,
              let thread = params["threadId"].string,
              let server = params["serverName"].string,
              let message = params["message"].string else { return nil }
        threadID = thread; serverName = server; self.message = message
        arguments = params["_meta"]["tool_params"]
        toolTitle = params["_meta"]["tool_title"].string ?? params["_meta"]["tool_name"].string ?? server
        let persistence = params["_meta"]["persist"]
        supportsSessionApproval = persistence.string == "session" || persistence.array?.contains(.string("session")) == true
    }

    public func response(accept: Bool) -> JSONValue {
        // No persistence metadata: every acceptance authorizes this call only.
        .object(["action": .string(accept ? "accept" : "decline"), "content": accept ? .object([:]) : .null])
    }

    /// The server, not the client, remembers the grant for this tool in this session.
    /// Never write an `always` grant or synthesize one when it was not offered.
    public func sessionResponse() throws -> JSONValue {
        guard supportsSessionApproval else { throw BridgeError.server("Codex did not offer session approval for this tool.") }
        return .object(["action": .string("accept"), "content": .object([:]), "_meta": .object(["persist": .string("session")])])
    }
}
extension CodexBridge {
    public func startThread(_ params: ThreadStartRequest) async throws -> CodexThread {
        try await request("thread/start", params: .encoded(params), timeout: .seconds(60)).decoded(ThreadStartResponse.self).thread
    }
    public func startTurn(_ params: TurnStartRequest) async throws -> String {
        try await request("turn/start", params: .encoded(params)).decoded(TurnStartResponse.self).turn.id
    }
    public func unsubscribe(_ id: String) async throws {
        _ = try await request("thread/unsubscribe", params: .encoded(ThreadIDRequest(id)))
    }
}
