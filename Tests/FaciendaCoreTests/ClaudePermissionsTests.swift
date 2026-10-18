import Foundation
import Testing
@testable import FaciendaCore

private func settingsFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "claude-settings-\(UUID().uuidString)")
}

private let helper = "/Applications/Facienda.app/Contents/Helpers/facienda-mcp"
private let hook = "/Applications/Facienda.app/Contents/Helpers/facienda-hook"

@Test func hooksAreAddedInPlaceAndNoRuleIsWrittenForEverySession() throws {
    let folder = settingsFolder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "settings.json")
    let original = """
    {
      "model": "opus",
      "enabledPlugins": {
        "allow": ["not-a-permission"]
      },
      "permissions": {
        "allow": [
          "Edit(**)",
          "Bash(git status)"
        ],
        "defaultMode": "auto",
        "deny": [
          "Bash(rm -rf /)"
        ]
      },
      "skipWorkflowUsageWarning": true
    }

    """
    try Data(original.utf8).write(to: file)
    #expect(ClaudePermissions.missing(helper: helper, hook: hook, settings: file) == ["Hook \(hook) --claude on PermissionRequest, Notification, PreToolUse, PostToolUse, UserPromptSubmit, Stop"])
    #expect(ClaudePermissions.missingHooks(hook: hook, settings: file) == ["PermissionRequest", "Notification", "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"])
    let backup = try #require(try ClaudePermissions.install(helper: helper, hook: hook, settings: file, backupDirectory: folder.appending(path: "Backups")))
    #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    let updated = try String(contentsOf: file, encoding: .utf8)
    // The hooks go before the closing brace: every other line keeps its layout, and no allow rule is added.
    #expect(updated.hasPrefix(String(original[..<original.range(of: "\"skipWorkflowUsageWarning\": true")!.upperBound]) + ",\n  \"hooks\": {\n    \"Notification\": ["))
    #expect(try ClaudePermissions.allowList(in: Data(contentsOf: file)) == ["Edit(**)", "Bash(git status)"])
    #expect(ClaudePermissions.missing(helper: helper, hook: hook, settings: file).isEmpty)
    #expect(ClaudePermissions.missingHooks(hook: hook, settings: file).isEmpty)
    let hooks = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["hooks"] as? [String: Any])
    let notification = try #require((hooks["Notification"] as? [[String: Any]])?.first)
    #expect(notification["matcher"] as? String == "permission_prompt")
    #expect(((notification["hooks"] as? [[String: Any]])?.first?["command"] as? String) == hook + " --claude")
    // A second run changes nothing.
    #expect(try ClaudePermissions.install(helper: helper, hook: hook, settings: file, backupDirectory: folder.appending(path: "Backups")) == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == updated)
    // Removal takes exactly Facienda's hooks away.
    try ClaudePermissions.remove(helper: helper, settings: file, backupDirectory: folder.appending(path: "Backups"))
    let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(((removed?["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Edit(**)", "Bash(git status)"])
    #expect(((removed?["enabledPlugins"] as? [String: Any])?["allow"] as? [String]) == ["not-a-permission"])
    #expect(removed?["model"] as? String == "opus")
    #expect(removed?["hooks"] == nil)
}

@Test func hooksJoinTheUsersOwnAndReplaceAnEarlierBuildsHooksAndRules() throws {
    let folder = settingsFolder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "settings.json")
    let mine: [String: Any] = ["type": "command", "command": "afplay ping.aiff"]
    let earlier: [String: Any] = ["type": "command", "command": "'/Users/me/build/Debug/facienda-hook' --claude"]
    let settings: [String: Any] = ["permissions": ["allow": ["Bash(git status)", "Bash(\(helper) *)", "mcp__facienda"]],
                                   "hooks": ["Stop": [["hooks": [mine]]], "PostToolUse": [["matcher": "*", "hooks": [earlier]]]]]
    try JSONSerialization.data(withJSONObject: settings).write(to: file)
    // Rules from an earlier build never count as missing; only the hook is.
    #expect(ClaudePermissions.missing(helper: helper, hook: hook, settings: file) == ["Hook \(hook) --claude on PermissionRequest, Notification, PreToolUse, PostToolUse, UserPromptSubmit, Stop"])
    try ClaudePermissions.install(helper: helper, hook: hook, settings: file, backupDirectory: folder.appending(path: "Backups"))
    // Installing takes the earlier build's rules for every session out, and keeps the user's own.
    #expect(try ClaudePermissions.allowList(in: Data(contentsOf: file)) == ["Bash(git status)"])
    var hooks = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
    let commands = { (event: String) in (hooks[event] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } } }
    #expect(commands("Stop") == ["afplay ping.aiff", hook + " --claude"])
    #expect(commands("PostToolUse") == [hook + " --claude"])
    #expect(ClaudePermissions.missing(helper: helper, hook: hook, settings: file).isEmpty)
    try ClaudePermissions.remove(helper: helper, settings: file, backupDirectory: folder.appending(path: "Backups"))
    hooks = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
    #expect(Array(hooks.keys) == ["Stop"] && commands("Stop") == ["afplay ping.aiff"])
}

@Test func removeTakesOutExactlyAnEarlierBuildsRules() throws {
    let folder = settingsFolder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "settings.json")
    let quoted = "/My Apps/facienda-mcp"
    let allow = ["Bash('/My Apps/facienda-mcp' *)", "mcp__facienda", "Bash('/My Apps/facienda-mcp' --database x --call *)", "mcp__facienda__save_result", "Bash(\(helper) *)"]
    try JSONSerialization.data(withJSONObject: ["permissions": ["allow": allow]]).write(to: file)
    #expect(ClaudePermissions.legacyRules(helper: quoted) == ["Bash('/My Apps/facienda-mcp' *)", "mcp__facienda"])
    try ClaudePermissions.remove(helper: quoted, settings: file, backupDirectory: folder.appending(path: "Backups"))
    #expect(try ClaudePermissions.allowList(in: Data(contentsOf: file)) == ["Bash('/My Apps/facienda-mcp' --database x --call *)", "mcp__facienda__save_result", "Bash(\(helper) *)"])
}

@Test func missingFilesGetOnlyTheHook() throws {
    let folder = settingsFolder()
    let file = folder.appending(path: "nested/settings.json")
    #expect(try ClaudePermissions.install(helper: "/My Apps/facienda-mcp", hook: hook, settings: file, backupDirectory: folder) == nil)
    #expect(try ClaudePermissions.allowList(in: Data(contentsOf: file)).isEmpty)
    #expect(ClaudePermissions.missing(helper: "/My Apps/facienda-mcp", hook: hook, settings: file).isEmpty)
    #expect(throws: (any Error).self) { try ClaudePermissions.removing(["a"], from: "[1, 2]") }
}
