import SwiftUI
import FaciendaCore

struct DashboardView: View {
    @Bindable var model: AppModel
    var appDelegate: AppDelegate? = nil
    var workspaces: WorkspaceController? = nil
    /// False when `WorkspaceWindow` draws the sidebar, so it stays put while this board is swapped for another workspace's.
    var sidebar = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var omnibar: OmnibarModel
    /// The empty space either side of the top bar's field, which it may take while you type.
    @State private var gaps: [CGFloat] = [0, 0]
    /// The window's height, which long text in the bar may take most of.
    @State private var pageHeight: CGFloat = 0
    @State private var pageWidth: CGFloat = 0

    init(model: AppModel, appDelegate: AppDelegate? = nil, workspaces: WorkspaceController? = nil, sidebar: Bool = true) {
        _model = Bindable(model); self.appDelegate = appDelegate; self.workspaces = workspaces; self.sidebar = sidebar
        _omnibar = State(initialValue: OmnibarModel(model: model, workspaces: workspaces))
    }

    /// A nearly full disk holds new task starts, so the board says why nothing starts and where to free space.
    private var lowSpaceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.amber)
            Text("Your disk is nearly full\(model.freeDiskSpace.map { " (\($0.formatted(.byteCount(style: .file))) free)" } ?? ""). Facienda is holding new task starts until there is more room.")
                .font(.system(size: 12))
            Spacer()
            Button("See storage…") { model.showSettings = true }.buttonStyle(QuietButton())
        }.padding(.horizontal, 16).padding(.vertical, 8).background(Palette.amber.opacity(0.12))
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebar {
                WorkspaceSidebar(model: model, workspaces: workspaces, windowWidth: pageWidth)
                Divider()
            }
            VStack(spacing: 0) {
                // Above the page, which the bar grows down over.
                topBar.zIndex(1)
                if model.diskNearlyFull { lowSpaceBar }
                if model.destination == .inbox && model.search.isEmpty { inbox }
                // The task lists are the board with one state's chip on; a task opens in a panel over it.
                // Beside the board rather than over it, so the board narrows and the task's row stays in view.
                else {
                    HStack(spacing: 0) {
                        DashboardModes(model: model)
                        if let task = model.selectedTask {
                            TaskPanel(model: model, task: task) { model.select(nil) }
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }.animation(Motion.move, value: model.selection)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        // A card's + opens its group as a sheet until the task is started or let go.
        .overlayPreferenceValue(GroupCardKey.self) { cards in
            GeometryReader { proxy in
                GroupSheetLayer(omnibar: omnibar, cards: cards.mapValues { proxy[$0] }, size: proxy.size)
            }
        }
        .overlayPreferenceValue(OmnibarAnchorKey.self) { anchor in
            if omnibar.isOpen, let anchor {
                GeometryReader { proxy in
                    let field = proxy[anchor]
                    let width = min(max(field.width, 560), proxy.size.width - 32)
                    ZStack(alignment: .topLeading) {
                        // A click outside closes the results and keeps the board filtered. It lets a lit group go too.
                        Color.black.opacity(0.001).padding(.top, field.maxY + 4)
                            .contentShape(Rectangle()).onTapGesture { omnibar.dismissed = true; model.releaseSpotlight() }
                        // The results take what is left beneath a tall bar.
                        OmnibarPanel(omnibar: omnibar, tallest: proxy.size.height - field.maxY - 22).frame(width: width)
                            .offset(x: min(max(16, field.midX - width / 2), proxy.size.width - width - 16), y: field.maxY + 6)
                    }
                }
            }
        }
        .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
        .frame(minWidth: sidebar ? 680 : 440, minHeight: 520)
        .overlay(alignment: .bottom) { UndoOfferToast(model: model) }
        .sheet(item: $omnibar.chosenChat) { chat in ChatChoice(omnibar: omnibar, chat: chat).foregroundStyle(Palette.ink) }
        .sheet(isPresented: $model.showCapture) { CaptureView(model: model) }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsCard() }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, workspaces: workspaces) }
        .alert("Unable to continue", isPresented: Binding(presenting: $model.error)) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("Send this again?", isPresented: Binding(presenting: $model.resendConfirmation), presenting: model.resendConfirmation) { item in
            Button("Send again") { model.retryUndelivered(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Facienda could not confirm that this never arrived. Send it again only if you checked Codex yourself, or the request may run twice.")
        }
        // A task list is the board with its chips on, and a task in the panel keeps its own chip on.
        .onChange(of: model.requestedList, initial: true) { _, list in
            guard let list else { return }
            StateLegend.show(list); model.requestedList = nil
        }
        .onChange(of: model.selection, initial: true) { _, _ in
            if let task = model.selectedTask { StateLegend.reveal(task, in: model) }
        }
        // A task's panel belongs to the board; Memory, Chats and the composer let it go.
        .onChange(of: model.destination) { _, destination in
            if destination != .dashboard, model.selection != nil { model.select(nil) }
            model.releaseSpotlight()
        }
        .onAppear {
            model.undoManager = undoManager
            SafeUndo.failed = { [weak model] message in model?.error = message }
            model.start()
            appDelegate?.reopenWindow = { openWindow(id: "main") }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .onDisappear {
            // Another workspace's model takes the window; its changes can no longer be undone from here.
            if let undoManager { SafeUndo.clear(undoManager) }; model.undoOffer = nil
        }
    }

    /// Search owns the bar. The composer keeps a way back to the board; Memory, Chats and
    /// Settings are reached from the sidebar.
    private var topBar: some View {
        HStack(spacing: 12) {
            if model.destination == .inbox {
                Button { model.showBoard(.dashboard) } label: {
                    Label("Dashboard", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }.buttonStyle(QuietButton(compact: true)).accessibilityLabel("Back to dashboard")
                Text(model.destination.rawValue).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gaps[0] = $0 }
            HStack(spacing: 14) {
                Image("BrandIcon").resizable().scaledToFit().frame(width: 26, height: 26).accessibilityLabel("Facienda")
                if model.destination == .dashboard { DashboardModeSwitch() }
                OmnibarField(omnibar: omnibar, spare: gaps[0] + gaps[1], reach: pageHeight)
            }
            Spacer(minLength: 0).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gaps[1] = $0 }
        }
        // Behind the bar, so a bar growing down over the page is not crossed by the line.
        .padding(.horizontal, 24).frame(height: 60).background(alignment: .bottom) { Divider() }
        .overlay(alignment: .trailing) { UpdatePill().padding(.trailing, 20) }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What would you like done?").font(.system(size: 28, weight: .medium, design: .serif))
                Text("Describe a task and add anything that helps.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            TaskComposer(model: model)
        }.frame(maxWidth: 720).padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
