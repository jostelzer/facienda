import Foundation
import FaciendaCore
import FaciendaBridge

extension AppModel {
    /// Whether Codex can do background work now: installed and signed in.
    var codexServiceAvailable: Bool { connected && accountReady }
    /// Whether Claude Code is on this Mac, looked up at most once a minute.
    var claudeServiceAvailable: Bool { ClaudeCodeLookup.available }
    /// What setup recommends: Codex's Luna when Codex is there, Claude's Haiku when only Claude is.
    var recommendedServiceModel: ServiceModelChoice {
        .recommended(codex: codexServiceAvailable || !claudeServiceAvailable, claude: claudeServiceAvailable)
    }
    /// Whether the chosen app can do Facienda's background work now.
    var serviceModelReady: Bool {
        serviceModel.provider == .claude ? claudeServiceAvailable : accountReady
    }
    func chooseServiceModel(_ choice: ServiceModelChoice) {
        guard !demo else { serviceModel = choice; return }
        perform { try store.saveServiceModel(choice); serviceModel = choice }
    }
    /// Reads the library's choice; a library that never chose uses what setup would recommend.
    func loadServiceModel() {
        serviceModel = (try? store.serviceModel()) ?? recommendedServiceModel
        ServiceModelChoice.current = serviceModel
    }
}

/// Finding Claude Code reads a few folders, so the answer is kept for a minute.
@MainActor enum ClaudeCodeLookup {
    private static var checked: (at: Date, found: Bool)?
    static var available: Bool {
        if let checked, Date().timeIntervalSince(checked.at) < 60 { return checked.found }
        let found = ClaudeBackground.locate() != nil
        checked = (Date(), found)
        return found
    }
}
