import Foundation

/// The one approval Facienda asks for in Claude, in the user's Claude settings: a hook that tells Facienda when a task's
/// session waits for the user's permission. The hook only reports; it never answers a prompt. Facienda's allow rules
/// live only in its own folders (see `prepareClaudeFolder`), never in these settings for every session; rules that
/// earlier builds put here are taken out whenever Facienda changes the file.
/// Everything else in the file keeps its content; the original is backed up first.
public enum ClaudePermissions {
    public static var settingsURL: URL {
        let environment = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (environment ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")).appending(path: "settings.json")
    }

    /// The rules earlier builds added for every session: any helper command, and every tool of its MCP server.
    public static func legacyRules(helper: String) -> [String] {
        ["Bash(\(FaciendaStore.shellArgument(helper)) *)", "mcp__facienda"]
    }

    /// Earlier builds' rules still in the settings.
    static func presentLegacyRules(helper: String, settings: URL) -> [String] {
        let present = (try? allowList(in: Data(contentsOf: settings))) ?? []
        return legacyRules(helper: helper).filter(present.contains)
    }

    /// The hook events Facienda listens to, and the matcher each needs: a permission prompt, and the session moving on.
    static let hookEvents: [(event: String, matcher: String?)] = [
        ("PermissionRequest", "*"), ("Notification", "permission_prompt"), ("PreToolUse", "*"), ("PostToolUse", "*"), ("UserPromptSubmit", nil), ("Stop", nil)
    ]
    /// The hook's command line. The hook binary reads Facienda's own library, wherever the app keeps it.
    public static func hookCommand(hook: String) -> String { FaciendaStore.shellArgument(hook) + " --claude" }
    /// A hook entry from any Facienda build, wherever it lived.
    static func isFaciendaHook(_ handler: Any) -> Bool {
        guard let command = (handler as? [String: Any])?["command"] as? String else { return false }
        return command.contains("facienda-hook") && command.hasSuffix(" --claude")
    }

    /// Hook events that do not yet run this hook. Unreadable settings count as missing every event.
    public static func missingHooks(hook: String, settings: URL = settingsURL) -> [String] {
        let root = (try? Data(contentsOf: settings)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hooks = root?["hooks"] as? [String: Any] ?? [:]
        let command = hookCommand(hook: hook)
        return hookEvents.map(\.event).filter { event in
            let groups = hooks[event] as? [Any] ?? []
            return !groups.contains { group in
                ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains { (($0 as? [String: Any])?["command"] as? String) == command }
            }
        }
    }

    /// Everything Facienda would still add, one line each, for the question that asks to add it. Only the hook: allow
    /// rules are never added to these settings.
    public static func missing(helper: String, hook: String, settings: URL = settingsURL) -> [String] {
        let hooks = missingHooks(hook: hook, settings: settings)
        return hooks.isEmpty ? [] : ["Hook " + hookCommand(hook: hook) + " on " + hooks.joined(separator: ", ")]
    }

    /// Adds the missing hooks, takes out earlier builds' rules, and returns the backup of the previous file, if there was one.
    @discardableResult
    public static func install(helper: String, hook: String, settings: URL = settingsURL, backupDirectory: URL) throws -> URL? {
        let legacy = presentLegacyRules(helper: helper, settings: settings)
        let hooksMissing = !missingHooks(hook: hook, settings: settings).isEmpty
        guard !legacy.isEmpty || hooksMissing else { return nil }
        let original = try? Data(contentsOf: settings)
        var backup: URL?
        if let original {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = Date().fileStamp
            let file = backupDirectory.appending(path: "claude-settings-\(stamp).json")
            try original.write(to: file, options: .atomic)
            backup = file
        }
        var updated = original.map { String(decoding: $0, as: UTF8.self) } ?? "{}\n"
        if !legacy.isEmpty { updated = try removing(legacy, from: updated) }
        if hooksMissing { updated = try addingHooks(hook: hook, to: updated) }
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: settings, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        return backup
    }

    /// The settings without the given allow rules, everything else kept.
    static func removing(_ rules: [String], from text: String) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw StoreError.invalid("Your Claude settings file is not a JSON object, so Facienda left it unchanged.")
        }
        guard var permissions = root["permissions"] as? [String: Any], let allow = permissions["allow"] as? [Any] else { return text }
        permissions["allow"] = allow.filter { !(($0 as? String).map(rules.contains) ?? false) }
        root["permissions"] = permissions
        return tidy(String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)) + "\n"
    }

    /// Removes exactly Facienda's rules for this helper from any earlier build and its hooks from any build, keeping every other entry.
    public static func remove(helper: String, settings: URL = settingsURL, backupDirectory: URL) throws {
        guard let original = try? Data(contentsOf: settings),
              var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { return }
        var changed = false
        if var permissions = root["permissions"] as? [String: Any], let allow = permissions["allow"] as? [Any] {
            let ours = Set(legacyRules(helper: helper))
            let kept = allow.filter { !(($0 as? String).map(ours.contains) ?? false) }
            if kept.count != allow.count { permissions["allow"] = kept; root["permissions"] = permissions; changed = true }
        }
        if let hooks = root["hooks"] as? [String: Any] {
            let kept = withoutFaciendaHooks(hooks)
            if (kept as NSDictionary) != (hooks as NSDictionary) { root["hooks"] = kept.isEmpty ? nil : kept; changed = true }
        }
        guard changed else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Date().fileStamp
        try original.write(to: backupDirectory.appending(path: "claude-settings-\(stamp).json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: settings, options: .atomic)
    }

    /// Every hook group with Facienda's handlers taken out; groups and events left empty go too.
    static func withoutFaciendaHooks(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { result[event] = value; continue }
            let kept: [Any] = groups.compactMap { group in
                guard var object = group as? [String: Any], let handlers = object["hooks"] as? [Any] else { return group }
                let retained = handlers.filter { !isFaciendaHook($0) }
                if retained.count == handlers.count { return group }
                guard !retained.isEmpty else { return nil }
                object["hooks"] = retained; return object
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// Adds Facienda's hook to each event, replacing one from an earlier build, and keeps every other hook.
    static func addingHooks(hook: String, to text: String) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw StoreError.invalid("Your Claude settings file is not a JSON object, so Facienda left it unchanged.")
        }
        if let value = root["hooks"], !(value is [String: Any]) {
            throw StoreError.invalid("The hooks in your Claude settings are not an object, so Facienda left the file unchanged.")
        }
        var hooks = withoutFaciendaHooks(root["hooks"] as? [String: Any] ?? [:])
        let handler: [String: Any] = ["type": "command", "command": hookCommand(hook: hook), "timeout": 2]
        for (event, matcher) in hookEvents {
            guard hooks[event] == nil || hooks[event] is [Any] else {
                throw StoreError.invalid("The \(event) hooks in your Claude settings are not a list, so Facienda left the file unchanged.")
            }
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [Any] ?? []) + [group]
        }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Settings without hooks get them added before the closing brace, so the rest keeps its layout.
        if root["hooks"] == nil, let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            let block = tidy(String(decoding: try JSONSerialization.data(withJSONObject: hooks, options: options), as: UTF8.self))
                .split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n  ")
            let body = text[text.index(after: open)..<close]
            let last = body.lastIndex { !$0.isWhitespace }
            var result = text
            if let last {
                result.replaceSubrange(text.index(after: last)..<close, with: ",\n  \"hooks\": " + block + "\n")
            } else {
                result.replaceSubrange(text.index(after: open)..<close, with: "\n  \"hooks\": " + block + "\n")
            }
            return result
        }
        var updated = root
        updated["hooks"] = hooks
        return tidy(String(decoding: try JSONSerialization.data(withJSONObject: updated, options: options), as: UTF8.self)) + "\n"
    }

    /// Foundation writes `"key" : value`; Claude and people write `"key": value`.
    static func tidy(_ json: String) -> String {
        json.replacingOccurrences(of: #"(?m)^(\s*"(?:[^"\\]|\\.)*") : "#, with: "$1: ", options: .regularExpression)
    }

    static func allowList(in data: Data) throws -> [String] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["permissions"] as? [String: Any])?["allow"] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
