import SwiftUI
import FaciendaCore

@main struct FaciendaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var workspaces: WorkspaceController
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @State private var showSetup = false
    private let updater = AppUpdater.shared
    private let demo: Bool
    private var model: AppModel? { workspaces.model }
    init() {
        demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--snapshot")
        let needsSetup = !demo && (!UserDefaults.standard.bool(forKey: "setupCompleted") || !LibraryHome.exists)
        _workspaces = State(initialValue: WorkspaceController(demo: demo, load: !needsSetup))
        if needsSetup {
            _showSetup = State(initialValue: true)
        }
    }
    private func openNewTask() {
        delegate.reopenWindow?()
        model?.composeUnsorted()
    }
    private func go(_ destination: Destination) {
        delegate.reopenWindow?()
        model?.showBoard(destination)
    }
    var body: some Scene {
        WindowGroup(demo ? "Facienda — Demo" : Bundle.main.bundleIdentifier == "org.facienda.mac.development" ? "Facienda — Development" : "Facienda", id: "main") {
            Group {
                if showSetup {
                    OnboardingView(setup: OnboardingModel(codex: workspaces.codex)) { workspace in
                        UserDefaults.standard.set(true, forKey: "setupCompleted")
                        workspaces.install(workspace); delegate.model = workspace; showSetup = false
                    }
                } else if let model {
                    WorkspaceWindow(model: model, appDelegate: delegate, workspaces: workspaces)
                        .onAppear { delegate.model = model; delegate.workspaces = workspaces; model.narrowOldClaudeFolders() }
                } else {
                    VStack(spacing: 20) {
                        if workspaces.workspaces.isEmpty && workspaces.startupError == nil {
                            ContentUnavailableView("Welcome to Facienda", systemImage: "square.stack.3d.up", description: Text("Set up your library to give your tasks a home."))
                            Button("Set up Facienda…") { showSetup = true }.buttonStyle(QuietButton(prominent: true))
                        } else {
                            ContentUnavailableView("Unable to open your library", systemImage: "externaldrive.badge.exclamationmark", description: Text(workspaces.startupError ?? workspaces.error ?? "Facienda could not open its library."))
                            Button("Try again") { do { try workspaces.openLibrary() } catch { workspaces.startupError = error.localizedDescription } }.buttonStyle(QuietButton(prominent: true))
                            Button("Set up a new library…") { showSetup = true }.buttonStyle(QuietButton())
                        }
                    }.padding(40)
                }
            }.preferredColorScheme(appearance.colorScheme)
                .sheet(item: $workspaces.sheet) { sheet in WorkspaceSheetView(workspaces: workspaces, sheet: sheet).preferredColorScheme(appearance.colorScheme) }
                .alert("Unable to open workspace", isPresented: Binding(get: { workspaces.error != nil && workspaces.sheet == nil }, set: { if !$0 { workspaces.error = nil } })) {
                    Button("OK") { workspaces.error = nil }
                } message: { Text(workspaces.error ?? "") }
                .onChange(of: workspaces.model?.workspaceID) { _, url in
                    delegate.model = workspaces.model
                    if url != nil { showSetup = false; UserDefaults.standard.set(true, forKey: "setupCompleted") }
                }
                .task {
                    while !Task.isCancelled {
                        workspaces.reload()
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
        }
        // A first window fills most of the screen; afterwards macOS remembers the size the user gave it.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect.size
            return WindowPlacement(size: CGSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded()))
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if updater.isAvailable { Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck) }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Task") { openNewTask() }.keyboardShortcut("n").disabled(model == nil)
                Button("New Group") { delegate.reopenWindow?(); model?.requestNewGroup() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model == nil || demo)
                Button("Find or Ask…") { delegate.reopenWindow?(); model?.omnibarFocusRequest += 1 }.keyboardShortcut("k").disabled(model == nil)
                Button("Dictate") { delegate.reopenWindow?(); model?.dictationRequest += 1 }.keyboardShortcut("d").disabled(model == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { EditHistory.undo(model) }.keyboardShortcut("z")
                Button("Redo") { EditHistory.redo(model) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model?.showSettings = true }.keyboardShortcut(",").disabled(model == nil) }
            CommandMenu("Workspaces") {
                Button("Switch workspace…") { workspaces.reload(); workspaces.sheet = .manage }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(demo)
                Button("New workspace…") { workspaces.error = nil; workspaces.sheet = .create }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(demo)
                Divider()
                WorkspaceMenuItems(workspaces: workspaces, includeQuickActions: false).disabled(demo)
            }
            CommandMenu("Tasks") {
                Button("Accept recommendation") { model?.acceptRecommendation() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(model?.acceptableDecision == nil)
                Button("Next decision") { model?.stepDecision(1) }.keyboardShortcut("]", modifiers: .command)
                Button("Previous decision") { model?.stepDecision(-1) }.keyboardShortcut("[", modifiers: .command)
                Button("Mark done") { model?.completeSelection() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model == nil)
            }
            CommandMenu("Go") {
                Button("Dashboard") { go(.dashboard) }.keyboardShortcut("1")
                Button("In progress") { go(.processing) }.keyboardShortcut("2")
                Button("For review") { go(.forYou) }.keyboardShortcut("3")
                Button("Waiting") { go(.waiting) }.keyboardShortcut("4")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard shortcuts") { delegate.reopenWindow?(); model?.showShortcuts = true }.keyboardShortcut("/").disabled(model == nil)
            }
        }
        MenuBarExtra("Facienda", image: "MenuBarIcon") {
            WorkspaceMenu(model: model, delegate: delegate, workspaces: workspaces)
        }
    }
}

private struct WorkspaceMenu: View {
    let model: AppModel?
    let delegate: AppDelegate
    let workspaces: WorkspaceController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Quick capture") { openWindow(id: "main"); delegate.capture() }.keyboardShortcut("n").disabled(model == nil)
        Button("Show Facienda") { openWindow(id: "main"); delegate.show() }
        if let model { Text("\(model.attentionCount) tasks need you") }
        if !workspaces.demo {
            Menu(workspaces.name) { WorkspaceMenuItems(workspaces: workspaces) }
        }
        Divider()
        Button("Quit Facienda") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
