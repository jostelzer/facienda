import AppKit
import Observation
import Sparkle

/// Sparkle updates for builds that name a feed and key: the Tester build. Debug and Release name neither, so they never look.
/// As in Codex, a new version downloads by itself once a day's check finds it, then waits behind one Update button.
@MainActor @Observable final class AppUpdater {
    enum Phase: Equatable { case idle, checking, downloading(Double?), installing, ready }

    static let shared = AppUpdater()
    static var isConfigured: Bool {
        func value(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }
        return !value("SUFeedURL").isEmpty && !value("SUPublicEDKey").isEmpty
    }

    fileprivate(set) var phase = Phase.idle
    /// The version on its way or waiting behind the button, such as 0.1.1.
    fileprivate(set) var version: String?
    /// False while Sparkle is already checking or installing.
    private(set) var canCheck = false
    var isAvailable: Bool { updater != nil }

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: UpdateDriver?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        guard Self.isConfigured, !CommandLine.arguments.contains("--demo"), !CommandLine.arguments.contains("--snapshot") else { return }
        let driver = UpdateDriver(owner: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            NSLog("Facienda updates are off: \(error.localizedDescription)")
            return
        }
        self.driver = driver
        self.updater = updater
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() { updater?.checkForUpdates() }
    /// Installs the downloaded version and opens it again.
    func install() { driver?.install() }
}

/// Sparkle's questions answered the way Codex does: always download, and ask only at the end, through the Update button.
@MainActor private final class UpdateDriver: NSObject, SPUUserDriver {
    private unowned let owner: AppUpdater
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var userInitiated = false
    private var reply: ((SPUUserUpdateChoice) -> Void)?

    init(owner: AppUpdater) { self.owner = owner }

    func install() {
        guard let reply else { return }
        self.reply = nil
        owner.phase = .installing
        reply(.install)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Testers agreed to daily checks by joining; nothing about their Mac is sent.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        owner.phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        userInitiated = false
        owner.version = appcastItem.displayVersionString
        if state.stage == .notDownloaded {
            owner.phase = .downloading(nil)
            reply(.install)
        } else {
            // Downloaded before the app last quit: installing now would restart Facienda unasked, so it waits for the button.
            owner.phase = .ready
            self.reply = reply
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        finishCheck(error, title: "Facienda is up to date")
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        NSLog("Facienda update failed: \(error.localizedDescription)")
        finishCheck(error, title: "Unable to update Facienda")
        acknowledgement()
    }

    /// Only a check the user asked for gets an answer; the daily one stays quiet.
    private func finishCheck(_ error: any Error, title: String) {
        if owner.phase != .ready { owner.phase = .idle }
        guard userInitiated else { return }
        userInitiated = false
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        owner.phase = .downloading(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedLength = expectedContentLength }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        owner.phase = .downloading(min(1, Double(receivedLength) / Double(expectedLength)))
    }

    func showDownloadDidStartExtractingUpdate() { owner.phase = .installing }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Left waiting, the update still installs when Facienda quits.
        owner.phase = .ready
        self.reply = reply
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner.phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        owner.phase = .idle
        acknowledgement()
    }

    func showUpdateInFocus() { NSApp.activate() }

    func dismissUpdateInstallation() {
        if reply == nil { owner.phase = .idle }
    }
}
