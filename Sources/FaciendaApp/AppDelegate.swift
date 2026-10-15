import SwiftUI
import Carbon.HIToolbox
import FaciendaCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var workspaces: WorkspaceController?
    var reopenWindow: (() -> Void)?
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            NSApp.setActivationPolicy(.accessory)
            // Render a native view into an offscreen bitmap without moving any app to the front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.snapshot(path: path) }
            return
        }
        ApplicationsMove.offerIfNeeded()
        _ = AppUpdater.shared
        // Silent CloudKit changes must reach the running app, including while its window is closed.
        if MobileCompanion.isCloudBuild && !CommandLine.arguments.contains("--demo") {
            NSApp.registerForRemoteNotifications()
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            MainActor.assumeIsolated {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                if identifier.id == 2 { delegate.captureByVoice() } else { delegate.capture() }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        // ⌃⌥Space captures; ⌃⌥D captures with the microphone already on.
        var clashes: [String] = []
        for (id, key, name) in [(UInt32(1), kVK_Space, "⌃⌥Space"), (UInt32(2), kVK_ANSI_D, "⌃⌥D")] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x46414349, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotKeys.append(reference) } else { clashes.append(name) }
        }
        if !clashes.isEmpty { model?.notice = "The \(clashes.joined(separator: " and ")) hotkey is already in use. Use ⌘N or the menu bar." }
    }
    func applicationWillTerminate(_ notification: Notification) {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        DispatcherHost.shared.stopForQuit()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func show() { reopenWindow?(); NSApp.activate(); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
    /// ⌃⌥D: the New task sheet, listening. If a composer is already open, it just starts listening.
    func captureByVoice() {
        show()
        guard let model = workspaces?.model ?? model else { return }
        if model.composersOnScreen > 0 { model.dictationRequest += 1 } else { model.listenOnCompose = true; model.showCapture = true }
    }
    func capture() { show(); (workspaces?.model ?? model)?.showCapture = true }
}
