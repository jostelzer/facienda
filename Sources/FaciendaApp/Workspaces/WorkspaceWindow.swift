import SwiftUI
import FaciendaCore

/// The window: the bar across its top, and under it the workspaces' island down the left side and the board in the room
/// beside it, as two equal panels on the window's ground. The bar is the window's, not a board's: it spans island and
/// board alike, and what is typed in it stays while workspaces are switched. The island stays where it is; only its right
/// edge moves, to make it wider or narrower. While that edge is dragged only the island redraws; let go, and the board
/// takes its new room and slides over to it whole. A switch only rings the open tile while one board fades into the
/// next.
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
        // Goals is the window's other side: the island and the board slide out to the left as Goals comes in from the right.
        // Opened from a miniature beside a subgoal, the board grows out of it instead, and shrinks back into it.
        let goalsOpen = workspaces.goals.isOpen, origin = reduceMotion ? nil : workspaces.goals.boardOrigin
        let away: CGFloat = goalsOpen && !reduceMotion && origin == nil ? -window.width : 0
        ZStack(alignment: .topLeading) {
            // The title row is the bar's now; around it the window still moves the way a title bar does.
            Color.clear.frame(maxWidth: .infinity).frame(height: island.minY)
                .contentShape(Rectangle()).gesture(WindowDragGesture())
            ZStack(alignment: .topLeading) {
            // Both boards share the panel while one fades into the other, so the panel itself never fades.
            ZStack {
                DashboardView(model: model, appDelegate: appDelegate, workspaces: workspaces, sidebar: false, omnibar: omnibar)
                    .id(model.workspaceID).transition(.opacity)
            }
            .boardPanel()
            // Under what came in, the board waits as it was, out of reach of VoiceOver and the keyboard.
            .accessibilityHidden(workspaces.feed.isOpen || goalsOpen)
            // As far from the island and the window's edges as the island is from its edges, and as far below the bar.
            .padding(.top, island.minY)
            .padding([.bottom, .trailing], IslandFrame.margin)
            .padding(.leading, island.maxX + IslandFrame.margin)
            .offset(x: slide + away)
            .opacity(goalsOpen && reduceMotion ? 0 : 1)
            if window.width > 0 {
                ResizableIsland(model: model, workspaces: workspaces, settled: island, window: window, land: land)
                    .offset(x: away)
                    .opacity(goalsOpen && reduceMotion ? 0 : 1)
                    .accessibilityHidden(workspaces.feed.isOpen || goalsOpen)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(Miniature(frame: goalsOpen ? origin : nil, window: window))
            // The same work by what it is for, across every workspace, in the whole room under the bar. The workspace side
            // stays as it was out of sight, and comes back as it was.
            if goalsOpen {
                // Goals draws its own panels: the map, and today's list beside it when that is open.
                GoalsView(goals: workspaces.goals, workspaces: workspaces)
                    .padding(.top, island.minY)
                    .padding([.leading, .bottom, .trailing], IslandFrame.margin)
                    .transition(reduceMotion || origin != nil ? .opacity : .move(edge: .trailing))
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
                SideSwitch(goals: workspaces.goals)
                if let sub = workspaces.goals.cameFrom, !goalsOpen { WayBack(goals: workspaces.goals, subgoal: sub) }
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
        .coordinateSpace(name: WorkspaceWindow.space)
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
        .animation(reduceMotion ? Motion.fade : Motion.travel, value: workspaces.goals.isOpen)
        .onAppear { workspaces.feed.start(); workspaces.goals.start() }
    }

    /// Where a miniature board's frame is measured, so the real board can grow out of it.
    static let space = "workspaceWindow"

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

/// The window's two sides, at the start of the bar: the workspaces with their boards, and Goals. The highlight slides
/// from one to the other.
private struct SideSwitch: View {
    @Bindable var goals: GoalsModel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            side(goals: false, symbol: "square.grid.2x2", title: "Workspaces", help: "Workspaces and their boards")
            side(goals: true, symbol: "scope", title: "Goals", help: "Your goals, and the work that serves them (⌘G)")
        }
        .padding(2)
        .background(Palette.sidebar, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        .fixedSize()
    }

    private func side(goals isGoals: Bool, symbol: String, title: String, help: String) -> some View {
        let on = goals.isOpen == isGoals
        return Button {
            if !on { goals.toggle() }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Palette.ink : Palette.muted)
                .frame(width: 34, height: 30)
                .background {
                    if on {
                        Capsule().fill(Palette.card).overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                            .matchedGeometryEffect(id: "side", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
        .animation(Motion.move, value: goals.isOpen)
        .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
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

/// The island and the board drawn small over a task's picture in Goals, unseen, so they grow out of it and shrink back.
/// One scale for both sides, so the board keeps its shape as it grows.
private struct Miniature: ViewModifier {
    let frame: CGRect?
    let window: CGSize

    func body(content: Content) -> some View {
        // One view either way, so the board keeps its state and eases between the two.
        let on = frame != nil && window.width > 0 && window.height > 0, f = frame ?? .zero
        let scale = on ? max(f.width / window.width, f.height / window.height) : 1
        content
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: on ? f.midX - window.width * scale / 2 : 0, y: on ? f.midY - window.height * scale / 2 : 0)
            .opacity(on ? 0 : 1)
            .allowsHitTesting(!on)
    }
}

/// After a board was opened from a task in a subgoal: back into that subgoal, still close.
private struct WayBack: View {
    let goals: GoalsModel
    let subgoal: Goal

    var body: some View {
        Button { goals.returnToSubgoal() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Image(systemName: "scope").font(.system(size: 11))
                Text(subgoal.text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .frame(maxWidth: 240)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.firmLine, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Back to this subgoal in Goals")
        .transition(.opacity)
    }
}
