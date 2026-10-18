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
    /// The window's bar when `WorkspaceWindow` draws it above the panels; on its own the board draws one in its top bar.
    private let shared: OmnibarModel?
    @State private var own: OmnibarModel
    private var omnibar: OmnibarModel { shared ?? own }
    /// The window's height, which long text in the bar may take most of.
    @State private var pageHeight: CGFloat = 0
    @State private var pageWidth: CGFloat = 0

    /// `query` and `sheetDraft` put text in the bar or an open group's sheet, as if typed; the demo snapshots use them.
    init(model: AppModel, appDelegate: AppDelegate? = nil, workspaces: WorkspaceController? = nil, sidebar: Bool = true, omnibar: OmnibarModel? = nil,
         query: String = "", sheetDraft: String? = nil) {
        _model = Bindable(model); self.appDelegate = appDelegate; self.workspaces = workspaces; self.sidebar = sidebar
        shared = omnibar
        let own = omnibar ?? OmnibarModel(model: model, workspaces: workspaces)
        // A bar shared with the window keeps its own text.
        if omnibar == nil {
            own.query = sheetDraft ?? query
            if let sheetDraft, let group = model.omnibarGroup { own.seedDraft(sheetDraft, for: group) }
        }
        _own = State(initialValue: own)
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
        @Bindable var bar = omnibar
        HStack(spacing: 0) {
            if sidebar {
                WorkspaceSidebar(model: model, workspaces: workspaces)
                    .frame(width: min(max(pageWidth * 0.25, 220), 560) - IslandFrame.margin * 2).padding(IslandFrame.margin)
            }
            panel(VStack(spacing: 0) {
                // Above the page, which the bar grows down over. In the window the bar is the window's, so a board has none.
                if shared == nil || model.destination == .inbox { topBar.zIndex(1) }
                if model.diskNearlyFull { lowSpaceBar }
                if model.destination == .inbox && model.search.isEmpty { inbox }
                // The task lists are the board with one state's chip on; a task opens in a panel over it.
                // Beside the board rather than over it, so the board narrows and the task's row stays in view.
                else {
                    DashboardModes(model: model) {
                        if let task = model.selectedTask {
                            TaskPanel(model: model, task: task) { model.select(nil) }
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            })
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        // A card's + opens its group as a sheet until the task is started or let go.
        .overlayPreferenceValue(GroupCardKey.self) { cards in
            GeometryReader { proxy in
                GroupSheetLayer(omnibar: omnibar, cards: cards.mapValues { proxy[$0] }, size: proxy.size)
            }
        }
        // With the bar in the window, the window draws its results, so they can hang over the island too.
        .overlayPreferenceValue(OmnibarAnchorKey.self) { anchor in
            if shared == nil, omnibar.isOpen, let anchor { OmnibarResults(omnibar: omnibar, model: model, anchor: anchor) }
        }
        .background(sidebar ? Palette.sidebar : Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
        // Beside the island it asks no more than the island leaves it, so it never pushes past the window.
        .frame(minWidth: sidebar ? 680 : IslandFrame.board.width, minHeight: sidebar ? 520 : IslandFrame.board.height)
        .overlay(alignment: .bottom) { UndoOfferToast(model: model) }
        .sheet(item: $bar.chosenChat) { chat in ChatChoice(omnibar: omnibar, chat: chat).foregroundStyle(Palette.ink) }
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

    /// With the island drawn here too, the board is a panel beside it, as `WorkspaceWindow` draws it.
    @ViewBuilder private func panel(_ page: some View) -> some View {
        if sidebar { page.background(Palette.paper).boardPanel().padding([.vertical, .trailing], IslandFrame.margin) } else { page }
    }

    /// In the window the bar is above the panels and the pages' switch is the board's own first row. On its own the board
    /// keeps the field here, running out to its right edge, so the bar shares the cards' edges. The composer keeps a way
    /// back to the board; Settings are reached from the sidebar.
    private var topBar: some View {
        HStack(spacing: 12) {
            if model.destination == .inbox {
                Button { model.showBoard(.dashboard) } label: {
                    Label("Dashboard", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }.buttonStyle(QuietButton(compact: true)).accessibilityLabel("Back to dashboard")
                Text(model.destination.rawValue).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            if shared == nil {
                OmnibarField(omnibar: omnibar, reach: pageHeight, widest: .infinity)
                UpdatePill()
            } else { Spacer(minLength: 0) }
        }
        // The field sits as far down from the panel's top as in from its sides, so its corners nest in the panel's.
        // Without it the way back alone needs less.
        .padding(.horizontal, IslandFrame.inset)
        .frame(height: (shared == nil ? 40 : 28) + IslandFrame.inset * 2)
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
