import AppKit
import Observation
import FaciendaBridge

/// The app's one connection to Codex. Every workspace shares it, so switching workspaces
/// never starts another Codex process or waits for the account check again.
@MainActor @Observable final class CodexConnection {
    let bridge: CodexBridge
    let demo: Bool
    var executable = UserDefaults.standard.string(forKey: "codexExecutable") ?? CodexBridge.discoverExecutable() ?? "/opt/homebrew/bin/codex"
    var connection = "Not connected"
    var connected = false
    var accountReady = false
    var connecting = false
    var signInID: String?
    var signingIn = false
    var signInError: String?
    /// What is left of the Codex plan, from the last read.
    private(set) var codexUsage: PlanUsage?
    @ObservationIgnored private var usageReadAt = Date.distantPast
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var nextReconnect = Date.distantPast
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(bridge: CodexBridge = CodexBridge(), demo: Bool = false) {
        self.bridge = bridge
        self.demo = demo
    }

    /// Plan limits for each signed-in agent, shown at the foot of the sidebar.
    var usage: [PlanUsage] { connected && accountReady ? [codexUsage].compactMap { $0 } : [] }
    var usageIsStale: Bool { Date().timeIntervalSince(usageReadAt) > 300 || codexUsage?.stale() == true }
    var reconnectIsDue: Bool { !connected && wantsConnection && Date() >= nextReconnect }

    /// Connects once at launch when the last session ended connected. Later callers join that attempt.
    func connectOnLaunch() async {
        guard !demo, !connected, UserDefaults.standard.bool(forKey: "connectOnLaunch") else { return }
        wantsConnection = true
        await connect()
    }
    /// A connection that survived a whole service tick is stable, so the backoff starts over.
    func confirmStable() { if connected { failures = 0 } }

    func connect() async {
        guard !demo else { return }
        if messageTask == nil {
            let bridge = bridge
            messageTask = Task { [weak self] in
                for await message in bridge.messages { await self?.handle(message) }
            }
        }
        if let connectionTask { await connectionTask.value; return }
        let attempt = Task { await establishConnection() }
        connectionTask = attempt
        await attempt.value
        connectionTask = nil
    }
    private func establishConnection() async {
        wantsConnection = true; connecting = true; accountReady = false; signInError = nil; connection = "Connecting…"
        defer { connecting = false }
        do {
            try await bridge.connect(executable: executable)
            connected = true
            try await refreshAccount()
            UserDefaults.standard.set(executable, forKey: "codexExecutable")
            UserDefaults.standard.set(true, forKey: "connectOnLaunch")
        } catch {
            connected = false; accountReady = false; failures += 1; connection = error.localizedDescription
            nextReconnect = Date().addingTimeInterval(min(300, pow(2, Double(min(failures, 8)))))
        }
    }
    func disconnect() async {
        await cancelSignIn()
        wantsConnection = false; connected = false; accountReady = false; connection = "Not connected"
        UserDefaults.standard.set(false, forKey: "connectOnLaunch")
        await bridge.disconnect()
    }
    func refreshAccount() async throws {
        accountReady = try await bridge.accountStatus().isReady
        connection = accountReady ? "Codex connected" : "Sign in to Codex to continue"
        await refreshUsage()
    }
    /// This connection runs no turns, so Codex seldom pushes usage changes; the service loop reads again every few minutes.
    func refreshUsage() async {
        usageReadAt = Date()
        guard !demo, connected, accountReady else { codexUsage = nil; return }
        // API-key accounts have no plan limits, and a failed read hides the meter rather than showing old numbers.
        codexUsage = try? await bridge.planUsage()
    }
    func signInToCodex() async {
        guard !signingIn, signInID == nil else { return }
        signingIn = true; signInError = nil
        defer { signingIn = false }
        if !connected { await connect() }
        guard connected else { signInError = connection; return }
        do {
            try await refreshAccount()
            guard !accountReady else { return }
            let login = try await bridge.startSignIn()
            signInID = login.id
            guard NSWorkspace.shared.open(login.url) else {
                await cancelSignIn()
                signInError = "The browser could not open Codex sign-in. Try again."
                return
            }
        } catch { signInError = error.localizedDescription }
    }
    func cancelSignIn() async {
        guard let id = signInID else { return }
        signInID = nil
        do { try await bridge.cancelSignIn(id) }
        catch { signInError = error.localizedDescription }
    }

    func handle(_ message: BridgeMessage) async {
        if message.method == "account/login/completed" {
            guard let id = signInID, message.params["loginId"].string == id else { return }
            signInID = nil
            if message.params["success"] == .bool(true) {
                do { try await refreshAccount(); signInError = nil }
                catch { signInError = error.localizedDescription }
            } else { signInError = message.params["error"].string ?? "Codex sign-in did not finish. Try again." }
            return
        }
        if message.method == "account/updated", connected {
            do { try await refreshAccount() } catch { signInError = error.localizedDescription }
            return
        }
        if message.method == "account/rateLimits/updated", connected {
            await refreshUsage()
            return
        }
        if message.method == "facienda/disconnected" {
            connected = false; accountReady = false; signInID = nil; connection = "Connection lost · retrying"
            // Reconnect now rather than on the next 30 s service tick. Backoff still applies if it keeps dropping.
            failures += 1
            let delay = min(300, pow(2, Double(min(failures, 8))))
            nextReconnect = Date().addingTimeInterval(delay)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.wantsConnection, !self.connected else { return }
                await self.connect()
            }
            return
        }
        // This connection only reads stored chats and handles account setup.
        // Execution, steering, and approvals stay in the native Codex app.
        if let id = message.requestID { try? await bridge.rejectUnsupported(id: id) }
    }
}
