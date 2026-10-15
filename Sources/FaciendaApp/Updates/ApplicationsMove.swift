import AppKit

/// Testers open Facienda from its disk image or Downloads, but Codex, Claude and the hooks reach its helpers inside
/// /Applications/Facienda.app. So a Tester build that opens anywhere else offers to move there before anything connects.
@MainActor enum ApplicationsMove {
    static let destination = URL(fileURLWithPath: "/Applications/Facienda.app")

    static func offerIfNeeded() {
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard AppUpdater.isConfigured, source.path != destination.path else { return }
        let alert = NSAlert()
        alert.messageText = "Move Facienda to Applications?"
        alert.informativeText = "Codex and Claude reach Facienda in your Applications folder. Facienda moves itself there and opens again."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try move(from: source)
        } catch {
            let failure = NSAlert(error: error)
            failure.informativeText = "Drag Facienda into your Applications folder yourself, then open it from there."
            failure.runModal()
        }
    }

    private static func move(from source: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath().path == destination.path }
            if running { throw MoveError("Another Facienda is open from Applications. Quit it, then try again.") }
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.copyItem(at: source, to: destination)
        // A copy in Downloads goes to the Trash; a disk image, or a copy macOS opened from a hidden place, stays as it is.
        if !source.path.contains("/AppTranslocation/"), files.isDeletableFile(atPath: source.path) {
            try? files.trashItem(at: source, resultingItemURL: nil)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private struct MoveError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
