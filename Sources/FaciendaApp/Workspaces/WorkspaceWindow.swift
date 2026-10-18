import SwiftUI
import FaciendaCore

/// The window: the bar across its top, and under it the workspaces' island down the left side and the board in the room
/// beside it, as two equal panels on the window's ground. The bar is the window's, not a board's: it spans island and
/// board alike, and what is typed in it stays while workspaces are switched. The island stays where it is; only its right
/// edge moves, to make it wider or narrower. While that edge is dragged only the island redraws; let go, and the board
/// takes its new room and slides over to it whole. A switch only brings the open planet close while one board fades
/// into the next.
struct WorkspaceWindow: View {
    @Bindable var model: AppModel
    var appDelegate: AppDelegate?
    let workspaces: WorkspaceController
    /// A fixed island for snapshots, as fractions of the window, so they never touch the saved one.
    var fixedIsland: String?
    /// A bar already holding text, for snapshots.
    var bar: OmnibarModel?
    /// The bar's model, one for each workspace it has been over, the draft carried from one to the next.
    @State private var bars = OmnibarBars()
    @State private var window: CGSize = .zero
    /// The island's width as a share of the window's, so it keeps its proportion as the window changes size.
    @AppStorage("islandShare") private var share = 0.0
    /// Where the island was saved before it was always full height; its width carries over to a first share.
    @AppStorage("islandFrame") private var oldFrame = ""
    /// How far the board still has to go to the room it was just given. It is laid out there at once and slides over
    /// whole, so its groups reflow once rather than on every frame of the way.
    @State private var slide: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var island: CGRect {
        let saved = fixedIsland.flatMap(IslandFrame.share(fromSavedFrame:)) ?? (share > 0 ? share : IslandFrame.share(fromSavedFrame: oldFrame) ?? 0)
        return IslandFrame.frame(width: IslandFrame.width(share: saved, in: window), in: window)
    }

    var body: some View {
        let island = island, omnibar = bars.bar(for: model, workspaces: workspaces, preset: bar)
        ZStack(alignment: .topLeading) {
            // The title row is the bar's now; around it the window still moves the way a title bar does.
            Color.clear.frame(maxWidth: .infinity).frame(height: island.minY)
                .contentShape(Rectangle()).gesture(WindowDragGesture())
            // Both boards share the panel while one fades into the other, so the panel itself never fades.
            ZStack {
                DashboardView(model: model, appDelegate: appDelegate, workspaces: workspaces, sidebar: false, omnibar: omnibar)
                    .id(model.workspaceID).transition(.opacity)
            }
            .boardPanel()
            // Under what came in, the board waits as it was, out of reach of VoiceOver and the keyboard.
            .accessibilityHidden(workspaces.feed.isOpen)
            // As far from the island and the window's edges as the island is from its edges, and as far below the bar.
            .padding(.top, island.minY)
            .padding([.bottom, .trailing], IslandFrame.margin)
            .padding(.leading, island.maxX + IslandFrame.margin)
            .offset(x: slide)
            if window.width > 0 {
                ResizableIsland(model: model, workspaces: workspaces, settled: island, window: window, land: land)
                    .accessibilityHidden(workspaces.feed.isOpen)
            }
            // What came in spans every workspace, so it takes the whole room under the bar. The board stays where it
            // was underneath, and comes back as it was.
            if workspaces.feed.isOpen {
                FeedView(feed: workspaces.feed, workspaces: workspaces)
                    .boardPanel()
                    // Esc anywhere in the window brings the board back.
                    .background { Button("") { workspaces.feed.close() }.keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true) }
                    .padding(.top, island.minY)
                    .padding([.leading, .bottom, .trailing], IslandFrame.margin)
                    .transition(.opacity)
            }
            // Over both panels, since the bar grows down over them as you type. It starts after the traffic lights and
            // runs to the window's right edge, as far in from it as the panels are.
            HStack(spacing: 12) {
                OmnibarField(omnibar: omnibar, reach: window.height, widest: .infinity,
                             accessory: AnyView(FeedTrail(feed: workspaces.feed, workspaces: workspaces)))
                UpdatePill()
            }
            .padding(.top, IslandFrame.barTop)
            .padding(.leading, IslandFrame.lights)
            .padding(.trailing, IslandFrame.margin)
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { window = $0 }
        // The title bar is hidden, but SwiftUI still keeps its height free above the content. The bar belongs in that
        // row, beside the traffic lights, so the window's content starts at its top edge.
        .ignoresSafeArea(.container, edges: .top)
        // An empty toolbar makes the title row as tall as the bar, so the traffic lights sit at its middle.
        // The item has no glass of its own, or it shows through the bar as a thin line.
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }.sharedBackgroundVisibility(.hidden) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlayPreferenceValue(OmnibarAnchorKey.self) { anchor in
            if omnibar.isOpen, let anchor { OmnibarResults(omnibar: omnibar, model: model, anchor: anchor) }
        }
        .background(Palette.sidebar).foregroundStyle(Palette.ink).tint(Palette.accent)
        .frame(minWidth: 680, minHeight: 520)
        .animation(Motion.fade, value: workspaces.feed.isOpen)
        .onAppear { workspaces.feed.start() }
    }

    /// The island keeps the width it was let go at; the board takes its new room in one step and slides there from where it was.
    private func land(_ width: CGFloat) {
        guard window.width > 0 else { return }
        let gone = island.width - width
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            share = width / window.width
            if !reduceMotion { slide = gone }
        }
        guard slide != 0 else { return }
        // A frame later, so the board is drawn once where it was before it sets off.
        DispatchQueue.main.async { withAnimation(Motion.move) { slide = 0 } }
    }
}

/// The island over the board. Its right edge is a thin strip where the pointer turns into a resize arrow; while it is
/// dragged only the island redraws, following the pointer exactly.
private struct ResizableIsland: View {
    @Bindable var model: AppModel
    let workspaces: WorkspaceController
    let settled: CGRect
    let window: CGSize
    let land: (CGFloat) -> Void
    /// The island's width while its edge is dragged, and what it was when that began.
    @State private var live: CGFloat?
    @State private var start: CGFloat?

    var body: some View {
        WorkspaceSidebar(model: model, workspaces: workspaces, underLights: false)
            .frame(width: live ?? settled.width, height: settled.height)
            .overlay(alignment: .trailing) { edge }
            .offset(x: settled.minX, y: settled.minY)
    }

    private var edge: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle()).offset(x: 4)
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { resize($0.translation.width, done: false) }
                .onEnded { resize($0.translation.width, done: true) })
            .accessibilityHidden(true)
    }

    private func resize(_ dx: CGFloat, done: Bool) {
        let from = start ?? settled.width
        start = from
        let width = IslandFrame.clamped(from + dx, in: window)
        if done {
            land(width)
            live = nil; start = nil
        } else {
            live = width
        }
    }
}

/// The bar's model for the open workspace. The bar is the window's, so a switch keeps what was typed and the files
/// dropped in: a new model answers to the new workspace and takes the draft over. The one left behind keeps its files
/// listed, so nothing it pasted is thrown away under the new one.
@MainActor private final class OmnibarBars {
    private var current: OmnibarModel?

    func bar(for model: AppModel, workspaces: WorkspaceController, preset: OmnibarModel? = nil) -> OmnibarModel {
        if let current, current.model === model { return current }
        if current == nil, let preset, preset.model === model { current = preset; return preset }
        let next = OmnibarModel(model: model, workspaces: workspaces)
        if let current {
            next.query = current.query
            next.attachments = current.attachments
            // The board left behind no longer answers to the bar.
            current.model.readingTarget = nil
        }
        self.current = next
        return next
    }
}

/// The results beneath the bar, over whatever is under them. A click beside them closes the results and keeps the
/// board filtered; it lets a lit group go too.
struct OmnibarResults: View {
    @Bindable var omnibar: OmnibarModel
    let model: AppModel
    let anchor: Anchor<CGRect>

    var body: some View {
        GeometryReader { proxy in
            let field = proxy[anchor]
            let width = min(max(field.width, 560), proxy.size.width - 32)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).padding(.top, field.maxY + 4)
                    .contentShape(Rectangle()).onTapGesture { omnibar.dismissed = true; model.releaseSpotlight() }
                // The results take what is left beneath a tall bar.
                OmnibarPanel(omnibar: omnibar, tallest: proxy.size.height - field.maxY - 22).frame(width: width)
                    .offset(x: min(max(16, field.midX - width / 2), proxy.size.width - width - 16), y: field.maxY + 6)
            }
        }
    }
}

extension View {
    /// The board as the island's equal: paper with the island's corners, hairline and lift. The board is clipped to it, so
    /// the bar's results and a group's sheet stay inside the panel.
    func boardPanel() -> some View {
        clipShape(WorkspaceSidebar.island)
            .background { WorkspaceSidebar.island.fill(Palette.paper).shadow(color: .black.opacity(0.1), radius: 22, y: 12) }
            .overlay { WorkspaceSidebar.island.strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false) }
    }
}
