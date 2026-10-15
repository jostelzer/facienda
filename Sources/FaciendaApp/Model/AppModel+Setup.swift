import AppKit
import FaciendaCore
import FaciendaBridge

extension AppModel {
    func connect() async {
        await codex.connect()
        if connected { await pollThreads(); await loadCodexProjectFolders() }
    }
    func disconnect() async { await codex.disconnect() }
    func refreshAccount() async throws { try await codex.refreshAccount() }
    func refreshUsage() async { await codex.refreshUsage() }
    func signInToCodex() async { await codex.signInToCodex() }
    func cancelSignIn() async { await codex.cancelSignIn() }
    /// Codex, Claude and their hooks always run the installed app's helpers, so a development build never
    /// registers itself. Only without an installed app do the running build's own helpers stand in.
    var helperDirectory: URL {
        let installed = URL(fileURLWithPath: "/Applications/Facienda.app/Contents/Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: installed.appending(path: "facienda-mcp").path) ? installed : Bundle.main.bundleURL.appending(path: "Contents/Helpers")
    }
    var mcpHelperPath: String { helperDirectory.appending(path: "facienda-mcp").path }
    func prepareConnection(disconnect: Bool) async {
        guard !demo else { notice = "Connection changes are disabled in the demo."; return }
        do {
            connectionPlan = try await installer.plan(executable: executable, mcpPath: mcpHelperPath, hookPath: helperDirectory.appending(path: "facienda-hook").path, disconnect: disconnect)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func applyConnection(_ plan: ConnectionPlan) async -> Bool {
        do {
            try await installer.apply(plan); connectionPlan = nil
            notice = "Task reporting is connected. Review Facienda’s hooks in Codex to enable desktop activity updates."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Codex setup connects everything at once: Facienda's MCP server, so every task chat reports through its tools wherever
    /// it works, and its hooks, so chats show their state on the board. Files it replaces are backed up. Codex still asks
    /// the user to trust the hooks; `codexHooksTrusted` follows that.
    func connectCodexTools() async throws {
        // Only for the real library: Codex's config is global, so a test or experiment library never changes it.
        guard !demo, store.url.standardizedFileURL.path == LibraryHome.databaseURL.standardizedFileURL.path else { return }
        let plan = try await installer.plan(executable: executable, mcpPath: mcpHelperPath, hookPath: hookHelperPath, disconnect: false)
        guard !plan.upToDate else { return }
        try await installer.apply(plan)
        codexToolsConnected = true
    }
    /// Whether Codex trusts every one of Facienda's hooks, as Codex reports it; nil when it cannot tell.
    func refreshCodexHookTrust() async {
        guard !demo, connected, let reply = try? await bridge.request("hooks/list", params: .object(["cwds": .array([.string(store.workFolder.path)])])) else { return }
        let ours = (reply["data"].array ?? []).flatMap { $0["hooks"].array ?? [] }.filter { $0["statusMessage"].string == "Facienda lifecycle" }
        codexHooksTrusted = ours.isEmpty ? false : ours.allSatisfy { $0["trustStatus"].string == "trusted" }
    }
    /// A scheduled runner from before the dispatcher checked the queue every minute in a run of its own. Codex cannot be
    /// told to archive those from outside, so each run that ended cleanly is archived here. Failed runs stay visible.
    func archiveRunnerRuns() async {
        guard !demo, connected, let runs = try? store.runnerRunsToArchive(), !runs.isEmpty else { return }
        for thread in runs {
            let archived = (try? await bridge.request("thread/archive", params: .object(["threadId": .string(thread)]))) != nil
            try? store.markRunnerRun(thread, archived: archived)
        }
    }
    func openCodex() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
    var workspaceReady: Bool {
        if let workspaceSetup { return workspaceSetup.isReady(runner: nativeRunner) }
        // Workspaces connected before project onboarding already have a native runner.
        return nativeRunner != nil
    }
    /// A runner from before Facienda delivered to Codex itself: a scheduled automation or a runner chat. It keeps
    /// working until the user reconnects, which retires it.
    var codexNeedsReconnect: Bool { nativeRunner.map { !$0.isDispatcher } ?? false }
    /// Connects this library to Codex in one step, all from here: Facienda's tools and hooks go into Codex's config,
    /// the data folder becomes the `facienda` project, and Facienda's dispatcher takes over delivery, retiring any
    /// runner from before. Nothing has to be sent in Codex.
    func connectWorkspace(repair: Bool = false) async {
        guard !demo, !connectingWorkspace else { return }
        connectingWorkspace = true
        workspaceSetupError = nil
        defer { connectingWorkspace = false; refresh() }
        do {
            if !connected { await connect() }
            guard connected else { throw BridgeError.disconnected }
            guard accountReady else { throw StoreError.invalid("Sign in to Codex before connecting.") }
            _ = try store.prepareWorkspaceSetup(repair: repair)
            // Tools and hooks first, so the first task chat already has them. A problem here never holds up delivery.
            do { try await connectCodexTools(); codexToolsError = nil }
            catch { codexToolsError = error.localizedDescription }
            // A project Codex already has for the data folder is named for Facienda; otherwise Facienda makes it.
            let directory = store.nativeProjectDirectory, name = store.nativeProjectName
            let project: String
            if let existing = try? await bridge.connectProject(directory: directory, name: name, within: .zero) { project = existing.id }
            else { project = try await bridge.groupProject(folders: [directory.path], name: name, current: nil).id }
            try store.bindCodexDispatcher()
            try store.verifyDispatcherSetup(projectId: project)
            refresh()
            startDispatcher(self)
        } catch { workspaceSetupError = error.localizedDescription }
    }
    /// A setup whose project name was never confirmed, for example after its folder moved while Codex was slow to
    /// register it, or one connected under an older name: name the project as soon as Codex knows the folder,
    /// without another setup message.
    func confirmPendingProjectName() async {
        guard !demo, connected, accountReady, !connectingWorkspace, let setup = workspaceSetup,
              setup.confirmedProjectName != setup.projectName,
              setup.projectPath == store.nativeProjectDirectory.path else { return }
        guard let project = try? await bridge.connectProject(directory: store.nativeProjectDirectory, name: store.nativeProjectName, within: .zero) else { return }
        do {
            try store.confirmWorkspaceProject(challenge: setup.challenge, id: project.id, name: project.name, directory: store.nativeProjectDirectory)
            refresh()
        } catch {}
    }
}
