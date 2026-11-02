import Foundation
import FaciendaCore

extension AppModel {
    /// Why an agent cannot take new work now, or nil when it can. Codex's dispatcher and the Claude runner both check
    /// in while they reach their app; a check-in older than a few minutes means a task started now would only wait.
    func whyDown(_ provider: AgentProvider, at now: Date = Date()) -> String? {
        guard !demo else { return nil }
        switch provider {
        case .codex:
            guard workspaceReady else { return "Connect Codex in Settings first." }
            if diskNearlyFull { return "Your disk is nearly full, so Codex can’t start tasks." }
            guard nativeRunner?.isAwake(at: now) == true else { return "Codex hasn’t answered for a few minutes." }
        case .claude:
            guard claudeInstalled else { return "Install the Claude app to run tasks with Claude." }
            guard claudeConnected else { return "Connect Claude in Settings first." }
            guard claudeRunner?.isAwake(at: now) == true else { return "The Claude runner is asleep. Wake it in Settings." }
        }
        return nil
    }
    func canStart(_ provider: AgentProvider, at now: Date = Date()) -> Bool { whyDown(provider, at: now) == nil }

    /// Rereads both check-ins, so a start is judged on the latest one rather than the last refresh.
    func rereadCheckIns() {
        guard !demo else { return }
        if let runner = try? store.runnerState() { nativeRunner = runner }
        if let runner = try? store.claudeRunner() { claudeRunner = runner }
    }
}

extension AppModel {
    /// The agents the user set up that can't take work now, by name, for the sidebar's usage bars. One never set up
    /// is left out: it has nothing to fade.
    func agentsDown(at now: Date = Date()) -> [String: String] {
        var down: [String: String] = [:]
        if workspaceReady, let reason = whyDown(.codex, at: now) { down[AgentProvider.codex.name] = reason }
        if claudeConnected, let reason = whyDown(.claude, at: now) { down[AgentProvider.claude.name] = reason }
        return down
    }
}
