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
    /// The cards sorted by date, newest message first, the same way. The rest keep the order the user dragged.
    @State private var byDate: Set<String> = []
    /// True while a released card glides into its slot.
    @State private var settling = false
    /// The group that just landed, for a brief confirming pulse.
    @State private var landed: String?
    /// A card to scroll into view.
    @State private var scrollTarget: String?
    /// The task awaiting confirmation to be deleted.
    @State private var deleting: FaciendaTask?
    /// A group with work running, awaiting confirmation to be archived.
    @State private var archiving: TaskGroup?
    /// The task whose name is being edited in place, and the name being typed.
    @State private var renamingTask: String?
    @State private var taskDraft = ""
    @FocusState private var taskNameFocused: Bool
    /// The card's horizontal padding: how far a row reaches to touch the card's edge.
    static let cardInset: CGFloat = 20
    private static let unreadDot: CGFloat = 7
    /// A row's padding above and below, and its name's one line, which the glyph and the unread dot centre on.
    static let rowPadding: CGFloat = 7
    static let nameLine: CGFloat = 16
    /// Each row is a tile of its own; this is half the gap between two tiles, kept above and below every row.
    static let tileSpace: CGFloat = 3
    /// How far a row's tile, and an unread row's slip in the same place, stays in from the card's edge.
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
            let key = group ?? Self.looseKey
            let shown = tasks.filter {
                !hidden.contains(TaskDot.Kind(model: model, task: $0).legend.rawValue) && (!onlyNew || model.isUnread($0))
            }
            lists[key] = byDate.contains(key) ? DateOrder.sorted(shown, movedAt: model.movedAt) : shown
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
                .alert("Archive this group?", isPresented: Binding(presenting: $archiving), presenting: archiving) { group in
                    Button("Archive") { model.archiveGroup(group); archiving = nil }
                    Button("Cancel", role: .cancel) { archiving = nil }
                } message: { group in
                    let running = runningCount(in: group)
                    Text("\(running == 1 ? "One task is" : "\(running) tasks are") running in “\(group.name)”. \(running == 1 ? "Its agent stops" : "Their agents stop"), and Restore brings \(running == 1 ? "it" : "them") back as Needs me.")
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
            .onAppear { folded = FoldedCards.load(model.storageKey); byDate = DateSortedCards.load(model.storageKey); if model.newGroupRequested { beginNewGroup() }; openRequested(); landRequested() }
            .onChange(of: model.boardOpenRequest) { _, _ in openRequested() }
            .onChange(of: model.boardLandRequest) { _, _ in landRequested() }
            .onChange(of: model.newGroupRequested) { _, requested in if requested { beginNewGroup() } }
            // A group made on the board's + may land below the fold; its sheet folds into it there.
            .onChange(of: model.sheetLanding) { _, group in if let group { scrollTarget = group } }
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
            .onChange(of: byDate) { _, now in DateSortedCards.save(now, for: model.storageKey) }
            .coordinateSpace(.named(Self.boardSpace))
            // An opened task grows out of its row, which lies in the window, not on the board.
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { rowFrames.origin = $0 }
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
                        if !rowDrag.planned, let task = model.tasksByID[rowDrag.id] { rowFace(task, aged: isSorted(cardKey(of: task.id))) }
                        else if rowDrag.planned, let line = model.planLines.first(where: { $0.id == rowDrag.id }) {
                            PlannedRow(model: model, line: line, hover: hover, carrying: true)
                        }
                    }
                    .frame(width: rowDrag.size.width, height: rowDrag.size.height)
                    // Hugs the row's tile, not the gap around it.
                    .background { RoundedRectangle(cornerRadius: 8).fill(Palette.card).padding(.horizontal, -(Self.cardInset - Self.slipInset)).padding(.vertical, Self.tileSpace) }
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1).padding(.horizontal, -(Self.cardInset - Self.slipInset)).padding(.vertical, Self.tileSpace) }
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

    /// Whether a card shows its tasks by date.
    private func isSorted(_ key: String) -> Bool { byDate.contains(key) }

    /// Sorts the card by date, or gives it back its own order. With ⌥ held it does the same to every card on the board, as folding does.
    private func toggleSort(_ key: String) {
        let every = NSEvent.modifierFlags.contains(.option)
        setSorted(every ? Set(shownKeys(visibleLists).filter { $0 != Self.newKey }) : [key], !isSorted(key))
    }

    /// The rows glide to their new places in one move, as they do when the user drags one.
    private func setSorted(_ keys: Set<String>, _ sorted: Bool) {
        withAnimation(Motion.move) { if sorted { byDate.formUnion(keys) } else { byDate.subtract(keys) } }
    }

    /// The card a task sits in: its group's ID, or looseKey for "Unsorted".
    private func cardKey(of taskID: String) -> String {
        model.groupMembers[taskID].flatMap { group in model.groups.contains { $0.id == group } ? group : nil } ?? Self.looseKey
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
                    Menu("Works in") { WorkPlaceChoices(model: model, group: group) }
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
                Button(isSorted(key) ? "Back to your order" : "Sort by date") { setSorted([key], !isSorted(key)) }
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
                    // Archiving asks first only when it would stop an agent at work.
                    Button("Archive group") { if runningCount(in: group) > 0 { archiving = group } else { model.archiveGroup(group) } }
                    Button("Delete group", role: .destructive) { if model.omnibarGroup == group.id { model.omnibarGroup = nil }; model.deleteGroup(group) }
                }
            }
    }

    private func runningCount(in group: TaskGroup) -> Int {
        model.tasks.filter { $0.state == .running && model.groupMembers[$0.id] == group.id }.count
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
        .padding(.horizontal, Self.cardInset).padding(.top, shut && !banner ? 11 : 12).padding(.bottom, shut ? (banner ? 0 : 11) : Self.slipInset - Self.tileSpace)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resting ? Color.clear : Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { CardEdge(hover: hover, key: hoverKey) }
    }

    /// The card's tasks and planned lines, below its title.
    @ViewBuilder private func cardRows(_ id: String?, group: TaskGroup?, tasks: [FaciendaTask], planned: [PlanLine]) -> some View {
        let dated = isSorted(id ?? Self.looseKey)
        ForEach(entries(tasks, dated: dated)) { entry in
            if let band = entry.band {
                DayCaption(band: band, first: entry.index == 0).transition(.opacity)
            } else if let task = entry.task {
                // The dragged task's own slot stays open where it will land.
                let lifted = rowDrag?.planned == false && rowDrag?.id == task.id
                row(task, in: id, among: tasks, at: entry.index, aged: dated)
                    .opacity(lifted ? 0 : 1)
                    .background { if lifted { RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(0.04)).padding(.horizontal, -(Self.cardInset - Self.slipInset)).padding(.vertical, Self.tileSpace) } }
            }
        }
        ForEach(Array(planned.enumerated()), id: \.element.id) { index, line in
            // A planned row moves like a task: its slot stays open where it will land.
            let lifted = rowDrag?.planned == true && rowDrag?.id == line.id
            PlannedRow(model: model, line: line, hover: hover, carrying: rowDrag != nil)
                .opacity(lifted ? 0 : 1)
                .background { if lifted { RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(0.04)).padding(.horizontal, -(Self.cardInset - Self.slipInset)).padding(.vertical, Self.tileSpace) } }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.boardSpace)) } action: { rowFrames.rows[Self.plannedKey(line.id)] = $0 }
        }
    }

    /// What a card lists: its tasks, and by date a day's caption wherever the day changes. `index` counts the tasks only.
    private struct CardEntry: Identifiable {
        let id: String
        var task: FaciendaTask?
        var band: DayBand?
        var index: Int
    }

    private func entries(_ tasks: [FaciendaTask], dated: Bool) -> [CardEntry] {
        guard dated else { return tasks.enumerated().map { CardEntry(id: $1.id, task: $1, index: $0) } }
        let now = Date()
        var result: [CardEntry] = [], last: DayBand?
        for (index, task) in tasks.enumerated() {
            let band = DayBand.of(model.movedAt(task), now: now)
            if band != last { result.append(CardEntry(id: "day:\(band.caption)", band: band, index: index)); last = band }
            result.append(CardEntry(id: task.id, task: task, index: index))
        }
        return result
    }

    /// The group's name, with where it works when that is not the workspace's usual place, set on the cover's fade or on a row of its own. Folded, the counts take that place;
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
            else if let group, model.worksElsewhere(group) { WorkPlaceChip(model: model, group: group).background(GraceZone()).transition(.opacity) }
            // Beside the +, in every open card: the order the user dragged, or newest message first.
            if !resting && !fold.folded {
                SortButton(byDate: isSorted(key)) { toggleSort(key) }.padding(.vertical, -2).transition(.opacity)
            }
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
        let live = ids.compactMap { model.tasksByID[$0] }
        // By date a carried row has no spot to aim at: it shows where its date puts it.
        return isSorted(key) ? DateOrder.sorted(live, movedAt: model.movedAt) : live
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
                    hover.row = nil
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
                            if isSorted(card) {
                                // Its own order has no say here: a row from another card joins at the top of it, one already there stays.
                                if cardKey(of: current.id) != card { model.place(taskID: current.id, in: card == Self.looseKey ? nil : card, at: .top) }
                            } else {
                                let spot: AppModel.TaskSpot = index > 0 ? .below(rows[index - 1]) : rows.count > 1 ? .above(rows[1]) : .top
                                model.place(taskID: current.id, in: card == Self.looseKey ? nil : card, at: spot)
                            }
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
        // A card sorted by date keeps a row it already holds where its date puts it, so there is nothing to aim at inside it.
        if isSorted(card), lists[card]?.contains(id) == true { return (lists, false) }
        var moved = lists
        for key in moved.keys { moved[key]?.removeAll { $0 == id } }
        // A folded card, or one sorted by date, takes it at the top: its rows aren't there to aim between.
        let above = isFolded(card) || isSorted(card) ? 0 : moved[card, default: []].filter { (frame($0)?.midY ?? .infinity) < centre.y }.count
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
    static func plannedKey(_ id: String) -> String { AppModel.plannedRowKey(id) }

    /// Opens the group's sheet: the task started there joins it. No group means "Unsorted".
    /// Asking again for the lit group lets it go.
    private func newTask(in group: TaskGroup?) {
        let key = group?.id ?? AppModel.unsortedGroup
        if model.spotlitGroup == key { model.releaseSpotlight(); return }
        model.omnibarGroup = key
    }

    /// The row at `index` among the card's shown tasks.
    /// `aged` shows the row's age whatever its state, as a card sorted by date does; it has no order of the user's to move within.
    private func row(_ task: FaciendaTask, in group: String?, among tasks: [FaciendaTask], at index: Int, aged: Bool) -> some View {
        let unread = model.isUnread(task), dot = TaskDot.Kind(model: model, task: task)
        return rowFace(task, aged: aged)
        .contentShape(Rectangle())
        .onTapGesture { choose(task) }
        .popover(isPresented: Binding(get: { renamingTask == task.id }, set: { if !$0 && renamingTask == task.id { renamingTask = nil } }), arrowEdge: .bottom) {
            renamePopover(task)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.boardSpace)) } action: { rowFrames.rows[task.id] = $0 }
        .contextMenu { actions(task) }
        // A name cut short shows whole under the pointer, anywhere on the row. Where the task works is told here too, so
        // the tile keeps to the name and the exchange.
        .fullTextOnHover(task.displayName, help: dot.label + (waitingSince(task, dot).map { " since " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) } ?? "")
                         + (model.folderLabel(for: task).map { ". Works in " + $0 } ?? "") + ". Click to open, or drag to move")
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(task) }
        .accessibilityActions {
            if !aged {
                Button("Move up") { if index > 0 { reorder(task, in: group, at: .above(tasks[index - 1].id)) } }
                Button("Move down") { if index < tasks.count - 1 { reorder(task, in: group, at: .below(tasks[index + 1].id)) } }
            }
        }
        .accessibilityLabel(task.displayName + ", " + dot.label + (unread ? ", new" : ""))
        .onHover { inside in if inside, rowDrag == nil { hover.row = task.id } else if hover.row == task.id { hover.row = nil } }
    }

    /// Since when the task's agent has waited on the user. Nil while it works, is parked or done.
    private func waitingSince(_ task: FaciendaTask, _ dot: TaskDot.Kind) -> Date? {
        dot.waitsOnUser ? model.lastMessageAt(for: task) : nil
    }

    /// What a row looks like, on its card or lifted under the pointer.
    /// A row's name, with the thread's latest turn after it in grey when there is one.
    private func rowName(_ task: FaciendaTask, tail: String?) -> some View {
        let name = Text(task.displayName)
        let text = tail.map { Text("\(name)\(Text(" · " + $0).foregroundStyle(Palette.muted))") } ?? name
        return text.shortened(to: 1)
    }

    private func rowFace(_ task: FaciendaTask, aged: Bool = false) -> some View {
        let unread = model.isUnread(task), dot = TaskDot.Kind(model: model, task: task)
        let naming = model.namingTasks.contains(task.id)
        let detail = naming ? "Finding a clearer name…" : model.subtitle(for: task)
        // Every row shows its last exchange: the user's last words and the answer. Without one it keeps its line.
        let exchange = naming ? nil : model.rowExchange(for: task)
        // By date every row says how long ago it last moved; otherwise only the ones waiting on the user do.
        let waiting = aged ? model.movedAt(task) : waitingSince(task, dot)
        return VStack(alignment: .leading, spacing: 3) {
            // The glyph and how long the agent has waited on the user sit at the end of the name's line, so state and time
            // read as one (a question, 2 h) and everything under the name has the row's whole width.
            HStack(spacing: 8) {
                // The name stays the one the user recognises; where the thread went follows it, greyed. A tail shows
                // only when it fits whole: half a word after a dot says less than nothing.
                ViewThatFits(in: .horizontal) {
                    rowName(task, tail: model.handovers[task.id]?.tail ?? model.recaps[task.id]?.steps.last)
                    rowName(task, tail: nil)
                }
                .font(.system(size: 13, weight: unread ? .semibold : .regular))
                .foregroundStyle(dot == .done || naming ? Palette.muted : Palette.ink)
                Spacer(minLength: 0)
                // The glyph only shows the state; the whole row is the one place to click.
                HStack(spacing: 4) {
                    TaskDot(kind: dot)
                    if let waiting { MessageAge(date: waiting).transition(.opacity) }
                }
                .allowsHitTesting(false)
            }
            .frame(minHeight: Self.nameLine)
            if let exchange {
                TaskRecapView(exchange: exchange, agent: model.agent(for: task), asking: dot.waitsOnUser).padding(.top, 1).transition(.opacity)
                // What holds the task stays in view under the exchange: a wait, a permission, a prerequisite.
                if let held = model.statusLine(for: task) {
                    Text(held).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            } else if let detail {
                // No exchange to show, so the line stands alone; it keeps the exchange's column all the same, or the
                // board's left edge would jump from row to row.
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).multilineTextAlignment(.leading)
                    .padding(.leading, TaskRecapView.gutter)
            }
        }
        .padding(.vertical, Self.rowPadding).frame(maxWidth: .infinity, alignment: .leading)
        // The wash takes the tile's shape and lies over it.
        .background { RowWash(hover: hover, id: task.id, slip: unread) }
        .background { UnreadSlip(on: unread, since: model.cameBack(task)).padding(.horizontal, -(Self.cardInset - Self.slipInset)) }
        // Every row is a tile of its own, so rows part by a gap rather than a rule. An unread row's slip covers it.
        .background { RowTile() }
        // The task the top bar's reading acts on, in the slip's own shape.
        .overlay { ReadingRing(on: model.readingTarget == task.id).padding(.horizontal, -(Self.cardInset - Self.slipInset)) }
        .padding(.vertical, Self.tileSpace)
        // Unread is a dot in the slip's margin beside the name, like an unread mail: the eye runs down one column.
        // Centred on what the eye sees: from inside the slip's 1 pt edge to where the title's ink begins, half a point in.
        .overlay(alignment: .topLeading) {
            if unread { UnreadDot(size: Self.unreadDot).offset(x: ((Self.slipInset + 1) + (Self.cardInset + 0.5)) / 2 - Self.cardInset - Self.unreadDot / 2,
                                                               y: Self.tileSpace + Self.rowPadding + Self.nameLine / 2 - Self.unreadDot / 2) }
        }
        // The slip rises once when the work comes back and settles when the task's choices close.
        .animation(Motion.move, value: unread)
    }

    /// Every row opens the same way: the task over the board, grown out of its row, with what it says and what's next.
    private func choose(_ task: FaciendaTask) {
        let row = rowFrames.rows[task.id]?.offsetBy(dx: rowFrames.origin.x, dy: rowFrames.origin.y)
        withAnimation(TaskOpenLayer.motion(from: row)) { model.showTask(task, from: row) }
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
        // The task waits for the scroll, so it opens out of the row where it lands.
        Task { try? await Task.sleep(for: .milliseconds(400)); if let task = model.tasksByID[id] { choose(task) } }
    }

    /// Brings the row Goals pointed at into view once the window has turned, and lights it and its card. A filter
    /// hiding it gives way, and Planned shows for a planned row.
    private func landRequested() {
        guard let id = model.boardLandRequest else { return }
        model.boardLandRequest = nil
        let line = model.planLines.first { Self.plannedKey($0.id) == id }
        let group = model.groups.contains { $0.id == id } ? id : line?.groupId ?? model.groupMembers[id]
        let card = group.flatMap { group in model.groups.contains { $0.id == group } ? group : nil } ?? Self.looseKey
        if line != nil, hidden.contains("notStarted") {
            hiddenStates = hidden.subtracting(["notStarted"]).sorted().joined(separator: ",")
        } else if line == nil, group != id, !visibleLists.values.contains(where: { $0.contains { $0.id == id } }) {
            hiddenStates = LegendScope.board.defaultHidden; onlyNew = false
        }
        if isFolded(card) { setFolded([card], false) }
        scrollTarget = card
        Task {
            // The landing ripple keeps its own clock: it plays once the turn (Motion.travel) has brought the card in.
            try? await Task.sleep(for: .milliseconds(520))
            landed = card
            if group != id { hover.row = id }
            try? await Task.sleep(for: .seconds(1.6))
            if hover.row == id { hover.row = nil }
        }
    }

    @ViewBuilder private func actions(_ task: FaciendaTask) -> some View {
        if let recovery = model.recoveryDispatch(for: task.id) { DeliveryRecoveryMenu(model: model, item: recovery); Divider() }
        if task.state.isOpen {
            Button("Mark as done", systemImage: "checkmark") { withAnimation(Motion.move) { model.complete(task) } }
            Divider()
        }
        Button("Rename automatically", systemImage: "sparkles") { model.generateName(for: task) }.disabled(model.namingTasks.contains(task.id))
        Button("Rename…", systemImage: "pencil") { beginRename(task) }
        Divider()
        Menu("Goal", systemImage: "scope") { ServesChoices(model: model, taskID: task.id) }
        if HandoverChoices.offered(task, in: model) {
            Menu("Continue in a new chat", systemImage: "arrow.triangle.swap") { HandoverChoices(model: model, task: task) }
        }
        Divider()
        if !model.otherWorkspaces.isEmpty {
            Menu("Move to workspace", systemImage: "arrow.right.circle") { WorkspaceMoveChoices(model: model, task: task) }
            Divider()
        }
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

/// Where a task can move, as menu items: each other workspace, and in it no group or one of its groups.
/// A workspace without groups is a single choice.
struct WorkspaceMoveChoices: View {
    let model: AppModel
    let task: FaciendaTask

    var body: some View {
        ForEach(model.otherWorkspaces) { workspace in
            let groups = model.otherGroups[workspace.id] ?? []
            if groups.isEmpty {
                Button(workspace.name) { model.moveTask(task, to: workspace) }
            } else {
                Menu(workspace.name) {
                    Button("No group") { model.moveTask(task, to: workspace) }
                    Divider()
                    ForEach(groups) { group in Button(group.name) { model.moveTask(task, to: workspace, group: group) } }
                }
            }
        }
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

    struct PressFade: ButtonStyle {
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
    /// True while a row is carried across the board: the rows it passes don't wash, and letting go over play doesn't start this one.
    let carrying: Bool
    @State private var launching = false
    /// Its popover is open: the words, its group and Start, in one place.
    @State private var opened = false
    private var key: String { GroupBoard.plannedKey(line.id) }

    var body: some View {
        let hot = hover.row == key
        VStack(alignment: .leading, spacing: 3) {
            // Laid out as a task's row: the circle that starts it at the end of the name's line.
            HStack(spacing: 8) {
                Text(line.text).font(.system(size: 13)).foregroundStyle(Palette.ink).shortened(to: 1)
                Spacer(minLength: 0)
                Button { start() } label: {
                    Group {
                        if launching { ProgressView().controlSize(.mini) }
                        else if hot { Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.blue) }
                        else { TaskDot(kind: .notStarted) }
                    }
                    // A target wider than the circle, so play is easy to hit; it doesn't widen the line.
                    .frame(width: 16, height: GroupBoard.nameLine).padding(8).contentShape(Rectangle()).padding(-8)
                }
                .buttonStyle(.plain).disabled(launching)
                .help("Start it on \(model.composerModel.name)")
                .accessibilityLabel("Start “\(line.text)”")
            }
            .frame(minHeight: GroupBoard.nameLine)
            Text("Planned").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .padding(.vertical, GroupBoard.rowPadding).frame(maxWidth: .infinity, alignment: .leading)
        .background { GroupBoard.RowWash(hover: hover, id: key) }
        .background { GroupBoard.RowTile() }
        .padding(.vertical, GroupBoard.tileSpace)
        .contentShape(Rectangle())
        .onTapGesture { if !carrying { opened = true } }
        .popover(isPresented: $opened, arrowEdge: .bottom) {
            PlannedPopover(text: line.text, canStart: !launching, startHelp: "Start it on \(model.composerModel.name)") {
                Menu {
                    ForEach(model.groups) { group in
                        Button { move(to: group) } label: {
                            if group.id == line.groupId { Label(group.name, systemImage: "checkmark") } else { Text(group.name) }
                        }
                    }
                } label: { PlannedPlaceLabel(name: model.groups.first { $0.id == line.groupId }?.name ?? "Its group") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            } save: { model.setPlanText(line.id, $0) } start: { start($0) } remove: { model.deletePlanLine(line.id) } dismiss: { opened = false }
        }
        .onHover { inside in if inside, !carrying { hover.row = key } else if hover.row == key { hover.row = nil } }
        // A line cut short shows whole under the pointer, before the row's hint.
        .fullTextOnHover(line.text, help: "Planned. Click to change it, or drag to move")
        .contextMenu {
            Button("Start now", systemImage: "play") { start() }.disabled(launching)
            Button("Edit…", systemImage: "pencil") { opened = true }
            Divider()
            Button("Remove from the plan", systemImage: "trash", role: .destructive) { model.deletePlanLine(line.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.text + ", planned")
    }

    private func start(_ text: String? = nil) {
        guard !launching, !carrying else { return }
        launching = true
        Task {
            _ = await model.launchPlanLine(line, text: text ?? line.text)
            launching = false
        }
    }

    /// To the end of another group's plan, as carrying it to that card does.
    private func move(to group: TaskGroup) {
        guard group.id != line.groupId else { return }
        withAnimation(Motion.move) { model.placePlanLine(line.id, in: group.id, parentId: nil, before: nil) }
    }
}
