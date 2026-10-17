import SwiftUI
import FaciendaCore

/// The window: the workspaces' island leaning on its walls, and the board in the room left beside it. The island moves
/// when its empty space is dragged and resizes from its free edges. Walls pull it on as it comes near, with a tap on the
/// trackpad, so it is already where it lands; let go, and it stays exactly there while the board takes its new room and
/// slides over to it whole. A switch only brings the open planet close while one board fades into the next.
struct WorkspaceWindow: View {
    @Bindable var model: AppModel
    var appDelegate: AppDelegate?
    let workspaces: WorkspaceController
    /// A fixed island for snapshots, as fractions of the window, so they never touch the saved one.
    var fixedIsland: String?
    @State private var window: CGSize = .zero
    /// Where the island sits, as fractions of the window, so it keeps its place as the window changes size.
    @AppStorage("islandFrame") private var saved = ""
    /// The old sidebar's share of the window, which a first island takes for its width.
    @AppStorage("sidebarShare") private var share = 0.25
    /// Fixed in place from the island's menu, when it neither moves nor resizes.
    @AppStorage("islandFixed") private var fixed = false
    /// How far the board still has to go to the room it was just given. It is laid out there at once and slides over
    /// whole, so its groups reflow once rather than on every frame of the way.
    @State private var slide: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settled: CGRect { IslandFrame.snap(IslandFrame.decode(fixedIsland ?? saved, share: share, in: window), in: window) }

    var body: some View {
        let room = IslandFrame.room(for: settled, in: window)
        ZStack(alignment: .topLeading) {
            // Both boards share the space while one fades into the other.
            ZStack {
                DashboardView(model: model, appDelegate: appDelegate, workspaces: workspaces, sidebar: false)
                    .id(model.workspaceID).transition(.opacity)
            }
            .padding(room)
            .offset(slide)
            .environment(\.besideLights, room.leading < 80 && room.top < 40)
            if window.width > 0 {
                FloatingIsland(model: model, workspaces: workspaces, settled: settled, window: window, fixed: $fixed, land: land)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { window = $0 }
        .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
        .frame(minWidth: 680, minHeight: 520)
    }

    /// The island stays where it was let go; the board takes its new room in one step and slides there from where it was.
    private func land(_ frame: CGRect) {
        let before = IslandFrame.room(for: settled, in: window), after = IslandFrame.room(for: frame, in: window)
        let gone = CGSize(width: before.leading - after.leading, height: before.top - after.top)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            saved = IslandFrame.encode(frame, in: window)
            if !reduceMotion { slide = gone }
        }
        guard slide != .zero else { return }
        // A frame later, so the board is drawn once where it was before it sets off.
        DispatchQueue.main.async { withAnimation(Motion.move) { slide = .zero } }
    }
}

/// The island over the board. While it is carried or resized only the island redraws: it follows the pointer, clicks
/// onto the walls it comes near, and slides along them exactly with the pointer.
private struct FloatingIsland: View {
    @Bindable var model: AppModel
    let workspaces: WorkspaceController
    let settled: CGRect
    let window: CGSize
    @Binding var fixed: Bool
    let land: (CGRect) -> Void
    /// The island while it is being moved or resized, and where it was when that began.
    @State private var live: CGRect?
    @State private var start: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let island = live ?? settled
        let carry: ((CGSize, Bool) -> Void)? = fixed ? nil : { move($0, done: $1) }
        let free = fixed ? [] : IslandFrame.freeEdges(island, in: window)
        WorkspaceSidebar(model: model, workspaces: workspaces, underLights: island.minX < 40 && island.minY < 30,
                         fixed: $fixed, moveIsland: carry)
            .frame(width: island.width, height: island.height)
            .overlay { IslandEdges(free: free) { resize($0, $1, done: $2) } }
            .offset(x: island.minX, y: island.minY)
    }

    private func move(_ translation: CGSize, done: Bool) {
        let from = start ?? settled
        start = from
        follow(IslandFrame.snap(from.offsetBy(dx: translation.width, dy: translation.height), in: window), done: done)
    }

    /// One free edge follows the pointer and clicks onto its wall when it comes near; the opposite edge stays put.
    private func resize(_ edge: Edge, _ translation: CGSize, done: Bool) {
        let from = start ?? settled
        start = from
        var frame = from
        let least = IslandFrame.smallest
        switch edge {
        case .leading: frame.origin.x = min(from.minX + translation.width, from.maxX - least.width); frame.size.width = from.maxX - frame.minX
        case .trailing: frame.size.width = max(from.width + translation.width, least.width)
        case .top: frame.origin.y = min(from.minY + translation.height, from.maxY - least.height); frame.size.height = from.maxY - frame.minY
        case .bottom: frame.size.height = max(from.height + translation.height, least.height)
        }
        follow(IslandFrame.resized(frame, moving: edge, in: window), done: done)
    }

    /// A wall taking the island, or letting it go, is one short step and a tap; anything else follows the pointer exactly.
    private func follow(_ frame: CGRect, done: Bool) {
        let clicked = IslandFrame.touching(frame, in: window) != IslandFrame.touching(live ?? settled, in: window)
        if clicked { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        if done {
            land(frame)
            live = nil; start = nil
        } else {
            withAnimation(clicked && !reduceMotion ? Motion.fade : nil) { live = frame }
        }
    }
}

/// Thin strips over the island's edges: the pointer turns into a resize arrow and dragging moves that edge.
/// Only the edges that lie free in the window: an edge resting on a wall stays there.
private struct IslandEdges: View {
    let free: Set<Edge>
    let resize: (Edge, CGSize, Bool) -> Void

    var body: some View {
        ZStack {
            if free.contains(.leading) { strip(.leading).frame(width: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).offset(x: -4) }
            if free.contains(.trailing) { strip(.trailing).frame(width: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).offset(x: 4) }
            if free.contains(.top) { strip(.top).frame(height: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).offset(y: -4) }
            if free.contains(.bottom) { strip(.bottom).frame(height: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).offset(y: 4) }
        }
    }

    private func strip(_ edge: Edge) -> some View {
        let position: FrameResizePosition = switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
        return Color.clear.contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { resize(edge, $0.translation, false) }
                .onEnded { resize(edge, $0.translation, true) })
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// True when the board's top left corner lies under the window's traffic lights, so its top bar keeps clear of them.
    @Entry var besideLights = false
}
