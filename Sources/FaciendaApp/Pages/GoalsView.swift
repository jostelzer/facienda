import SwiftUI
import FaciendaCore

/// Goals: the other side of the window. Where the island and the board show work by where it lives, this shows it by
/// what it is for. A map of the few goals, each a painted circle with its subgoals around it, takes the whole room;
/// Reached in the header lists everything reached, under the goal it served. Goals and subgoals move where they are
/// dragged. Nothing zooms: a goal starts folded, its subgoals only beads on its rim, and a click on it sends them out
/// onto its orbit with their names, or folds them back. A click on a subgoal hangs its minigoals under its dot as short
/// lines, and the subgoals in the way give way. A click on a line opens its minigoal's box beside it, with the work
/// toward it. Near an unfolded goal, the orbit its subgoals sit on shows; a click on it writes a new subgoal on that
/// spot. Esc folds one step at a time, then turns back to the board.
/// Today in the header opens the day's list in a panel of its own on the right, and the map makes room. While it is
/// open every subgoal's minigoals hang out and a click on one picks it for the day; a subgoal's + writes a new one.
struct GoalsView: View {
    @Bindable var goals: GoalsModel
    let workspaces: WorkspaceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The goal or subgoal being dragged, and how far.
    @State private var drag: Drag?
    /// The map's size, so a drag can be saved as a share of it.
    @State private var mapSize: CGSize = .zero
    @State private var namingGoal = false
    @State private var showingReached = false
    /// The goal a new subgoal is being named for.
    @State private var namingSubgoal: String?
    /// A subgoal being written where it was clicked on its goal's orbit, and its words.
    @State private var placing: OrbitLayer.Hit?
    @State private var placingText = ""
    @FocusState private var placingFocus: Bool
    /// The line, or the subgoal's name, a dragged task is over.
    @State private var target: String?
    @State private var hovered: String?
    /// The minigoal whose words and place are open from its line.
    @State private var editing: String?
    /// What is being written under each open subgoal.
    @State private var drafts: [String: String] = [:]
    @FocusState private var writing: String?
    /// The open box's height, to keep it inside the map.
    @State private var boxHeight: CGFloat = 0
    /// Words on their way from a minigoal on the map to its new row on today's list.
    @State private var flight: Flight?
    /// Where each minigoal's words sit, and each line to write on, for a flight to start from. Only read on a click,
    /// so it is kept out of what the view watches.
    @State private var origins = Origins()
    static let mapSpace = "goalMap"
    /// The map and today's list together, which words fly across.
    static let roomSpace = "goalRoom"
    /// What a dragged task carries: its id, marked so a stray drop of text from elsewhere is turned away.
    static let dragMark = "facienda-goal-task:"

    struct Drag: Equatable { var id: String; var by: CGSize }

    /// A picked minigoal's words, drawn over both panels while they travel to their row. `to` is known once the row is
    /// laid out.
    private struct Flight: Equatable { var id: String; var text: String; var from: CGPoint; var to: CGRect? }
    private final class Origins { var frames: [String: CGRect] = [:] }

    /// Where everything sits on the map.
    private struct Spots {
        var goals: [String: CGPoint] = [:]
        var subgoals: [String: CGPoint] = [:]
        var hangs: [String: Hang] = [:]
        /// Each subgoal's name with any minigoals hanging from it, as drawn.
        var rooms: [String: CGRect] = [:]
        var names: [String: CGRect] = [:]
    }

    /// How an open subgoal's minigoals hang from its dot: on the side its name reads to, down unless down is in the way.
    private struct Hang {
        var right: Bool
        var down: Bool
        /// From the dot to the first line, clear of the name.
        var gap: CGFloat
        var width: CGFloat
        var height: CGFloat
        /// Something under the subgoal is new: its name starts after a blue dot, and so do the words of its lines.
        var fresh: Bool

        /// From the side of a line to its words: the marker, the space after it, the padding and any blue dot.
        var inset: CGFloat { GoalsView.leafInset + (fresh ? 12 : 0) }

        func frame(at point: CGPoint) -> CGRect {
            CGRect(x: right ? point.x - 4 : point.x + 4 - width, y: down ? point.y + gap : point.y - gap - height, width: width, height: height)
        }
    }

    var body: some View {
        HStack(spacing: IslandFrame.margin) {
            VStack(spacing: 0) {
                header
                GeometryReader { proxy in map(in: proxy.size) }
                    .coordinateSpace(name: Self.mapSpace)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
                    .clipped()
            }
            .background(Palette.paper)
            .boardPanel()
            if goals.today {
                TodayList(goals: goals, workspaces: workspaces, hovered: $hovered, writing: $writing, arriving: flight?.id) { id, frame in land(id, at: frame) }
                    .frame(width: TodayList.width)
                    .boardPanel()
                    // From past the window's edge, so nothing of it shows before it moves.
                    .transition(reduceMotion ? .opacity : .offset(x: TodayList.width + IslandFrame.margin))
            }
        }
        .coordinateSpace(name: Self.roomSpace)
        .overlay(alignment: .topLeading) { flying }
        // Esc anywhere folds a step: the open box, then the open minigoals, then turns back to the board. With Today
        // open it first ends what is being written.
        .background {
            Button("") {
                if placing != nil { placingText = ""; placing = nil }
                else if goals.today, writing != nil { writing = nil } else { goals.back(reduceMotion: reduceMotion) }
            }
                .keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true)
        }
        // Focus going elsewhere ends the new subgoal: kept if it has words, dropped if not.
        .onChange(of: placingFocus) { _, focused in if !focused { finishPlacing() } }
    }

    // MARK: Picking

    /// A click on a minigoal with Today open puts it on the list, or takes it off. Picked, its words fly to their row.
    private func pick(_ item: GoalItem) {
        if item.line.pickedAt == nil { fly(item.line.id, text: item.line.text, from: item.line.id) }
        withAnimation(reduceMotion ? Motion.fade : Motion.travel) { goals.pick(item) }
    }

    private func fly(_ id: String, text: String, from key: String) {
        guard !reduceMotion, let from = origins.frames[key] else { return }
        flight = Flight(id: id, text: text, from: from.origin)
        // A row that never shows, such as one under a goal reached meanwhile, must not leave the words hanging.
        Task { try? await Task.sleep(for: .seconds(1)); if flight?.id == id { flight = nil } }
    }

    /// The row is laid out: the words travel there with everything else that moves, and the row takes over.
    private func land(_ id: String, at frame: CGRect) {
        guard flight?.id == id, flight?.to == nil else { return }
        withAnimation(Motion.travel) { flight?.to = frame } completion: { if flight?.id == id { flight = nil } }
    }

    /// The words in flight, drawn as the row will draw them, a little smaller at first as they are on the map.
    @ViewBuilder private var flying: some View {
        if let flight {
            Text(flight.text).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(3)
                .frame(width: flight.to?.width ?? TodayList.width - 80, alignment: .leading)
                .scaleEffect(flight.to == nil ? 12.0 / 13 : 1, anchor: .topLeading)
                .offset(x: flight.to?.minX ?? flight.from.x, y: flight.to?.minY ?? flight.from.y)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    // MARK: Header

    /// Goals, then Reached, the + for a new goal and the ✕.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Goals").font(.system(size: 22, weight: .medium, design: .serif))
            Spacer(minLength: 12)
            todayButton
            reachedButton
            PlusButton(help: "New goal", label: "New goal") { namingGoal = true }
                .popover(isPresented: $namingGoal, arrowEdge: .bottom) {
                    NamePopover(title: "New goal", prompt: "What you want to move", initial: "", action: "Add") { text in
                        goals.newGoal(text); namingGoal = false
                    } cancel: { namingGoal = false }
                }
            Button { goals.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26).background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain).help("Back to the board").accessibilityLabel("Close Goals")
        }
        .padding(.leading, 20).padding(.trailing, 14).frame(height: 52)
    }

    /// Today's list, beside the map. Lit while it is open.
    private var todayButton: some View {
        Button { goals.setToday(!goals.today, reduceMotion: reduceMotion) } label: {
            Text("Today").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 11).frame(height: 26)
                .background(goals.today ? Palette.selected : Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(goals.today ? Palette.firmLine : Palette.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(goals.today ? "Close today's list" : "Pick what today is for")
        .accessibilityAddTraits(goals.today ? .isSelected : [])
    }

    /// A switch for what was reached: on, finished minigoals show faint on the map and done rows on today's list; off,
    /// both keep to what is still open. Lit while on. Its chevron opens everything reached, by goal.
    private var reachedButton: some View {
        let count = goals.ledger.count, on = goals.showReached
        return HStack(spacing: 0) {
            Button { goals.setShowReached(!on, reduceMotion: reduceMotion) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(count > 0 || on ? Palette.green : Palette.muted)
                    Text("Reached").font(.system(size: 12, weight: .medium))
                    if count > 0 { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted).contentTransition(.numericText()) }
                }
                .foregroundStyle(Palette.ink).padding(.leading, 11).padding(.trailing, 5).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(on ? "Hide what you reached" : "Show what you reached")
            .accessibilityAddTraits(on ? .isSelected : [])
            Button { showingReached.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
                    .padding(.leading, 3).padding(.trailing, 10).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("What you reached, by goal").accessibilityLabel("What you reached, by goal")
            .popover(isPresented: $showingReached, arrowEdge: .bottom) { ReachedList(goals: goals, workspaces: workspaces) }
        }
        .background(on || showingReached ? Palette.selected : Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(on ? Palette.firmLine : Palette.line, lineWidth: 1))
        .clipShape(Capsule())
        .animation(Motion.fade, value: count)
    }

    // MARK: Map

    private static let radius: CGFloat = 58
    /// The orbit a goal's subgoals sit on, a circle like the goal's own, and how far out from the goal's middle a click
    /// still reaches it.
    fileprivate static let orbit: CGFloat = 132
    private static let orbitReach: CGFloat = 215
    /// How far out from a folded goal's middle its subgoals sit as beads, close around its circle.
    private static let beadReach: CGFloat = radius + 8

    /// Subgoals fan out away from the middle of the map, so neighbours keep their distance.
    private static func away(from centre: CGPoint, middle: CGPoint) -> Double {
        hypot(centre.x - middle.x, centre.y - middle.y) < 20 ? -Double.pi / 2 : atan2(centre.y - middle.y, centre.x - middle.x)
    }

    /// Where a subgoal sits on its goal's orbit until it is moved, as an offset from the goal.
    private static func fan(_ index: Int, of count: Int, away: Double) -> CGSize {
        let step = min(38, 150 / Double(max(count - 1, 1))) * .pi / 180
        let angle = away + (Double(index) - Double(count - 1) / 2) * step
        return CGSize(width: cos(angle) * orbit, height: sin(angle) * orbit)
    }

    /// The goal whose orbit a point is near, and the place on the orbit in line with it. Not on a goal's circle, nor on
    /// a subgoal's name or its lines, and the nearest goal wins.
    fileprivate static func orbitHit(at point: CGPoint, centres: [String: CGPoint], rooms: [CGRect]) -> OrbitLayer.Hit? {
        guard !rooms.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(point) }),
              let near = centres.min(by: { hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y) })
        else { return nil }
        let centre = near.value, distance = hypot(point.x - centre.x, point.y - centre.y)
        guard distance > radius + 16, distance < orbitReach else { return nil }
        let angle = atan2(point.y - centre.y, point.x - centre.x)
        return OrbitLayer.Hit(goal: near.key, offset: CGSize(width: cos(angle) * orbit, height: sin(angle) * orbit))
    }

    /// Where a hairline from a goal's middle toward a point leaves the goal's rim.
    fileprivate static func rim(_ centre: CGPoint, toward end: CGPoint) -> CGPoint {
        let length = max(hypot(end.x - centre.x, end.y - centre.y), 1), rim = radius + 8
        return CGPoint(x: centre.x + (end.x - centre.x) / length * rim, y: centre.y + (end.y - centre.y) / length * rim)
    }
    /// One minigoal's line under its subgoal, and the widest a line may be.
    private static let leafHeight: CGFloat = 26, leafWidth: CGFloat = 300
    /// The line to write a new minigoal on.
    private static let writerWidth: CGFloat = 200
    private static let boxWidth: CGFloat = 290

    /// Where each open goal and subgoal sits, with any drag under way, and how each open subgoal's minigoals hang.
    private func places(in size: CGSize) -> Spots {
        let open = goals.openGoals
        var spots = Spots(), sizes: [String: CGSize] = [:], beads: [String: CGPoint] = [:]
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        for (index, goal) in open.enumerated() {
            var centre = goal.x.flatMap { x in goal.y.map { CGPoint(x: x * size.width, y: $0 * size.height) } }
                ?? Self.slot(index, of: open.count, in: size)
            if let drag, drag.id == goal.id { centre.x += drag.by.width; centre.y += drag.by.height }
            centre = Self.clamp(centre, in: size)
            spots.goals[goal.id] = centre
            let children = goals.subgoals(of: goal.id), away = Self.away(from: centre, middle: middle)
            for (i, sub) in children.enumerated() {
                var offset = sub.x.flatMap { x in sub.y.map { CGSize(width: x, height: $0) } }
                    ?? Self.fan(i, of: children.count, away: away)
                if let drag, drag.id == sub.id { offset.width += drag.by.width; offset.height += drag.by.height }
                // Folded, the subgoal is a bead on the rim in line with its place on the orbit, so it travels straight
                // out when the goal unfolds. Beads have no names, so nothing gives way to them.
                guard goals.spreads(goal.id) else {
                    let length = max(hypot(offset.width, offset.height), 1)
                    beads[sub.id] = CGPoint(x: centre.x + offset.width / length * Self.beadReach, y: centre.y + offset.height / length * Self.beadReach)
                    continue
                }
                let point = CGPoint(x: centre.x + offset.width, y: centre.y + offset.height)
                let node = Self.nodeSize(sub, fresh: goals.hasNew(subgoal: sub.id), holds: holds(sub), open: goals.hangs(sub.id))
                spots.subgoals[sub.id] = point
                sizes[sub.id] = node
                if goals.hangs(sub.id) { spots.hangs[sub.id] = hang(sub.id, at: point, centre: centre, node: node, in: size) }
            }
        }
        separate(&spots, sizes: sizes, in: size)
        spots.subgoals.merge(beads) { place, _ in place }
        return spots
    }

    /// How a subgoal's open minigoals hang: one short line each and the line to write on last, down from its dot, or up
    /// when down would cross its goal's circle or run off the map.
    private func hang(_ id: String, at point: CGPoint, centre: CGPoint, node: CGSize, in size: CGSize) -> Hang {
        let leaves = goals.leaves(of: id), right = point.x >= centre.x - 8, fresh = goals.hasNew(subgoal: id)
        let down = max(22, node.height / 2 + 6), up = node.height / 2 + 10
        // Where the map is narrow beside the dot, the words give way rather than the subgoal moving. The room counts from
        // where the dot ends up once its name is held inside the map.
        let x = right ? min(point.x, size.width - 8 - node.width + 13) : max(point.x, 8 + node.width - 13)
        let room = right ? size.width - 8 - (x - 4) : x + 4 - 8
        let inset = Self.leafInset + (fresh ? 12 : 0)
        let width = max(min(Self.leafWidth, max(Self.writerWidth, inset + Self.widest(leaves, plain: goals.today)), room), 120)
        var hang = Hang(right: right, down: true, gap: down, width: width, height: CGFloat(leaves.count + 1) * Self.leafHeight, fresh: fresh)
        let below = hang.frame(at: point)
        hang.down = false; hang.gap = up
        let above = hang.frame(at: point)
        let fitsBelow = below.maxY <= size.height - 8, fitsAbove = above.minY >= 8
        func clear(_ frame: CGRect, fits: Bool) -> Bool { fits && !Self.crosses(frame, circle: centre, radius: Self.radius + 14) }
        hang.down = clear(below, fits: fitsBelow) || (!clear(above, fits: fitsAbove) && (fitsBelow || !fitsAbove))
        if hang.down { hang.gap = down }
        return hang
    }

    /// From the side of a line to its words: the marker, the space after it and the padding round the words.
    fileprivate static let leafInset: CGFloat = 8 + 7 + 14

    /// The widest of a subgoal's lines past the inset: its words, held to a name's width, and its counts. Plain, with
    /// Today open, a line is its words alone.
    private static func widest(_ leaves: [GoalsModel.Leaf], plain: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return leaves.map { leaf in
            min(170, ceil(((leaf.entry?.line.line.text ?? "No minigoal") as NSString).size(withAttributes: [.font: font]).width)) + (plain ? 0 : extras(leaf))
        }.max() ?? 0
    }

    /// How far a line's work is: "d of n", or "n tasks" once it is done or holds the work on no minigoal.
    private static func progress(_ leaf: GoalsModel.Leaf) -> String? {
        let count = leaf.work.count
        guard count > 0 else { return nil }
        return leaf.entry == nil || leaf.isDone ? "\(count) task\(count == 1 ? "" : "s")" : "\(leaf.finished) of \(count)"
    }

    /// What was found for a line, after its sparkle: just the number where the line is narrow.
    private static func found(_ leaf: GoalsModel.Leaf, short: Bool) -> String { short ? "\(leaf.found)" : "\(leaf.found) found" }

    /// The room a line's counts take beside its words, measured as they are drawn.
    private static func extras(_ leaf: GoalsModel.Leaf, short: Bool = false) -> CGFloat {
        func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let counts = progress(leaf).map { 6 + width($0, .monospacedDigitSystemFont(ofSize: 11, weight: .regular)) } ?? 0
        let found = leaf.found > 0 ? 6 + 10 + 3 + width(found(leaf, short: short), .systemFont(ofSize: 11)) : 0
        return counts + found
    }

    /// Whether a frame comes nearer a circle's centre than its radius.
    private static func crosses(_ frame: CGRect, circle centre: CGPoint, radius: CGFloat) -> Bool {
        let dx = max(frame.minX - centre.x, 0, centre.x - frame.maxX), dy = max(frame.minY - centre.y, 0, centre.y - frame.maxY)
        return dx * dx + dy * dy < radius * radius
    }

    /// Moves subgoals, as little as it takes, so no name sits on another name, on open minigoals or on a goal, no
    /// minigoals hang over a goal, and nothing runs off the map. The one being dragged stays under the pointer, and an
    /// open one gives way only to it; the others give way to both. Where a subgoal was left is kept as it was; only where
    /// it is drawn moves.
    private func separate(_ spots: inout Spots, sizes: [String: CGSize], in size: CGSize) {
        let ids = spots.subgoals.keys.sorted(), centres = spots.goals, hangs = spots.hangs, gap: CGFloat = 6, margin: CGFloat = 8
        guard !ids.isEmpty else { return }
        var points = spots.subgoals
        let parents = Dictionary(uniqueKeysWithValues: ids.compactMap { id in goals.goal(id)?.parentId.flatMap { centres[$0] }.map { (id, $0) } })
        func name(_ id: String) -> CGRect {
            let point = points[id] ?? .zero, size = sizes[id] ?? CGSize(width: 120, height: 26)
            let right = point.x >= (parents[id]?.x ?? point.x) - 8
            return CGRect(x: right ? point.x - 13 : point.x + 13 - size.width, y: point.y - size.height / 2, width: size.width, height: size.height)
        }
        // A name with the minigoals hanging from it.
        func room(_ id: String) -> CGRect {
            guard let hang = hangs[id], let point = points[id] else { return name(id) }
            return name(id).union(hang.frame(at: point))
        }
        func rank(_ id: String) -> Int { id == drag?.id ? 2 : hangs[id] != nil ? 1 : 0 }
        let reach = Self.radius + 12
        let rims = centres.values.map { CGRect(x: $0.x - Self.radius - 8, y: $0.y - Self.radius - 8, width: (Self.radius + 8) * 2, height: (Self.radius + 8) * 2) }
        // How far to move a span so it sits inside the map, the start first when it can't fit.
        func inside(_ low: CGFloat, _ high: CGFloat, _ limit: CGFloat) -> CGFloat {
            low < margin ? margin - low : high > limit - margin ? max(limit - margin - high, margin - low) : 0
        }
        for _ in 0..<24 {
            var moved = false
            func shift(_ id: String, x: CGFloat = 0, y: CGFloat = 0) {
                guard abs(x) > 0.5 || abs(y) > 0.5 else { return }
                points[id]?.x += x; points[id]?.y += y; moved = true
            }
            for (index, a) in ids.enumerated() {
                for b in ids[(index + 1)...] {
                    let first = room(a), second = room(b)
                    guard first.insetBy(dx: -gap, dy: -gap / 2).intersects(second) else { continue }
                    // Upper and lower by their dots, so a name under an open subgoal's dot moves below all its minigoals.
                    let (upper, lower) = (points[a]?.y ?? 0) <= (points[b]?.y ?? 0) ? (a, b) : (b, a)
                    let push = room(upper).maxY - room(lower).minY + gap
                    let up = rank(upper) > rank(lower) ? 0 : rank(lower) > rank(upper) ? push : push / 2
                    shift(upper, y: -up); shift(lower, y: push - up)
                }
                if a != drag?.id {
                    // A goal's circle stays clear of names too: the name moves off it to whichever side is nearer.
                    for rim in rims where name(a).intersects(rim) {
                        let frame = name(a)
                        shift(a, y: frame.midY < rim.midY ? -(frame.maxY - rim.minY + gap) : rim.maxY - frame.minY + gap)
                    }
                    // Minigoals never hang over a goal: they move sideways, away from its middle, until they clear it.
                    if let hang = hangs[a], let point = points[a] {
                        for centre in centres.values {
                            let frame = hang.frame(at: point)
                            guard Self.crosses(frame, circle: centre, radius: reach) else { continue }
                            let dy = max(frame.minY - centre.y, 0, centre.y - frame.maxY), clear = (reach * reach - dy * dy).squareRoot()
                            shift(a, x: frame.midX >= centre.x ? centre.x + clear - frame.minX : centre.x - clear - frame.maxX)
                        }
                    }
                }
                let whole = room(a)
                shift(a, x: inside(whole.minX, whole.maxX, size.width), y: inside(whole.minY, whole.maxY, size.height))
            }
            if !moved { break }
        }
        spots.subgoals = points
        spots.rooms = Dictionary(uniqueKeysWithValues: ids.map { ($0, room($0)) })
        spots.names = Dictionary(uniqueKeysWithValues: ids.map { ($0, name($0)) })
    }

    /// How much room a subgoal takes on the map: its dot, the blue dot when something came back, and its name up to two
    /// lines, with what it holds beneath.
    private static func nodeSize(_ sub: Goal, fresh: Bool, holds: String, open: Bool) -> CGSize {
        let name = (sub.text as NSString).boundingRect(with: CGSize(width: 170, height: 200), options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: NSFont.systemFont(ofSize: 12, weight: open ? .semibold : .regular)])
        let below = (holds as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width
        let line = NSFont.systemFont(ofSize: 12).boundingRectForFont.height
        let height = min(ceil(name.height), ceil(line * 2)) + (holds.isEmpty ? 0 : 15)
        return CGSize(width: 26 + 5 + (fresh ? 12 : 0) + max(min(170, ceil(name.width)), ceil(below)), height: max(26, height))
    }

    /// What a subgoal holds, in the board's words: tasks, what is planned but not started, and board work found for it.
    private func holds(_ sub: Goal) -> String {
        // With Today open nothing is counted: the map is for picking.
        if goals.today { return "" }
        let tasks = goals.items(of: sub.id).filter { $0.task != nil }.count, planned = goals.entries(of: sub.id).filter(\.isPlanned).count
        let found = goals.found(subgoal: sub.id)
        return [tasks > 0 ? "\(tasks) task\(tasks == 1 ? "" : "s")" : nil, planned > 0 ? "\(planned) planned" : nil, found > 0 ? "\(found) found" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Where a goal sits until it is moved: four in a square, more in a ring.
    private static func slot(_ index: Int, of count: Int, in size: CGSize) -> CGPoint {
        let spots: [CGPoint] = switch count {
        case 1: [CGPoint(x: 0.5, y: 0.47)]
        case 2: [CGPoint(x: 0.3, y: 0.47), CGPoint(x: 0.7, y: 0.47)]
        case 3: [CGPoint(x: 0.28, y: 0.3), CGPoint(x: 0.72, y: 0.3), CGPoint(x: 0.5, y: 0.72)]
        case 4: [CGPoint(x: 0.28, y: 0.3), CGPoint(x: 0.72, y: 0.3), CGPoint(x: 0.28, y: 0.72), CGPoint(x: 0.72, y: 0.72)]
        default: (0..<count).map { i in
            let angle = -Double.pi / 2 + Double(i) * 2 * .pi / Double(count)
            return CGPoint(x: 0.5 + cos(angle) * 0.3, y: 0.5 + sin(angle) * 0.3)
        }
        }
        return CGPoint(x: spots[index].x * size.width, y: spots[index].y * size.height)
    }

    private static func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let margin = radius + 16
        return CGPoint(x: min(max(point.x, margin), max(size.width - margin, margin)), y: min(max(point.y, margin), max(size.height - margin, margin)))
    }

    /// A hairline from a goal's rim to one of its subgoals.
    private struct Strand: Identifiable { var id: String; var from: CGPoint; var to: CGPoint }

    private func strands(_ spots: Spots) -> [Strand] {
        goals.openGoals.flatMap { goal in
            goals.subgoals(of: goal.id).compactMap { sub -> Strand? in
                guard let centre = spots.goals[goal.id], let end = spots.subgoals[sub.id] else { return nil }
                let length = hypot(end.x - centre.x, end.y - centre.y), rim = Self.radius + 8
                guard length > Self.radius + 14 else { return nil }
                let from = CGPoint(x: centre.x + (end.x - centre.x) / length * rim, y: centre.y + (end.y - centre.y) / length * rim)
                // Folded, the hairline shrinks to nothing on the rim, and grows out again with its subgoal.
                return Strand(id: sub.id, from: from, to: goals.spreads(goal.id) ? end : from)
            }
        }
    }

    @ViewBuilder private func map(in size: CGSize) -> some View {
        let open = goals.openGoals
        if open.isEmpty {
            VStack(spacing: 14) {
                EmptyNote(symbol: "scope", title: "No goals yet",
                          detail: "Write down the few things you want to move. Their subgoals hold the work that serves them.")
                    .frame(maxHeight: 260)
                Button("New goal") { namingGoal = true }.buttonStyle(QuietButton())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let spots = places(in: size)
            let subs = open.flatMap { goals.subgoals(of: $0.id) }
            ZStack(alignment: .topLeading) {
                // A click on the empty map first ends what is open: the box, a line being written, a new subgoal. With
                // nothing open, a click on a goal's orbit starts a subgoal there.
                OrbitLayer(centres: spots.goals.filter { goals.spreads($0.key) || goals.subgoals(of: $0.key).isEmpty }, rooms: Array(spots.rooms.values),
                           live: drag == nil && placing == nil && goals.openBox == nil && writing == nil) { hit in
                    if placing != nil { finishPlacing() }
                    else if goals.openBox != nil || writing != nil { goals.closeBox(); writing = nil }
                    else if let hit { placingText = ""; placing = hit }
                }
                // Hairlines from each goal's rim to its subgoals, which move with them as minigoals open.
                ForEach(strands(spots)) { strand in Wire(from: strand.from, to: strand.to).stroke(Palette.line, lineWidth: 1) }
                    .allowsHitTesting(false)
                ForEach(open) { goal in
                    if let centre = spots.goals[goal.id] {
                        ForEach(goals.subgoals(of: goal.id)) { sub in
                            if let point = spots.subgoals[sub.id] {
                                subgoalNode(sub, at: point, goalCentre: centre, folded: !goals.spreads(goal.id))
                            }
                        }
                        goalNode(goal, at: centre, size: size)
                    }
                }
                // Over the circles, so a line is never under a goal.
                ForEach(subs) { sub in
                    if let point = spots.subgoals[sub.id], let hang = spots.hangs[sub.id] {
                        hanging(sub, at: point, hang: hang).transition(.opacity)
                    }
                }
                openBox(spots, in: size)
                if let placing, let centre = spots.goals[placing.goal] { placingField(placing, centre: centre) }
            }
            .animation(Motion.move, value: goals.goals.map(\.id))
        }
    }

    private func goalNode(_ goal: Goal, at centre: CGPoint, size: CGSize) -> some View {
        let moved = goals.moved(goal: goal.id), quiet = goals.quietWeeks(goal: goal.id), r = Self.radius
        let image = goals.cover(goal), painting = goals.painting.contains(goal.id)
        let subs = goals.subgoals(of: goal.id), shown = goals.spreads(goal.id)
        // A picture's name sits on the side facing the middle, away from its subgoals.
        let inward: CGFloat = centre.y < size.height / 2 ? 1 : -1
        let label = VStack(spacing: 3) {
            if image != nil {
                Text(goal.text).font(.system(size: 14, weight: .medium, design: .serif)).multilineTextAlignment(.center).lineLimit(2)
                    .foregroundStyle(quiet == nil ? Palette.ink : Palette.muted)
            }
        }
        .frame(width: 200)
        return ZStack {
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFill().opacity(painting ? 0.5 : 1) }
                else { quiet == nil ? Palette.card : Palette.paper }
                if image == nil {
                    VStack(spacing: 3) {
                        Text(goal.text).font(.system(size: 14, weight: .medium, design: .serif)).multilineTextAlignment(.center)
                            .lineLimit(4).minimumScaleFactor(0.8).foregroundStyle(quiet == nil ? Palette.ink : Palette.muted)
                        if let quiet { Text("quiet \(quiet) week\(quiet == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    }
                    .frame(width: r * 1.6)
                }
                if painting { ProgressView().controlSize(.small) }
            }
            .frame(width: r * 2, height: r * 2).clipShape(Circle())
            .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            .opacity(image != nil && quiet != nil ? 0.6 : 1)
            .shadow(color: .black.opacity(image == nil ? 0 : 0.12), radius: 4, y: 3)
            label.offset(y: inward * (r + (image == nil ? 24 : 40)))
            if image != nil, let quiet {
                Text("quiet \(quiet) week\(quiet == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .offset(y: inward * (r + 70)).frame(width: 160)
            }
        }
        .frame(width: (r + 8) * 2, height: (r + 8) * 2)
        .contentShape(Circle())
        .onTapGesture { open(goal) }
        .gesture(moving(goal.id))
        .contextMenu {
            Button(shown ? "Fold subgoals" : "Show subgoals") { open(goal) }.disabled(subs.isEmpty)
            Button("New subgoal") { namingSubgoal = goal.id }
            Button("Rename") { goals.renaming = goal.id }
            Divider()
            Button(goal.coverPaintedAt == nil ? "Paint picture" : "Repaint picture") { goals.paint(goal) }.disabled(painting || workspaces.demo)
            if goal.coverStyle != nil { Button("Repaint in a new style") { goals.paint(goal, newStyle: true) }.disabled(painting || workspaces.demo) }
            Divider()
            Button(subs.isEmpty ? "Goal reached" : "Goal reached, once its subgoals are") { withAnimation(Motion.move) { goals.reach(goal.id) } }
                .disabled(!subs.isEmpty)
            Divider()
            Button("Delete goal", role: .destructive) { goals.delete(goal.id) }
        }
        .popover(isPresented: renaming(goal.id), arrowEdge: .bottom) {
            NamePopover(title: "Goal", prompt: "What you want to move", initial: goal.text, action: "Save") { goals.rename(goal.id, to: $0); goals.renaming = nil } cancel: { goals.renaming = nil }
        }
        .popover(isPresented: Binding(get: { namingSubgoal == goal.id }, set: { if !$0 { namingSubgoal = nil } }), arrowEdge: .bottom) {
            NamePopover(title: "New subgoal", prompt: "What should be true", initial: "", action: "Add") { goals.newSubgoal($0, in: goal.id); namingSubgoal = nil } cancel: { namingSubgoal = nil }
        }
        .help(subs.isEmpty ? goal.text : goal.text + (shown ? ". Click to fold its subgoals" : ". Click to show its subgoals"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(goal.text), \(moved) moved this week")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(goal) }
        .position(centre)
    }

    /// A goal's circle sends its subgoals out onto its orbit, or folds them back; with none yet, it asks for the first
    /// subgoal. With Today open they start out, and fold the same way.
    private func open(_ goal: Goal) {
        guard drag == nil else { return }
        if goals.subgoals(of: goal.id).isEmpty { namingSubgoal = goal.id } else { goals.toggle(goal: goal.id, reduceMotion: reduceMotion) }
    }

    /// A subgoal's name folds its minigoals out or away, also with Today open, where they start out.
    private func open(subgoal sub: Goal) {
        guard drag == nil else { return }
        goals.toggle(subgoal: sub.id, reduceMotion: reduceMotion)
    }

    /// The new subgoal's dot on the orbit, on its hairline, in a round field that reads outward as its name will.
    @ViewBuilder private func placingField(_ hit: OrbitLayer.Hit, centre: CGPoint) -> some View {
        let point = CGPoint(x: centre.x + hit.offset.width, y: centre.y + hit.offset.height), right = point.x >= centre.x - 8
        let dot = SubgoalMark().frame(width: 28, height: 28)
        let field = TextField("What should be true", text: $placingText)
            .textFieldStyle(.plain).font(.system(size: 12))
            .multilineTextAlignment(right ? .leading : .trailing)
            .frame(width: 190)
            .focused($placingFocus)
            .onSubmit { finishPlacing() }
            .onAppear { placingFocus = true }
        Wire(from: Self.rim(centre, toward: point), to: point).stroke(Palette.line, lineWidth: 1).allowsHitTesting(false)
        HStack(spacing: 2) { if right { dot; field } else { field; dot } }
            .padding(right ? .trailing : .leading, 12).frame(height: 28)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
            // The dot, not the field, sits on the point.
            .frame(width: 480, alignment: right ? .leading : .trailing)
            .offset(x: right ? 240 - 14 : -(240 - 14))
            .position(point)
            .transition(.opacity)
    }

    /// Adds the subgoal being written, if it has words, where it was clicked. Its siblings keep where they are drawn.
    private func finishPlacing() {
        guard let hit = placing else { return }
        let text = placingText.trimmingCharacters(in: .whitespacesAndNewlines)
        placing = nil; placingText = ""
        guard !text.isEmpty, mapSize.width > 0, let centre = places(in: mapSize).goals[hit.goal] else { return }
        let children = goals.subgoals(of: hit.goal), away = Self.away(from: centre, middle: CGPoint(x: mapSize.width / 2, y: mapSize.height / 2))
        var keeping: [String: CGSize] = [:]
        for (i, sub) in children.enumerated() where sub.x == nil || sub.y == nil { keeping[sub.id] = Self.fan(i, of: children.count, away: away) }
        withAnimation(reduceMotion ? Motion.fade : Motion.move) { goals.newSubgoal(text, in: hit.goal, at: hit.offset, keeping: keeping) }
    }

    /// Folded, only the dot shows, smaller, as a bead on its goal's rim; blue when something under it is new.
    /// Every subgoal's dot is the same thin open circle.
    private func subgoalNode(_ sub: Goal, at point: CGPoint, goalCentre: CGPoint, folded: Bool) -> some View {
        let moved = goals.moved(subgoal: sub.id), fresh = goals.hasNew(subgoal: sub.id), holds = holds(sub)
        let shown = goals.hangs(sub.id)
        // The name reads outward, away from its goal.
        let right = point.x >= goalCentre.x - 8
        let dot = ZStack {
            if folded, fresh { Circle().fill(Palette.blue).frame(width: 9, height: 9) } else { SubgoalMark() }
        }
        .scaleEffect(folded ? 0.7 : 1)
        .frame(width: 26, height: 26)
        let name = VStack(alignment: right ? .leading : .trailing, spacing: 1) {
            Text(sub.text).font(.system(size: 12, weight: shown ? .semibold : .regular)).foregroundStyle(moved > 0 || shown ? Palette.ink : Palette.muted)
                .multilineTextAlignment(right ? .leading : .trailing).lineLimit(2).frame(maxWidth: 170, alignment: right ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
            if !holds.isEmpty { Text(holds).font(.system(size: 10.5)).foregroundStyle(Palette.muted) }
        }
        let blue = Circle().fill(Palette.blue).frame(width: 7, height: 7).opacity(fresh ? 1 : 0)
        let node = HStack(spacing: 5) {
            if right { dot; if fresh { blue.opacity(folded ? 0 : 1) }; name.opacity(folded ? 0 : 1) }
            else { name.opacity(folded ? 0 : 1); if fresh { blue.opacity(folded ? 0 : 1) }; dot }
        }
            .fixedSize()
            // A task dropped on the subgoal's name stays with the subgoal, in no minigoal.
            .background { if target == sub.id { dropMark(RoundedRectangle(cornerRadius: 12)).padding(-3) } }
            .contentShape(Rectangle())
            .onTapGesture { open(subgoal: sub) }
            .gesture(moving(sub.id))
            .help(shown ? "Click to fold its minigoals" : "Click to show its minigoals")
            .contextMenu {
                Button(shown ? "Hide minigoals" : "Show minigoals") { goals.toggle(subgoal: sub.id, reduceMotion: reduceMotion) }
                if goals.today, shown { Button("New minigoal") { writing = sub.id } }
                Button("Rename") { goals.renaming = sub.id }
                Divider()
                Button("Reached") { withAnimation(Motion.move) { goals.reach(sub.id) } }
                Divider()
                Button("Delete subgoal", role: .destructive) { goals.delete(sub.id) }
            }
            .popover(isPresented: renaming(sub.id), arrowEdge: .bottom) {
                NamePopover(title: "Subgoal", prompt: "What should be true", initial: sub.text, action: "Save") { goals.rename(sub.id, to: $0); goals.renaming = nil } cancel: { goals.renaming = nil }
            }
            .dropDestination(for: String.self) { payloads, _ in drop(payloads, sub: sub.id, line: nil) } isTargeted: { over(sub.id, $0) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(sub.text), \(moved) moved this week")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(subgoal: sub) }
        // The dot, not the name, sits on the point. A bead is only a sign: the goal's circle takes the clicks.
        return node.frame(width: 440, alignment: right ? .leading : .trailing)
            .offset(x: right ? 220 - 13 : -(220 - 13))
            .position(point)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
            .animation(Motion.fade, value: target == sub.id)
    }

    // MARK: Minigoals

    /// A subgoal's minigoals as short lines on a thread from its dot: open ones, the work on no minigoal, finished ones,
    /// and the line to write a new one on at the far end of the thread. They read outward, as the subgoal's name does.
    private func hanging(_ sub: Goal, at point: CGPoint, hang: Hang) -> some View {
        let leaves = goals.leaves(of: sub.id), order = goals.boxes(of: sub.id).minigoals, frame = hang.frame(at: point)
        let side: Alignment = hang.right ? .topLeading : .topTrailing
        // The thread runs from the edge of the dot to the last minigoal.
        let dot = SubgoalMark.side / 2 + 2
        // With Today open it runs on to the + at its far end, where a new one is written.
        let far: CGFloat = goals.today ? Self.leafHeight - 9 : 0
        let top = hang.down ? -(hang.gap - dot) : Self.leafHeight * 1.5 - far
        let bottom = hang.down ? CGFloat(leaves.count) * Self.leafHeight - Self.leafHeight / 2 + far : hang.height + hang.gap - dot
        return VStack(alignment: hang.right ? .leading : .trailing, spacing: 0) {
            if !hang.down { writer(sub, hang: hang) }
            ForEach(leaves) { leaf in leafRow(leaf, sub: sub, hang: hang, order: order) }
            if hang.down { writer(sub, hang: hang) }
        }
        .frame(width: frame.width, height: frame.height, alignment: side)
        .background(alignment: side) {
            if !leaves.isEmpty || goals.today {
                Rectangle().fill(Palette.line).frame(width: 1.2, height: max(bottom - top, 0))
                    .offset(x: hang.right ? 3.4 : -3.4, y: top)
            }
        }
        .animation(Motion.move, value: leaves.map(\.id))
        .position(x: frame.midX, y: frame.midY)
    }

    /// One minigoal on its subgoal's thread: a marker for how it stands, its words, how far its work is and what was
    /// found for it. A click opens its box beside it; a task dropped here goes into it. With Today open a line is its
    /// words alone, and a click picks it for the day: picked, it sits on a filled pill.
    private func leafRow(_ leaf: GoalsModel.Leaf, sub: Goal, hang: Hang, order: [GoalsModel.Entry]) -> some View {
        let key = leaf.id, open = goals.openBox == leaf.box, loose = leaf.entry == nil, right = hang.right
        let picking = goals.today, picked = picking && leaf.entry?.isPicked == true
        // Where the words would get too little room, what was found shows as its number alone.
        let short = !picking && hang.width - hang.inset - Self.extras(leaf) < 60
        let extras = picking ? 0 : Self.extras(leaf, short: short)
        // Beside the thread, as the subgoal's blue dot is, so the words of every line line up with its name.
        let blue = Circle().fill(Palette.blue).frame(width: 6, height: 6).opacity(leaf.isNew ? 1 : 0)
        let label = HStack(spacing: 6) {
            if right && hang.fresh { blue }
            Text(leaf.entry?.line.line.text ?? "No minigoal").font(.system(size: 12, weight: open ? .semibold : .regular))
                .foregroundStyle(loose || leaf.isDone ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.roomSpace)) } action: { origins.frames[key] = $0 }
                .frame(maxWidth: loose ? nil : min(170, max(50, hang.width - hang.inset - extras)), alignment: right ? .leading : .trailing)
                .fixedSize(horizontal: loose, vertical: false)
            if !picking, let progress = Self.progress(leaf) {
                Text(progress).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted)
            }
            if !picking, leaf.found > 0 {
                HStack(spacing: 3) { Image(systemName: "sparkles").font(.system(size: 9)); Text(Self.found(leaf, short: short)) }
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if !right && hang.fresh { blue }
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background {
            if target == key { dropMark(RoundedRectangle(cornerRadius: 8)) }
            else if picked { RoundedRectangle(cornerRadius: 8).fill(Palette.selected) }
            else if open || hovered == key { RoundedRectangle(cornerRadius: 8).fill(Palette.selected.opacity(0.6)) }
        }
        // The pointer is on it, here or on its row in today's list.
        .overlay { if picked, hovered == key { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.firmLine, lineWidth: 1) } }
        return HStack(spacing: 7) {
            if right { marker(leaf); label } else { label; marker(leaf) }
        }
        .frame(height: Self.leafHeight)
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = key } else if hovered == key { hovered = nil } }
        .onTapGesture { act(on: leaf) }
        .help(((leaf.entry?.line.line.text).map { $0 + ". " } ?? "")
              + (picking ? (picked ? "Click to take it off today" : leaf.isDone ? "Reached" : "Click to pick it for today") : open ? "Click to close its box" : "Click to open its box"))
        .contextMenu {
            if let item = leaf.entry?.line {
                MinigoalActions(goals: goals, workspaces: workspaces, item: item, order: order) { editing = key }
            }
        }
        .background {
            Color.clear.popover(isPresented: Binding(get: { editing == key }, set: { if !$0, editing == key { editing = nil } }), arrowEdge: .bottom) {
                if let item = leaf.entry?.line { MinigoalEditor(goals: goals, workspaces: workspaces, item: item) { editing = nil } }
            }
        }
        .dropDestination(for: String.self) { payloads, _ in drop(payloads, sub: sub.id, line: leaf.box.lineID) } isTargeted: { over(key, $0) }
        .animation(Motion.fade, value: target == key)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { act(on: leaf) }
    }

    /// A click on a line: its box opens or closes, or, with Today open, the minigoal is picked or let go. One already
    /// reached is not picked anew.
    private func act(on leaf: GoalsModel.Leaf) {
        if goals.today {
            if let entry = leaf.entry, !entry.isDone || entry.isPicked { pick(entry.line) }
        } else { goals.toggle(box: leaf.box, reduceMotion: reduceMotion) }
    }

    /// How a minigoal stands, on the thread: an empty ring with no work yet, a dot with work, a tick once all of it is
    /// done, and a dashed ring for the work on no minigoal.
    private func marker(_ leaf: GoalsModel.Leaf) -> some View {
        ZStack {
            // Paper round the marker breaks the thread, so each line hangs from a point of its own.
            Circle().fill(Palette.paper).frame(width: 14, height: 14)
            if leaf.entry == nil {
                Circle().strokeBorder(Palette.firmLine, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.6])).frame(width: 9, height: 9)
            } else if leaf.isDone {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.green)
            } else if leaf.work.isEmpty {
                Circle().strokeBorder(Palette.firmLine, lineWidth: 1.2).frame(width: 8, height: 8)
            } else {
                Circle().fill(Palette.ink).frame(width: 8, height: 8)
            }
        }
        .frame(width: 8, height: 8)
    }

    /// The line to write a new minigoal on, last on the thread: Return adds it, ⌘Return also starts a task named like it.
    /// With Today open every thread is out, so the line waits as a small + until it is clicked; what is written there
    /// hangs on the map and is picked with a click, like any other.
    private func writer(_ sub: Goal, hang: Hang) -> some View {
        let right = hang.right
        let draft = Binding(get: { drafts[sub.id] ?? "" }, set: { drafts[sub.id] = $0 })
        let filled = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let folded = goals.today && writing != sub.id && !filled
        let field = TextField("Write a minigoal…", text: draft)
            .textFieldStyle(.plain).font(.system(size: 12))
            .multilineTextAlignment(right ? .leading : .trailing)
            .focused($writing, equals: sub.id)
            .onSubmit { add(to: sub.id, start: false) }
        let play = Button { add(to: sub.id, start: true) } label: {
            Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.blue).frame(width: 16, height: 20).contentShape(Rectangle())
        }
            .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
            .help("Add it and start a task named like it, where it is suggested (⌘Return)")
        return HStack(spacing: 4) {
            if right { field; if filled, !goals.today { play } } else { if filled, !goals.today { play }; field }
        }
        // The field stays in place under the +, so the click can hand it the keys.
        .opacity(folded ? 0 : 1).allowsHitTesting(!folded)
        .padding(right ? .leading : .trailing, 22 + (hang.fresh ? 12 : 0))
        .frame(width: min(Self.writerWidth, hang.width), height: Self.leafHeight)
        .overlay(alignment: right ? .leading : .trailing) {
            if folded {
                // On the thread, where the next minigoal will hang.
                Button { writing = sub.id } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).offset(x: right ? -7 : 7)
                .help("New minigoal").accessibilityLabel("New minigoal under \(sub.text)")
            }
        }
    }

    private func add(to subgoalID: String, start: Bool) {
        let text = (drafts[subgoalID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.move) { goals.addLine(text, to: subgoalID, startNow: start && !goals.today) }
        drafts[subgoalID] = ""; writing = subgoalID
    }

    /// The open minigoal's box, beside its line: toward the goal or past the line's words, from level with the line to
    /// ending at it, or just above or below the lines, wherever it covers least and stays nearest its line. It never
    /// covers its own lines or its subgoal's name, and it stays inside the map.
    @ViewBuilder private func openBox(_ spots: Spots, in size: CGSize) -> some View {
        if let box = goals.openBox, let sub = goals.goal(box.subgoalID), let point = spots.subgoals[box.subgoalID], let hang = spots.hangs[box.subgoalID],
           let index = goals.leaves(of: box.subgoalID).firstIndex(where: { $0.box == box }) {
            let column = hang.frame(at: point), card = CGSize(width: Self.boxWidth, height: max(boxHeight, 60))
            // Lines hanging above the dot start with the line to write on.
            let line = column.minY + CGFloat(index + (hang.down ? 0 : 1)) * Self.leafHeight + Self.leafHeight / 2
            let inward = hang.right ? point.x - 22 - card.width : point.x + 22
            let outward = hang.right ? column.maxX + 12 : column.minX - 12 - card.width
            let levels = Array(stride(from: line - 18, through: line + 18 - card.height, by: -24)) + [line + 18 - card.height]
            let x = hang.right ? column.minX : column.maxX - card.width
            let options = levels.flatMap { y in [CGPoint(x: inward, y: y), CGPoint(x: outward, y: y)] }
                + [CGPoint(x: x, y: column.maxY + 10), CGPoint(x: x, y: column.minY - 10 - card.height)]
            let spot = Self.spot(for: card, options: options, line: line, in: size, spots: spots, own: box.subgoalID)
            MinigoalBox(goals: goals, workspaces: workspaces, sub: sub, box: box, limit: max(size.height - 40, 120))
                .frame(width: card.width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boxHeight = $0 }
                .offset(x: spot.x, y: spot.y)
                .id(box)
                .transition(.opacity)
        }
    }

    /// The place among those a card could go, held inside the map with room for its shadow, whose head lies nearest its
    /// line and that covers least. Its own lines and name are as good as walls. Other subgoals' names and lines count in
    /// full; a goal's circle hardly does, since a box far from its line reads as someone else's.
    private static func spot(for card: CGSize, options: [CGPoint], line: CGFloat, in size: CGSize, spots: Spots, own: String) -> CGPoint {
        func inside(_ origin: CGPoint) -> CGPoint {
            CGPoint(x: min(max(origin.x, 16), max(size.width - card.width - 16, 16)), y: min(max(origin.y, 12), max(size.height - card.height - 24, 12)))
        }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        let circles = spots.goals.values.map { CGRect(x: $0.x - radius - 10, y: $0.y - radius - 10, width: (radius + 10) * 2, height: (radius + 10) * 2) }
        let column = spots.subgoals[own].flatMap { point in spots.hangs[own].map { $0.frame(at: point).insetBy(dx: -4, dy: 0) } } ?? .null
        let name = spots.names[own]?.insetBy(dx: -4, dy: -4) ?? .null
        let others = spots.rooms.filter { $0.key != own }.map(\.value)
        func cost(_ origin: CGPoint) -> CGFloat {
            let rect = CGRect(origin: origin, size: card)
            return (area(rect.intersection(column)) + area(rect.intersection(name))) * 50
                + others.reduce(0) { $0 + area(rect.intersection($1)) } + circles.reduce(0) { $0 + area(rect.intersection($1)) / 4 }
                + abs(rect.minY + 18 - line) * 60
        }
        return options.map(inside).min { cost($0) < cost($1) } ?? .zero
    }

    // MARK: Moving

    /// What a drop carries, if it is a task dragged out of a box.
    static func dropped(_ payloads: [String]) -> String? {
        payloads.lazy.compactMap { $0.hasPrefix(dragMark) ? String($0.dropFirst(dragMark.count)) : nil }.first
    }

    private func drop(_ payloads: [String], sub: String, line: String?) -> Bool {
        target = nil
        guard let id = Self.dropped(payloads) else { return false }
        withAnimation(Motion.move) { goals.file(task: id, under: line, subgoal: sub) }
        return true
    }

    private func over(_ key: String, _ inside: Bool) {
        if inside { target = key } else if target == key { target = nil }
    }

    /// Dragging a goal or subgoal follows the pointer; let go, and it stays where it was left. A goal's subgoals travel
    /// with it, since they keep their offset from it.
    private func moving(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.mapSpace))
            .onChanged { value in drag = Drag(id: id, by: value.translation) }
            .onEnded { value in
                drag = Drag(id: id, by: value.translation)
                settle(id)
            }
    }

    /// Saves where the drag left a node: a goal as a share of the map, a subgoal as its offset from its goal.
    private func settle(_ id: String) {
        defer { var still = Transaction(); still.disablesAnimations = true; withTransaction(still) { drag = nil } }
        guard mapSize.width > 0, mapSize.height > 0 else { return }
        let spots = places(in: mapSize)
        if let centre = spots.goals[id] {
            goals.place(id, x: Double(centre.x / mapSize.width), y: Double(centre.y / mapSize.height))
        } else if let point = spots.subgoals[id], let parent = goals.goal(id)?.parentId, let centre = spots.goals[parent] {
            goals.place(id, x: Double(point.x - centre.x), y: Double(point.y - centre.y))
        }
    }

    private func renaming(_ id: String) -> Binding<Bool> {
        Binding(get: { goals.renaming == id }, set: { if !$0, goals.renaming == id { goals.renaming = nil } })
    }
}

/// The empty map under everything. Near a goal it shows the orbit its subgoals sit on, dotted, with a dot where the
/// pointer meets it on a hairline from the goal; a click hands that place on. It is a view of its own so the pointer
/// moving redraws only this, not the map.
fileprivate struct OrbitLayer: View {
    struct Hit: Equatable { var goal: String; var offset: CGSize }
    let centres: [String: CGPoint]
    let rooms: [CGRect]
    /// Off while something else is open or moving: then a click only ends that.
    let live: Bool
    let tap: (Hit?) -> Void
    @State private var pointer: CGPoint?

    var body: some View {
        let hit = live ? pointer.flatMap { GoalsView.orbitHit(at: $0, centres: centres, rooms: rooms) } : nil
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .named(GoalsView.mapSpace)) { phase in
                    switch phase {
                    case .active(let point): pointer = point
                    case .ended: pointer = nil
                    }
                }
                .onTapGesture(coordinateSpace: .named(GoalsView.mapSpace)) { point in
                    tap(live ? GoalsView.orbitHit(at: point, centres: centres, rooms: rooms) : nil)
                }
            if let hit, let centre = centres[hit.goal] {
                let point = CGPoint(x: centre.x + hit.offset.width, y: centre.y + hit.offset.height)
                // One goal's orbit fades in and out as a whole; the dot on it follows the pointer without travelling.
                ZStack(alignment: .topLeading) {
                    Circle().stroke(Palette.firmLine, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 6]))
                        .frame(width: GoalsView.orbit * 2, height: GoalsView.orbit * 2).position(centre)
                    Wire(from: GoalsView.rim(centre, toward: point), to: point).stroke(Palette.line, lineWidth: 1)
                    SubgoalMark().position(point)
                }
                .allowsHitTesting(false)
                .id(hit.goal)
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: hit?.goal)
        .accessibilityHidden(true)
    }
}

/// A hairline between two points that follows them as they move, where a drawn line would jump.
private struct Wire: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set { from.animatableData = newValue.first; to.animatableData = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

/// Where a dragged task would land, lit as a selected row is.
private func dropMark(_ shape: some InsettableShape) -> some View {
    shape.fill(Palette.selected.opacity(0.7)).overlay(shape.strokeBorder(Palette.blue.opacity(0.45), lineWidth: 1))
}

// MARK: - A minigoal's box

/// The box beside a minigoal's line on the map: its words and how far its work is, then that work, tasks with their
/// glyphs, and board work that seems to belong, drawn faint until it is kept or sent away. The line for work on no
/// minigoal opens the same way. A task is dragged from here onto another line, or onto the subgoal's name to take it out
/// of its minigoal; a found one is kept where it is dropped. A minigoal never starts itself: play puts it in the bar,
/// which asks for the detail, and the task lands in its box. A click on a task opens the same choices as its row on the
/// board; a click on the minigoal opens its words and where its tasks start.
private struct MinigoalBox: View {
    @Bindable var goals: GoalsModel
    let workspaces: WorkspaceController
    let sub: Goal
    let box: GoalsModel.OpenBox
    /// The tallest the box may grow, the map's height less a margin; past that it scrolls.
    let limit: CGFloat
    @State private var hovered: String?
    /// The row whose popover is open: a task's choices, or the minigoal's words and place.
    @State private var editing: String?
    @State private var renamingTask: String?
    @State private var deleting: FaciendaTask?
    /// A dragged task is over the box.
    @State private var targeted = false
    @State private var height: CGFloat = 0

    var body: some View {
        let boxes = goals.boxes(of: sub.id), shape = RoundedRectangle(cornerRadius: 14)
        ScrollView {
            content(boxes).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), limit))
        .background(Palette.card, in: shape)
        .overlay { shape.strokeBorder(Palette.line, lineWidth: 1) }
        .overlay { if targeted { dropMark(shape).allowsHitTesting(false) } }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
        .dropDestination(for: String.self) { payloads, _ in drop(payloads) } isTargeted: { targeted = $0 }
        .animation(Motion.move, value: rows(boxes))
        .animation(Motion.fade, value: targeted)
        .alert("Delete this task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { task in
            Button("Delete", role: .destructive) { board(for: task)?.deleteTask(task); deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { task in
            let name = task.displayName
            Text("“" + (name.count > 60 ? String(name.prefix(60)) + "…" : name) + "” disappears from Facienda for good. The Codex chat is left alone.")
        }
    }

    @ViewBuilder private func content(_ boxes: GoalsModel.Boxes) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = box.lineID {
                if let entry = boxes.minigoals.first(where: { $0.id == id }) {
                    let found = goals.guesses(line: id)
                    head(entry, order: boxes.minigoals)
                    ForEach(entry.work) { item in if let task = item.task { row(item, task: task) } }
                    ForEach(found) { guessRow($0) }
                    if entry.work.isEmpty, found.isEmpty {
                        Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.leading, 8).padding(.bottom, 6)
                    }
                }
            } else {
                Text("No minigoal").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.muted)
                    .padding(.leading, 6).frame(minHeight: 28)
                ForEach(boxes.loose) { item in if let task = item.task { row(item, task: task) } }
                ForEach(goals.guesses(subgoal: sub.id)) { guessRow($0) }
            }
        }
        .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What moves in the box: its rows.
    private func rows(_ boxes: GoalsModel.Boxes) -> [String] {
        guard let id = box.lineID else { return boxes.loose.map(\.id) + goals.guesses(subgoal: sub.id).map(\.id) }
        return (boxes.minigoals.first { $0.id == id }?.work.map(\.id) ?? []) + goals.guesses(line: id).map(\.id)
    }

    /// The board a task lives on, which its choices act through.
    private func board(for task: FaciendaTask) -> AppModel? {
        task.workspaceId.flatMap { goals.boards[$0] ?? workspaces.model(for: $0) }
    }

    private func drop(_ payloads: [String]) -> Bool {
        targeted = false
        guard let id = GoalsView.dropped(payloads) else { return false }
        withAnimation(Motion.move) { goals.file(task: id, under: box.lineID, subgoal: sub.id) }
        return true
    }

    // MARK: The minigoal

    /// The minigoal's words at the top of its box, with how far its work is. Its glyph says how it stands: the empty
    /// circle while nothing is under it, play under the pointer, a tick once all its work is done.
    private func head(_ entry: GoalsModel.Entry, order minigoals: [GoalsModel.Entry]) -> some View {
        let item = entry.line, key = item.line.id, count = entry.work.count, settled = entry.isDone
        return HStack(spacing: 7) {
            Text(item.line.text).font(.system(size: 12.5, weight: settled ? .medium : .semibold))
                .foregroundStyle(settled ? Palette.muted : Palette.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if count > 0 {
                Text(settled ? "\(count) task\(count == 1 ? "" : "s")" : "\(entry.finished) of \(count)")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted).fixedSize()
            }
            Spacer(minLength: 6)
            glyph(item, empty: count == 0, settled: settled).frame(width: 26, height: 20)
        }
        .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 4).frame(minHeight: 28)
        // The minigoal the bar is taking detail for stays lit, so the chip up there and the box belong together.
        .background { if hovered == key || goals.aim?.lineID == key { RoundedRectangle(cornerRadius: 10).fill(Palette.selected.opacity(0.6)) } }
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = key } else if hovered == key { hovered = nil } }
        .onTapGesture { editing = key }
        .help("Click to change it, or where its tasks start")
        .contextMenu { MinigoalActions(goals: goals, workspaces: workspaces, item: item, order: minigoals) { editing = key } }
        .background {
            Color.clear.popover(isPresented: Binding(get: { editing == key }, set: { if !$0, editing == key { editing = nil } }), arrowEdge: .bottom) {
                MinigoalEditor(goals: goals, workspaces: workspaces, item: item) { editing = nil }
            }
        }
    }

    /// Play puts the minigoal in the bar, where Return starts a task toward it once the detail is added. With no place
    /// and no suggestion, play asks where first.
    @ViewBuilder private func glyph(_ item: GoalItem, empty: Bool, settled: Bool) -> some View {
        if goals.launching.contains(item.line.id) { ProgressView().controlSize(.mini) }
        else if settled { TaskDot(kind: .done) }
        else if let place = goals.place(of: item) {
            Button { goals.detail(item) } label: { playOrPlanned(item, empty: empty) }.buttonStyle(.plain)
                .help("Start a task toward it in " + place.place.label)
        } else {
            Menu { PlaceChoices(goals: goals, workspaces: workspaces, item: item) { goals.detail(item, at: $0) } } label: { playOrPlanned(item, empty: empty) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Start a task toward it: choose where")
        }
    }

    private func playOrPlanned(_ item: GoalItem, empty: Bool) -> some View {
        Group {
            if hovered == item.line.id || goals.aim?.lineID == item.line.id { Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.blue) }
            else if empty { TaskDot(kind: .notStarted) }
        }
        .frame(width: 22, height: 20).contentShape(Rectangle())
    }

    // MARK: Tasks

    /// A task in the box, as on the board: where it lives, its words, its glyph. It can be dragged onto another line.
    private func row(_ item: GoalItem, task: FaciendaTask) -> some View {
        let key = item.line.id
        return HStack(alignment: .top, spacing: 10) {
            PlaceFace(goals: goals, workspaces: workspaces, item: item, sub: sub)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayName).font(.system(size: 13)).foregroundStyle(task.state.isOpen ? Palette.ink : Palette.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text([workspaces.workspaces.first { $0.id == task.workspaceId }?.name, item.groupName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Group { if let kind = TaskDot.Kind(state: task.state) { TaskDot(kind: kind) } }.frame(width: 26, height: 20)
        }
        .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 6)
        .background { if hovered == key { RoundedRectangle(cornerRadius: 12).fill(Palette.selected.opacity(0.6)) } }
        .overlay(alignment: .leading) { if item.isNew { Circle().fill(Palette.blue).frame(width: 6, height: 6).offset(x: -3) } }
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = key } else if hovered == key { hovered = nil } }
        .onTapGesture { editing = key }
        .help("Click to choose what's next. Drag it onto another minigoal")
        .contextMenu { taskActions(item, task: task) }
        .draggable(GoalsView.dragMark + task.id) { dragFace(task.displayName) }
        // Its own anchor, so it never competes with the rename popover on the row.
        .background {
            Color.clear.popover(isPresented: Binding(get: { editing == key }, set: { if !$0, editing == key { editing = nil } }), arrowEdge: .bottom) {
                if let model = board(for: task) {
                    TaskChoicesPopover(model: model, task: task, done: { withAnimation(Motion.move) { model.complete(task) } },
                                       parked: { _, label in withAnimation(Motion.move) { model.offerUndo("Parked · " + label) } }) { editing = nil }
                }
            }
        }
        .popover(isPresented: Binding(get: { renamingTask == key }, set: { if !$0, renamingTask == key { renamingTask = nil } }), arrowEdge: .bottom) {
            NamePopover(title: "Rename task", prompt: "Task name", initial: task.displayName, action: "Rename") {
                board(for: task)?.renameTask(task, name: $0); renamingTask = nil
            } cancel: { renamingTask = nil }
        }
        .transition(.opacity)
    }

    /// The board's own menu for a task, then what only Goals has: its minigoal, the board, and letting it go.
    @ViewBuilder private func taskActions(_ item: GoalItem, task: FaciendaTask) -> some View {
        let model = board(for: task), minigoals = goals.boxes(of: sub.id).open
        if let model, let recovery = model.recoveryDispatch(for: task.id) { DeliveryRecoveryMenu(model: model, item: recovery); Divider() }
        Button("Rename automatically", systemImage: "sparkles") { model?.generateName(for: task) }
            .disabled(model == nil || model?.namingTasks.contains(task.id) == true)
        Button("Rename…", systemImage: "pencil") { renamingTask = item.line.id }.disabled(model == nil)
        Divider()
        Menu("Minigoal", systemImage: "square.stack") {
            ForEach(minigoals) { entry in
                Button { file(task, under: entry.id) } label: { choice(entry.line.line.text, on: item.line.parentLineId == entry.id) }
            }
            if !minigoals.isEmpty { Divider() }
            Button { file(task, under: nil) } label: { choice("No minigoal", on: item.line.parentLineId == nil) }
        }
        if let model { Menu("Goal", systemImage: "scope") { ServesChoices(model: model, taskID: task.id) } }
        if let model, HandoverChoices.offered(task, in: model) {
            Menu("Continue in a new chat", systemImage: "arrow.triangle.swap") { HandoverChoices(model: model, task: task) }
        }
        Divider()
        Button("Show on the board", systemImage: "square.grid.2x2") { goals.show(task) }
        Button("Open chat", systemImage: "bubble.left") { goals.openChat(task) }
        Divider()
        Button("Stop serving this", systemImage: "scope") { goals.unserve(item) }
        Button("Delete task…", systemImage: "trash", role: .destructive) { deleting = task }.disabled(model == nil)
    }

    private func file(_ task: FaciendaTask, under line: String?) {
        withAnimation(Motion.move) { goals.file(task: task.id, under: line, subgoal: sub.id) }
    }

    @ViewBuilder private func choice(_ name: String, on: Bool) -> some View {
        if on { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    /// What follows the pointer while a task is dragged: its words on a card.
    private func dragFace(_ name: String) -> some View {
        Text(name).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }

    /// Board work Facienda found for the minigoal, or for the subgoal: drawn faint, as a suggested place is, until the
    /// user keeps it, sends it away, or drags it onto the line it belongs to. Its picture leads to the board, as every
    /// row's does.
    private func guessRow(_ guess: GoalGuess) -> some View {
        let task = guess.task
        return HStack(alignment: .top, spacing: 10) {
            PlaceFace(goals: goals, workspaces: workspaces, item: guess.item, sub: sub, group: guess.groupId).opacity(0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayName).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9))
                    Text(task.state.isOpen ? "Found on the board" : "Found on the board · done")
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button("Keep") { withAnimation(Motion.move) { goals.keep(guess) } }.buttonStyle(QuietButton(compact: true))
                .help(guess.lineId == nil ? "It serves this subgoal" : "It works toward this minigoal")
            Button { goals.dismiss(guess) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted).frame(width: 22, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Not for this").accessibilityLabel("Not for this")
        }
        .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 6)
        .contentShape(Rectangle())
        .draggable(GoalsView.dragMark + task.id) { dragFace(task.displayName) }
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }
}

/// What can be done with a minigoal, from its line or its box: start work toward it, change it, move it, remove it.
private struct MinigoalActions: View {
    let goals: GoalsModel
    let workspaces: WorkspaceController
    let item: GoalItem
    /// The subgoal's minigoals in order, to move this one past its neighbours.
    let order: [GoalsModel.Entry]
    let edit: () -> Void

    var body: some View {
        let index = order.firstIndex { $0.id == item.id }
        Button("Add detail…", systemImage: "text.badge.plus") { goals.detail(item) }.disabled(goals.place(of: item) == nil)
        Button("Start now", systemImage: "play") { goals.start(item) }.disabled(goals.place(of: item) == nil)
        Button("Edit…", systemImage: "pencil", action: edit)
        Divider()
        Button(item.line.pickedAt == nil ? "Pick for today" : "Take off today", systemImage: "sun.max") { withAnimation(Motion.move) { goals.pick(item) } }
        // Done by hand, for what no task does. One that is done by its work has nothing to tick.
        if item.line.tickedAt != nil { Button("Not done after all", systemImage: "circle") { withAnimation(Motion.move) { goals.tick(item) } } }
        else { Button("Done", systemImage: "checkmark") { withAnimation(Motion.move) { goals.tick(item) } }.disabled(order.first { $0.id == item.id }?.isDone == true) }
        Divider()
        Menu("Tasks start in", systemImage: "square.grid.2x2") { PlaceChoices(goals: goals, workspaces: workspaces, item: item) { goals.setPlace(item, to: $0) } }
        Button("Move up", systemImage: "arrow.up") { goals.moveLine(item, by: -1) }.disabled(index == nil || index == 0)
        Button("Move down", systemImage: "arrow.down") { goals.moveLine(item, by: 1) }.disabled(index.map { $0 + 1 >= order.count } ?? true)
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive) { goals.unserve(item) }
    }
}

/// A minigoal opened: its words, where its tasks start, and Start, which starts one named like it.
private struct MinigoalEditor: View {
    let goals: GoalsModel
    let workspaces: WorkspaceController
    let item: GoalItem
    let dismiss: () -> Void

    var body: some View {
        let place = goals.place(of: item)
        PlannedPopover(text: item.line.text, canStart: place != nil,
                       startHelp: place.map { "Start a task toward it in " + $0.place.label } ?? "Choose where its tasks start first", minigoal: true) {
            Menu { PlaceChoices(goals: goals, workspaces: workspaces, item: item) { goals.setPlace(item, to: $0) } } label: {
                PlannedPlaceLabel(name: place.map { ($0.chosen ? "" : "Suggested: ") + $0.place.label } ?? "Choose…", suggested: place?.chosen == false)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        } save: { goals.editLine(item.line.id, text: $0) } start: { goals.start(item, text: $0) } remove: { goals.unserve(item) } dismiss: { dismiss() }
    }
}

/// Where a planned line can start: Facienda's suggestions first, then every workspace with its groups, or none.
struct PlaceChoices: View {
    let goals: GoalsModel
    let workspaces: WorkspaceController
    let item: GoalItem
    let choose: (BarPlace) -> Void

    var body: some View {
        let suggested = goals.suggestedPlaces(item), current = item.line.workspaceId == nil ? nil : goals.place(of: item)?.place
        if !suggested.isEmpty {
            Section("Suggested") {
                ForEach(suggested, id: \.self) { place in Button { choose(place) } label: { choice(place.label, on: place == current) } }
            }
        }
        Section("Anywhere") {
            ForEach(workspaces.ordered) { workspace in
                Menu(workspace.name) {
                    let none = BarPlace(workspaceID: workspace.id, workspaceName: workspace.name)
                    Button { choose(none) } label: { choice("No group", on: current?.workspaceID == workspace.id && current?.groupID == nil) }
                    let groups = goals.groups.filter { $0.workspaceId == workspace.id }
                    if !groups.isEmpty { Divider() }
                    ForEach(groups) { group in
                        let place = BarPlace(workspaceID: workspace.id, workspaceName: workspace.name, groupID: group.id, groupName: group.name)
                        Button { choose(place) } label: { choice(group.name, on: current?.groupID == group.id) }
                    }
                }
            }
        }
        if item.line.workspaceId != nil {
            Divider()
            Button("Suggest a place again") { goals.setPlace(item, to: nil) }
        }
    }

    @ViewBuilder private func choice(_ name: String, on: Bool) -> some View {
        if on { Label(name, systemImage: "checkmark") } else { Text(name) }
    }
}

// MARK: - Pieces

/// Naming a goal, subgoal or line.
private struct NamePopover: View {
    let title: String
    let prompt: String
    let initial: String
    let action: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            TextField(prompt, text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3).onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(action, action: commit).keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 12))
        }
        .padding(14).frame(width: 300)
        .onAppear { draft = initial }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        save(text)
    }
}

/// A subgoal's dot on the map: a thin open circle, the same for every subgoal.
struct SubgoalMark: View {
    static let side: CGFloat = 9

    var body: some View {
        Circle().strokeBorder(Palette.ink, lineWidth: 1.2).frame(width: Self.side, height: Self.side)
    }
}

/// A workspace's planet, small: its painted picture, or its initial.
struct GoalPlanet: View {
    let id: String
    let workspaces: WorkspaceController
    var size: CGFloat = 14

    var body: some View {
        let workspace = workspaces.workspaces.first { $0.id == id }
        ZStack {
            Palette.line
            if let image = workspaces.coverImages[id] { Image(nsImage: image).resizable().scaledToFill() }
            else { Text((workspace?.name ?? "").prefix(1).uppercased()).font(.system(size: size * 0.6, design: .serif)).foregroundStyle(Palette.muted) }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(Palette.ink.opacity(0.1), lineWidth: 0.5))
        .help(workspace?.name ?? "")
    }
}

// MARK: - Reached

/// Everything reached, under the goal it served. The goal whose subgoal was reached last comes first; a goal reached in
/// full says so beside its name. Each subgoal shows how long it took, how many tasks served it and where they lived.
/// Nothing here is ever thrown away.
private struct ReachedList: View {
    @Bindable var goals: GoalsModel
    let workspaces: WorkspaceController

    /// One goal and what of it was reached: itself, when reached in full, and its subgoals, newest first.
    private struct Section: Identifiable {
        var goal: Goal
        var whole: GoalsModel.LedgerEntry?
        var subgoals: [GoalsModel.LedgerEntry]
        var id: String { goal.id }
        var latest: Date { ([whole?.reachedAt] + subgoals.map(\.reachedAt)).compactMap { $0 }.max() ?? .distantPast }
    }

    private var sections: [Section] {
        var byGoal: [String: Section] = [:]
        for entry in goals.ledger {
            let goal = entry.parent ?? entry.goal
            var section = byGoal[goal.id] ?? Section(goal: goal, whole: nil, subgoals: [])
            if entry.parent == nil { section.whole = entry } else { section.subgoals.append(entry) }
            byGoal[goal.id] = section
        }
        return byGoal.values.sorted { $0.latest > $1.latest }
    }

    var body: some View {
        let sections = sections
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Reached").font(.system(size: 17, weight: .medium, design: .serif))
                if !sections.isEmpty { Text("\(goals.ledger.count)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted) }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if sections.isEmpty {
                Text("Subgoals you mark reached are kept here, under their goal.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section($0) }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                    .animation(Motion.move, value: goals.ledger.map(\.id))
                }
                .frame(maxHeight: 480)
            }
        }
        .frame(width: 380)
    }

    private func section(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                GoalCoverThumb(goals: goals, goal: section.goal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.goal.text).font(.system(size: 14.5, weight: .medium, design: .serif)).lineLimit(2)
                    if let whole = section.whole {
                        Text("Goal reached · " + Self.day(whole.reachedAt) + " · \(whole.weeks) week\(whole.weeks == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
            .contextMenu { if let whole = section.whole { Button("Not reached yet") { withAnimation(Motion.move) { goals.reopen(whole.goal.id) } } } }
            ForEach(section.subgoals) { row($0) }
        }
        .padding(.vertical, 4)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
        .transition(.opacity)
    }

    private func row(_ entry: GoalsModel.LedgerEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.green).frame(width: 26, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.goal.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("\(entry.weeks) week\(entry.weeks == 1 ? "" : "s") · \(entry.tasks) task\(entry.tasks == 1 ? "" : "s")")
                    ForEach(entry.workspaceIDs, id: \.self) { GoalPlanet(id: $0, workspaces: workspaces, size: 12) }
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Text(Self.day(entry.reachedAt)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { Button("Not reached yet") { withAnimation(Motion.move) { goals.reopen(entry.goal.id) } } }
        .transition(.opacity)
    }

    private static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// A goal's picture, small, beside what of it was reached.
private struct GoalCoverThumb: View {
    let goals: GoalsModel
    let goal: Goal

    var body: some View {
        ZStack {
            Palette.line
            if let image = goals.cover(goal) { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(goal.text.prefix(1).uppercased()).font(.system(size: 14, design: .serif)).foregroundStyle(Palette.muted) }
        }
        .frame(width: 26, height: 26).clipShape(Circle())
        .overlay(Circle().strokeBorder(Palette.ink.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Where a line lives

/// A line's place, at the start of its row: its group's picture with the workspace's planet on its corner, or the
/// planet alone for work in no group. A click turns to the board, which grows out of the picture, and lands on the row.
/// A planned line shows where it will start; a place Facienda only suggests is drawn faint.
private struct PlaceFace: View {
    let goals: GoalsModel
    let workspaces: WorkspaceController
    let item: GoalItem
    let sub: Goal
    /// The task's group when it is known already, as for board work not yet on any goal.
    var group: String?
    /// What the row sits on, so the planet's ring blends into it.
    var ring = Palette.card
    @State private var frame: CGRect = .zero
    @State private var hovering = false
    private static let side: CGFloat = 30

    var body: some View {
        let place = goals.place(of: item)
        let workspaceID = item.task?.workspaceId ?? place?.place.workspaceID
        let groupID = group ?? item.task.flatMap { task in task.workspaceId.flatMap { goals.boards[$0]?.groupMembers[task.id] } } ?? (item.task == nil ? place?.place.groupID : nil)
        let suggested = item.task == nil && place?.chosen == false
        if let workspaceID {
            let workspace = workspaces.workspaces.first { $0.id == workspaceID }?.name ?? ""
            let spot = [workspace, item.task == nil ? place?.place.groupName : item.groupName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            Button { goals.land(item, from: frame, subgoal: sub) } label: {
                face(workspaceID: workspaceID, groupID: groupID)
                    .opacity(suggested ? 0.55 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: groupID == nil ? Self.side / 2 : 8)
                            .strokeBorder(hovering ? Palette.firmLine : .clear, lineWidth: 1.5).padding(-3)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.fade, value: hovering)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkspaceWindow.space)) } action: { frame = $0 }
            .help("On the board: " + spot)
            .accessibilityLabel("Show on the board, " + spot)
        } else {
            // Nowhere yet: an empty frame where its picture will be.
            RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.firmLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: Self.side, height: Self.side)
                .help("No place yet")
        }
    }

    @ViewBuilder private func face(workspaceID: String, groupID: String?) -> some View {
        if let groupID {
            ZStack {
                Palette.line
                if let cover = workspaces.groupCover(groupID) { Image(nsImage: cover).resizable().scaledToFill() }
                else {
                    Text((goals.groups.first { $0.id == groupID }?.name ?? "").prefix(1).uppercased())
                        .font(.system(size: 12, weight: .medium, design: .serif)).foregroundStyle(Palette.muted)
                }
            }
            .frame(width: Self.side, height: Self.side).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                GoalPlanet(id: workspaceID, workspaces: workspaces, size: 14)
                    .background(Circle().fill(ring).padding(-2))
                    .offset(x: 5, y: 5)
            }
        } else {
            GoalPlanet(id: workspaceID, workspaces: workspaces, size: Self.side)
        }
    }
}
