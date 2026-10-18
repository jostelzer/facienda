import SwiftUI
import FaciendaCore

/// The dashboard: every current task on one page, in groups the user can shape.
struct GroupBoard: View {
    @Bindable var model: AppModel
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var dropTarget: String?
    /// Comma-separated legend entries the user switched off. Done tasks start hidden.
    @AppStorage(LegendScope.board.hiddenKey) private var hiddenStates = LegendScope.board.defaultHidden
    /// Narrows the board to unread tasks, whatever their state.
    @AppStorage(LegendScope.board.onlyNewKey) private var onlyNew = false
    @AppStorage("groupCovers") private var showCovers = true
    /// The card, row and cover under the pointer. Only the small views that draw the hover read it, so moving the
    /// pointer across the board redraws those alone rather than every card.
    @State private var hover = BoardHover()
    /// The group whose cover is being adjusted, and the wish being typed.
    @State private var adjusting: String?
    @State private var wish = ""
    /// A group being dragged: where the pointer is, where it grabbed the card, and the card's size.
    @State private var drag: (id: String, location: CGPoint, grab: CGSize, size: CGSize)?
    /// The board while a drag is in flight; saved when the card is dropped.
    @State private var livePlaces: [String: BoardSlot]?
    @State private var cardFrames: [String: CGRect] = [:]
    /// A task or planned row being dragged: where the pointer is, where it grabbed the row, and the row's size.
    @State private var rowDrag: RowDrag?
    /// Every card's rows while a task is dragged, the dragged one already where it would land. The others slide aside to make room.
    @State private var liveRows: [String: [String]]?
    /// Every group's planned rows while a planned one is dragged, the same way. Unsorted has no plan, so it has none.
    @State private var livePlanned: [String: [String]]?
    /// True while a released task glides into its slot.
    @State private var rowSettling = false
    /// Each row's frame on the board, read only while a task is dragged, so recording them never redraws the board.
    @State private var rowFrames = RowFrames()
    @State private var boardWidth: CGFloat = 0
    /// Off until the board has its real width, so the first layout appears in place instead of sliding out of one column.
    @State private var boardReady = false
    /// Where the user put "Unsorted".
    @State private var looseSlot: BoardSlot?
    private var looseSlotKey: String { "dashboardLoosePlace:" + model.storageKey }
    /// The cards folded to their title, by group ID or looseKey for "Unsorted". Kept per workspace.
    @State private var folded: Set<String> = []
    /// True while a released card glides into its slot.
    @State private var settling = false
    /// The group that just landed, for a brief confirming pulse.
    @State private var landed: String?
    /// The task whose row was clicked and now offers what to do next.
    @State private var choosing: String?
    /// A card to scroll into view.
    @State private var scrollTarget: String?
    /// The task awaiting confirmation to be deleted.
    @State private var deleting: FaciendaTask?
    /// The task whose name is being edited in place, and the name being typed.
    @State private var renamingTask: String?
    @State private var taskDraft = ""
    @FocusState private var taskNameFocused: Bool
    static let actionWidth: CGFloat = 46
    /// The card's horizontal padding: how far a row reaches to touch the card's edge.
    static let cardInset: CGFloat = 20
    private static let unreadDot: CGFloat = 7
    /// How far down a row with a recap its name's first line sits, in the middle: slip 3, row 8, half a 16 pt line.
    private static let recapNameMiddle: CGFloat = 3 + 8 + 8
    /// How far an unread row's slip stays in from the card's edge.
    static let slipInset: CGFloat = 4
    @FocusState private var nameFocused: Bool
    private nonisolated static let boardSpace = "board"

    private static let minLaneWidth: CGFloat = 290
    private static let laneSpacing: CGFloat = 14
    /// Stands in for "Unsorted" in the board.
    private static let looseKey = ""
    private static let looseName = "Unsorted"
    /// Stands in for the card a carried task can be dropped on to start a group. It shows only while a task is carried,
    /// at the foot of the shortest column.
    private static let newKey = "+new"

    private var laneCount: Int { max(1, Int((boardWidth + Self.laneSpacing) / (Self.minLaneWidth + Self.laneSpacing))) }

    /// The cards on screen in display order: groups as saved, then "Unsorted", and the drop card while a task is carried.
    private func shownKeys(_ lists: [String: [FaciendaTask]]) -> [String] {
        // While filtering, groups with nothing to show step aside; truly empty ones rest in place otherwise.
        let filtering = filtering
        var keys = model.groups.filter { !filtering || lists[$0.id]?.isEmpty == false || !visiblePlannedLines(in: $0.id).isEmpty }.map(\.id)
        if !filtering || lists[Self.looseKey]?.isEmpty == false { keys.append(Self.looseKey) }
        if rowDrag != nil { keys.append(Self.newKey) }
        return keys
    }

    /// Where each card sits: its column and its place in that column's stack. Cards the user placed keep their column and order; the rest join the shortest column.
    private func places(_ lists: [String: [FaciendaTask]]) -> [String: BoardSlot] {
        if let livePlaces { return livePlaces }
        let count = laneCount, keys = shownKeys(lists)
        var lanes = Array(repeating: [(key: String, row: Int)](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        func height(_ key: String) -> CGFloat {
            cardFrames[key]?.height ?? CGFloat(60 + 50 * (lists[key]?.count ?? 0))
        }
        var placed = Set<String>()
        for key in keys {
            let slot: BoardSlot?
            if key == Self.looseKey { slot = looseSlot }
            else if let group = model.groups.first(where: { $0.id == key }), let lane = group.lane { slot = BoardSlot(lane: lane, row: group.row ?? 0) }
            else { slot = nil }
            // A narrower window folds the columns that no longer fit back onto the first ones.
            guard let slot else { continue }
            lanes[slot.lane % count].append((key, slot.row)); heights[slot.lane % count] += height(key); placed.insert(key)
        }
        for lane in lanes.indices { lanes[lane].sort { $0.row < $1.row } }
        for key in keys where !placed.contains(key) {
            let lane = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            lanes[lane].append((key, .max)); heights[lane] += height(key)
        }
        return Self.slots(lanes.map { $0.map(\.key) })
    }

    /// Numbers each column top to bottom, so a card's row is simply its place in the stack.
    private static func slots(_ lanes: [[String]]) -> [String: BoardSlot] {
        var result: [String: BoardSlot] = [:]
        for (lane, keys) in lanes.enumerated() { for (row, key) in keys.enumerated() { result[key] = BoardSlot(lane: lane, row: row) } }
        return result
    }

    private var hidden: Set<String> { Set(hiddenStates.split(separator: ",").map(String.init)) }
    /// Done rests hidden and Planned only folds plan lines away, so showing or hiding either is not a filter; hiding any other state is.
    /// Otherwise hiding Planned would also take away Unsorted and the empty groups, which hold no plan lines to hide.
    private static let tidyingStates: Set<String> = [TaskDot.Kind.done.rawValue, TaskDot.Kind.notStarted.rawValue]
    private var filtering: Bool { !hidden.subtracting(Self.tidyingStates).isEmpty || onlyNew || !model.search.isEmpty }

    private func visiblePlannedLines(in groupID: String) -> [PlanLine] {
        guard !hidden.contains(TaskDot.Kind.notStarted.rawValue), !onlyNew, model.search.isEmpty else { return [] }
        return model.plannedLines(in: groupID)
    }

    /// Each card's tasks as shown, with the legend's filters applied, keyed by group ID or looseKey for "Unsorted".
    /// Worked out once per redraw and handed to everything that needs it.
    private var visibleLists: [String: [FaciendaTask]] {
        let hidden = hidden, onlyNew = onlyNew
        var lists: [String: [FaciendaTask]] = [:]
        for (group, tasks) in model.boardLists {
            lists[group ?? Self.looseKey] = tasks.filter {
                !hidden.contains(TaskDot.Kind(model: model, task: $0).legend.rawValue) && (!onlyNew || model.isUnread($0))
            }
        }
        return lists
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // The top inset lives inside the scroll view, so a fresh card's glow in the first row isn't clipped.
                    board.padding(.horizontal, IslandFrame.inset).padding(.top, 8).padding(.bottom, IslandFrame.inset).frame(maxWidth: .infinity, alignment: .leading)
                }
                .alert("Delete this task?", isPresented: Binding(presenting: $deleting), presenting: deleting) { task in
                    Button("Delete", role: .destructive) { model.deleteTask(task); deleting = nil }
                    Button("Cancel", role: .cancel) { deleting = nil }
                } message: { task in
                    let name = task.displayName
                    Text("“" + (name.count > 60 ? String(name.prefix(60)) + "…" : name) + "” disappears from Facienda for good. The Codex chat is left alone.")
                }
                // A new group may land below the fold; bring it into view.
                .onChange(of: scrollTarget) { _, key in
                    guard let key else { return }
                    withAnimation(Motion.move) { proxy.scrollTo(key, anchor: .center) }
                    scrollTarget = nil
                }
            }
            // The File menu, the shortcut and the command bar all press the board's +.
            // The folded cards come first, so a task asked for on arrival can open its card.
            .onAppear { folded = FoldedCards.load(model.storageKey); if model.newGroupRequested { beginNewGroup() }; openRequested() }
            .onChange(of: model.boardOpenRequest) { _, _ in openRequested() }
            .onChange(of: model.newGroupRequested) { _, requested in if requested { beginNewGroup() } }
            // A group made on the board's + may land below the fold; its sheet folds into it there.
            .onChange(of: model.sheetLanding) { _, group in if let group { scrollTarget = group } }
            // A new row keeps its recap while its choices are open, and counts as read once they close.
            .onChange(of: choosing) { closed, _ in if let closed, let task = model.tasksByID[closed] { model.noteOpened(task) } }
        }
    }

    /// Every card in its column and place, and the lifted one following the pointer.
    private var board: some View {
        VStack(alignment: .leading, spacing: 16) {
            let lists = visibleLists
            let placed = places(lists)
            BoardLayout(lanes: laneCount, spacing: Self.laneSpacing) {
                ForEach(Array(shownKeys(lists).enumerated()), id: \.element) { order, key in
                    let slot = placed[key] ?? BoardSlot(lane: 0, row: 0)
                    Group {
                        if let group = model.groups.first(where: { $0.id == key }) { card(group.id, name: group.name, group: group, tasks: lists[key] ?? []) }
                        else if key == Self.looseKey { card(nil, name: Self.looseName, group: nil, tasks: lists[key] ?? []) }
                        else if key == Self.newKey { newGroupCard }
                    }.layoutValue(key: BoardSlotKey.self, value: BoardSlotValue(lane: slot.lane, row: slot.row, order: order, lifted: drag?.id == key))
                }
            }
            // Room below the lowest card, so there is always somewhere to drop.
            .padding(.bottom, 160)
            // On the board rather than the row: a task carried into another card is drawn anew there, which would end a row's own gesture mid-drag.
            .simultaneousGesture(dragRow(lists))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let first = boardWidth == 0
                boardWidth = width
                if first { DispatchQueue.main.async { boardReady = true } }
            }
            .onAppear {
                if let saved = UserDefaults.standard.array(forKey: looseSlotKey) as? [Int], saved.count == 2 { looseSlot = BoardSlot(lane: saved[0], row: saved[1]) }
            }
            .onChange(of: folded) { _, now in FoldedCards.save(now, for: model.storageKey) }
            .coordinateSpace(.named(Self.boardSpace))
            .overlay(alignment: .topLeading) {
                // The lifted card follows the pointer while its slot stays in the layout and the others make room.
                if let drag {
                    let group = model.groups.first { $0.id == drag.id }
                    cardContent(group?.id, name: group?.name ?? Self.looseName, group: group, tasks: lists[group?.id ?? Self.looseKey] ?? [])
                        .frame(width: drag.size.width)
                        .shadow(color: .black.opacity(settling ? 0.08 : 0.28), radius: settling ? 4 : 16, y: settling ? 1 : 8)
                        .scaleEffect(settling ? 1 : 1.03)
                        .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                        .allowsHitTesting(false)
                }
                // The lifted task or planned row follows the pointer; its slot stays open where it will land.
                if let rowDrag {
                    Group {
                        if !rowDrag.planned, let task = model.tasksByID[rowDrag.id] { rowFace(task, previous: nil) }
                        else if rowDrag.planned, let line = model.planLines.first(where: { $0.id == rowDrag.id }) {
                            PlannedRow(model: model, line: line, hover: hover, above: nil, lifted: false, carrying: true)
                        }
                    }
                    .frame(width: rowDrag.size.width, height: rowDrag.size.height)
                    .background { RoundedRectangle(cornerRadius: 10).fill(Palette.card).padding(.horizontal, -(Self.cardInset - Self.slipInset)) }
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1).padding(.horizontal, -(Self.cardInset - Self.slipInset)) }
                    .shadow(color: .black.opacity(rowSettling ? 0.06 : 0.22), radius: rowSettling ? 3 : 14, y: rowSettling ? 1 : 6)
                    .scaleEffect(rowSettling ? 1 : 1.025)
                    .offset(x: rowDrag.location.x - rowDrag.grab.width, y: rowDrag.location.y - rowDrag.grab.height)
                    .allowsHitTesting(false)
                }
            }
            .animation(boardReady ? Motion.move : nil, value: placed)
            .animation(Motion.move, value: model.groupMembers)
            .animation(Motion.move, value: liveRows)
            .animation(Motion.move, value: livePlanned)
            .animation(Motion.move, value: model.taskPlaces)
            .animation(Motion.move, value: hiddenStates)
        }
    }

    /// Lifts a card by its header. The key is a group's ID, or looseKey for "Unsorted".
    private func dragCard(_ key: String) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                if drag == nil {
                    guard let frame = cardFrames[key] else { return }
                    renaming = nil
                    livePlaces = places(visibleLists)
                    drag = (key, value.location, CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY), frame.size)
                }
                guard var current = drag, let now = livePlaces, let previous = now[key] else { return }
                current.location = value.location; drag = current
                // The landing spot is the column under the lifted card, just above the first card whose middle lies below it.
                let count = laneCount
                let centre = CGPoint(x: value.location.x - current.grab.width + current.size.width / 2, y: value.location.y - current.grab.height + min(current.size.height, 120) / 2)
                let laneWidth = (boardWidth - Self.laneSpacing * CGFloat(count - 1)) / CGFloat(count)
                let lane = min(max(Int(centre.x / (laneWidth + Self.laneSpacing)), 0), count - 1)
                var lanes = (0..<count).map { column in now.filter { $0.value.lane == column && $0.key != key && $0.key != Self.newKey }.sorted { $0.value.row < $1.value.row }.map(\.key) }
                let above = lanes[lane].filter { (cardFrames[$0]?.midY ?? .infinity) < centre.y }.count
                lanes[lane].insert(key, at: above)
                // The New group card stays at the foot of its column while the others move.
                if let resting = now[Self.newKey] { lanes[resting.lane].append(Self.newKey) }
                let next = Self.slots(lanes)
                guard next != now else { return }
                livePlaces = next
                // One soft tick when the card crosses into another column; reordering within a column stays quiet.
                if previous.lane != lane { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
            .onEnded { _ in
                guard let current = drag else { livePlaces = nil; return }
                guard let slot = cardFrames[current.id] else { finishDrag(current.id); return }
                // Glide from the pointer into the landing spot, then hand over to the real card.
                withAnimation(Motion.move) {
                    settling = true
                    drag?.location = CGPoint(x: slot.minX + current.grab.width, y: slot.minY + current.grab.height)
                } completion: {
                    finishDrag(current.id)
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
    }

    /// Dropping saves every card's column and place in it, so the arrangement holds.
    private func finishDrag(_ id: String) {
        if let livePlaces {
            if let slot = livePlaces[Self.looseKey] {
                looseSlot = slot
                UserDefaults.standard.set([slot.lane, slot.row], forKey: looseSlotKey)
            }
            model.placeGroups(livePlaces.compactMap { key, slot in key == Self.looseKey || key == Self.newKey ? nil : GroupPlacement(id: key, lane: slot.lane, row: slot.row) })
        }
        livePlaces = nil; drag = nil; settling = false; landed = id
    }

    /// Whether a card shows only its title.
    private func isFolded(_ key: String) -> Bool { folded.contains(key) }

    /// Folds the card to its title, or shows its tasks again. With ⌥ held it does the same to every card on the board, as in Finder.
    private func toggleFold(_ key: String) {
        let every = NSEvent.modifierFlags.contains(.option)
        setFolded(every ? Set(shownKeys(visibleLists).filter { $0 != Self.newKey }) : [key], !isFolded(key))
    }

    /// The card's rows and its cover's height change in one move, and the columns close up or open with them.
    private func setFolded(_ keys: Set<String>, _ fold: Bool) {
        withAnimation(Motion.move) { if fold { folded.formUnion(keys) } else { folded.subtract(keys) } }
    }

    /// How far a + sits in from the edge of the board or of its card, so every + on the board lines up.
    static let plusInset: CGFloat = cardInset - 6

    private func card(_ id: String?, name: String, group: TaskGroup?, tasks: [FaciendaTask]) -> some View {
        let key = id ?? Self.looseKey, lifted = drag?.id == key
        // A drop target already shows its own blue edge; the rim steps aside rather than double it.
        let fresh = tasks.contains(where: model.isUnread) && dropTarget != key
        // The fresh rim and a drop target already have their own edge; hover leaves them be.
        return cardContent(id, name: name, group: group, tasks: arranged(tasks, in: key), hoverKey: fresh || dropTarget == key || drag != nil ? nil : key)
            .overlay { FreshRim(on: fresh) }
            // The lifted card's own slot stays in the layout and shows where it will land.
            // A card opened as a sheet steps aside for it, and is back in place as the sheet folds home.
            .opacity(lifted || model.spotlitGroup == key ? 0 : 1)
            .animation(Motion.fade, value: model.spotlitGroup == key)
            .overlay { if lifted { LandingSpot() } }
            .overlay { if landed == key { LandingPulse { landed = nil } } }
            .overlay { if dropTarget == key { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.blue, lineWidth: 2) } }
            // Where the card's sheet grows out of and folds back into.
            .anchorPreference(key: GroupCardKey.self, value: .bounds) { [key: $0] }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // A click anywhere on the card folds or opens it. Rows, buttons and the grace around them keep their own clicks.
            // A resting card has nothing to open, so a click leaves it as it is.
            .onTapGesture { if renaming != key && !isResting(group, tasks: arranged(tasks, in: key)) { toggleFold(key) } }
            .onHover { inside in if inside { hover.card = key } else if hover.card == key { hover.card = nil } }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.boardSpace)) } action: { cardFrames[key] = $0 }
            .contextMenu {
                Button("New task here") { newTask(in: group) }
                if let group {
                    Button("Rename") { beginRename(group) }
                    Menu("Link source") { SourceLinkChoices(model: model, group: group) }
                    if !model.otherWorkspaces.isEmpty {
                        Menu("Move to workspace") {
                            ForEach(model.otherWorkspaces) { workspace in Button(workspace.name) { model.moveGroup(group, to: workspace) } }
                        }
                    }
                }
                Divider()
                Button(isFolded(key) ? "Show tasks" : "Fold tasks") { setFolded([key], !isFolded(key)) }
                let every = Set(shownKeys(visibleLists).filter { $0 != Self.newKey })
                Button(every.isSubset(of: folded) ? "Show every card" : "Fold every card") { setFolded(every, !every.isSubset(of: folded)) }
                if let group {
                    if showCovers, model.coverPainter != nil {
                        let painting = model.paintingCovers.contains(group.id)
                        Divider()
                        Button(group.coverPaintedAt == nil ? "Paint cover" : "Repaint cover") { model.paintCover(group) }.disabled(painting)
                        if group.coverStyle?.isEmpty == false { Button("Repaint in a new style") { model.paintCover(group, newStyle: true) }.disabled(painting) }
                        if group.coverPaintedAt != nil { Button("Adjust cover…") { beginAdjusting(group) }.disabled(painting) }
                        if model.canUndoCover(group) { Button("Restore previous cover") { model.undoCover(group) } }
                    }
                    Divider()
                    Button("Delete group", role: .destructive) { if model.omnibarGroup == group.id { model.omnibarGroup = nil }; model.deleteGroup(group) }
                }
            }
    }

    /// Shows only while a task is carried, at the foot of the shortest column: drop the task on it and it becomes a group
    /// where it stands, its name open, ready to change.
    private var newGroupCard: some View {
        let key = Self.newKey, targeted = dropTarget == key
        return Label("Drop to start a group", systemImage: "plus")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(targeted ? Palette.blue : Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 22).padding(.horizontal, 14).padding(.vertical, 12)
            .background(targeted ? Palette.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Palette.blue : Palette.line, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4])))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.boardSpace)) } action: { cardFrames[key] = $0 }
    }

    /// Nothing to show under the card's title: no tasks and no planned lines, as the card draws them.
    private func isResting(_ group: TaskGroup?, tasks: [FaciendaTask]) -> Bool {
        tasks.isEmpty && (group.map { arrangedPlanned(visiblePlannedLines(in: $0.id), in: $0.id).isEmpty } ?? true)
    }

    /// `hoverKey` names the card whose rim firms up under the pointer; nil keeps the rim as it is.
    private func cardContent(_ id: String?, name: String, group: TaskGroup?, tasks: [FaciendaTask], hoverKey: String? = nil) -> some View {
        // Tasks planned and not started follow the group's tasks. They are never new, so New and a search leave them out.
        let planned = group.map { arrangedPlanned(visiblePlannedLines(in: $0.id), in: $0.id) } ?? []
        let resting = isResting(group, tasks: tasks)
        // A resting card has nothing to show under its title, so it rests as a folded band that says since when.
        let shut = isFolded(id ?? Self.looseKey) || resting
        // A painted cover carries the name on its fade; without one the name has its own row.
        let banner = showCovers && group.map { model.coverImages[$0.id] != nil } == true
        return VStack(alignment: .leading, spacing: 0) {
            let fold = CardFoldState(folded: shut, tasks: tasks, planned: planned.count)
            if showCovers, let group { cover(group, resting: resting, folded: shut) { titleRow(id, name: name, group: group, resting: resting, fold: fold, banner: true, size: 15) } }
            if !banner { titleRow(id, name: name, group: group, resting: resting, fold: fold, banner: false).padding(.bottom, shut ? 0 : 6) }
            // Folded, the card is its title alone; what it holds shows as counts in the title.
            if !shut {
                VStack(alignment: .leading, spacing: 0) { cardRows(id, group: group, tasks: tasks, planned: planned) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The rows keep their clicks out to the card's edges and its foot, so a near miss on a row never folds the card.
                    .padding(.horizontal, Self.cardInset).padding(.bottom, 8).contentShape(Rectangle()).onTapGesture {}
                    .padding(.horizontal, -Self.cardInset).padding(.bottom, -8)
            }
        }
        // A folded card is one 44 pt band: the cover's own, or the title row's with even padding.
        .padding(.horizontal, Self.cardInset).padding(.top, shut && !banner ? 11 : 12).padding(.bottom, shut ? (banner ? 0 : 11) : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resting ? Color.clear : Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { CardEdge(hover: hover, key: hoverKey) }
    }

    /// The card's tasks and planned lines, below its title.
    @ViewBuilder private func cardRows(_ id: String?, group: TaskGroup?, tasks: [FaciendaTask], planned: [PlanLine]) -> some View {
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            // The dragged task's own slot stays open where it will land.
            let lifted = rowDrag?.planned == false && rowDrag?.id == task.id
            row(task, in: id, among: tasks, at: index)
                .opacity(lifted ? 0 : 1)
                .background { if lifted { RoundedRectangle(cornerRadius: 10).fill(Palette.ink.opacity(0.04)).padding(.horizontal, -(Self.cardInset - Self.slipInset)) } }
        }
        ForEach(Array(planned.enumerated()), id: \.element.id) { index, line in
            // A planned row moves like a task: its slot stays open where it will land.
            let lifted = rowDrag?.planned == true && rowDrag?.id == line.id
            PlannedRow(model: model, line: line, hover: hover,
                       above: index == 0 ? tasks.last?.id : Self.plannedKey(planned[index - 1].id), lifted: index == 0 && tasks.last.map(model.isUnread) == true,
                       carrying: rowDrag != nil)
                .opacity(lifted ? 0 : 1)
                .background { if lifted { RoundedRectangle(cornerRadius: 10).fill(Palette.ink.opacity(0.04)).padding(.horizontal, -(Self.cardInset - Self.slipInset)) } }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.boardSpace)) } action: { rowFrames.rows[Self.plannedKey(line.id)] = $0 }
        }
    }

    /// The group's name with its sources, set on the cover's fade or on a row of its own. Folded, the counts take the sources' place;
    /// resting, the line that says since when. The whole row folds and unfolds the card, out to the card's edges and its padding,
    /// so the click never has to find the arrow. A resting card has nothing to unfold, so it has no arrow and the click does nothing.
    /// Renaming is in the card's menu.
    private func titleRow(_ id: String?, name: String, group: TaskGroup?, resting: Bool, fold: CardFoldState, banner: Bool, size: CGFloat = 13) -> some View {
        let key = id ?? Self.looseKey, editing = group != nil && renaming == group?.id
        // How far the row's click reaches past its text: to the card's sides, and up and down through the padding around it.
        // Folded, a cover's whole band is its title, so the click reaches up to the band's top edge.
        let top: CGFloat = banner ? (fold.folded ? Self.bandHeight - 22 - 10 : 12) : (fold.folded ? 11 : 12)
        let reach = EdgeInsets(top: top, leading: Self.cardInset, bottom: banner ? 10 : (fold.folded ? 11 : 6), trailing: Self.cardInset)
        let verb = fold.folded ? "show its tasks" : "fold its tasks"
        return HStack(spacing: 8) {
            if let group, editing {
                TextField("Group name", text: $draftName).textFieldStyle(.plain).font(.system(size: size, weight: .semibold))
                    .focused($nameFocused).onSubmit { commitRename(group) }.onExitCommand { renaming = nil }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename(group) } }
            } else {
                Text(name).font(.system(size: size, weight: .semibold)).foregroundStyle(resting || group == nil ? Palette.muted : Palette.ink).lineLimit(1)
            }
            Spacer(minLength: 0)
            if resting {
                Text(group == nil ? "Nothing here right now" : RestingLine.text(since: model.lastActive(in: group?.id)))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).transition(.opacity)
            } else if fold.folded { FoldTally(model: model, tasks: fold.tasks, planned: fold.planned).transition(.opacity) }
            else if let group { SourcesButton(model: model, group: group).background(GraceZone()).transition(.opacity) }
            // The island's +, in the same corner of every card, Unsorted's too: a task in this group, or in the pile.
            PlusButton(help: "New task in " + name, label: "New task in " + name) { newTask(in: group) }
                .padding(.trailing, -6).padding(.vertical, -2)
        }
        .frame(minHeight: 22)
        .overlay(alignment: .leading) { if !resting { FoldArrow(hover: hover, key: key, folded: fold.folded).offset(x: Self.foldArrowOffset) } }
        .padding(reach).contentShape(Rectangle()).padding(EdgeInsets(top: -reach.top, leading: -reach.leading, bottom: -reach.bottom, trailing: -reach.trailing))
        .help((group == nil ? "Tasks without a group. " : "") + (resting ? "Nothing to show until a task joins. Drag to move." : "Click to \(verb), ⌥-click to do it to every card. Drag to move."))
        .onTapGesture { if !editing && !resting { toggleFold(key) } }
        .simultaneousGesture(dragCard(key))
        .accessibilityElement(children: .contain)
        .accessibilityActions { if !resting { Button(fold.folded ? "Show tasks" : "Fold tasks") { toggleFold(key) } } }
    }
    /// Where the fold arrow sits, in the card's margin just left of the name.
    private static let foldArrowOffset: CGFloat = -19

    /// While a task is dragged, each card shows its rows as they will be once it lands.
    private func arranged(_ tasks: [FaciendaTask], in key: String) -> [FaciendaTask] {
        guard let ids = liveRows?[key] else { return tasks }
        return ids.compactMap { model.tasksByID[$0] }
    }

    /// While a planned row is dragged, each group shows its planned rows as they will be once it lands.
    private func arrangedPlanned(_ lines: [PlanLine], in key: String) -> [PlanLine] {
        guard let ids = livePlanned?[key] else { return lines }
        return ids.compactMap { id in model.planLines.first { $0.id == id } }
    }

    /// Lifts a task, or a planned row, by its row. It follows the pointer across cards, and the rows under it slide aside to open its spot.
    /// A planned row moves among the planned rows of the groups' cards; Unsorted has no plan, so over it the row stays where it last was.
    /// `shown` is the board's lists as drawn; the row grabbed is the shown one under where the drag began.
    private func dragRow(_ shown: [String: [FaciendaTask]]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                if rowDrag == nil {
                    // Only a row starts a row's drag; a card's header and the rest of the board leave it be.
                    // Rows filtered out keep their last frame, so only the ones on screen count.
                    guard drag == nil else { return }
                    let keys = shownKeys(shown), start = value.startLocation
                    func lift(_ id: String, _ frame: CGRect, planned: Bool) -> RowDrag {
                        RowDrag(id: id, location: value.location, grab: CGSize(width: start.x - frame.minX, height: start.y - frame.minY), size: frame.size, planned: planned)
                    }
                    if let task = keys.lazy.compactMap({ shown[$0] }).joined().first(where: { rowFrames.rows[$0.id]?.contains(start) == true }),
                       let frame = rowFrames.rows[task.id] {
                        liveRows = Dictionary(uniqueKeysWithValues: keys.filter { $0 != Self.newKey }.map { ($0, shown[$0]?.map(\.id) ?? []) })
                        rowDrag = lift(task.id, frame, planned: false)
                    } else if let line = keys.lazy.flatMap({ visiblePlannedLines(in: $0) }).first(where: { rowFrames.rows[Self.plannedKey($0.id)]?.contains(start) == true }),
                              let frame = rowFrames.rows[Self.plannedKey(line.id)] {
                        livePlanned = Dictionary(uniqueKeysWithValues: model.groups.filter { keys.contains($0.id) }.map { ($0.id, visiblePlannedLines(in: $0.id).map(\.id)) })
                        rowDrag = lift(line.id, frame, planned: true)
                    } else { return }
                    choosing = nil; hover.row = nil
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
                guard var current = rowDrag else { return }
                current.location = value.location
                let centre = CGPoint(x: value.location.x - current.grab.width + current.size.width / 2, y: value.location.y - current.grab.height + current.size.height / 2)
                // Over the New group card, the row will start a group of its own.
                current.newGroup = cardFrames[Self.newKey]?.contains(centre) == true
                // A folded card has no rows to slide aside, so its edge lights instead.
                let shut = (current.planned ? livePlanned : liveRows)?.keys.first { isFolded($0) && cardFrames[$0]?.contains(centre) == true }
                dropTarget = current.newGroup ? Self.newKey : shut
                rowDrag = current
                guard !current.newGroup, let lists = current.planned ? livePlanned : liveRows,
                      let moved = carry(current.id, in: lists, to: centre, frame: { rowFrames.rows[current.planned ? Self.plannedKey($0) : $0] }),
                      moved.lists != lists else { return }
                if current.planned { livePlanned = moved.lists } else { liveRows = moved.lists }
                // One soft tick when the row crosses into another card; moving within a card stays quiet.
                if moved.crossed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
            .onEnded { _ in
                guard let current = rowDrag else { finishRowDrag(); return }
                if current.newGroup {
                    finishRowDrag()
                    makeGroup(named: AppModel.newGroupName, holding: current.planned ? [] : [current.id], planning: current.planned ? [current.id] : [])
                    return
                }
                guard let lists = current.planned ? livePlanned : liveRows else { finishRowDrag(); return }
                // Into a folded card the row glides onto its title band, where the card takes it in; elsewhere into its open slot.
                let into = lists.first { $0.value.contains(current.id) }?.key
                let band = into.flatMap { isFolded($0) ? cardFrames[$0] : nil }.map { CGRect(origin: CGPoint(x: $0.minX + Self.cardInset, y: $0.minY), size: current.size) }
                guard let slot = band ?? rowFrames.rows[current.planned ? Self.plannedKey(current.id) : current.id] else { finishRowDrag(); return }
                // Glide from the pointer into the open slot, then save the order the board already shows.
                withAnimation(Motion.move) {
                    rowSettling = true
                    rowDrag?.location = CGPoint(x: slot.minX + current.grab.width, y: slot.minY + current.grab.height)
                } completion: {
                    if let (card, rows) = lists.first(where: { $0.value.contains(current.id) }), let index = rows.firstIndex(of: current.id) {
                        if current.planned {
                            // Just above the planned row below it, or last in the group's plan. Put back where it was, nothing changes.
                            if rows != visiblePlannedLines(in: card).map(\.id) {
                                model.placePlanLine(current.id, in: card, parentId: nil, before: index + 1 < rows.count ? rows[index + 1] : nil)
                            }
                        } else {
                            let spot: AppModel.TaskSpot = index > 0 ? .below(rows[index - 1]) : rows.count > 1 ? .above(rows[1]) : .top
                            model.place(taskID: current.id, in: card == Self.looseKey ? nil : card, at: spot)
                        }
                    }
                    finishRowDrag()
                    // A folded card shows it took the row with the landing ripple, since no row of its own appears.
                    if band != nil { landed = into }
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
    }

    /// `lists` with the carried row moved into the card under `centre`, just above the first row whose middle lies below it,
    /// and whether that took it into another card. Nil between cards, and over a card `lists` doesn't hold.
    private func carry(_ id: String, in lists: [String: [String]], to centre: CGPoint, frame: (String) -> CGRect?) -> (lists: [String: [String]], crossed: Bool)? {
        guard let card = lists.keys.first(where: { cardFrames[$0]?.contains(centre) == true }) else { return nil }
        var moved = lists
        for key in moved.keys { moved[key]?.removeAll { $0 == id } }
        // A folded card takes it at the top: its rows aren't there to aim between.
        let above = isFolded(card) ? 0 : moved[card, default: []].filter { (frame($0)?.midY ?? .infinity) < centre.y }.count
        moved[card, default: []].insert(id, at: above)
        return (moved, lists[card]?.contains(id) != true)
    }

    private func finishRowDrag() {
        liveRows = nil; livePlanned = nil; rowDrag = nil; rowSettling = false; dropTarget = nil
    }

    /// The painted banner across the top of a group's card, or its placeholder while Codex paints. A resting group's banner is dimmed down and darkened.
    /// It darkens into the card's colour as the workspace banner does, with the group's name on the fade.
    /// Folded, it rolls up into a shorter band, as bright as when open, with the title on a deeper fade at its foot.
    @ViewBuilder private func cover<Title: View>(_ group: TaskGroup, resting: Bool, folded: Bool, @ViewBuilder title: () -> Title) -> some View {
        if let image = model.coverImages[group.id] {
            let painting = model.paintingCovers.contains(group.id)
            // The card's own colour; a resting card has none, so its banner sinks into the board.
            let ground = resting ? Palette.paper : Palette.card
            Color.clear.frame(height: folded ? Self.bandHeight : Self.coverHeight)
                .overlay {
                    Image(nsImage: image).resizable().scaledToFill()
                        .saturation(resting ? 0.6 : 1).brightness(resting ? -0.4 : 0)
                        .animation(Motion.move, value: resting)
                        // Only the picture is hidden from VoiceOver. Hiding the banner that carries the help keeps the banner from taking a drag.
                        .accessibilityHidden(true)
                }
                .clipped().opacity(painting ? 0.5 : 1)
                .overlay {
                    LinearGradient(stops: [.init(color: ground.opacity(0), location: 0.3), .init(color: ground.opacity(0.55), location: 0.7),
                                           .init(color: ground, location: 1)], startPoint: .top, endPoint: .bottom)
                        .opacity(folded ? 0 : 1)
                        .animation(Motion.move, value: resting)
                }
                // Folded, the fade is measured up from the band's foot: the title sits on nearly plain card,
                // and the band above it is the picture at full brightness.
                .overlay {
                    LinearGradient(stops: Self.foldedFade.map { .init(color: ground.opacity($0.opacity), location: $0.location) }, startPoint: .top, endPoint: .bottom)
                        .opacity(folded ? 1 : 0)
                        .animation(Motion.move, value: resting)
                }
                .help(group.coverStyle?.isEmpty == false ? "Cover: " + group.coverStyle! : "Group cover")
                .simultaneousGesture(dragCard(group.id))
                // The name has its own drag and its own help, so it goes on after the picture's.
                .overlay(alignment: .bottom) { title().padding(.horizontal, Self.cardInset).padding(.bottom, 10) }
                .overlay(alignment: .topTrailing) {
                    // A folded band has no room for the cover's controls; they wait until the card opens.
                    if painting, !folded {
                        // It only shows the work; a press on it still lifts the card.
                        ProgressView().controlSize(.small).padding(8).allowsHitTesting(false)
                    } else if !folded {
                        CoverHover(hover: hover, id: group.id, pinned: adjusting == group.id) { coverControls(group) }
                    }
                }
                .onHover { inside in if inside { hover.cover = group.id } else if hover.cover == group.id { hover.cover = nil } }
                // Out through the card's padding to its edges, where the card's clip rounds the top corners.
                .padding(.horizontal, -Self.cardInset).padding(.top, -12).padding(.bottom, folded ? 0 : 2)
        } else if model.paintingCovers.contains(group.id), !folded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).allowsHitTesting(false)
                Text("Painting a cover…").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity).frame(height: Self.coverHeight).background(Palette.sidebar)
                // The card moves by its band while the first cover is painted, as it will by the picture.
                .contentShape(Rectangle())
                .simultaneousGesture(dragCard(group.id))
                .padding(.horizontal, -Self.cardInset).padding(.top, -12).padding(.bottom, 10)
        }
    }
    private static let coverHeight: CGFloat = 112
    /// A folded cover's height: the title at its foot, and room above it for enough of the picture to know the group by.
    private static let bandHeight: CGFloat = 84
    /// The folded band's fade, as distances up from its foot: clear above the title, nearly the card's colour behind it.
    private static let foldedFade: [(opacity: Double, location: CGFloat)] =
        ([(0, 45), (0.62, 31), (0.92, 20), (1, 11)] as [(Double, CGFloat)]).map { (opacity: $0.0, location: (bandHeight - $0.1) / bandHeight) }

    /// Appears over the banner on hover: a wish for this picture, and a way back. A plain repaint is only in the card's menu.
    private func coverControls(_ group: TaskGroup) -> some View {
        HStack(spacing: 2) {
            if model.canUndoCover(group) {
                coverButton("arrow.uturn.backward", help: "Restore the previous cover") { model.undoCover(group) }
            }
            coverButton("wand.and.stars", help: "Adjust this cover") { beginAdjusting(group) }
                .popover(isPresented: Binding(get: { adjusting == group.id }, set: { if !$0 { adjusting = nil } }), arrowEdge: .bottom) {
                    adjustPopover(group)
                }
        }
        .padding(3).background(.ultraThinMaterial, in: Capsule()).background(GraceZone()).padding(6)
        .transition(.opacity)
    }

    private func coverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func adjustPopover(_ group: TaskGroup) -> some View {
        CoverWishPopover(wish: $wish, notes: group.coverNoteList, subject: "cover",
                         forget: { model.forgetCoverNotes(group) }, apply: { applyWish(group) }, cancel: { adjusting = nil })
    }

    private func beginAdjusting(_ group: TaskGroup) {
        wish = ""; hover.cover = group.id; adjusting = group.id
    }

    private func applyWish(_ group: TaskGroup) {
        guard !wish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.adjustCover(group, instruction: wish)
        wish = ""; adjusting = nil
    }

    /// A planned line's key among the rows the pointer can be over, apart from task IDs.
    static func plannedKey(_ id: String) -> String { "planned:" + id }

    /// Opens the group's sheet: the task started there joins it. No group means "Unsorted".
    /// Asking again for the lit group lets it go.
    private func newTask(in group: TaskGroup?) {
        let key = group?.id ?? AppModel.unsortedGroup
        if model.spotlitGroup == key { model.releaseSpotlight(); return }
        model.omnibarGroup = key
    }

    /// The row at `index` among the card's shown tasks.
    private func row(_ task: FaciendaTask, in group: String?, among tasks: [FaciendaTask], at index: Int) -> some View {
        let unread = model.isUnread(task), dot = TaskDot.Kind(model: model, task: task)
        return rowFace(task, previous: index > 0 ? tasks[index - 1] : nil)
        .contentShape(Rectangle())
        .onTapGesture { choose(task) }
        // Its own anchor, so it never competes with the rename popover on the row.
        .background {
            Color.clear.popover(isPresented: Binding(get: { choosing == task.id }, set: { if !$0 && choosing == task.id { choosing = nil } }), arrowEdge: .bottom) {
                TaskChoicesPopover(model: model, task: task, done: { finish(task) },
                                   parked: { _, label in withAnimation(Motion.move) { model.offerUndo("Parked · " + label) } }) { choosing = nil }
            }
        }
        .popover(isPresented: Binding(get: { renamingTask == task.id }, set: { if !$0 && renamingTask == task.id { renamingTask = nil } }), arrowEdge: .bottom) {
            renamePopover(task)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.boardSpace)) } action: { rowFrames.rows[task.id] = $0 }
        .contextMenu { actions(task, in: group, among: tasks, at: index) }
        // A name cut short shows whole under the pointer, anywhere on the row.
        .fullTextOnHover(task.displayName, help: dot.label + ". Click to choose what's next, or drag to move")
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(task) }
        .accessibilityAction(named: "Move up") { if index > 0 { reorder(task, in: group, at: .above(tasks[index - 1].id)) } }
        .accessibilityAction(named: "Move down") { if index < tasks.count - 1 { reorder(task, in: group, at: .below(tasks[index + 1].id)) } }
        .accessibilityLabel(task.displayName + ", " + dot.label + (unread ? ", new" : ""))
        .onHover { inside in if inside, rowDrag == nil { hover.row = task.id } else if hover.row == task.id { hover.row = nil } }
    }

    /// What a row looks like, on its card or lifted under the pointer.
    private func rowFace(_ task: FaciendaTask, previous: FaciendaTask?) -> some View {
        let unread = model.isUnread(task), dot = TaskDot.Kind(model: model, task: task)
        let naming = model.namingTasks.contains(task.id)
        let detail = naming ? "Finding a clearer name…" : model.subtitle(for: task)
        // A new row tells where its task went and what came back; closing the task's choices folds it to its line.
        let recap = naming ? nil : model.recap(for: task)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // A recap's one time, when the agent answered, ends the name's line.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.displayName).font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .foregroundStyle(dot == .done || naming ? Palette.muted : Palette.ink).shortened(to: 2).multilineTextAlignment(.leading)
                    if let time = recap.flatMap(TaskRecapView.time(of:)) {
                        Spacer(minLength: 0)
                        Text(time).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Palette.muted).fixedSize()
                    }
                }
                if let recap {
                    // It runs on under the glyph's column, so its lines wrap less.
                    TaskRecapView(recap: recap, agent: model.agent(for: task)).padding(.top, 2).padding(.trailing, -(Self.actionWidth - 12)).transition(.opacity)
                } else if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).multilineTextAlignment(.leading) }
                if let folders = model.folderLabel(for: task) {
                    Label(folders, systemImage: "folder").font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1).help("Works in " + folders)
                }
            }
            // The words come first, so a recap gets the row's whole width rather than half of it.
            .layoutPriority(1)
            Spacer(minLength: 6)
        }
        .padding(.vertical, 8).padding(.trailing, Self.actionWidth).frame(maxWidth: .infinity, alignment: .leading)
        // The wash takes the slip's shape; the rules either side give way to it.
        .background { RowWash(hover: hover, id: task.id, slip: unread) }
        .background { UnreadSlip(on: unread, since: model.cameBack(task)).padding(.horizontal, -(Self.cardInset - Self.slipInset)) }
        // The task the top bar's reading acts on, in the slip's own shape.
        .overlay { ReadingRing(on: model.readingTarget == task.id).padding(.horizontal, -(Self.cardInset - Self.slipInset)) }
        // A lifted slip stands a little apart from its neighbours, so two in a row read as two.
        .padding(.vertical, unread ? 3 : 0)
        .overlay(alignment: .top) { RowRule(hover: hover, id: task.id, above: previous?.id, lifted: unread || previous.map(model.isUnread) == true) }
        // Unread is a dot centred in the slip's margin, like an unread mail: the eye runs down one column.
        // Centred on what the eye sees: from inside the slip's 1 pt edge to where the title's ink begins, half a point in.
        // Beside the name on a row with a recap: the slip's 3 pt, the row's 8 pt, then half the name's first line.
        .overlay(alignment: recap == nil ? .leading : .topLeading) {
            if unread { UnreadDot(size: Self.unreadDot).offset(x: ((Self.slipInset + 1) + (Self.cardInset + 0.5)) / 2 - Self.cardInset - Self.unreadDot / 2,
                                                               y: recap == nil ? 0 : Self.recapNameMiddle - Self.unreadDot / 2) }
        }
        // The slip rises once when the work comes back and settles when the task's choices close.
        .animation(Motion.move, value: unread)
        // The glyph only shows the state; the whole row is the one place to click.
        .overlay(alignment: .trailing) {
            // Beside the name on a row with a recap, rather than in the middle of it.
            TaskDot(kind: dot).frame(width: Self.actionWidth - 6).frame(maxHeight: .infinity, alignment: recap == nil ? .center : .top)
                .padding(.top, recap == nil ? 0 : Self.recapNameMiddle - 8).allowsHitTesting(false)
        }
    }

    /// Every row opens the same choices: what's next with the chat, and Done or Wait until….
    private func choose(_ task: FaciendaTask) {
        choosing = task.id
    }

    /// Scrolls to the task the top bar brought back and opens its choices, showing its state again if a filter hid it.
    private func openRequested() {
        guard let id = model.boardOpenRequest else { return }
        model.boardOpenRequest = nil
        if !visibleLists.values.contains(where: { $0.contains { $0.id == id } }) { hiddenStates = LegendScope.board.defaultHidden; onlyNew = false }
        let card = model.groupMembers[id].flatMap { group in model.groups.contains { $0.id == group } ? group : nil } ?? Self.looseKey
        // Its card opens if it was folded, so the row is there for its choices.
        if isFolded(card) { setFolded([card], false) }
        scrollTarget = card
        // The choices wait for the scroll, so they open on the row where it lands.
        Task { try? await Task.sleep(for: .milliseconds(400)); choosing = id }
    }

    @ViewBuilder private func actions(_ task: FaciendaTask, in group: String?, among tasks: [FaciendaTask], at index: Int) -> some View {
        if let recovery = model.recoveryDispatch(for: task.id) { DeliveryRecoveryMenu(model: model, item: recovery); Divider() }
        Button("Rename automatically", systemImage: "sparkles") { model.generateName(for: task) }.disabled(model.namingTasks.contains(task.id))
        Button("Rename…", systemImage: "pencil") { beginRename(task) }
        Divider()
        // Ask first is the old, stricter scope; it shows as the careful choice.
        Picker(selection: Binding(get: { task.automationScope == .autonomous ? AutomationScope.autonomous : .prepareOnly }, set: { model.setScope(task, $0) })) {
            Text("Prepares, then asks me").tag(AutomationScope.prepareOnly)
            Text("Goes ahead").tag(AutomationScope.autonomous)
        } label: { Label("Agent", systemImage: "hand.raised") }
        Divider()
        // Up and down step past the neighbours on screen.
        Button("Move up", systemImage: "arrow.up") { reorder(task, in: group, at: .above(tasks[index - 1].id)) }.disabled(index == 0)
        Button("Move down", systemImage: "arrow.down") { reorder(task, in: group, at: .below(tasks[index + 1].id)) }.disabled(index == tasks.count - 1)
        Divider()
        Button("Delete task…", systemImage: "trash", role: .destructive) { deleting = task }
    }

    private func reorder(_ task: FaciendaTask, in group: String?, at spot: AppModel.TaskSpot) {
        withAnimation(Motion.move) { model.place(taskID: task.id, in: group, at: spot) }
    }

    private func renamePopover(_ task: FaciendaTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename task").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            TextField("Task name", text: $taskDraft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                .focused($taskNameFocused).onSubmit { commitRename(task) }
            HStack {
                Button("Suggest a name", systemImage: "sparkles") { renamingTask = nil; model.generateName(for: task) }
                    .buttonStyle(.plain).foregroundStyle(Palette.blue).font(.system(size: 12))
                Spacer()
                Button("Cancel") { renamingTask = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(task) }.keyboardShortcut(.defaultAction)
                    .disabled(taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 12))
        }
        .padding(14).frame(width: 300)
        .onAppear { taskNameFocused = true }
    }

    private func beginRename(_ task: FaciendaTask) {
        taskDraft = task.displayName; renamingTask = task.id
    }

    private func commitRename(_ task: FaciendaTask) {
        guard renamingTask == task.id else { return }
        renamingTask = nil
        model.renameTask(task, name: taskDraft)
    }

    private func finish(_ task: FaciendaTask) {
        withAnimation(Motion.move) { model.complete(task) }
    }

    /// The board's +: a sheet with the group's name and its first task. Asking again while it is up lets it go.
    private func beginNewGroup() {
        model.newGroupRequested = false
        if model.spotlitGroup == AppModel.newGroupSheet { model.releaseSpotlight(); return }
        model.omnibarGroup = AppModel.newGroupSheet
    }

    /// Makes the group in the New group card's spot. Dropped tasks and planned rows arrive with the name open, ready to change.
    private func makeGroup(named name: String, holding taskIDs: [String], planning lineIDs: [String] = []) {
        let spot = places(visibleLists)[Self.newKey]
        guard let group = model.createGroup(name: name, holding: taskIDs, planning: lineIDs, lane: spot?.lane, row: spot?.row) else { return }
        let dropped = !taskIDs.isEmpty || !lineIDs.isEmpty
        // A filter hides groups with nothing to show, which would swallow the empty group just made.
        // Done and Planned are no filter, so they stay as the user left them.
        if !dropped && filtering {
            hiddenStates = hidden.intersection(Self.tidyingStates).sorted().joined(separator: ",")
            onlyNew = false; model.search = ""
        }
        landed = group.id
        if dropped { beginRename(group) }
        scrollTarget = group.id
    }

    private func beginRename(_ group: TaskGroup) {
        draftName = group.name; renaming = group.id; nameFocused = true
    }

    private func commitRename(_ group: TaskGroup) {
        guard renaming == group.id else { return }
        renaming = nil
        if !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.renameGroup(group, name: draftName) }
    }
}

/// A task lifted off the board: where the pointer is, where it grabbed the row, the row's size, and whether it is over the New group card.
/// A planned row lifts the same way; its `id` is then its plan line's.
struct RowDrag: Equatable {
    var id: String
    var location: CGPoint
    var grab: CGSize
    var size: CGSize
    var newGroup = false
    var planned = false
}

/// The island's +, as the board uses it: a bare glyph in muted ink that adds one thing inside what it sits on.
/// Under the pointer it only deepens; nothing grows or moves.
struct PlusButton: View {
    let help: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26).contentShape(Rectangle())
                .brightness(hovering ? 0.08 : 0)
        }
        .buttonStyle(PressFade())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        // On a card a click folds the card, so a near miss on the + must not.
        .background(GroupBoard.GraceZone())
    }

    private struct PressFade: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
    }
}

/// A task written down in the group's plan and not started yet, below the group's tasks.
/// It carries the Plan view's empty circle, which turns into play under the pointer and starts it.
/// It drags like a task, into another group's plan too.
private struct PlannedRow: View {
    let model: AppModel
    let line: PlanLine
    let hover: BoardHover
    let above: String?
    let lifted: Bool
    /// True while a row is carried across the board: the rows it passes don't wash, and letting go over play doesn't start this one.
    let carrying: Bool
    @State private var launching = false
    private var key: String { GroupBoard.plannedKey(line.id) }

    var body: some View {
        let hot = hover.row == key
        VStack(alignment: .leading, spacing: 3) {
            Text(line.text).font(.system(size: 13)).foregroundStyle(Palette.ink).shortened(to: 2).multilineTextAlignment(.leading)
            Text("Planned").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 8).padding(.trailing, GroupBoard.actionWidth).frame(maxWidth: .infinity, alignment: .leading)
        .background { GroupBoard.RowWash(hover: hover, id: key) }
        .overlay(alignment: .top) { GroupBoard.RowRule(hover: hover, id: key, above: above, lifted: lifted) }
        .overlay(alignment: .trailing) {
            Button(action: start) {
                Group {
                    if launching { ProgressView().controlSize(.mini) }
                    else if hot { Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.blue) }
                    else { TaskDot(kind: .notStarted) }
                }
                .frame(width: GroupBoard.actionWidth - 6).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(launching)
            .help("Start it on \(model.composerModel.name)")
            .accessibilityLabel("Start “\(line.text)”")
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside, !carrying { hover.row = key } else if hover.row == key { hover.row = nil } }
        // A line cut short shows whole under the pointer, before the row's hint.
        .fullTextOnHover(line.text, help: "Planned. Drag to move")
        .contextMenu {
            Button("Start now", systemImage: "play") { start() }.disabled(launching)
            Divider()
            Button("Remove from the plan", systemImage: "trash", role: .destructive) { model.deletePlanLine(line.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.text + ", planned")
    }

    private func start() {
        guard !launching, !carrying else { return }
        launching = true
        Task {
            _ = await model.launchPlanLine(line, text: line.text)
            launching = false
        }
    }
}
