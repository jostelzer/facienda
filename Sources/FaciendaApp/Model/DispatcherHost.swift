import Foundation
import ServiceManagement
import Darwin
import FaciendaCore
import FaciendaBridge

/// Where the Codex dispatcher runs: one for the library, however many of its workspaces are open. The installed app
/// hands it to a launch agent, so tasks, replies and due checks reach Codex while Facienda is closed. Any other build
/// runs it inside the app instead, so a development build never registers itself. Both at once is harmless: only
/// one dispatcher holds the queue at a time.
@MainActor @Observable final class DispatcherHost {
    static let shared = DispatcherHost()
    enum Mode: Equatable { case stopped, inApp, agent, needsApproval }
    private(set) var mode: Mode = .stopped
    private(set) var problem: String?
    @ObservationIgnored private var inApp: (library: URL, task: Task<Void, Never>)?
    @ObservationIgnored private let agent = SMAppService.agent(plistName: "org.facienda.dispatch.plist")
    @ObservationIgnored private var lastRepair = Date.distantPast

    static var isInstalledApp: Bool { Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Facienda.app" }

    /// Starts the dispatcher for the model's library, or keeps the one that runs. Safe to call often.
    func start(for model: AppModel) {
        let library = model.store.url.standardizedFileURL
        // The agent follows the library the app uses; a test or experiment library never gets it.
        if Self.isInstalledApp, library.path == LibraryHome.databaseURL.standardizedFileURL.path {
            do {
                if agent.status != .enabled { try agent.register(); UserDefaults.standard.set(Self.agentStamp, forKey: Self.stampKey) }
                problem = nil
            } catch { problem = error.localizedDescription }
            // launchd keeps the agent's signature from when it was registered and refuses a changed binary, as after
            // an update. A new binary is registered again.
            if agent.status == .enabled, UserDefaults.standard.string(forKey: Self.stampKey) != Self.agentStamp {
                UserDefaults.standard.set(Self.agentStamp, forKey: Self.stampKey)
                lastRepair = Date()
                reregister()
            }
            if agent.status == .enabled {
                // Allowed is not the same as running: the agent proves it by running. The app then lets go of the
                // queue, even one it took while the agent was starting, so the two never take turns.
                if Self.agentRuns || Self.anotherDispatcherHolds(model.nativeRunner) { stopInApp(); mode = .agent; return }
                // Listed as allowed but not running, for example unloaded by hand: register it again, and deliver from here meanwhile.
                if Date().timeIntervalSince(lastRepair) > 600 { lastRepair = Date(); reregister() }
                mode = .inApp
            } else {
                mode = agent.status == .requiresApproval ? .needsApproval : .inApp
            }
        } else {
            // Only a lease on this library counts. The installed agent may be serving a different library.
            if Self.anotherDispatcherHolds(model.nativeRunner) { stopInApp(); mode = .agent; return }
            mode = .inApp
        }
        // Until the agent may run, the app delivers while it is open.
        guard inApp?.library != library else { return }
        stopInApp()
        let helper = model.mcpHelperPath, executable = model.executable
        inApp = (library, Task.detached(priority: .utility) {
            guard let store = try? LibraryHome.open(at: library) else { return }
            await CodexDispatcher(store: store, helper: helper, executable: executable, log: { NSLog("%@", $0) }).run()
        })
    }

    private static let stampKey = "dispatchAgentStamp"
    /// Which agent binary is registered: its size and modification date change with every build.
    private static var agentStamp: String {
        let path = Bundle.main.bundleURL.appending(path: "Contents/Helpers/facienda-dispatch").path
        let info = try? FileManager.default.attributesOfItem(atPath: path)
        return "\((info?[.size] as? Int) ?? 0)-\((info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    private func reregister() {
        let agent = agent
        Task {
            do { try await agent.unregister(); try agent.register() }
            catch { problem = error.localizedDescription }
        }
    }

    /// The agent waits for the user's approval in System Settings › General › Login Items.
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// The installed app's agent process is running, whichever build asks.
    private static var agentRuns: Bool {
        let agentPath = "/Applications/Facienda.app/Contents/Helpers/facienda-dispatch"
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096)
        return pids.prefix(max(0, count)).contains { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == agentPath
        }
    }

    /// Another living dispatcher holds the queue, such as the agent. One that stopped cleanly gave it back, and one
    /// that is gone has its hold taken over, so neither counts.
    private static func anotherDispatcherHolds(_ runner: NativeRunnerState?) -> Bool {
        guard let runner, let holder = runner.leaseHolder, holder != CodexDispatcher.processHolder,
              (runner.leaseUntil ?? .distantPast) > Date() else { return false }
        return !FaciendaStore.holderIsGone(holder)
    }

    /// The app is quitting: its dispatcher gives the queue back, so the agent takes it at once instead of waiting
    /// out the lease.
    func stopForQuit() {
        guard let library = inApp?.library else { return }
        stopInApp()
        try? LibraryHome.open(at: library).endRunnerTurn(runnerId: CodexDispatcher.runnerId, holder: CodexDispatcher.processHolder)
    }

    private func stopInApp() { inApp?.task.cancel(); inApp = nil }
}
