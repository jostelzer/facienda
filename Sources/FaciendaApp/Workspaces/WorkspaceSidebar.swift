import SwiftUI
import FaciendaCore

/// The workspaces as an island floating over the window, laid out like a phone's home screen: a rounded tile of each
/// workspace's painting in a space of its own, its name under it, all the same size, open or not. The open one wears a
/// fine ring of its painting's colour, and the whole island takes on a wash of that colour, so nothing ever grows or moves
/// on its own. Each tile tells two things on its corners: what came back new, as a blue badge at the top, and what agents
/// are still working on, as the board's running arc on a small disc at the bottom. Then the agents' limits and Settings.
/// The island fills whatever frame the window gives it, and stays there.
struct WorkspaceSidebar: View {
    @Bindable var model: AppModel
    var workspaces: WorkspaceController?
    /// True when the island sits under the window's traffic lights, so its top keeps room for them.
    var underLights = true
    @State private var hovered: String?
    /// The tile being carried to another space: where it was picked up, and where it is now, under the pointer.
    @State private var carried: (id: String, start: CGPoint, point: CGPoint)?
    /// The tile under a pressed pointer, which answers before the click is even finished.
    @State private var pressed: String?
    /// The workspace whose picture is being adjusted, and the wish being typed.
    @State private var adjusting: String?
    @State private var wish = ""
    /// A memory link being made: with ⌥, a memory dragged onto the workspace that should read it; from a tile's menu,
    /// that tile waiting for the memory it should read to be clicked. Links draw no lines; the tile's menu lists them.
    @State private var linking: MemoryLinking?
    /// The workspace waiting for the user to confirm it should be archived.
    @State private var archiving: Workspace?
    /// The workspace last switched to, and when, on the clock events are stamped with.
    @State private var switched: (id: String, at: TimeInterval)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The room at the island's top: for the window's traffic lights when it sits under them, else as much as the board
    /// beside it gives its page row, so the first tiles start on the first cards' line and the + sits on the row's middle.
    private static let lights: CGFloat = 48, header: CGFloat = IslandFrame.firstLine - IslandGrid.top
    static let island = RoundedRectangle(cornerRadius: 26, style: .continuous)
    @Environment(\.colorScheme) private var colorScheme
    private static let fieldSpace = "island field"

    var body: some View {
        VStack(spacing: 0) {
            if let workspaces { field(workspaces) } else { Spacer() }
            // The limits, with Memory and Settings stacked to their right rather than rows of their own.
            // Someone using Claude gets a way to sign in for its limits rather than no row at all.
            let claudeUsagePrompt = model.claudeConnected && !model.demo && ClaudeUsage.shared.usage == nil
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    // Check-ins go stale without anything changing, so the faded bars are judged again every half minute.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        UsageMeters(usage: model.usage, down: model.agentsDown(at: context.date))
                    }
                    if claudeUsagePrompt { ClaudeUsagePrompt() }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) { memoryButton; settingsButton }
            }.padding(.leading, 6).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 10)
        }
        .padding(.top, underLights ? Self.lights : Self.header)
        .overlay(alignment: .topTrailing) { newWorkspaceButton.padding(.top, underLights ? 8 : IslandFrame.inset).padding(.trailing, 12) }
        .clipShape(Self.island)
        .contentShape(Self.island)
        .contextMenu {
            if let workspaces {
                Button("Close the gaps", systemImage: "square.grid.2x2") { withAnimation(Motion.move) { workspaces.closeGaps() } }
                    .disabled(!workspaces.hasGaps)
                Button("New workspace…", systemImage: "plus") { workspaces.error = nil; workspaces.sheet = .create }.disabled(workspaces.demo)
                archivedWorkspaces(workspaces)
            }
        }
        .alert("Archive workspace?", isPresented: Binding(presenting: $archiving), presenting: archiving) { workspace in
            Button("Cancel", role: .cancel) { archiving = nil }
            Button("Archive") {
                archiving = nil
                Task { _ = await workspaces?.archive(workspace) }
            }
        } message: { workspace in
            Text(Self.archiveMessage(workspace, running: workspaces?.runningCount(for: workspace) ?? 0))
        }
        // Paper, like the board's panel beside it, washed in the open workspace's colour, lit a little from above and lifted
        // off the window's ground. The wash changes with the switch, on its animation.
        .background {
            Self.island.fill(ground)
                .overlay { RadialGradient(colors: [Palette.card.opacity(0.5), .clear], center: .top, startRadius: 0, endRadius: 420).clipShape(Self.island) }
                .shadow(color: .black.opacity(0.1), radius: 22, y: 12)
        }
        .overlay { Self.island.strokeBorder(Palette.line, lineWidth: 1) }
        .onChange(of: workspaces.map { $0.codex.connected && $0.codex.accountReady } ?? false, initial: true) { _, ready in
            if ready { workspaces?.paintMissingCovers() }
        }
    }

    /// Every workspace in its space of the grid. A carried tile follows the pointer, and the tile in the space it is over
    /// steps into the space it left, so the island always shows what letting go would do. Only while a tile is carried do
    /// the empty spaces show. Which workspace is open plays no part, so switching leaves every tile where it is.
    private func field(_ workspaces: WorkspaceController) -> some View {
        GeometryReader { proxy in
            let all = workspaces.ordered, area = proxy.size
            let taken = Dictionary(uniqueKeysWithValues: all.map { ($0.id, workspaces.slot(of: $0)) })
            let grid = IslandGrid(area: area, lastTaken: taken.values.max() ?? 0)
            let target = carried.map { grid.space(nearest: $0.point) }
            let shown = Self.arrangement(taken, carried: carried?.id, to: target)
            ZStack(alignment: .topLeading) {
                // A click on the open island lets go of a link being chosen.
                Color.clear.contentShape(Rectangle()).onTapGesture { if linking?.anchorReads == true { withAnimation(Motion.fade) { linking = nil } } }
                spaces(grid, shown: shown, target: target)
                linkTarget(grid, shown: shown)
                ForEach(all) { workspace in
                    let held = carried?.id == workspace.id
                    let home = grid.centre(of: shown[workspace.id] ?? 0)
                    tile(workspace, workspaces, grid: grid, at: home.x)
                        .position(held ? carried?.point ?? home : home)
                        // The tile that steps aside moves on the shared curve; the carried one keeps to the pointer.
                        .animation(held ? nil : Motion.move, value: target)
                        .zIndex(held ? 3 : hovered == workspace.id ? 2 : workspace.id == workspaces.current?.id ? 1 : 0)
                        .gesture(carry(workspace, workspaces, from: home, grid: grid, shown: shown, in: area))
                }
            }
            .coordinateSpace(.named(Self.fieldSpace))
            .onContinuousHover(coordinateSpace: .named(Self.fieldSpace)) { phase in
                guard var chosen = linking, chosen.anchorReads else { return }
                if case .active(let pointer) = phase {
                    chosen.target = Self.workspace(at: pointer, except: chosen.anchor, shown: shown, grid: grid)
                } else { chosen.target = nil }
                if chosen.target != linking?.target, chosen.target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                linking = chosen
            }
            .overlay(alignment: .top) {
                if let chosen = linking, chosen.anchorReads, let reader = all.first(where: { $0.id == chosen.anchor }) {
                    Text("Click the memory \(reader.name) should read").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Palette.card, in: Capsule()).overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                        .padding(.top, 2).transition(.opacity).allowsHitTesting(false)
                }
            }
            .animation(Motion.fade, value: linking?.anchorReads)
            // A wider or narrower island wraps the tiles into more or fewer columns, on the shared curve.
            .animation(Motion.move, value: grid.columns)
        }
    }

    /// Where each tile shows: in its own space, except while one is carried, which shows in the space under it, and the
    /// tile there in the space the carried one left.
    private static func arrangement(_ taken: [String: Int], carried: String?, to target: Int?) -> [String: Int] {
        guard let carried, let target, let from = taken[carried], from != target else { return taken }
        var shown = taken
        if let other = taken.first(where: { $0.value == target })?.key { shown[other] = from }
        shown[carried] = target
        return shown
    }

    /// While a tile is carried the empty spaces show faintly, and the one it would land in a little more.
    private func spaces(_ grid: IslandGrid, shown: [String: Int], target: Int?) -> some View {
        let full = Set(shown.compactMap { $0.key == carried?.id ? nil : $0.value })
        let shape = RoundedRectangle(cornerRadius: grid.corner, style: .continuous)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<grid.spaces, id: \.self) { space in
                if !full.contains(space) {
                    let aimed = space == target
                    shape.fill(Palette.ink.opacity(aimed ? 0.09 : 0.05))
                        .overlay { shape.strokeBorder(Palette.ink.opacity(aimed ? 0.2 : 0.06), lineWidth: aimed ? 1.5 : 1) }
                        .frame(width: grid.tile, height: grid.tile)
                        .position(grid.centre(of: space))
                }
            }
        }
        .opacity(carried == nil ? 0 : 1)
        .animation(Motion.fade, value: carried == nil)
        .animation(Motion.fade, value: target)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// While a memory link is being made, the tile it would join gets a fine halo, outside where the open tile's ring
    /// sits. Links themselves draw nothing on the island; the tile's menu and the Memory page list them.
    private func linkTarget(_ grid: IslandGrid, shown: [String: Int]) -> some View {
        ZStack(alignment: .topLeading) {
            if let target = linking?.target, let space = shown[target] {
                RoundedRectangle(cornerRadius: grid.corner + 9, style: .continuous).stroke(Palette.muted, lineWidth: 1)
                    .frame(width: grid.tile + 18, height: grid.tile + 18)
                    .position(grid.centre(of: space))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.fade, value: linking?.target)
        .accessibilityHidden(true)
    }

    /// The workspace whose tile is under a point, if any but the one named.
    private static func workspace(at point: CGPoint, except id: String, shown: [String: Int], grid: IslandGrid) -> String? {
        guard let space = grid.space(under: point) else { return nil }
        return shown.first { $0.key != id && $0.value == space }?.key
    }

    private func tile(_ workspace: Workspace, _ workspaces: WorkspaceController, grid: IslandGrid, at x: CGFloat) -> some View {
        let open = workspace.id == workspaces.current?.id, held = carried?.id == workspace.id
        // A name stays centred under its tile, a long word drawing its letters closer and then hyphenating to fit. A name
        // that needs more than two lines even so shows whole while the pointer is on its tile, on a card that opens
        // where the name is and only grows downward, so nothing moves sideways.
        let room = grid.name(at: x), label = TileName(workspace.name, width: room - Self.namePad * 2)
        let unfolded = hovered == workspace.id && !held && label.cut
        let fresh = workspaces.newCount(for: workspace), running = workspaces.runningCount(for: workspace)
        let painting = workspaces.paintingCovers.contains(workspace.id)
        let size = grid.tile
        return ZStack {
            // On a switch the new ring closes in from a little wider and settles on its tile, while the old one opens
            // outward as it fades, evenly on every side. Under Reduce Motion they only fade.
            if open {
                ring(workspaces.coverColours[workspace.id], grid: grid)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.28).combined(with: .opacity))
            }
            face(workspace, image: workspaces.coverImages[workspace.id], painting: painting, grid: grid, open: open, held: held)
        }
        .animation(reduceMotion ? Motion.fade : Motion.move, value: open)
        // Picked up, the tile lifts a little towards the pointer, its ring with it.
        .scaleEffect(held ? 1.06 : 1)
        .animation(Motion.fade, value: held)
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            // New at the top corner, working at the bottom one, like a phone's badges, cut out of the island's colour.
            ZStack(alignment: .topLeading) {
                NewBadge(count: fresh, cut: ground).position(x: size - 5, y: 5)
                RunningBadge(count: running, cut: ground).offset(x: size - 5 - RunningBadge.centre, y: size - 5 - RunningBadge.centre)
            }
            .frame(width: size, height: size, alignment: .topLeading)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            // A name wraps onto a second line, as on the Mac desktop, and only one longer than that is cut. The open
            // workspace's name sits in a pill of a deep shade of its colour, as the Mac marks a selected icon.
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            Text(label.text).font(.system(size: TileName.size)).tracking(label.tracking)
                .foregroundStyle(open ? onPill : Palette.ink)
                .lineLimit(unfolded ? nil : 2).truncationMode(.tail).multilineTextAlignment(.center)
                .padding(.horizontal, Self.namePad).padding(.vertical, 1)
                .background {
                    shape.fill(Palette.card).overlay { shape.strokeBorder(Palette.line, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
                        .opacity(unfolded && !open ? 1 : 0)
                }
                // The pill settles onto the name the way the ring settles onto the tile.
                .background(shape.fill(pill(workspaces.coverColours[workspace.id]))
                    .scaleEffect(x: open || reduceMotion ? 1 : 1.18, y: open || reduceMotion ? 1 : 1.4)
                    .opacity(open ? 1 : 0))
                .animation(reduceMotion ? Motion.fade : Motion.move, value: open)
                .animation(Motion.fade, value: unfolded)
                .frame(width: room)
                .offset(y: size + 4)
        }
        .onHover { inside in if inside { hovered = workspace.id } else if hovered == workspace.id { hovered = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.name + (fresh > 0 ? ", \(fresh) new" : "") + (running > 0 ? ", \(running) running" : "")
                            + (painting ? ", painting a picture" : ""))
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(workspace, workspaces) }
        .contextMenu { menu(workspace, workspaces) }
        .popover(isPresented: Binding(get: { adjusting == workspace.id }, set: { if !$0 { adjusting = nil } }), arrowEdge: .trailing) {
            CoverWishPopover(wish: $wish, notes: workspace.coverNoteList, subject: "picture",
                             forget: { workspaces.forgetCoverNotes(workspace) },
                             apply: { workspaces.adjustCover(workspace, instruction: wish); wish = ""; adjusting = nil },
                             cancel: { adjusting = nil },
                             restore: workspaces.canUndoCover(workspace) ? { workspaces.undoCover(workspace); adjusting = nil } : nil)
        }
    }

    /// How far in from the pill's edge a name under a tile stands.
    private static let namePad: CGFloat = 4

    /// The painting as a rounded tile, the same size open or not. Its initial until a picture exists.
    private func face(_ workspace: Workspace, image: NSImage?, painting: Bool, grid: IslandGrid, open: Bool, held: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: grid.corner, style: .continuous)
        return ZStack {
            Palette.line
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .opacity(painting ? 0.5 : 1)
            } else if !painting {
                Text(workspace.name.prefix(1).uppercased()).font(.system(size: grid.tile * 0.42, design: .serif)).foregroundStyle(Palette.muted)
            }
            if painting { ProgressView().controlSize(.small) }
        }
        .frame(width: grid.tile, height: grid.tile)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.ink.opacity(0.12), lineWidth: 1) }
        .brightness(hovered == workspace.id && !open ? 0.04 : 0)
        .opacity(pressed == workspace.id ? 0.8 : 1)
        .shadow(color: .black.opacity(held ? 0.22 : 0.12), radius: held ? 14 : 4, y: held ? 14 : 3)
        .contentShape(shape)
    }

    /// The open tile's ring: 3 points of its painting's colour, a little off the tile's edge. The wash is that colour too,
    /// so the ring takes a deeper shade of it in Light and a lighter one in Dark to stand off it. Muted until the
    /// workspace has a picture.
    private func ring(_ mean: NSColor?, grid: IslandGrid) -> some View {
        let shade = mean.map { Color(nsColor: WorkspaceController.islandTint(of: $0, lightness: colorScheme == .dark ? 0.8 : 0.46, boost: 1.8)) }
        return RoundedRectangle(cornerRadius: grid.corner + 5.5, style: .continuous)
            .strokeBorder(shade ?? Palette.muted, lineWidth: 3)
            .frame(width: grid.tile + 11, height: grid.tile + 11)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The open name's pill: a deep shade of the painting's colour in both looks, so light text reads on it. Muted until
    /// the workspace has a picture.
    private func pill(_ mean: NSColor?) -> Color {
        mean.map { Color(nsColor: WorkspaceController.islandTint(of: $0, lightness: 0.5)) } ?? Palette.muted
    }

    /// Light text on the pill: the paper in Light, the ink (itself light) in Dark.
    private var onPill: Color { colorScheme == .dark ? Palette.ink : Palette.paper }

    /// The island's paper with a fifth of the open workspace's colour in it, a little more in Dark where colour on dark
    /// paper shows less, so which workspace is open shows from the corner of the eye. Plain paper until it has a picture.
    private var ground: Color {
        guard let id = workspaces?.current?.id, let mean = workspaces?.coverColours[id] else { return Palette.paper }
        return Palette.paper.mix(with: Color(nsColor: WorkspaceController.islandTint(of: mean)), by: colorScheme == .dark ? 0.24 : 0.2, in: .device)
    }

    /// A click opens the workspace; a drag carries its tile to another space. The tile lifts and follows the pointer, the
    /// space it would land in shows, the trackpad taps as it comes over another, and the tile there steps aside into the
    /// space the carried one left. Let go, and it lands: the two have swapped, and nothing else has moved.
    ///
    /// With ⌥ held, the drag draws a memory link instead: let go over another tile and that workspace reads this one's
    /// memory, or stops reading it if it already did. While a link is chosen from a tile's menu, a click on another tile
    /// picks the memory it reads.
    private func carry(_ workspace: Workspace, _ workspaces: WorkspaceController, from home: CGPoint, grid: IslandGrid,
                       shown: [String: Int], in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.fieldSpace))
            .onChanged { drag in
                let dragging = linking.map { $0.anchor == workspace.id && !$0.anchorReads } ?? false
                guard linking?.anchorReads != true,
                      carried?.id == workspace.id || dragging || hypot(drag.translation.width, drag.translation.height) > 4 else {
                    if pressed != workspace.id { pressed = workspace.id }
                    return
                }
                pressed = nil
                if dragging || (carried == nil && !workspaces.demo && NSEvent.modifierFlags.contains(.option)) {
                    let target = Self.workspace(at: drag.location, except: workspace.id, shown: shown, grid: grid)
                    if let target, target != linking?.target { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    linking = MemoryLinking(anchor: workspace.id, anchorReads: false, target: target)
                    return
                }
                let start = carried?.id == workspace.id ? carried?.start ?? home : home
                // Kept whole inside the island.
                let half = grid.tile / 2
                let point = CGPoint(x: min(max(start.x + drag.translation.width, half), max(area.width - half, half)),
                                    y: min(max(start.y + drag.translation.height, half), max(area.height - half, half)))
                let before = carried.map { grid.space(nearest: $0.point) }
                carried = (workspace.id, start, point)
                if let before, before != grid.space(nearest: point) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
            .onEnded { _ in
                pressed = nil
                if let drawn = linking {
                    // A memory dragged onto a reader, or, from a reader's menu, the memory clicked for it to read.
                    let reader = drawn.anchorReads ? drawn.anchor : drawn.target
                    let source = drawn.anchorReads ? workspace.id : drawn.anchor
                    if drawn.anchorReads || drawn.anchor == workspace.id {
                        if let reader, reader != source, let readerSpace = workspaces.workspaces.first(where: { $0.id == reader }),
                           let sourceSpace = workspaces.workspaces.first(where: { $0.id == source }) {
                            withAnimation(Motion.fade) { workspaces.toggleRead(readerSpace, sourceSpace); hovered = reader }
                        }
                        withAnimation(Motion.fade) { linking = nil }
                        return
                    }
                }
                guard let held = carried, held.id == workspace.id else { choose(workspace, workspaces); return }
                withAnimation(Motion.move) {
                    workspaces.setSlot(workspace, to: grid.space(nearest: held.point))
                    carried = nil
                }
            }
    }

    /// The chosen tile's ring comes as the open one's fades and one board fades into the next, all starting at the click
    /// and landing together, with no tile moving. Reading the workspace and building its board hold the first frame for a
    /// moment.
    private func choose(_ workspace: Workspace, _ workspaces: WorkspaceController) {
        // A click on the open workspace goes back to its board, folding away an opened task as its × does.
        if workspace.id == workspaces.current?.id {
            // The second click of a double-click, or a click made while a big board was still coming, still belongs to
            // the switch here: the task left open in this workspace stays open.
            if let switched, switched.id == workspace.id, let event = NSApp.currentEvent, event.timestamp - switched.at < 5,
               event.clickCount > 1 || ProcessInfo.processInfo.systemUptime - event.timestamp > 0.1 { return }
            model.search = ""; model.destination = .dashboard
            if model.selection != nil { withAnimation(TaskOpenLayer.motion(from: model.openedFrom)) { model.select(nil) } }
            return
        }
        guard !workspaces.demo else { return }
        switched = (workspace.id, ProcessInfo.processInfo.systemUptime)
        withAnimation(reduceMotion ? Motion.fade : Motion.move) { workspaces.open(workspace) }
    }

    @ViewBuilder private func menu(_ workspace: Workspace, _ workspaces: WorkspaceController) -> some View {
        Button("Memory", systemImage: "book.closed") {
            // The page switch is the window's, so the page shows once the workspace is open.
            UserDefaults.standard.set(DashboardMode.memory.rawValue, forKey: "dashboardMode")
            choose(workspace, workspaces)
        }
        Button("Edit workspace…", systemImage: "pencil") { workspaces.error = nil; workspaces.sheet = .edit(workspace) }
        let others = workspaces.ordered.filter { $0.id != workspace.id }
        if !others.isEmpty, !workspaces.demo {
            Button("Read another memory…", systemImage: "arrow.down.forward.circle") {
                withAnimation(Motion.fade) { linking = MemoryLinking(anchor: workspace.id, anchorReads: true) }
            }
            Menu("Reads memory of", systemImage: "link") {
                ForEach(others) { other in
                    Toggle(other.name, isOn: Binding(get: { workspaces.read(workspace, other) != nil },
                                                     set: { _ in withAnimation(Motion.fade) { workspaces.toggleRead(workspace, other) } }))
                }
                // Whether each memory read here lends what it has understood too, marked as inferred.
                let sources = others.filter { workspaces.read(workspace, $0) != nil }
                if !sources.isEmpty {
                    Section("With what they have understood") {
                        ForEach(sources) { other in
                            Toggle(other.name, isOn: Binding(get: { workspaces.read(workspace, other)?.understanding ?? false },
                                                             set: { workspaces.setRead(workspace, other, understanding: $0) }))
                        }
                    }
                }
                Divider()
                Text("Or hold ⌥ and drag another workspace onto this one")
            }
        }
        if workspaces.coverPainter != nil, !workspaces.demo {
            let painting = workspaces.paintingCovers.contains(workspace.id)
            Divider()
            if workspace.coverPaintedAt == nil {
                Button("Paint a picture", systemImage: "paintbrush") { workspaces.paintCover(workspace) }.disabled(painting)
            } else {
                Button("Adjust the picture…", systemImage: "wand.and.stars") { wish = ""; adjusting = workspace.id }.disabled(painting)
                Button("Paint a new picture", systemImage: "paintbrush") { workspaces.paintCover(workspace, newStyle: true) }.disabled(painting)
            }
            if workspaces.canUndoCover(workspace) {
                Button("Restore the previous picture", systemImage: "arrow.uturn.backward") { workspaces.undoCover(workspace) }
            }
        }
        if workspace.id == workspaces.current?.id, !model.archivedGroups.isEmpty {
            Divider()
            Menu("Archived groups", systemImage: "archivebox") {
                ForEach(model.archivedGroups) { group in
                    Button("Restore “\(group.name)”") { model.restoreGroup(group) }
                }
            }
        }
        Divider()
        Button("Archive workspace…", systemImage: "archivebox") { workspaces.error = nil; archiving = workspace }
            .disabled(workspaces.demo || workspaces.workspaces.count < 2)
        Button("Manage workspaces…", systemImage: "square.stack.3d.up") { workspaces.reload(); workspaces.error = nil; workspaces.sheet = .manage }
    }

    @ViewBuilder private func archivedWorkspaces(_ workspaces: WorkspaceController) -> some View {
        if !workspaces.archived.isEmpty, !workspaces.demo {
            Divider()
            Menu("Archived workspaces", systemImage: "archivebox") {
                ForEach(workspaces.archived) { workspace in
                    Button("Restore “\(workspace.name)”") { workspaces.restore(workspace) }
                }
            }
        }
    }

    /// What archiving takes with it, said plainly: everything is kept, and any agent at work stops.
    static func archiveMessage(_ workspace: Workspace, running: Int) -> String {
        let kept = "“\(workspace.name)” is put away with its groups, tasks, chats and memory, and its open tasks are archived too. Restore brings it all back."
        guard running > 0 else { return kept }
        return kept + " \(running == 1 ? "One task is" : "\(running) tasks are") running now: \(running == 1 ? "its agent stops" : "their agents stop"), and they come back as Needs me."
    }

    private var newWorkspaceButton: some View {
        Button { workspaces?.error = nil; workspaces?.sheet = .create } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .disabled(workspaces == nil || workspaces?.demo == true)
        .help("New workspace")
        .accessibilityLabel("New workspace")
    }

    /// Opens Settings on Memory, where every read between workspaces shows above the rest.
    private var memoryButton: some View {
        Button { model.openSettings(.memory) } label: {
            // The book's cover sits right of its spine and the page corner pokes out further, so it is drawn a point to the
            // left to stand on the gear's axis rather than to one side of it.
            Image(systemName: "book.closed").font(.system(size: 14)).offset(x: -1)
                .foregroundStyle(model.showSettings && model.settingsPane == .memory ? Palette.ink : Palette.muted)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .help("Memory")
        .accessibilityLabel("Memory")
    }

    private var settingsButton: some View {
        Button { model.openSettings() } label: {
            Image(systemName: "gearshape").font(.system(size: 14))
                .foregroundStyle(model.showSettings && model.settingsPane != .memory ? Palette.ink : Palette.muted)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

/// What came back new: a blue badge on the tile's top corner, a dot for one task and the number for more. While the work
/// waits it rings as the board's blue dot does, on the same clock, so the island and the board ring together; nothing at
/// all when nothing is new. Like the board's dot it keeps ringing under Reduce Motion, growing in place.
private struct NewBadge: View {
    let count: Int
    /// The island's colour, round the badge, so it stands clear of the picture's edge.
    let cut: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if count > 0 {
                Group {
                    if count > 1 {
                        Text("\(count)").font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(Palette.paper)
                            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                    } else { Color.clear.frame(width: 12, height: 12) }
                }
                .background(Palette.blue, in: Capsule())
                // The ring leaves the badge's own edge and goes as far out as the board's does, so a number rings too.
                .background {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let eased = UnreadDot.ring(at: context.date)
                        Capsule().strokeBorder(Palette.blue, lineWidth: 1.5)
                            .padding(-UnreadDot.travel * eased).opacity(0.85 * (1 - eased))
                    }
                }
                .padding(2).background(cut, in: Capsule())
                .fixedSize()
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.move, value: count > 0)
        .animation(Motion.fade, value: count > 1)
        .accessibilityHidden(true)
    }
}

/// What agents are still working on: the board's running arc on a small disc at the tile's lower corner, with the count
/// beside it when more than one task runs. It turns once every 4.4 seconds, a quarter of the board's pace, and every badge
/// reads the same clock, so a busy island turns as one slow thing rather than several quick ones. Like the board's, it
/// keeps turning under Reduce Motion, as a progress indicator does.
private struct RunningBadge: View {
    let count: Int
    let cut: Color
    /// Where the arc's middle sits, from the badge's top left, so the badge can be set by it.
    static let centre: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The board's card in Light; in Dark, where the card is darker than the washed island and would sink into it, the
    /// island lifted a shade instead.
    private var disc: Color { colorScheme == .dark ? cut.mix(with: Palette.ink, by: 0.11, in: .device) : Palette.card }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if count > 0 {
                HStack(spacing: 0) {
                    TaskDot(kind: .running, turn: 4.4)
                    if count > 1 {
                        Text("\(count)").font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(Palette.green)
                            .padding(.trailing, 5)
                    }
                }
                .frame(height: 16)
                .background(disc, in: Capsule())
                .padding(2).background(cut, in: Capsule())
                .compositingGroup()
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
                .fixedSize()
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: UnitPoint(x: 0.3, y: 0.5)).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.move, value: count > 0)
        .animation(Motion.fade, value: count > 1)
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

/// A memory link on its way: the tile it starts at, whether that tile is the one that will read, and the tile under the
/// pointer.
private struct MemoryLinking: Equatable {
    var anchor: String
    var anchorReads: Bool
    var target: String? = nil
}

