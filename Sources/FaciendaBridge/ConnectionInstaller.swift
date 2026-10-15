import Foundation
import FaciendaCore

public struct ConnectionPlan: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let hooksURL: URL
    public let originalHooks: Data?
    public let originalConfig: Data?
    public let proposedHooks: Data
    public let cliArguments: [String]
    public let executable: String
    public let preview: String
    /// Connecting would change nothing: the MCP server is registered and the hooks are in place.
    public var upToDate = false
}

/// Plans are inert. Only the explicit Apply action calls apply; no startup installation.
public actor ConnectionInstaller {
    private let codexHome: URL
    private let backupRoot: URL
    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"), backupRoot: URL = URL.applicationSupportDirectory.appending(path: "Facienda/ConnectionBackups")) {
        self.codexHome = codexHome; self.backupRoot = backupRoot
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Only the events that change a task: a turn starting (which also hands over the task's context), an approval
    /// request, work resuming after it, and the turn ending or being stopped. Tool starts and session edges add nothing.
    static let hookEvents: Set<String> = ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt"]
    private static func isFaciendaHook(_ handler: JSONValue, command: String) -> Bool {
        guard handler["statusMessage"].string == "Facienda lifecycle", let existing = handler["command"].string else { return false }
        return existing == command || existing.hasSuffix("/facienda-hook'")
    }
    public func plan(executable: String, mcpPath: String, hookPath: String, disconnect: Bool) async throws -> ConnectionPlan {
        guard FileManager.default.isExecutableFile(atPath: mcpPath), FileManager.default.isExecutableFile(atPath: hookPath) else { throw StoreError.invalid("The bundled helpers are missing. Build Facienda with scripts/build.sh first.") }
        let hooksURL = codexHome.appending(path: "hooks.json"), configURL = codexHome.appending(path: "config.toml")
        let original = try readIfExists(hooksURL), config = try readIfExists(configURL)
        var root = original == nil ? [:] : (try JSONDecoder().decode(JSONValue.self, from: original!)).object ?? [:]
        if let original, (try JSONDecoder().decode(JSONValue.self, from: original)).object == nil { throw StoreError.invalid("hooks.json must contain an object.") }
        if let value = root["hooks"], value.object == nil { throw StoreError.invalid("Existing hooks configuration is not an object. No changes were made.") }
        var hooks = root["hooks"]?.object ?? [:]
        let command = Self.shellQuote(hookPath)
        for event in Set(hooks.keys).union(Self.hookEvents).sorted() {
            if let value = hooks[event], value.array == nil { throw StoreError.invalid("Existing \(event) hooks are not an array. No changes were made.") }
            var groups = hooks[event]?.array ?? []
            // Remove entries from any Facienda build, wherever it lived, preserving all other handlers.
            groups = groups.compactMap { group in
                guard var object = group.object, let handlers = object["hooks"]?.array else { return group }
                let retained = handlers.filter { !Self.isFaciendaHook($0, command: command) }
                if retained.count == handlers.count { return group }
                guard !retained.isEmpty else { return nil }
                object["hooks"] = .array(retained); return .object(object)
            }
            if !disconnect, Self.hookEvents.contains(event) {
                groups.append(.object(["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(1), "statusMessage": .string("Facienda lifecycle")])])]))
            }
            hooks[event] = groups.isEmpty ? nil : .array(groups)
        }
        root["hooks"] = .object(hooks)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let proposed = try encoder.encode(JSONValue.object(root))
        let args = disconnect ? ["mcp", "remove", "facienda"] : ["mcp", "add", "facienda", "--", mcpPath]
        // Prevent taking over a same-name server that belongs to the user or another install.
        let existing = try await Self.run(executable, ["mcp", "get", "facienda", "--json"], acceptFailure: true)
        if existing.status == 0 {
            let data = try JSONDecoder().decode(JSONValue.self, from: existing.data)
            guard data["transport"]["command"].string == mcpPath else { throw StoreError.invalid("A different MCP server named facienda is already registered. Review it in Codex before connecting this build.") }
        }
        let unchangedHooks = try original.map { try JSONDecoder().decode(JSONValue.self, from: $0) } == JSONValue.object(root)
        let preview = "Command:\n" + ([executable] + args).map(Self.shellQuote).joined(separator: " ") + "\n\nWrite \(hooksURL.path):\n" + String(decoding: proposed, as: UTF8.self) + "\n\nOriginal hooks.json and config.toml will be backed up in \(backupRoot.path).\n\nAfter connecting, review and trust these hooks with /hooks in Codex. Installation alone does not activate untrusted hooks."
        var plan = ConnectionPlan(title: disconnect ? "Disconnect Codex" : "Connect Codex", hooksURL: hooksURL, originalHooks: original, originalConfig: config, proposedHooks: proposed, cliArguments: args, executable: executable, preview: preview)
        plan.upToDate = !disconnect && existing.status == 0 && unchangedHooks
        return plan
    }
    /// Each connect keeps the files it replaced. Only the most recent ones are worth keeping.
    func pruneBackups(keeping count: Int) {
        let files = FileManager.default
        let folders = ((try? files.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for folder in folders.dropFirst(count) { try? files.removeItem(at: folder) }
    }
    public func apply(_ plan: ConnectionPlan) async throws {
        let configURL = codexHome.appending(path: "config.toml")
        guard try readIfExists(plan.hooksURL) == plan.originalHooks, try readIfExists(configURL) == plan.originalConfig else { throw StoreError.conflict }
        let backup = backupRoot.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = plan.originalHooks { try data.write(to: backup.appending(path: "hooks.json"), options: .atomic) }
        if let data = plan.originalConfig { try data.write(to: backup.appending(path: "config.toml"), options: .atomic) }
        try Data(plan.preview.utf8).write(to: backup.appending(path: "change.txt"), options: .atomic)
        pruneBackups(keeping: 10)
        _ = try await Self.run(plan.executable, plan.cliArguments)
        guard try readIfExists(plan.hooksURL) == plan.originalHooks else { throw StoreError.invalid("MCP registration changed, but hooks.json changed during installation. Review a fresh plan; existing hooks were preserved.") }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try plan.proposedHooks.write(to: plan.hooksURL, options: .atomic)
    }
    private func readIfExists(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }; return try Data(contentsOf: url)
    }
    private struct Output: Sendable { let status: Int32; let data: Data }
    private static func run(_ executable: String, _ arguments: [String], acceptFailure: Bool = false) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "org.facienda.connection").async {
                do {
                    let process = Process(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                    process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); watchdog.cancel()
                    guard acceptFailure || process.terminationStatus == 0 else { throw StoreError.invalid("Codex registration failed (exit \(process.terminationStatus)). Backups were preserved.") }
                    continuation.resume(returning: Output(status: process.terminationStatus, data: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
