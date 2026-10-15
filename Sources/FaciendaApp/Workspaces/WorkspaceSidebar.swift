import SwiftUI
import FaciendaCore

/// The open workspace as a painting across the top, its name set large over it, then the other workspaces as quiet
/// rows, then the agents' limits and Settings. Click a workspace to switch, drag one to reorder.
struct WorkspaceSidebar: View {
    @Bindable var model: AppModel
    var workspaces: WorkspaceController?
    /// The window's width, so the sidebar can keep its share of it.
    var windowWidth: CGFloat = 0
    @State private var dragging: String?
    @State private var drop: (id: String, after: Bool)?
    @State private var heights: [String: CGFloat] = [:]
    @State private var adjusting: String?
    @State private var hoveringHero = false
    @State private var hoveredRow: String?
    @State private var height: CGFloat = 0
    /// The sidebar's share of the window. Drag its edge to change it; double-click the edge to bring it back.
    @AppStorage("sidebarShare") private var share = Self.defaultShare
    @State private var dragStart: CGFloat?
    private static let defaultShare: CGFloat = 0.25, narrowest: CGFloat = 220, widest: CGFloat = 560
    /// Everything grows with the sidebar: about 60 points of picture at the default quarter of a usual window.
    private var thumbnail: CGFloat { (width * 0.175).rounded() }
    private var rowFont: CGFloat { max(13, (thumbnail * 0.25).rounded()) }
    private var heroFont: CGFloat { min(max(width * 0.085, 22), 44).rounded() }

    private var width: CGFloat {
        guard windowWidth > 0 else { return 300 }
        return min(max(windowWidth * share, Self.narrowest), Self.widest)
    }
    /// About square, and never more than half the sidebar's height.
    private var heroHeight: CGFloat { min(width, max(height * 0.5, 180)).rounded() }
    /// Rounded at the window's top-left corner, where the picture starts; its lower edge has no line, the picture washes out into the sidebar.
    private static let heroShape = UnevenRoundedRectangle(topLeadingRadius: 16, style: .continuous)
    @State private var wish = ""
    /// Where each other workspace's tile and the open picture sit, so a switch can fly the pictures between them.
    @State private var tiles: [String: CGRect] = [:]
    @State private var heroFrame: CGRect = .zero
    @State private var flight: WorkspaceFlight?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let space = "workspaceSidebar"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let workspaces, let current = workspaces.current { hero(current, workspaces) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let workspaces {
                        ForEach(workspaces.ordered.filter { $0.id != workspaces.current?.id }) { row($0, workspaces) }
                        Button("New workspace…") { workspaces.error = nil; workspaces.sheet = .create }
                            .buttonStyle(SidebarLinkStyle()).padding(.leading, thumbnail + thumbnail * 0.25).padding(.top, 2).disabled(workspaces.demo)
                    }
                }.padding(.horizontal, 12).padding(.top, 14)
            }.scrollIndicators(.never)
            // The limits, with Settings as a gear to their right rather than a row of its own.
            // Someone using Claude gets a way to sign in for its limits rather than no row at all.
            let claudeUsagePrompt = model.claudeConnected && !model.demo && ClaudeUsage.shared.usage == nil
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    UsageMeters(usage: model.usage)
                    if claudeUsagePrompt { ClaudeUsagePrompt() }
                }.frame(maxWidth: .infinity, alignment: .leading)
                settingsButton
            }.padding(.leading, 12).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 12)
        }
        .overlay(alignment: .topLeading) { flightLayer }
        .coordinateSpace(.named(Self.space))
        // A workspace without a picture still leaves room for the window's traffic lights.
        .padding(.top, workspaces?.current == nil ? 52 : 0)
        .onChange(of: workspaces.map { $0.codex.connected && $0.codex.accountReady } ?? false, initial: true) { _, ready in
            if ready { workspaces?.paintMissingCovers() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(width: width).frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { resizeHandle.offset(x: 4) }
        .background(Palette.sidebar)
    }

    /// The open workspace's painting, edge to edge under the traffic lights, with its name over a soft fade.
    private func hero(_ workspace: Workspace, _ workspaces: WorkspaceController) -> some View {
        let fresh = workspaces.newCount(for: workspace)
        let painting = workspaces.paintingCovers.contains(workspace.id)
        return Button { choose(workspace, workspaces) } label: {
            // The frame is fixed first and the painting fills it from behind, so a wide picture can't push the name out past the edge.
            Palette.line
                .overlay {
                    if let image = workspaces.coverImages[workspace.id] {
                        Image(nsImage: image).resizable().scaledToFill().opacity(painting ? 0.5 : 1)
                    }
                }
                .frame(width: width, height: heroHeight).clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: Palette.sidebar.opacity(0), location: 0.3), .init(color: Palette.sidebar.opacity(0.55), location: 0.7),
                                           .init(color: Palette.sidebar, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) { heroName(workspace.name, fresh: fresh, running: model.count(.processing)) }
                .overlay {
                    if painting {
                        Label("Painting a picture…", systemImage: "paintbrush").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.4), in: Capsule())
                    }
                }
                .clipShape(Self.heroShape)
                .contentShape(Self.heroShape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { pictureControls(workspace, workspaces).padding(12) }
        // While the pictures fly, the flight layer draws this one; it shows again as the flight lands on it.
        .opacity(flight == nil ? 1 : 0)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { heroFrame = $0 }
        .onHover { hoveringHero = $0 }
        .help(workspace.coverStyle?.isEmpty == false ? "Picture: " + workspace.coverStyle! : workspace.name)
        .accessibilityLabel(workspace.name + (fresh > 0 ? ", \(fresh) new" : ""))
        .accessibilityAddTraits(.isSelected)
        .contextMenu { menu(workspace, workspaces) }
    }

    private func row(_ workspace: Workspace, _ workspaces: WorkspaceController) -> some View {
        let fresh = workspaces.newCount(for: workspace)
        return Button { choose(workspace, workspaces) } label: {
            HStack(spacing: (thumbnail * 0.25).rounded()) {
                WorkspaceThumbnail(workspace: workspace, image: workspaces.coverImages[workspace.id],
                                   painting: workspaces.paintingCovers.contains(workspace.id), size: thumbnail)
                    .opacity(flight?.carries(workspace.id) == true ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { tiles[workspace.id] = $0 }
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name).font(.system(size: rowFont, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    if fresh > 0 { Text("\(fresh) new").font(.system(size: max(11.5, rowFont - 2))).foregroundStyle(Palette.muted).lineLimit(1) }
                }
                Spacer(minLength: 4)
                // New work since the user last looked, marked like an unread row on the board.
                if fresh > 0 { Circle().fill(Palette.blue).frame(width: 7, height: 7).accessibilityHidden(true) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hoveredRow == workspace.id ? Palette.card.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: drop?.after == true ? .bottom : .top) {
                if drop?.id == workspace.id { Capsule().fill(Palette.ink).frame(height: 1.5).padding(.horizontal, 8) }
            }
            .opacity(dragging == workspace.id ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .onHover { inside in if inside { hoveredRow = workspace.id } else if hoveredRow == workspace.id { hoveredRow = nil } }
        .disabled(workspaces.demo)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[workspace.id] = $0 }
        .help(fresh > 0 ? "\(workspace.name) · \(fresh) finished since you last looked" : workspace.name)
        .accessibilityLabel(workspace.name + (fresh > 0 ? ", \(fresh) new" : ""))
        .onDrag {
            dragging = workspace.id
            return NSItemProvider(object: workspace.id as NSString)
        }
        .onDrop(of: [.text], delegate: SidebarDropDelegate(target: workspace, height: heights[workspace.id] ?? 40, workspaces: workspaces, dragging: $dragging, drop: $drop))
        .contextMenu { menu(workspace, workspaces) }
    }

    @ViewBuilder private func menu(_ workspace: Workspace, _ workspaces: WorkspaceController) -> some View {
        Button("Edit workspace…", systemImage: "pencil") { workspaces.error = nil; workspaces.sheet = .edit(workspace) }
        Divider()
        Button("Manage workspaces…", systemImage: "square.stack.3d.up") { workspaces.reload(); workspaces.error = nil; workspaces.sheet = .manage }
    }

    /// A strip over the divider: the pointer turns into a resize arrow and dragging sets the sidebar's share of the window.
    private var resizeHandle: some View {
        Color.clear.frame(width: 8).frame(maxHeight: .infinity).contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    guard windowWidth > 0 else { return }
                    let start = dragStart ?? width
                    dragStart = start
                    share = min(max(start + drag.translation.width, Self.narrowest), Self.widest) / windowWidth
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { withAnimation(Motion.move) { share = Self.defaultShare } }
            .accessibilityHidden(true)
    }

    private func choose(_ workspace: Workspace, _ workspaces: WorkspaceController) {
        if workspace.id == workspaces.current?.id { model.search = ""; model.destination = .dashboard; return }
        guard flight == nil, !reduceMotion, let leaving = workspaces.current, let tile = tiles[workspace.id] else {
            // Reduce Motion, or a click while pictures are still flying: the board fades across and nothing travels.
            withAnimation(reduceMotion ? Motion.fade : Motion.travel) { _ = workspaces.open(workspace) }
            return
        }
        // The list keeps your order without the open workspace, so the one you leave lands in its own place,
        // in one of the slots the rows fill now.
        let slots = workspaces.ordered.filter { $0.id != leaving.id }.compactMap { tiles[$0.id] }.sorted { $0.minY < $1.minY }
        let after = workspaces.ordered.map(\.id).filter { $0 != workspace.id }
        guard let index = after.firstIndex(of: leaving.id), slots.indices.contains(index) else {
            withAnimation(Motion.travel) { _ = workspaces.open(workspace) }
            return
        }
        flight = WorkspaceFlight(arriving: workspace, leaving: leaving, tile: tile, slot: slots[index], hero: heroFrame,
                                 leavingFresh: workspaces.newCount(for: leaving), leavingRunning: model.count(.processing))
        MotionLog.begin("Workspace switch")
        withAnimation(Motion.travel) {
            if workspaces.open(workspace) {
                // Counted once, from the model just opened, rather than on every frame of the flight.
                flight?.arrivingFresh = workspaces.newCount(for: workspace)
                flight?.arrivingRunning = workspaces.model?.count(.processing) ?? 0
                flight?.progress = 1
            } else { flight = nil }
        } completion: { flight = nil; MotionLog.end() }
    }

    /// The name set large over the picture, with what is new and running under it.
    private func heroName(_ name: String, fresh: Int, running: Int) -> some View {
        let summary = [fresh > 0 ? "\(fresh) new" : nil, running > 0 ? "\(running) running" : nil].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 5) {
            // Always the whole name: it wraps onto a second line, then steps down in size, but is never cut.
            Text(name).font(.system(size: heroFont, design: .serif)).foregroundStyle(Palette.ink)
                .lineLimit(2).minimumScaleFactor(0.55).multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.3), radius: 8)
            if !summary.isEmpty {
                HStack(spacing: 7) {
                    if fresh > 0 { Circle().fill(Palette.blue).frame(width: 7, height: 7) }
                    Text(summary).font(.system(size: max(12.5, (heroFont * 0.45).rounded()))).foregroundStyle(Palette.ink.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    /// The clicked tile growing into the picture, over the old picture shrinking into its place in the list.
    /// Each carries its name, which fades in on the way up and out on the way down.
    @ViewBuilder private var flightLayer: some View {
        if let flight, let workspaces {
            let corner = (thumbnail * 0.25).rounded()
            ZStack(alignment: .topLeading) {
                FlyingPicture(image: workspaces.coverImages[flight.leaving.id], from: flight.hero, to: flight.slot, corner: corner,
                              heroWidth: flight.hero.width, toHero: false, progress: flight.progress) {
                    heroName(flight.leaving.name, fresh: flight.leavingFresh, running: flight.leavingRunning)
                }
                FlyingPicture(image: workspaces.coverImages[flight.arriving.id], from: flight.tile, to: flight.hero, corner: corner,
                              heroWidth: flight.hero.width, toHero: true, progress: flight.progress) {
                    heroName(flight.arriving.name, fresh: flight.arrivingFresh, running: flight.arrivingRunning)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Hovering the painting offers a wish for it, like a group's cover, or a first picture while it has none.
    @ViewBuilder private func pictureControls(_ workspace: Workspace, _ workspaces: WorkspaceController) -> some View {
        if workspaces.coverPainter != nil, !workspaces.demo {
            let shown = (hoveringHero || adjusting == workspace.id) && !workspaces.paintingCovers.contains(workspace.id)
            let painted = workspace.coverPaintedAt != nil
            Button {
                if painted { wish = ""; adjusting = workspace.id } else { workspaces.paintCover(workspace) }
            } label: {
                Image(systemName: painted ? "wand.and.stars" : "paintbrush").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(.black.opacity(0.4), in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).help(painted ? "Adjust this picture" : "Paint a picture").accessibilityLabel(painted ? "Adjust this picture" : "Paint a picture")
            .opacity(shown ? 1 : 0).animation(Motion.fade, value: shown)
            .popover(isPresented: Binding(get: { adjusting == workspace.id }, set: { if !$0 { adjusting = nil } }), arrowEdge: .trailing) {
                CoverWishPopover(wish: $wish, notes: workspace.coverNoteList, subject: "picture",
                                 forget: { workspaces.forgetCoverNotes(workspace) },
                                 apply: { workspaces.adjustCover(workspace, instruction: wish); wish = ""; adjusting = nil },
                                 cancel: { adjusting = nil },
                                 restore: workspaces.canUndoCover(workspace) ? { workspaces.undoCover(workspace); adjusting = nil } : nil)
            }
        }
    }

    private var settingsButton: some View {
        Button { model.openSettings() } label: {
            Image(systemName: "gearshape").font(.system(size: 14))
                .foregroundStyle(model.showSettings ? Palette.ink : Palette.muted)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

/// A switch in flight: the workspace arriving from its tile and the one leaving for its slot in the list.
private struct WorkspaceFlight {
    let arriving: Workspace
    let leaving: Workspace
    let tile: CGRect
    let slot: CGRect
    let hero: CGRect
    /// The leaving workspace's counts, read before its model gives way to the new one.
    let leavingFresh: Int
    let leavingRunning: Int
    /// The arriving workspace's counts, read once its model is open.
    var arrivingFresh = 0
    var arrivingRunning = 0
    var progress: CGFloat = 0

    /// The tiles the flight draws itself, hidden in the list until it lands.
    func carries(_ id: String) -> Bool { id == arriving.id || id == leaving.id }
}

/// A workspace picture between a tile and the big picture. The frame, corners, wash and name all follow one progress,
/// so they move as a piece. The name keeps the big picture's width and is cropped by the frame rather than rewrapped.
private struct FlyingPicture<Name: View>: View, @MainActor Animatable {
    let image: NSImage?
    let from: CGRect
    let to: CGRect
    let corner: CGFloat
    let heroWidth: CGFloat
    let toHero: Bool
    var progress: CGFloat
    @ViewBuilder let name: () -> Name

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let _ = toHero ? MotionLog.frame() : ()
        let p = progress, mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * p }
        let rect = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width), height: mix(from.height, to.height))
        // 1 when this is the big picture, 0 when it is a tile.
        let hero = toHero ? p : 1 - p
        let square = corner * (1 - hero)
        Palette.line
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .overlay {
                LinearGradient(stops: [.init(color: Palette.sidebar.opacity(0), location: 0.3), .init(color: Palette.sidebar.opacity(0.55), location: 0.7),
                                       .init(color: Palette.sidebar, location: 1)], startPoint: .top, endPoint: .bottom)
                    .opacity(hero)
            }
            .frame(width: rect.width, height: rect.height).clipped()
            .overlay(alignment: .bottomLeading) {
                name().frame(width: heroWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true).opacity(hero)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: square + 16 * hero, bottomLeadingRadius: square,
                                              bottomTrailingRadius: square, topTrailingRadius: square, style: .continuous))
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The sidebar stays in the window while the board beside it is swapped for another workspace's, so a switch can fly
/// the pictures across the sidebar while one board fades into the next on the same curve.
struct WorkspaceWindow: View {
    @Bindable var model: AppModel
    var appDelegate: AppDelegate?
    let workspaces: WorkspaceController
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(model: model, workspaces: workspaces, windowWidth: width)
            Divider()
            // Both boards share the space while one fades into the other.
            ZStack {
                DashboardView(model: model, appDelegate: appDelegate, workspaces: workspaces, sidebar: false)
                    .id(model.workspaceID).transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
        .frame(minWidth: 680, minHeight: 520)
    }
}

/// Another workspace's painted picture as a small rounded tile, its initial until one exists, and a spinner while Codex paints.
private struct WorkspaceThumbnail: View {
    let workspace: Workspace
    let image: NSImage?
    let painting: Bool
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Palette.line)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().opacity(painting ? 0.5 : 1)
                } else if !painting {
                    Text(workspace.name.prefix(1).uppercased()).font(.system(size: size * 0.46, design: .serif)).foregroundStyle(Palette.muted)
                }
            }
            .overlay { if painting { ProgressView().controlSize(.mini) } }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .frame(width: size, height: size)
            .help(painting ? "Painting a picture…" : workspace.name)
            .accessibilityHidden(true)
    }
}

/// Hover only deepens the text; nothing grows or moves.
private struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SidebarRow(configuration: configuration) }
    private struct SidebarRow: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .brightness(hovering ? 0.08 : 0)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

private struct SidebarLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted.opacity(0.75))
            .padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Rows stay put while dragging; a thin line shows where the workspace will land.
private struct SidebarDropDelegate: DropDelegate {
    let target: Workspace
    let height: CGFloat
    let workspaces: WorkspaceController
    @Binding var dragging: String?
    @Binding var drop: (id: String, after: Bool)?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drop = dragging == target.id ? nil : (target.id, info.location.y > height / 2)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if drop?.id == target.id { drop = nil } }
    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; drop = nil }
        guard let dragging, let source = workspaces.workspaces.first(where: { $0.id == dragging }) else { return false }
        // The rows close up and open on the same move as the board's cards.
        withAnimation(Motion.move) { workspaces.move(source, to: target, after: info.location.y > height / 2) }
        return true
    }
}
