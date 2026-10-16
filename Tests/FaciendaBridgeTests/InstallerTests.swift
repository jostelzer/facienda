import Foundation
import Testing
import FaciendaCore
@testable import FaciendaBridge

private func installation() throws -> (ConnectionInstaller, URL, String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "FaciendaInstallerTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appending(path: "codex-fixture")
    try Data("#!/bin/sh\nif [ \"$2\" = get ]; then exit 1; fi\nexit 0\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    return (ConnectionInstaller(codexHome: root, backupRoot: root.appending(path: "backups")), root, fake.path)
}

@Test func installerPreservesOtherHooksAndIsReversible() async throws {
    let (installer, root, executable) = try installation()
    let original = Data(#"{"description":"My hooks","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-existing-hook"}]}]}}"#.utf8)
    let url = root.appending(path: "hooks.json")
    try original.write(to: url)
    let plan = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false)
    #expect(try Data(contentsOf: url) == original) // Preview alone never changes a file.
    try await installer.apply(plan)
    let installed = try Data(contentsOf: url)
    let repeated = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false)
    #expect(repeated.proposedHooks == installed) // Idempotent.
    let disconnect = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: true)
    try await installer.apply(disconnect)
    let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    #expect(restored["description"].string == "My hooks")
    #expect(restored["hooks"]["Stop"].array?.count == 1)
    #expect(restored["hooks"]["Stop"].array?.first?["hooks"].array?.first?["command"].string == "my-existing-hook")
    #expect(try FileManager.default.contentsOfDirectory(at: root.appending(path: "backups"), includingPropertiesForKeys: nil).count == 2)
}

@Test func installerRejectsStalePreviewAndMalformedExistingHooks() async throws {
    let (installer, root, executable) = try installation()
    let plan = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false)
    let url = root.appending(path: "hooks.json")
    let external = Data(#"{"hooks":{"Stop":"unexpected shape"}}"#.utf8)
    try external.write(to: url)
    await #expect(throws: StoreError.self) { try await installer.apply(plan) }
    await #expect(throws: StoreError.self) { try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false) }
    #expect(try Data(contentsOf: url) == external)
}

@Test func dispatchScopeDoesNotBypassApprovals() throws {
    for scope in AutomationScope.allCases {
        let params = ThreadStartRequest(cwd: "/tmp", developerInstructions: "Task data", scope: scope, mcpPath: "/Applications/Facienda.app/Contents/Helpers/facienda-mcp")
        let json = try JSONValue.encoded(params)
        #expect(json["approvalPolicy"].string == "on-request")
        #expect(json["approvalsReviewer"].string == "user")
        #expect(json["sandbox"].string == (scope == .autonomous ? "workspace-write" : "read-only"))
        #expect(json["config"]["mcp_servers"]["facienda"]["command"].string?.hasSuffix("facienda-mcp") == true)
        #expect(json["config"]["mcp_servers"]["facienda"]["required"] == .bool(true))
    }
}

@Test func installerReplacesHooksFromOtherBuildsWithOnlyTheNeededEvents() async throws {
    let (installer, root, executable) = try installation()
    let old = ConnectionInstaller.shellQuote("/Users/me/git/facienda/build/Debug/Facienda.app/Contents/Helpers/facienda-hook")
    let original = Data(#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"\#(old)","statusMessage":"Facienda lifecycle"}]}],"Stop":[{"hooks":[{"type":"command","command":"my-existing-hook"},{"type":"command","command":"\#(old)","statusMessage":"Facienda lifecycle"}]}]}}"#.utf8)
    try original.write(to: root.appending(path: "hooks.json"))
    let plan = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false)
    let hooks = try JSONDecoder().decode(JSONValue.self, from: plan.proposedHooks)["hooks"]
    #expect(Set(hooks.object?.keys.map { $0 } ?? []) == ConnectionInstaller.hookEvents)
    let commands = hooks.object!.values.flatMap { $0.array ?? [] }.flatMap { $0["hooks"].array ?? [] }.compactMap { $0["command"].string }
    #expect(!commands.contains(old))
    #expect(commands.filter { $0 == ConnectionInstaller.shellQuote(executable) }.count == ConnectionInstaller.hookEvents.count)
    #expect(hooks["Stop"].array?.first?["hooks"].array?.map { $0["command"].string } == ["my-existing-hook"])
}

@Test func setupSkipsConnectingWhenToolsAndHooksAreAlreadyThere() async throws {
    let (installer, root, _) = try installation()
    // A Codex that already has Facienda's MCP server registered at this helper.
    let codex = root.appending(path: "codex-registered")
    let helper = root.appending(path: "facienda-mcp").path
    try Data("#!/bin/sh\nif [ \"$2\" = get ]; then printf '{\"transport\":{\"command\":\"\(helper)\"}}'; fi\nexit 0\n".utf8).write(to: codex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    for path in [helper, root.appending(path: "facienda-hook").path] {
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
    let hook = root.appending(path: "facienda-hook").path
    let first = try await installer.plan(executable: codex.path, mcpPath: helper, hookPath: hook, disconnect: false)
    #expect(!first.upToDate) // The hooks are not there yet.
    try await installer.apply(first)
    let again = try await installer.plan(executable: codex.path, mcpPath: helper, hookPath: hook, disconnect: false)
    #expect(again.upToDate)
    #expect(try await !installer.plan(executable: codex.path, mcpPath: helper, hookPath: hook, disconnect: true).upToDate)
}

@Test func connectingLetsCodexReleaseChatsAfterAMinute() async throws {
    let (installer, root, executable) = try installation()
    let url = root.appending(path: "config.toml")
    let original = "model = \"gpt\"\nnotify = [\n  [\"a\"],\n]\n\n[mcp_servers.other]\ncommand = \"x\"\n"
    try Data(original.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let plan = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false)
    #expect(plan.releasesChats)
    #expect(plan.preview.contains("thread_unload_delay_secs = 60"))
    #expect(try String(contentsOf: url, encoding: .utf8) == original) // Preview alone never changes a file.
    try await installer.apply(plan)
    let installed = try String(contentsOf: url, encoding: .utf8)
    #expect(installed == ConnectionInstaller.chatRelease + "\n" + original)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    let again = try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: false)
    #expect(!again.releasesChats)
    try await installer.apply(try await installer.plan(executable: executable, mcpPath: executable, hookPath: executable, disconnect: true))
    #expect(try String(contentsOf: url, encoding: .utf8) == installed) // Disconnecting leaves it.
}

@Test func connectingKeepsTheUsersOwnChatRelease() throws {
    #expect(ConnectionInstaller.addingChatRelease(to: Data("thread_unload_delay_secs = 300\n".utf8)) == nil)
    #expect(ConnectionInstaller.addingChatRelease(to: Data("model = \"gpt\"\n  thread_unload_delay_secs=0\n".utf8)) == nil)
    #expect(ConnectionInstaller.addingChatRelease(to: nil) == Data(ConnectionInstaller.chatRelease.utf8))
    #expect(ConnectionInstaller.addingChatRelease(to: Data()) == Data(ConnectionInstaller.chatRelease.utf8))
}
