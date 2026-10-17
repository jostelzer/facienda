import AppKit
import FaciendaCore

extension AppModel {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// A Claude start that waits for the runner: queued, not yet handed to the Claude app in any way.
    func waitsForClaudeRunner(_ item: NativeDispatch) -> Bool {
        item.agent == .claude && ["start", nil].contains(item.kind) && item.state == "queued" && item.threadId == nil && !item.awaitsClaudeSend
    }
    /// Claude starts waiting for the runner in any of the library's workspaces, not only this one: the runner
    /// serves them all, so a task waiting where the user is not looking starts too.
    func waitingClaudeStarts(in dispatches: [NativeDispatch], tasks: [FaciendaTask], workspaces: [Workspace]) -> [NativeDispatch] {
        let live = Set(workspaces.map(\.id))
        let open = Set(tasks.filter { $0.state.isOpen && $0.workspaceId.map(live.contains) ?? true }.map(\.id))
        return dispatches.filter { open.contains($0.taskId) && waitsForClaudeRunner($0) && !claudeStartsHeld.contains($0.id) }
    }
    /// The next waiting start, read afresh, so one another window started meanwhile is not handed over twice.
    private func nextWaitingClaudeStart() -> NativeDispatch? {
        guard let dispatches = try? store.dispatches(), let tasks = try? store.library.tasks(),
              let workspaces = try? store.library.workspaces() else { return nil }
        return waitingClaudeStarts(in: dispatches, tasks: tasks, workspaces: workspaces).first
    }
    /// Starts every waiting Claude task once the runner is awake, one at a time. A start the Claude app did not
    /// pick up waits for the user, so a stubborn one never loops.
    func startWaitingClaudeTasks() async {
        guard !demo, !startingWaitingClaude else { return }
        startingWaitingClaude = true
        defer { startingWaitingClaude = false }
        while claudeRunner?.isAwake() == true, let item = nextWaitingClaudeStart() {
            await startInClaude(item)
            if let now = try? store.dispatches().first(where: { $0.id == item.id }), waitsForClaudeRunner(now) { claudeStartsHeld.insert(item.id) }
        }
    }
    /// Tries a held start again, as the user asked.
    func retryClaudeStart(_ item: NativeDispatch) async {
        claudeStartsHeld.remove(item.id)
        await startWaitingClaudeTasks()
    }
    /// Hands the Claude app a ready-made session for the task. If the app does not adopt it, the task waits here.
    func startInClaude(_ item: NativeDispatch) async {
        guard !demo else { return }
        do {
            let imported = try store.importClaudeSession(dispatchId: item.id, helper: mcpHelperPath,
                permissionMode: ClaudeDesktop.defaultPermissionMode(), cliVersion: ClaudeDesktop.cliVersion())
            refresh()
            let wasFront = NSApp?.isActive == true
            guard openURL(imported.url) else { throw StoreError.invalid("Facienda could not open the Claude app.") }
            // The Claude app comes forward to adopt the session; there is nothing to do there, so come back.
            if wasFront { Task { await Self.returnFromClaude() } }
            if await claudeSessionAdopted(imported.cliSessionId) {
                try store.confirmClaudeImport(dispatchId: item.id)
            } else {
                try store.revertClaudeImport(dispatchId: item.id)
                claudeStartsHeld.insert(item.id)
                notice = "Claude did not pick up the session. Try again from the task, or send it yourself in Claude."
            }
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    /// Shows a new task session in the Claude app's composer, ready to send. Reopening shows the same request again.
    /// Only on the user's request: Facienda never falls back to it by itself.
    func openInClaude(_ item: NativeDispatch) {
        guard !demo else { return }
        perform {
            let handed = try store.handOffToClaudeComposer(item.id)
            let url = try store.claudeComposerURL(dispatchId: handed.id, helper: mcpHelperPath)
            guard openURL(url) else { throw StoreError.invalid("Facienda could not open the Claude app.") }
            refresh()
        }
    }
    /// Brings Facienda back once the Claude app has taken the front for a link that needs no attention.
    /// macOS refuses Facienda's own request as expired when it carries the time of an input from before Claude came
    /// forward, so Launch Services then reopens it from outside, as a Dock click would.
    static func returnFromClaude(within seconds: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID else { return }
        try? await Task.sleep(for: .milliseconds(400))
        NSApp?.activate(ignoringOtherApps: true)
        NSApp?.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard NSApp?.isActive != true, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = [Bundle.main.bundlePath]
        try? reopen.run()
    }
    func connectClaude(repair: Bool = false) {
        guard !demo, !connectingClaude else { return }
        connectingClaude = true; claudeSetupError = nil
        defer { connectingClaude = false }
        do {
            guard claudeInstalled else { throw StoreError.invalid("Install the Claude app first.") }
            try store.prepareClaudeSetup(repair: repair)
            let url = try store.claudeSetupURL(helper: mcpHelperPath, runnerFolder: claudeRunnerFolder)
            guard openURL(url) else { throw StoreError.invalid("Facienda could not open the Claude app.") }
            claudeSetupOpened = true
            refresh()
        } catch { claudeSetupError = error.localizedDescription }
    }
    var claudeConnected: Bool { claudeRunner?.isBound == true }
    /// Task and runner folders from earlier builds let a session run any helper command; each launch narrows them.
    func narrowOldClaudeFolders() {
        guard !demo else { return }
        store.narrowClaudeFolders(helper: mcpHelperPath, runnerBase: claudeRunnerFolder)
    }
    static let claudeRunnerFolderKey = "claudeRunnerFolder"
    /// Where new runner sessions open: the user's choice, or ~/facienda/claude.
    var claudeRunnerFolder: URL {
        UserDefaults.standard.string(forKey: Self.claudeRunnerFolderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FaciendaStore.defaultClaudeRunnerFolder
    }
    static var connectionBackups: URL { LibraryHome.supportDirectory.appending(path: "ConnectionBackups") }
    /// The bundled hook that reports when a Claude task session waits for the user's permission.
    var hookHelperPath: String { helperDirectory.appending(path: "facienda-hook").path }
    /// Facienda's permission hook, when not yet in the user's Claude settings, one line each.
    var missingClaudeSetup: [String] { demo ? [] : ClaudePermissions.missing(helper: mcpHelperPath, hook: hookHelperPath) }
    func requestClaudeConnection(repair: Bool = false) {
        guard !demo else { return }
        if missingClaudeSetup.isEmpty { connectClaude(repair: repair) }
        else { claudeAccessNext = (true, repair); askingClaudeAccess = true }
    }
    /// Setup connects Claude completely: Facienda's permission hook goes into the Claude settings
    /// (backed up first), then the setup session opens. Pressing Run setup in Claude is the consent.
    func connectClaudeWithAccess() {
        guard !demo else { return }
        // Claude's settings are global too: only the real library changes them.
        if store.url.standardizedFileURL.path == LibraryHome.databaseURL.standardizedFileURL.path, !missingClaudeSetup.isEmpty {
            do { try ClaudePermissions.install(helper: mcpHelperPath, hook: hookHelperPath, backupDirectory: Self.connectionBackups) }
            catch { claudeSetupError = "Facienda could not update your Claude settings. " + error.localizedDescription; return }
        }
        connectClaude(repair: false)
    }
    func requestClaudeAccess() {
        guard !demo else { return }
        claudeAccessNext = (false, false); askingClaudeAccess = true
    }
    func answerClaudeAccess(allow: Bool) {
        askingClaudeAccess = false
        if allow {
            do { try ClaudePermissions.install(helper: mcpHelperPath, hook: hookHelperPath, backupDirectory: Self.connectionBackups) }
            catch { claudeSetupError = "Facienda could not update your Claude settings. " + error.localizedDescription; return }
        }
        if claudeAccessNext.connect { connectClaude(repair: claudeAccessNext.repair) }
    }
    func removeClaudeAccess() {
        do { try ClaudePermissions.remove(helper: mcpHelperPath, backupDirectory: Self.connectionBackups); claudeSetupError = nil }
        catch { claudeSetupError = "Facienda could not update your Claude settings. " + error.localizedDescription }
    }
}
