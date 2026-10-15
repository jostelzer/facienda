import Foundation
import GRDB

/// How Facienda opens Claude sessions: the prompts it hands them, the links that open the Claude app,
/// and the folders those sessions start in.
extension FaciendaStore {
    public static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Plain when nothing needs quoting, so a permission rule for the helper's path matches the command as written.
    static func shellArgument(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./+-@%=:,")
        return !text.isEmpty && text.unicodeScalars.allSatisfy(plain.contains) ? text : shellQuote(text)
    }

    /// The helper invocation every Claude prompt uses, pinned to this library.
    public func claudeHelperBase(helper: String) -> String {
        "\(Self.shellArgument(helper)) --database \(Self.shellArgument(url.path))"
    }

    private func dispatchAndTask(_ dispatchId: String) throws -> (NativeDispatch, FaciendaTask) {
        try db.read { db in
            guard let item = try NativeDispatch.fetchOne(db, key: dispatchId), let task = try FaciendaTask.fetchOne(db, key: item.taskId) else { throw StoreError.notFound }
            return (item, task)
        }
    }

    /// The task's name on one line, short enough for the head of a message.
    private static func promptSummary(_ task: FaciendaTask) -> String {
        let summary = task.displayName.count > 160 ? String(task.displayName.prefix(157)) + "…" : task.displayName
        return summary.replacingOccurrences(of: "\n", with: " ")
    }

    /// The first message of a new task session. Its first line is the delivery marker Facienda recognises.
    public func claudeBootstrapPrompt(dispatchId: String, helper: String) throws -> String {
        let (item, task) = try dispatchAndTask(dispatchId)
        let base = claudeHelperBase(helper: helper)
        return """
        Facienda dispatch: \(item.id)
        Facienda task: \(Self.promptSummary(task))

        I started this task in Facienda. Begin by running this command; it links this session to the task and prints your instructions:
        \(base) --claude attach --dispatch-id \(item.id)
        Then follow those instructions. Later, my Facienda runner session may message this session with my replies, answers and scheduled checks from Facienda. Each such message starts with "Facienda dispatch:" and names a command that prints the full request; run it and follow it as if I had written it here.
        """
    }

    /// The runner names a task while it sets up the session, but not when it was asleep (the user sent the request
    /// themselves), its setup ran out of time, or it skipped the step. A start that still finds no name has the
    /// session name its own task and itself; nil when there is nothing to name.
    public func claudeNamingStep(dispatchId: String, sessionId: String, base: String) throws -> String? {
        let (item, task) = try dispatchAndTask(dispatchId)
        guard ["start", nil].contains(item.kind), task.state.isOpen, task.displayTitle == nil else { return nil }
        let title = sessionId.isEmpty ? "" : " Then title this session with it using mcp__ccd_session_mgmt__set_session_title (session_id = \(sessionId)), if you have that tool."
        return """
        FIRST, NAME THIS TASK: Facienda has no short name for it yet. Write a concise title for the original request (action plus subject, at most \(TaskNameWriter.maximumLength) characters, in the request's language), save task-local JSON {"displayTitle":"TITLE"} to a file in your scratch space, and run \(base) --claude name --task-id \(task.id) --title-file FILE. Use the title it prints, which may be one set meanwhile.\(title) Naming must never block the task: if it fails, carry on. The original request stays the task's title in Facienda.
        """
    }

    /// A session the Claude app is asked to adopt. It opens at `url`; the runner then delivers the start.
    public struct ClaudeImport: Sendable {
        public let url: URL
        public let cliSessionId: String
        public let threadId: String
        public let cwd: String
    }

    /// The opening message of a session Facienda hands to the Claude app. The session is already linked, so it
    /// only has to wait for the runner's dispatch and treat it as the user's own request.
    public func claudeOpeningMessage(dispatchId: String, folder: String) throws -> String {
        let (item, task) = try dispatchAndTask(dispatchId)
        return """
        Facienda dispatch: \(item.id)
        Facienda task: \(Self.promptSummary(task))

        I started this task in Facienda, which created this session for it in \(folder). My Facienda runner session will message this session with a line starting "Facienda dispatch:" that names a command; run that command and follow what it prints as my own request. The same goes for my later replies, answers and scheduled checks, which the runner relays the same way. Do nothing until such a message arrives.
        """
    }

    /// Starts a task session without a Send: Facienda writes the session's opening message as a transcript, the
    /// Claude app adopts it through its resume link (trusting the folder itself), and the runner delivers the start.
    /// Needs an awake runner; the composer hand-off covers the rest.
    public func importClaudeSession(dispatchId: String, helper: String, permissionMode: String, cliVersion: String, transcripts: URL = ClaudeTranscript.projectsDirectory, now: Date = Date()) throws -> ClaudeImport {
        let task = try db.read { db -> FaciendaTask in
            guard let item = try NativeDispatch.fetchOne(db, key: dispatchId), item.agent == .claude,
                  let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen else { throw StoreError.notFound }
            guard item.state == "queued", item.threadId == nil else { throw StoreError.invalid("This task already has its Claude session.") }
            guard let runner = try Self.claudeRunner(db), runner.isAwake(at: now) else {
                throw StoreError.invalid("The Claude runner is asleep, so Facienda cannot start this session on its own.")
            }
            try validateStart(db, item: item, now: now)
            return task
        }
        let folder = claudeSessionFolder(for: task)
        if task.cwd.map({ isAutomaticWorkingDirectory($0, taskID: task.id) }) ?? true {
            try prepareClaudeFolder(URL(fileURLWithPath: folder), mcpHelper: helper, folders: task.folders ?? [])
        }
        let cli = UUID().uuidString.lowercased(), thread = "local_" + cli
        _ = try ClaudeTranscript.writeOpening(sessionId: cli, cwd: folder, message: claudeOpeningMessage(dispatchId: dispatchId, folder: folder),
                                              title: task.displayName, permissionMode: permissionMode, version: cliVersion, in: transcripts)
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: dispatchId), item.state == "queued", item.threadId == nil else { throw StoreError.conflict }
            // The runner must not touch the session before the app has adopted it; confirming lifts the hold.
            item.threadId = thread; item.availableAt = now.addingTimeInterval(30)
            try item.update(db)
            try ThreadLink(taskId: task.id, codexThreadId: thread, linkedBy: "Facienda", title: task.displayName, provider: .claude).insert(db)
            try ClaudeSession(threadId: thread, taskId: task.id, cliSessionId: cli, cwd: folder, linkedAt: now, model: task.workerModel,
                              effort: task.workerReasoningEffort, fast: task.workerServiceTier != nil, configureState: "importing").save(db)
            try TaskEvent(taskId: task.id, threadId: thread, source: .app, kind: "claude.session.imported", payload: cli, at: now).insert(db)
        }
        guard let url = Self.claudeResumeURL(cli) else { throw StoreError.invalid("Could not prepare the Claude session.") }
        return ClaudeImport(url: url, cliSessionId: cli, threadId: thread, cwd: folder)
    }

    /// The app adopted the session: the runner may now apply the model and deliver the start.
    public func confirmClaudeImport(dispatchId: String, now: Date = Date()) throws {
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: dispatchId), let thread = item.threadId,
                  var session = try ClaudeSession.fetchOne(db, key: thread), session.configureState == "importing" else { throw StoreError.conflict }
            item.availableAt = nil; try item.update(db)
            session.configureState = "pending"; try session.update(db)
        }
        signalRunners(dispatchId)
    }

    /// The app did not adopt the session: forget it, so the composer hand-off can take over.
    public func revertClaudeImport(dispatchId: String, transcripts: URL = ClaudeTranscript.projectsDirectory) throws {
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: dispatchId), let thread = item.threadId,
                  let session = try ClaudeSession.fetchOne(db, key: thread), session.configureState == "importing" else { throw StoreError.conflict }
            if let cwd = session.cwd, let cli = session.cliSessionId { ClaudeTranscript.removeOpening(sessionId: cli, cwd: cwd, in: transcripts) }
            try db.execute(sql: "DELETE FROM threadLinks WHERE codexThreadId = ? AND taskId = ?", arguments: [thread, item.taskId])
            try db.execute(sql: "DELETE FROM claudeSessions WHERE threadId = ?", arguments: [thread])
            item.threadId = nil; item.availableAt = nil; try item.update(db)
            try TaskEvent(taskId: item.taskId, source: .app, kind: "claude.session.unadopted", payload: thread).insert(db)
        }
    }

    /// Asks the Claude app to adopt a session from its transcript.
    public static func claudeResumeURL(_ cliSessionId: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "resume"
        parts.queryItems = [URLQueryItem(name: "session", value: cliSessionId)]
        return parts.url
    }

    /// Opens a new session in the Claude app with the request ready to send. Claude never sends it on its own.
    /// A task folder of Facienda's own gets its tools and approvals first.
    public func claudeComposerURL(dispatchId: String, helper: String) throws -> URL {
        let item = try db.read { db -> NativeDispatch in
            guard let item = try NativeDispatch.fetchOne(db, key: dispatchId) else { throw StoreError.notFound }
            return item
        }
        let task = try self.task(item.taskId)
        var folder = claudeSessionFolder(for: task), folders = task.folders ?? []
        if !(task.cwd.map({ isAutomaticWorkingDirectory($0, taskID: task.id) }) ?? true) {
            // The app would not open a folder it has seen before, so a chosen folder joins the task's own instead.
            folders = [folder] + folders.filter { $0 != folder }
            folder = taskFolder(task.id).path
            try Self.makePrivateFolder(URL(fileURLWithPath: folder))
        }
        try prepareClaudeFolder(URL(fileURLWithPath: folder), mcpHelper: helper, folders: folders)
        return try Self.claudeNewSessionURL(folder: folder, prompt: claudeBootstrapPrompt(dispatchId: dispatchId, helper: helper))
    }

    /// Where a new Claude session opens: the task's own folder. The Claude app applies a requested folder only when
    /// it has not seen it before, otherwise it opens a scratch folder in Ask mode. Every task folder is new, so each
    /// session opens there, in the user's usual permission mode.
    public func claudeSessionFolder(for task: FaciendaTask) -> String {
        task.cwd ?? taskFolder(task.id).path
    }

    static func claudeNewSessionURL(folder: String, prompt: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "code"; parts.path = "/new"
        parts.queryItems = [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "q", value: prompt)]
        guard let url = parts.url else { throw StoreError.invalid("Could not prepare the Claude session.") }
        return url
    }

    /// Opens an existing session in the Claude app.
    public static func claudeSessionURL(_ sessionId: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "code"; parts.path = "/continue"
        parts.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return parts.url
    }

    public func claudeSetupPrompt(helper: String) throws -> String {
        guard let setup = try claudeRunner() else { throw StoreError.invalid("Prepare the Claude connection first.") }
        let base = claudeHelperBase(helper: helper)
        return """
        Connect Facienda to Claude. This is my one-time setup request: it makes this session the Facienda runner for my library at \(nativeProjectDirectory.path). The runner applies the model I choose in Facienda to new task sessions, relays my Facienda replies, answers and scheduled checks to the session that owns each task, and never does task work itself.

        Run this command; it binds this session and prints the runner instructions:
        \(base) --claude bind --challenge \(setup.challenge)
        Then follow those instructions.
        """
    }

    /// Where runner sessions open unless the user picks another folder: beside the libraries, out of their task folders.
    public static var defaultClaudeRunnerFolder: URL {
        LibraryHome.savedDataFolder.map { $0.appending(path: "claude") } ?? LibraryHome.defaultDataFolder.appending(path: "claude")
    }

    /// A folder the Claude app has not seen, for the runner session that answers this setup request: `runner-<id>`
    /// in `base`. A marker inside names the library, so a later runner of this library can clear it away.
    public func claudeRunnerFolder(in base: URL? = nil) throws -> URL {
        guard let setup = try claudeRunner() else { throw StoreError.invalid("Prepare the Claude connection first.") }
        return (base ?? Self.defaultClaudeRunnerFolder).appending(path: "runner-\(setup.challenge.prefix(8).lowercased())")
    }

    public func claudeSetupURL(helper: String, runnerFolder base: URL? = nil) throws -> URL {
        let folder = try claudeRunnerFolder(in: base)
        try prepareClaudeFolder(folder, mcpHelper: helper, runner: true)
        try Data(url.path.utf8).write(to: folder.appending(path: Self.claudeRunnerMarker), options: .atomic)
        narrowClaudeFolders(helper: helper, runnerBase: base)
        return try Self.claudeNewSessionURL(folder: folder.path, prompt: claudeSetupPrompt(helper: helper))
    }

    static let claudeRunnerMarker = ".facienda-runner"

    /// Once a new runner is bound in `current`, this library's earlier runner folders beside it are deleted.
    /// Only folders marked for this library and holding nothing but Facienda's own files are touched.
    public func removeRetiredClaudeRunnerFolders(keeping current: URL) {
        let files = FileManager.default
        let current = current.standardizedFileURL
        guard (try? String(contentsOf: current.appending(path: Self.claudeRunnerMarker), encoding: .utf8)) == url.path else { return }
        let candidates = ((try? files.contentsOfDirectory(at: current.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []).filter { folder in
            folder.standardizedFileURL != current
                && (try? String(contentsOf: folder.appending(path: Self.claudeRunnerMarker), encoding: .utf8)) == url.path
        }
        let ours: Set = [".mcp.json", ".claude", ".claude/settings.local.json", Self.claudeRunnerMarker, ".DS_Store", ".claude/.DS_Store"]
        for folder in candidates {
            guard let walker = files.enumerator(atPath: folder.path) else { continue }
            if walker.allSatisfy({ ours.contains($0 as? String ?? "") }) { try? files.removeItem(at: folder) }
        }
    }

    /// The Claude app tools the runner uses on task sessions. Allowed in its own folder only, so applying a task's
    /// model or relaying a reply never stops for an approval.
    public static let claudeRunnerTools = ["get_session", "set_session_model", "set_session_effort", "set_session_fast_mode",
                                           "set_session_title", "list_events", "send_message"].map { "mcp__ccd_session_mgmt__" + $0 } + ["SendMessage"]

    /// What a task session may run without asking: Facienda's tools, and exactly the helper commands its instructions
    /// name, pinned to this library. Nothing that relays, binds, answers or administers.
    public func claudeTaskRules(helper: String) -> [String] {
        let base = claudeHelperBase(helper: helper)
        return ["mcp__facienda", "Bash(\(base) --call *)", "Bash(\(base) --tools)"]
            + ["attach --dispatch-id", "await --dispatch-id", "prompt --dispatch-id", "name --task-id"].map { "Bash(\(base) --claude \($0) *)" }
    }

    /// What the runner session may run without asking: its relay commands and the Claude app tools it relays with.
    public func claudeRunnerRules(helper: String) -> [String] {
        let base = claudeHelperBase(helper: helper)
        return ["next", "unreported", "instructions"].map { "Bash(\(base) --claude \($0))" }
            + ["bind --challenge", "capabilities --can-start-sessions", "watch --seconds", "configured --thread-id", "name --task-id",
               "begin --dispatch-id", "ack --dispatch-id", "defer --dispatch-id", "missed-report --dispatch-id"].map { "Bash(\(base) --claude \($0) *)" }
            + Self.claudeRunnerTools
    }

    /// Makes a folder of Facienda's own that only this account can open.
    static func makePrivateFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Lets a Claude session opened in one of Facienda's own folders use its tools natively and run the helper
    /// commands its instructions name without asking (`claudeTaskRules`, or `claudeRunnerRules` for the runner).
    /// Never replaces a file Facienda did not write; sessions elsewhere use the helper command instead.
    /// Linked folders are opened to the session too, so it works in them without asking for each one.
    public func prepareClaudeFolder(_ folder: URL, mcpHelper: String, runner: Bool = false, folders: [String] = []) throws {
        let server: JSONValue = .object(["mcpServers": .object(["facienda": .object([
            "type": .string("stdio"), "command": .string(mcpHelper), "args": .array([.string("--database"), .string(url.path)])
        ])])])
        // Everything else keeps the session's own permission mode.
        let rules = runner ? claudeRunnerRules(helper: mcpHelper) : claudeTaskRules(helper: mcpHelper)
        let settings: JSONValue = .object([
            "enabledMcpjsonServers": .array([.string("facienda")]),
            "permissions": .object(["allow": .array(rules.map(JSONValue.string))]
                .merging(folders.isEmpty ? [:] : ["additionalDirectories": .array(folders.map(JSONValue.string))]) { $1 })
        ])
        try Self.makePrivateFolder(folder)
        try Self.makePrivateFolder(folder.appending(path: ".claude"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for (file, content) in [(folder.appending(path: ".mcp.json"), server), (folder.appending(path: ".claude/settings.local.json"), settings)] {
            // A file someone else wrote stays as it is; the helper command still reaches every tool.
            if let existing = try? String(contentsOf: file, encoding: .utf8), !existing.contains("facienda") { continue }
            try encoder.encode(content).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Folders earlier builds prepared let a session run any helper command. This library's task folders and runner
    /// folders that still carry such a rule get today's narrow rules, keeping their linked folders.
    public func narrowClaudeFolders(helper: String, runnerBase: URL? = nil) {
        let files = FileManager.default
        let tasks = Set(((try? library.tasks()) ?? []).map(\.id))
        let taskFolders = ((try? files.contentsOfDirectory(at: workFolder, includingPropertiesForKeys: nil)) ?? []).filter { tasks.contains($0.lastPathComponent) }
        let runnerFolders = ((try? files.contentsOfDirectory(at: runnerBase ?? Self.defaultClaudeRunnerFolder, includingPropertiesForKeys: nil)) ?? []).filter {
            (try? String(contentsOf: $0.appending(path: Self.claudeRunnerMarker), encoding: .utf8)) == url.path
        }
        for (folder, runner) in taskFolders.map({ ($0, false) }) + runnerFolders.map({ ($0, true) }) {
            guard let data = try? Data(contentsOf: folder.appending(path: ".claude/settings.local.json")),
                  let permissions = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["permissions"] as? [String: Any],
                  let allow = permissions["allow"] as? [String],
                  allow.contains(where: { $0.hasPrefix("Bash(") && $0.hasSuffix(" *)") && !$0.contains(" --") }) else { continue }
            try? prepareClaudeFolder(folder, mcpHelper: helper, runner: runner, folders: permissions["additionalDirectories"] as? [String] ?? [])
        }
    }
}
