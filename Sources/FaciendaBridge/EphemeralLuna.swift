import Foundation
import FaciendaCore

/// One warm, locked-down Codex process for short hidden conversations with Luna.
/// Threads are ephemeral and have no tools, files or network. Each turn is forced into a schema.
public actor EphemeralLuna {
    public struct Profile: Sendable {
        public var id: String
        public var baseInstructions: String
        public var developerInstructions: String
        public var reasoningEffort: String
        public init(id: String, baseInstructions: String, developerInstructions: String, reasoningEffort: String) {
            self.id = id; self.baseInstructions = baseInstructions; self.developerInstructions = developerInstructions; self.reasoningEffort = reasoningEffort
        }
    }

    private let bridge = CodexBridge()
    private var config: JSONValue?
    private var busy = false
    /// The Codex model this process answers with, and each open thread's.
    private var model = MemoryInferenceRequest.model
    private var models: [String: String] = [:]
    private let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("facienda-luna-sandbox")

    public init() {}

    public static func startParameters(cwd: String, effectiveConfig: JSONValue, profile: Profile, model: String = MemoryInferenceRequest.model) -> JSONValue {
        let disabledServers = (effectiveConfig["mcp_servers"].object ?? [:]).mapValues { _ in JSONValue.object(["enabled": .bool(false)]) }
        let disabledPlugins = (effectiveConfig["plugins"].object ?? [:]).mapValues { _ in JSONValue.object(["enabled": .bool(false)]) }
        return .object([
            "cwd": .string(cwd), "ephemeral": .bool(true), "model": .string(model), "modelProvider": .string("openai"),
            "approvalPolicy": .string("untrusted"), "permissions": .string(profile.id),
            "baseInstructions": .string(profile.baseInstructions),
            "developerInstructions": .string(profile.developerInstructions),
            "config": .object([
                "permissions": .object([profile.id: .object([
                    "filesystem": .object([":root": .string("deny"), cwd: .string("read")]),
                    "network": .object(["enabled": .bool(false)])
                ])]),
                "mcp_servers": .object(disabledServers), "plugins": .object(disabledPlugins),
                "model_reasoning_effort": .string(profile.reasoningEffort),
                "web_search": .string("disabled"), "project_doc_max_bytes": .number(0),
                "features": .object(["shell_tool": .bool(false), "unified_exec": .bool(false), "multi_agent": .bool(false), "apps": .bool(false), "codex_hooks": .bool(false), "skill_mcp_dependency_install": .bool(false)]),
                "memories": .object(["generate_memories": .bool(false), "use_memories": .bool(false)])
            ])
        ])
    }

    /// Starts the process and checks the account and provider once. Safe to call again.
    public func warm(executable: String? = nil, model: String? = nil) async throws {
        if let model { self.model = model }
        if config != nil, await bridge.isConnected { return }
        config = nil
        guard let executable = executable ?? CodexBridge.discoverExecutable() else { throw BridgeError.unavailable }
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try await bridge.connect(executable: executable, arguments: EphemeralMemoryInference.serverArguments)
            guard try await bridge.accountStatus().isReady else { throw BridgeError.server("Sign in to Codex to describe a wait in your own words.") }
            let read = try await bridge.request("config/read", params: .object(["includeLayers": .bool(false)]))
            try EphemeralMemoryInference.validateProviderConfig(read["config"])
            config = read["config"]
        } catch { await bridge.disconnect(); config = nil; throw error }
    }

    /// The reasoning efforts and service tiers Codex advertises for Luna.
    public func options() async throws -> (efforts: [String], tiers: [String]) {
        try await warm()
        let list = try await bridge.request("model/list", params: .object(["limit": .number(100)]))
        let model = model
        let entry = list["data"].array?.first { $0["model"].string == model || $0["id"].string == model }
        return ((entry?["supportedReasoningEfforts"].array ?? []).compactMap { $0["reasoningEffort"].string },
                (entry?["serviceTiers"].array ?? []).compactMap { $0["id"].string })
    }

    public func open(_ profile: Profile, model: String? = nil) async throws -> String {
        try await warm()
        guard let config else { throw BridgeError.disconnected }
        let model = model ?? self.model
        let started: JSONValue
        do { started = try await bridge.request("thread/start", params: Self.startParameters(cwd: cwd.path, effectiveConfig: config, profile: profile, model: model), timeout: .seconds(60)) }
        catch BridgeError.disconnected { self.config = nil; throw BridgeError.disconnected }
        guard started["thread"]["ephemeral"].bool == true, started["model"].string == model,
              started["modelProvider"].string == "openai", started["activePermissionProfile"]["id"].string == profile.id,
              let id = started["thread"]["id"].string else {
            throw BridgeError.server("Codex did not confirm a hidden, tool-free Luna thread.")
        }
        models[id] = model
        return id
    }

    /// One turn on an open thread. The thread remembers earlier turns.
    public func ask(_ threadID: String, text: String, schema: JSONValue, effort: String, serviceTier: String? = nil, timeout: Duration = .seconds(45)) async throws -> String {
        guard !busy else { throw BridgeError.server("Still thinking about the previous message.") }
        busy = true; defer { busy = false }
        var params = try JSONValue.encoded(TurnStartRequest(threadId: threadID, text: text)).object ?? [:]
        params["model"] = .string(models[threadID] ?? model); params["effort"] = .string(effort)
        params["outputSchema"] = schema
        if let serviceTier { params["serviceTier"] = .string(serviceTier) }
        // Subscribe first so no notification sent right after turn/start is missed.
        let events = bridge.subscribe()
        let turn: JSONValue
        do { turn = try await bridge.request("turn/start", params: .object(params)) }
        catch BridgeError.disconnected { config = nil; throw BridgeError.disconnected }
        guard let turnID = turn["turn"]["id"].string else { throw BridgeError.server("Codex returned no turn.") }
        let bridge = bridge
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Self.observe(events, bridge: bridge, threadID: threadID, turnID: turnID) }
                group.addTask { try await Task.sleep(for: timeout); throw BridgeError.timeout("Luna") }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw BridgeError.disconnected }
                return result
            }
        } catch {
            _ = try? await bridge.request("turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
            if case BridgeError.disconnected = error { config = nil }
            throw error
        }
    }

    public func close(_ threadID: String) async { models[threadID] = nil; try? await bridge.unsubscribe(threadID) }

    /// True when Codex kept the thread out of the stored chat list.
    public func isHidden(_ threadID: String) async throws -> Bool {
        try await !bridge.listThreads().data.contains { $0.id == threadID }
    }

    public func shutdown() async { await bridge.disconnect(); config = nil }

    private static func observe(_ events: AsyncStream<BridgeMessage>, bridge: CodexBridge, threadID: String, turnID: String) async throws -> String {
        var final: String?
        for await message in events {
            try Task.checkCancellation()
            if message.method == "facienda/disconnected" { throw BridgeError.disconnected }
            if let id = message.requestID {
                try await bridge.rejectUnsupported(id: id)
                throw BridgeError.server("Luna attempted an unsupported interactive operation.")
            }
            guard message.params["threadId"].string == threadID else { continue }
            if ["item/started", "item/completed"].contains(message.method), message.params["turnId"].string == turnID,
               let kind = message.params["item"]["type"].string,
               !["agentMessage", "reasoning", "userMessage", "contextCompaction"].contains(kind) {
                throw BridgeError.server("Luna attempted an unsupported operation; the turn was stopped.")
            }
            if message.method == "item/completed", message.params["turnId"].string == turnID,
               let reply = AgentReply(item: message.params["item"]), reply.isFinal { final = reply.text }
            if message.method == "turn/completed", message.params["turn"]["id"].string == turnID {
                guard message.params["turn"]["status"].string == "completed", let final else {
                    throw BridgeError.server("Luna did not finish the reply.")
                }
                return final
            }
        }
        throw BridgeError.disconnected
    }
}

extension EphemeralLuna.Profile {
    public static let headline = Self(id: "facienda-headline", baseInstructions: HeadlineWriter.baseInstructions,
        developerInstructions: HeadlineWriter.developerInstructions, reasoningEffort: HeadlineWriter.reasoningEffort)
    public static let name = Self(id: "facienda-name", baseInstructions: HeadlineWriter.baseInstructions,
        developerInstructions: TaskNameWriter.developerInstructions, reasoningEffort: TaskNameWriter.reasoningEffort)
    public static let groupName = Self(id: "facienda-group-name", baseInstructions: HeadlineWriter.baseInstructions,
        developerInstructions: GroupNameWriter.developerInstructions, reasoningEffort: GroupNameWriter.reasoningEffort)
    public static let wait = Self(id: "facienda-wait", baseInstructions: WaitCompiler.baseInstructions,
        developerInstructions: WaitCompiler.developerInstructions, reasoningEffort: WaitCompiler.reasoningEffort)
    public static let nextSteps = Self(id: "facienda-next-steps", baseInstructions: NextStepWriter.baseInstructions,
        developerInstructions: NextStepWriter.developerInstructions, reasoningEffort: NextStepWriter.reasoningEffort)
    public static let ownStep = Self(id: "facienda-own-step", baseInstructions: OwnStepReader.baseInstructions,
        developerInstructions: OwnStepReader.developerInstructions, reasoningEffort: OwnStepReader.reasoningEffort)
    public static let finder = Self(id: "facienda-finder", baseInstructions: TaskFinder.baseInstructions,
        developerInstructions: TaskFinder.developerInstructions, reasoningEffort: TaskFinder.reasoningEffort)
    public static let reader = Self(id: "facienda-reader", baseInstructions: BarReader.baseInstructions,
        developerInstructions: BarReader.developerInstructions, reasoningEffort: BarReader.reasoningEffort)
    public static let recap = Self(id: "facienda-recap", baseInstructions: RecapWriter.baseInstructions,
        developerInstructions: RecapWriter.developerInstructions, reasoningEffort: RecapWriter.reasoningEffort)
}
