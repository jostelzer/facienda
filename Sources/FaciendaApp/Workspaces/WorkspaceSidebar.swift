import SwiftUI
import FaciendaCore

/// The workspaces as an island floating over the window, seen from further out than the board. Each is a small planet
/// of its painting, all the same size, wherever you put it; the open one comes closer where it stands, so nothing ever
/// moves on its own. The island tells two things: what agents are still working on, as a fine green dotted ring each,
/// breathing in, out and resting, ring after ring; and what came back new, as a soft blue glow and one fine blue ring
/// each. Then the agents' limits and Settings. The island fills whatever frame the window gives it, and stays there.
struct WorkspaceSidebar: View {
    @Bindable var model: AppModel
    var workspaces: WorkspaceController?
    /// True when the island sits under the window's traffic lights, so its top keeps room for them.
    var underLights = true
    @State private var hovered: String?
    /// The planet being carried to a new place: where it was picked up, and where it goes now, in line with any planet
    /// it has clicked to.
    @State private var carried: (id: String, start: CGPoint, snap: LineUp.Snap)?
    /// The planets a carried planet lines up with, kept a moment after it is set down so their lines fade, not vanish.
    @State private var lined: (id: String, column: String?, row: String?)?
    /// What is left of a carried planet's glide onto a line it just clicked to, or off one it left.
    @State private var glide: CGSize = .zero
    @State private var glider: String?
    /// Each name as it is set, so it can stay whole inside the island.
    @State private var nameSizes: [String: CGSize] = [:]
    /// The planets so low on the island that their names sit above them.
    @State private var namesAbove: Set<String> = []
    /// The planet last set down, which holds still where it was put while the others make room round it, until another
    /// planet is opened.
    @State private var dropped: String?
    /// The planet under a pressed pointer, which answers before the click is even finished.
    @State private var pressed: String?
    /// The workspace whose picture is being adjusted, and the wish being typed.
    @State private var adjusting: String?
    @State private var wish = ""
    /// Bumped each time something new lands in a workspace, to send one ripple out from its planet.
    @State private var arrivals: [String: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The room at the island's top: for the window's traffic lights when it sits under them, else for the + alone.
    private static let lights: CGFloat = 48, header: CGFloat = 38
    static let island = RoundedRectangle(cornerRadius: 26, style: .continuous)
    /// The open workspace comes close until its planet covers 1.6 times the area of the others. Its painting stays whole.
    private static let near: CGFloat = 1.6.squareRoot()

    var body: some View {
        VStack(spacing: 0) {
            if let workspaces { field(workspaces) } else { Spacer() }
            // The limits, with Settings as a gear to their right rather than a row of its own.
            // Someone using Claude gets a way to sign in for its limits rather than no row at all.
            let claudeUsagePrompt = model.claudeConnected && !model.demo && ClaudeUsage.shared.usage == nil
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    UsageMeters(usage: model.usage)
                    if claudeUsagePrompt { ClaudeUsagePrompt() }
                }.frame(maxWidth: .infinity, alignment: .leading)
                settingsButton
            }.padding(.leading, 6).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 10)
        }
        .padding(.top, underLights ? Self.lights : Self.header)
        .overlay(alignment: .topTrailing) { newWorkspaceButton.padding(.top, 8).padding(.trailing, 12) }
        .clipShape(Self.island)
        .contentShape(Self.island)
        .contextMenu {
            if let workspaces {
                Button("Arrange the planets", systemImage: "circle.grid.cross") { withAnimation(Motion.move) { workspaces.arrangePlaces(); dropped = nil } }
                Button("New workspace…", systemImage: "plus") { workspaces.error = nil; workspaces.sheet = .create }.disabled(workspaces.demo)
            }
        }
        // Paper, like the board's panel beside it, lit a little from above and lifted off the window's ground.
        .background {
            Self.island.fill(Palette.paper)
                .overlay { RadialGradient(colors: [Palette.card.opacity(0.5), .clear], center: .top, startRadius: 0, endRadius: 420).clipShape(Self.island) }
                .shadow(color: .black.opacity(0.1), radius: 22, y: 12)
        }
        .overlay { Self.island.strokeBorder(Palette.line, lineWidth: 1) }
        .onChange(of: workspaces.map { $0.codex.connected && $0.codex.accountReady } ?? false, initial: true) { _, ready in
            if ready { workspaces?.paintMissingCovers() }
        }
        .onChange(of: newWork, initial: true) { before, after in greet(before, after) }
    }

    /// Every workspace on the island, near its own place. Places are kept for an upright island; on a wide one, along a top
    /// or bottom wall, the same arrangement lies on its side. The planets keep a little space round each other: one that is
    /// carried, set down or opened holds still, and the others lean out of its way and drift home once there is room
    /// again. A carried planet clicks into line with the others, and is set down exactly where it shows. However small the
    /// island gets, every planet stays whole inside it.
    private func field(_ workspaces: WorkspaceController) -> some View {
        GeometryReader { proxy in
            let all = workspaces.ordered, area = proxy.size, wide = area.width > area.height
            let size = Self.planetSize(area: area, count: all.count)
            let openID = workspaces.current?.id
            // How far each planet reaches, rings included; the open one is nearer, so larger.
            let reach = Dictionary(uniqueKeysWithValues: all.map { workspace -> (String, CGFloat) in
                let rings = WorkRings.reach(new: workspaces.newCount(for: workspace), running: workspaces.runningCount(for: workspace))
                return (workspace.id, (size / 2 + rings) * (workspace.id == openID ? Self.near : 1) + 2)
            })
            // Where each planet rests when nothing pushes it: its own place, with all of it inside the island.
            let rest = Dictionary(uniqueKeysWithValues: all.map { workspace -> (String, CGPoint) in
                let place = workspaces.place(of: workspace)
                let fraction = wide ? CGPoint(x: place.y, y: place.x) : place
                return (workspace.id, Self.inside(CGPoint(x: fraction.x * area.width, y: fraction.y * area.height), reach: reach[workspace.id] ?? 0, area))
            })
            let bodies = Dictionary(uniqueKeysWithValues: all.map { workspace -> (String, ForceField.Body) in
                let home = carried.flatMap { $0.id == workspace.id ? $0.snap.point : nil } ?? rest[workspace.id] ?? .zero
                return (workspace.id, ForceField.Body(home: home, radius: reach[workspace.id] ?? 0))
            })
            let at = ForceField.settle(bodies, held: carried?.id ?? dropped ?? openID, in: CGRect(origin: .zero, size: area), lean: size * 0.35)
            ZStack(alignment: .topLeading) {
                Color.clear
                guides(at)
                ForEach(all) { workspace in
                    let point = at[workspace.id] ?? .zero
                    planet(workspace, workspaces, size: size, at: point, in: area)
                        .offset(glider == workspace.id ? glide : .zero)
                        .position(point)
                        .zIndex(carried?.id == workspace.id ? 3 : hovered == workspace.id ? 2 : workspace.id == workspaces.current?.id ? 1 : 0)
                        .gesture(carry(workspace, workspaces, from: point, reach: reach[workspace.id] ?? 0, rest: rest, in: area, wide: wide))
                }
            }
            // The others follow a carried planet at once; anything else that moves them, on the shared curve.
            .animation(carried == nil ? Motion.move : nil, value: at)
        }
    }

    /// About ninety points of planet on a usual island, smaller as the island shrinks or fills up, so all of them fit.
    private static func planetSize(area: CGSize, count: Int) -> CGFloat {
        let short = min(area.width, area.height), long = max(area.width, area.height)
        let fit = min(short * 0.21, long / (CGFloat(max(count, 1)) * 0.9 + 1)) * near
        return (min(max(fit, 38), 94) * (count > 6 ? 0.88 : 1)).rounded()
    }

    /// A planet's middle kept far enough from the island's edges for all of it to show; on an island too small for it, the
    /// island's middle.
    private static func inside(_ point: CGPoint, reach: CGFloat, _ area: CGSize) -> CGPoint {
        guard area.width >= reach * 2, area.height >= reach * 2 else { return CGPoint(x: area.width / 2, y: area.height / 2) }
        return CGPoint(x: min(max(point.x, reach), area.width - reach), y: min(max(point.y, reach), area.height - reach))
    }

    /// The lines a carried planet has clicked to, each from the middle of the planet it lines up with to its own. They lie
    /// under the planets, so only the stretch between the two shows.
    private func guides(_ at: [String: CGPoint]) -> some View {
        ZStack(alignment: .topLeading) {
            if let lined, let point = at[lined.id] {
                if let column = lined.column, let other = at[column] {
                    Self.guide(from: CGPoint(x: point.x, y: other.y), to: point).id("column " + column)
                }
                if let row = lined.row, let other = at[row] {
                    Self.guide(from: CGPoint(x: other.x, y: point.y), to: point).id("row " + row)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func guide(from start: CGPoint, to end: CGPoint) -> some View {
        Path { path in path.move(to: start); path.addLine(to: end) }
            .stroke(Palette.muted.opacity(0.75), lineWidth: 0.8)
            .transition(.opacity)
    }

    private func planet(_ workspace: Workspace, _ workspaces: WorkspaceController, size: CGFloat, at point: CGPoint, in area: CGSize) -> some View {
        let open = workspace.id == workspaces.current?.id
        let fresh = workspaces.newCount(for: workspace), running = workspaces.runningCount(for: workspace)
        let shown = open ? size * Self.near : size
        let image = workspaces.coverImages[workspace.id]
        let painting = workspaces.paintingCovers.contains(workspace.id)
        let reach = shown / 2 + WorkRings.reach(new: fresh, running: running) * (open ? Self.near : 1) + 6
        // A name stays under the middle of its planet until it would touch the island's edge, then waits there while the
        // planet goes on. Only when there is no room below does it cross over, fading, to sit above the planet; it comes
        // back a little later than it left, so it never flickers on the line.
        let name = nameSizes[workspace.id] ?? .zero, half = name.width / 2 + 10
        let shift = name.width + 20 > area.width ? area.width / 2 - point.x : min(max(point.x, half), area.width - half) - point.x
        let roomBelow = area.height + 4 - (point.y + reach + name.height)
        let above = namesAbove.contains(workspace.id)
        let showsName = open || carried?.id == workspace.id || (hovered == workspace.id && carried == nil)
        return ZStack {
            // Drawn for a far planet and brought close with it, so the rings only grow and shrink.
            WorkRings(new: fresh, running: running, radius: size / 2, phase: WorkRings.phase(for: workspace.id)).scaleEffect(open ? Self.near : 1)
            ArrivalRipple(trigger: arrivals[workspace.id] ?? 0, radius: shown / 2)
            disc(workspace, image: image, painting: painting, shown: shown, open: open)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .top) {
            label(workspace, painting: painting)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { nameSizes[workspace.id] = $0 }
                .offset(x: shift, y: reach + size / 2)
                .opacity(showsName && !above ? 1 : 0)
                .animation(open ? Motion.move : Motion.fade, value: showsName)
                .animation(Motion.fade, value: above)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            label(workspace, painting: painting)
                .fixedSize()
                .offset(x: shift, y: -(reach + size / 2))
                .opacity(showsName && above ? 1 : 0)
                .animation(open ? Motion.move : Motion.fade, value: showsName)
                .animation(Motion.fade, value: above)
                .allowsHitTesting(false)
        }
        .onChange(of: roomBelow, initial: true) { _, room in
            if room < 0, !namesAbove.contains(workspace.id) { namesAbove.insert(workspace.id) }
            else if room > 16, namesAbove.contains(workspace.id) { namesAbove.remove(workspace.id) }
        }
        .onHover { inside in if inside { hovered = workspace.id } else if hovered == workspace.id { hovered = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.name + (fresh > 0 ? ", \(fresh) new" : "") + (running > 0 ? ", \(running) running" : ""))
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

    /// The painting as a small sphere; the open one comes close, showing the same picture larger. Its initial until a
    /// picture exists.
    private func disc(_ workspace: Workspace, image: NSImage?, painting: Bool, shown: CGFloat, open: Bool) -> some View {
        ZStack {
            Palette.line
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .opacity(painting ? 0.5 : 1)
            } else if !painting {
                // Set large and scaled down, so the initial grows with its planet rather than jumping a size.
                Text(workspace.name.prefix(1).uppercased()).font(.system(size: 100, design: .serif)).foregroundStyle(Palette.muted)
                    .fixedSize().scaleEffect(shown * 0.42 / 100)
            }
            if painting { ProgressView().controlSize(.small) }
        }
        .frame(width: shown, height: shown)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(Palette.ink.opacity(0.12), lineWidth: open ? 0.6 : 1) }
        .brightness(hovered == workspace.id && !open ? 0.04 : 0)
        .opacity(pressed == workspace.id ? 0.8 : 1)
        .shadow(color: .black.opacity(open ? 0.22 : 0.12), radius: open ? 11 : 4, y: open ? 8 : 3)
        .contentShape(Circle())
    }

    /// The open workspace's name, or, on hover, any other's. Set the same way for both, so a planet chosen under the
    /// pointer keeps its name while it comes close, and the one drawing back lets its name fade as it was. Only names:
    /// the rings already say what is new and running.
    private func label(_ workspace: Workspace, painting: Bool) -> some View {
        VStack(spacing: 2) {
            Text(workspace.name).font(.system(size: 14, design: .serif)).foregroundStyle(Palette.ink)
            if painting { Text("Painting a picture…").font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
        // A soft edge of the island's own colour keeps it readable where it crosses another planet.
        .shadow(color: Palette.paper, radius: 2).shadow(color: Palette.paper, radius: 5)
    }

    /// A click opens the workspace; a drag carries its planet to a new place, where it stays. On the way it clicks into
    /// line with the other planets: it glides the last few points onto the line, the trackpad taps once, and a fine line
    /// joins it to the planet it lines up with. Let go, and it stays exactly where it shows.
    private func carry(_ workspace: Workspace, _ workspaces: WorkspaceController, from point: CGPoint, reach: CGFloat,
                       rest: [String: CGPoint], in area: CGSize, wide: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard carried?.id == workspace.id || hypot(drag.translation.width, drag.translation.height) > 4 else {
                    if pressed != workspace.id { pressed = workspace.id }
                    return
                }
                pressed = nil
                let before = carried?.id == workspace.id ? carried?.snap : nil
                let start = before == nil ? point : carried!.start
                let pointer = Self.inside(CGPoint(x: start.x + drag.translation.width, y: start.y + drag.translation.height), reach: reach, area)
                let snap = LineUp.snap(pointer, to: rest.filter { $0.key != workspace.id })
                carried = (workspace.id, start, snap)
                if let before, before.column != snap.column || before.row != snap.row {
                    // Only the direction that clicked on or let go jumps, and the planet glides over that jump.
                    glider = workspace.id
                    glide = CGSize(width: before.column == snap.column ? 0 : before.point.x - snap.point.x,
                                   height: before.row == snap.row ? 0 : before.point.y - snap.point.y)
                    // A moment later, so the planet is drawn once where it was before it glides on.
                    DispatchQueue.main.async { withAnimation(Motion.fade) { glide = .zero } }
                    if (snap.column != nil && snap.column != before.column) || (snap.row != nil && snap.row != before.row) {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                if lined?.id != workspace.id || lined?.column != snap.column || lined?.row != snap.row {
                    withAnimation(Motion.fade) { lined = (workspace.id, snap.column, snap.row) }
                }
            }
            .onEnded { _ in
                pressed = nil
                guard let held = carried, held.id == workspace.id else { choose(workspace, workspaces); return }
                var still = Transaction(); still.disablesAnimations = true
                withTransaction(still) {
                    let x = point.x / area.width, y = point.y / area.height
                    workspaces.setPlace(workspace, to: wide ? CGPoint(x: y, y: x) : CGPoint(x: x, y: y))
                    dropped = workspace.id
                    carried = nil
                }
                withAnimation(Motion.fade) { lined = nil }
            }
    }

    /// The chosen planet comes close and the open one draws back as one board fades into the next, all starting at the
    /// click and landing together. Reading the workspace and building its board hold the first frame for a moment.
    private func choose(_ workspace: Workspace, _ workspaces: WorkspaceController) {
        if workspace.id == workspaces.current?.id { model.search = ""; model.destination = .dashboard; return }
        guard !workspaces.demo else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.move) { dropped = nil; workspaces.open(workspace) }
    }

    /// What is new in every workspace, and which is open.
    private var newWork: NewWork {
        NewWork(open: workspaces?.current?.id, counts: Dictionary(uniqueKeysWithValues: (workspaces?.workspaces ?? []).map { ($0.id, workspaces?.newCount(for: $0) ?? 0) }))
    }

    /// Something that came back sends one ripple out from its planet. Not on a switch, when the open workspace's count
    /// is read from its model rather than the library, and not under Reduce Motion, where the new ring simply appears.
    private func greet(_ before: NewWork, _ after: NewWork) {
        guard !reduceMotion else { return }
        for (id, count) in after.counts where count > before.counts[id] ?? count {
            if before.open != after.open && (id == before.open || id == after.open) { continue }
            arrivals[id, default: 0] += 1
        }
    }

    @ViewBuilder private func menu(_ workspace: Workspace, _ workspaces: WorkspaceController) -> some View {
        Button("Memory", systemImage: "book.closed") {
            // The page switch is the window's, so the page shows once the workspace is open.
            UserDefaults.standard.set(DashboardMode.memory.rawValue, forKey: "dashboardMode")
            choose(workspace, workspaces)
        }
        Button("Edit workspace…", systemImage: "pencil") { workspaces.error = nil; workspaces.sheet = .edit(workspace) }
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
        Divider()
        Button("Manage workspaces…", systemImage: "square.stack.3d.up") { workspaces.reload(); workspaces.error = nil; workspaces.sheet = .manage }
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

/// What is new in each workspace, and which one is open.
private struct NewWork: Equatable {
    var open: String?
    var counts: [String: Int]
}

/// What a workspace is waiting for and what has arrived. Each task an agent is still working on is a fine green dotted
/// ring nearest the planet, dotted like the board's running sign; each that came back new is a fine solid blue ring just
/// outside them, in a soft blue glow. When an agent finishes, a dotted ring gives way to a solid one. Nothing at all
/// when nothing is running or new. Drawn for a far planet; the open one's are the same rings brought close.
private struct WorkRings: View {
    let new: Int
    let running: Int
    let radius: CGFloat
    /// Where in its cycle this workspace starts, so the island's planets never breathe as one.
    let phase: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let most = 5, mostRunning = 4, gap: CGFloat = 2.6, inset: CGFloat = 3
    /// Seconds for one cycle of the running rings: each takes its turn, from the planet outward, then all rest, still in view.
    private static let length: Double = 5.1
    /// Seconds between one ring starting its breath and the ring outside it starting theirs. Shorter than a breath, so a
    /// turn hands over to the next without a gap; four rings fit in a cycle with a moment's rest.
    private static let lane: Double = 0.95

    /// A steady place in the cycle for each workspace, from its id, the same on every launch.
    static func phase(for id: String) -> Double {
        Double(id.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % 1000) / 1000
    }

    /// How far past the planet's edge the rings reach.
    static func reach(new: Int, running: Int) -> CGFloat {
        let rings = min(running, mostRunning) + min(new, most)
        return rings == 0 ? 0 : inset + CGFloat(rings - 1) * gap + 1
    }

    var body: some View {
        let first = radius + Self.inset
        let dotted = min(running, Self.mostRunning), firstNew = first + CGFloat(dotted) * Self.gap
        ZStack {
            if new > 0 {
                let glow = radius + 2
                Circle().stroke(Palette.blue, lineWidth: 4.5)
                    .frame(width: glow * 2, height: glow * 2)
                    .blur(radius: 5)
                    .opacity(min(0.35 + 0.12 * Double(new), 0.75))
                    .transition(.opacity)
            }
            // The work under way breathes: the rings stand still, and each brightens, eases back and rests a little after the
            // one inside it, never fading out. Under Reduce Motion they rest at three quarters.
            if dotted > 0 {
                // One clock for every ring, read off the time itself, so a ring that joins later is in step with the rest
                // instead of stuck at the level it was born with.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    dottedRings(dotted, first: first, time: context.date.timeIntervalSinceReferenceDate)
                }
                .transition(.opacity)
            }
            ForEach(0..<min(new, Self.most), id: \.self) { ring in
                let size = (firstNew + CGFloat(ring) * Self.gap) * 2
                Circle().stroke(Palette.blue.opacity(1 - Double(ring) * 0.14), lineWidth: 0.8)
                    .frame(width: size, height: size)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.move, value: new)
        .animation(Motion.move, value: running)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dottedRings(_ count: Int, first: CGFloat, time: Double) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { ring in
                let size = (first + CGFloat(ring) * Self.gap) * 2
                Circle().stroke(Palette.green, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [0.01, 3.1]))
                    .frame(width: size, height: size)
                    .opacity(reduceMotion ? 0.75 : Breath.level(at: time + phase * Self.length - Double(ring) * Self.lane, in: Self.length))
                    .transition(.opacity)
            }
        }
    }
}

/// One blue ripple going out from the planet when something new lands, then gone. The only thing on the island that
/// moves by itself, once.
private struct ArrivalRipple: View {
    let trigger: Int
    let radius: CGFloat
    @State private var spread: CGFloat = 0
    @State private var visible = false

    var body: some View {
        Circle().stroke(Palette.blue, lineWidth: 1.2)
            .frame(width: radius * 2 + 2, height: radius * 2 + 2)
            .scaleEffect(1 + 0.9 * spread)
            .opacity(visible ? 0.85 * (1 - spread) : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: trigger) {
                spread = 0; visible = true
                withAnimation(Motion.curve(1.3)) { spread = 1 } completion: { visible = false }
            }
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

/// One running ring's breath, read off its workspace's clock: up to full over 0.6 s on the app's curve, back to its rest
/// over the next 0.9 s, then at rest until the cycle comes round again. The rest is a ring you can still see, never dark:
/// a ring that vanishes between breaths reads as a flicker, not as work going on. The caller sets each ring's place in
/// the cycle, so the rings take turns.
private enum Breath {
    static let lit = 0.6, out = 0.9
    static let rest = 0.55

    static func level(at time: Double, in length: Double) -> Double {
        let t = (time.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
        if t < lit { return rest + (1 - rest) * Motion.shape.value(at: t / lit) }
        if t < lit + out { return 1 - (1 - rest) * Motion.shape.value(at: (t - lit) / out) }
        return rest
    }
}
