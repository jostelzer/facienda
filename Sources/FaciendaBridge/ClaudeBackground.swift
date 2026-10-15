import Foundation
import FaciendaCore

/// Facienda's background work on Claude: one locked-down Claude Code call per message, with no tools, no MCP servers,
/// none of the user's settings and no saved session, so nothing appears in Claude and nothing runs on the Mac. The
/// reply is forced into the request's schema. A conversation is kept here and sent whole with each message.
public actor ClaudeBackground {
    private struct Conversation {
        var system: String
        var model: String
        var exchanges: [(asked: String, answered: String)] = []
    }
    private var conversations: [String: Conversation] = [:]
    private let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("facienda-claude-sandbox")

    public init() {}

    /// Claude Code as the Claude app installs it, newest first, then a separately installed command.
    public static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundled = URL.applicationSupportDirectory.appending(path: "Claude/claude-code")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: bundled.path)) ?? [])
            .filter { $0.first?.isNumber == true }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        var candidates: [String] = []
        for version in versions {
            let folder = bundled.appending(path: version)
            for build in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                candidates.append(folder.appending(path: "\(build)/claude.app/Contents/MacOS/claude").path)
            }
        }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appending(path: ".local/bin/claude").path, home.appending(path: ".claude/local/claude").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func open(_ profile: EphemeralLuna.Profile, model: String) -> String {
        let id = UUID().uuidString
        conversations[id] = Conversation(system: profile.baseInstructions + "\n\n" + profile.developerInstructions, model: model)
        return id
    }

    public func close(_ id: String) { conversations[id] = nil }

    /// One message on an open conversation. Returns the reply as JSON text matching `schema`.
    public func ask(_ id: String, text: String, schema: JSONValue, timeout: Duration = .seconds(60)) async throws -> String {
        guard var conversation = conversations[id] else { throw BridgeError.server("This Claude conversation was closed.") }
        let message = conversation.exchanges.isEmpty ? text : (conversation.exchanges.map { "USER:\n\($0.asked)\n\nYOU:\n\($0.answered)" } + ["USER:\n\(text)"]).joined(separator: "\n\n")
        let reply = try await Self.run(system: conversation.system, model: conversation.model, message: message, schema: schema, cwd: cwd, timeout: timeout)
        conversation.exchanges.append((text, reply))
        conversations[id] = conversation
        return reply
    }

    /// A single call, for a process that asks once and ends.
    public static func complete(system: String, model: String, message: String, schema: JSONValue, timeout: Duration = .seconds(600)) async throws -> String {
        try await run(system: system, model: model, message: message, schema: schema,
                      cwd: FileManager.default.temporaryDirectory.appendingPathComponent("facienda-claude-sandbox"), timeout: timeout)
    }

    private static func run(system: String, model: String, message: String, schema: JSONValue, cwd: URL, timeout: Duration) async throws -> String {
        guard let executable = locate() else { throw BridgeError.server("Claude Code was not found on this Mac. Install the Claude app, or choose Codex for background work in Settings › Models.") }
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let arguments = ["-p", "--model", model, "--output-format", "json", "--json-schema", schema.json, "--system-prompt", system,
                         "--tools", "", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        // A Claude Code session that started this process must not pass its own session on.
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        let seconds = Double(timeout.components.seconds)
        let output: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                process.currentDirectoryURL = cwd; process.environment = environment
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deadline)
                    input.fileHandleForWriting.write(Data(message.utf8))
                    try input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    deadline.cancel()
                    continuation.resume(returning: data)
                } catch { deadline.cancel(); continuation.resume(throwing: error) }
            }
        }
        guard let receipt = try? JSONDecoder().decode(JSONValue.self, from: output) else {
            throw BridgeError.server("Claude Code gave no answer. Check that it is signed in.")
        }
        if receipt["is_error"].bool == true { throw BridgeError.server("Claude: " + (receipt["result"].string ?? "the request failed.")) }
        if receipt["structured_output"] != .null { return receipt["structured_output"].json }
        guard let text = receipt["result"].string, !text.isEmpty else { throw BridgeError.server("Claude returned no answer.") }
        return text
    }
}

/// The model for Facienda's background work, in whichever app the user chose (`ServiceModelChoice.current`).
/// It offers what a hidden Luna does: open a conversation, ask in it with a schema, close it.
public actor BackgroundModel {
    private let luna = EphemeralLuna()
    private let claude = ClaudeBackground()
    private static let claudePrefix = "claude:"

    public init() {}

    /// Whether the chosen app can do the work on this Mac.
    public static var isAvailable: Bool {
        ServiceModelChoice.current.provider == .claude ? ClaudeBackground.locate() != nil : CodexBridge.discoverExecutable() != nil
    }

    public func warm(executable: String? = nil) async throws {
        if ServiceModelChoice.current.provider == .claude {
            guard ClaudeBackground.locate() != nil else { throw BridgeError.server("Claude Code was not found on this Mac.") }
            return
        }
        try await luna.warm(executable: executable, model: ServiceModelChoice.current.model)
    }

    /// The reasoning efforts and service tiers the chosen model offers. Claude's background calls take neither.
    public func options() async throws -> (efforts: [String], tiers: [String]) {
        ServiceModelChoice.current.provider == .claude ? ([], []) : try await luna.options()
    }

    public func open(_ profile: EphemeralLuna.Profile) async throws -> String {
        let choice = ServiceModelChoice.current
        if choice.provider == .claude { return Self.claudePrefix + (await claude.open(profile, model: choice.model)) }
        return try await luna.open(profile, model: choice.model)
    }

    public func ask(_ threadID: String, text: String, schema: JSONValue, effort: String, serviceTier: String? = nil, timeout: Duration = .seconds(45)) async throws -> String {
        if threadID.hasPrefix(Self.claudePrefix) {
            // Claude Code takes longer to start than a warm Luna; give it room.
            return try await claude.ask(String(threadID.dropFirst(Self.claudePrefix.count)), text: text, schema: schema, timeout: max(timeout, .seconds(90)))
        }
        return try await luna.ask(threadID, text: text, schema: schema, effort: effort, serviceTier: serviceTier, timeout: timeout)
    }

    public func close(_ threadID: String) async {
        if threadID.hasPrefix(Self.claudePrefix) { await claude.close(String(threadID.dropFirst(Self.claudePrefix.count))) }
        else { await luna.close(threadID) }
    }

    public func shutdown() async { await luna.shutdown() }
}
