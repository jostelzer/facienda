import SwiftUI
import FaciendaCore

/// Where each plan row sits, read when a drag starts. A plain class so recording a move never redraws the plan.
final class RowFrames {
    var rows: [String: CGRect] = [:]
}

/// One group's plan: lines the user writes, nested under larger goals, each started as a task on its own.
/// Built from the board's card so it looks and behaves like the same group. Every row can be picked up and moved.
struct PlanBoard: View {
    @Bindable var model: AppModel
    @Binding var groupID: String?
    @AppStorage("groupCovers") private var showCovers = true
    @AppStorage("dashboardHiddenStates") private var hiddenStates = GroupBoard.defaultHiddenStates
    @AppStorage("dashboardOnlyNew") private var onlyNew = false
    /// Text typed into a line and not yet saved. Saving happens on Return, on leaving the line and on starting it.
    @State private var drafts: [String: String] = [:]
    @FocusState private var focused: String?
    /// The line being edited. The others show as plain text, so they can be grabbed anywhere.
    @State private var editing: String?
    /// Where the cursor sits in the line being edited. Entering a line puts it at the end rather than selecting everything.
    @State private var caret: TextSelection?
    @State private var collapsed: Set<String> = []
    @State private var choosing: String?
    @State private var hovered: String?
    @State private var hoveredStrip: String?
    @State private var launching: Set<String> = []
    @State private var deleting: PlanLine?
    /// Each row's place in the card, for working out where a dragged row lands.
    /// Kept outside SwiftUI's state: rows move on every frame while a card folds, and redrawing the plan for each move made it stutter.
    @State private var frames = RowFrames()
    @State private var drag: RowDrag?
    /// Catches Backspace, Tab and the move keys before the text field does: an empty field swallows Backspace.
    @State private var keyMonitor: Any?
    /// The column on the left holding each row's state glyph, fold arrow or start button.
    private static let markWidth: CGFloat = 16
    private static let markGap: CGFloat = 8
    private static let rowPadding: CGFloat = 5
    private static let cardInset: CGFloat = 20
    private static let indent: CGFloat = 20
    private static let unreadDot: CGFloat = 7
    private static let coverHeight: CGFloat = 84
    /// Wide enough to use most of the window, short of lines so long they get hard to read.
    private static let columnWidth: CGFloat = 1100
    private nonisolated static let space = "plan"
    private static let newLineKey = "+new-line"
    private static let loosePrefix = "task:"

    private var group: TaskGroup? { model.groups.first { $0.id == groupID } ?? model.groups.first }
    private var lines: [PlanLine] { group.map { id in model.planLines.filter { $0.groupId == id.id } } ?? [] }
    private var outline: PlanOutline { PlanOutline(lines) }
    private var tasksByID: [String: FaciendaTask] { model.tasksByID }

    // MARK: Filters

    /// The board's filters: a task row shows when its state is shown and, with New on, when it is new.
    private func passes(_ task: FaciendaTask) -> Bool {
        !StateLegend.hidden(hiddenStates).contains(TaskDot.Kind(model: model, task: task).legend.rawValue) && (!onlyNew || model.isUnread(task))
    }

    /// The outline as it shows: filtered like the board, with folded lines' children left out.
    /// A line stays when anything under it shows, so a step never appears without its goal.
    private var visibleEntries: [PlanOutline.Entry] {
        let entries = outline.entries, tasks = tasksByID
        func shows(_ entry: PlanOutline.Entry) -> Bool {
            guard let id = entry.line.launchedTaskId else {
                return !onlyNew && !StateLegend.hidden(hiddenStates).contains(TaskDot.Kind.notStarted.rawValue)
            }
            guard let task = tasks[id] else { return !onlyNew }
            return passes(task)
        }
        var keep = Set<String>()
        for (index, entry) in entries.enumerated().reversed() where shows(entry) || entries[(index + 1)...].prefix(while: { $0.depth > entry.depth }).contains(where: { keep.contains($0.line.id) }) {
            keep.insert(entry.line.id)
        }
        var hiddenBelow: Int?
        return entries.filter { entry in
            guard keep.contains(entry.line.id) else { return false }
            if let depth = hiddenBelow { if entry.depth > depth { return false } else { hiddenBelow = nil } }
            if collapsed.contains(entry.line.id) && !entry.childIDs.isEmpty { hiddenBelow = entry.depth }
            return true
        }
    }

    /// The group's tasks that no line of its plan holds. They sit below the plan and can be dragged into it.
    private func looseTasks(_ group: TaskGroup) -> [FaciendaTask] {
        let planned = Set(lines.compactMap(\.launchedTaskId))
        return model.boardTasks(in: group.id).filter { !planned.contains($0.id) && passes($0) }
    }

    /// Every task the plan view shows, for the legend's counts.
    private func legendTasks(_ group: TaskGroup) -> [FaciendaTask] {
        let planned = lines.compactMap(\.launchedTaskId).compactMap { tasksByID[$0] }
        let planIDs = Set(planned.map(\.id))
        return planned + model.boardTasks(in: group.id).filter { !planIDs.contains($0.id) }
    }

    // MARK: Dragging

    /// A row lifted by the pointer: a plan line with the lines under it, or a task from below the plan.
    /// The rest of the outline makes room as it moves.
    private struct RowDrag {
        var root: String
        var block: [String]
        /// The visible plan lines that stay put, in order.
        var others: [String]
        var frames: [String: CGRect]
        var depths: [String: Int]
        var rootDepth: Int
        /// Where it started among the others. Nil for a task from below the plan.
        var origin: Int?
        var translation: CGSize = .zero
        /// Where it would land among the others. Nil while a task from below the plan is still below it.
        var target: Int?
        var depth: Int
        var loose: Bool { origin == nil }
    }

    private enum Row {
        case line(PlanOutline.Entry)
        case loose(FaciendaTask)
    }

    /// The plan's rows in the order they show, with a lifted row at the spot it would land and the depth it would take.
    private func planRows(_ group: TaskGroup) -> [(key: String, row: Row, depth: Int)] {
        let entries = visibleEntries
        guard let drag else { return entries.map { (key: $0.line.id, row: .line($0), depth: $0.depth) } }
        let byID = Dictionary(entries.map { ($0.line.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = drag.others.compactMap { byID[$0] }.map { (key: $0.line.id, row: Row.line($0), depth: $0.depth) }
        guard let target = drag.target else { return rows }
        let lifted: [(key: String, row: Row, depth: Int)]
        if drag.loose {
            guard let task = tasksByID[String(drag.root.dropFirst(Self.loosePrefix.count))] else { return rows }
            lifted = [(key: drag.root, row: .loose(task), depth: drag.depth)]
        } else {
            lifted = drag.block.compactMap { byID[$0] }.map { (key: $0.line.id, row: .line($0), depth: $0.depth - drag.rootDepth + drag.depth) }
        }
        rows.insert(contentsOf: lifted, at: min(target, rows.count))
        return rows
    }

    /// The tasks below the plan, less one that is being dragged up into it.
    private func belowRows(_ group: TaskGroup) -> [FaciendaTask] {
        looseTasks(group).filter { !(drag?.loose == true && drag?.target != nil && drag?.root == Self.loosePrefix + $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let group {
                // The legend stays put, as on the board; the plan below can grow tall.
                StateLegend(model: model, tasks: legendTasks(group),
                            plannedCount: lines.filter { $0.launchedTaskId == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
                    .frame(maxWidth: Self.columnWidth, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4).frame(maxWidth: .infinity)
            }
            ScrollView {
                // One column like the board: the open group is a full card, the others fold to a strip.
                VStack(spacing: 10) {
                    if model.groups.isEmpty { noGroups }
                    ForEach(stack) { option in
                        Group {
                            if option.id == group?.id { card(option).transition(.opacity) } else { strip(option).transition(.opacity) }
                        }
                        .id(option.id)
                    }
                }
                .frame(maxWidth: Self.columnWidth).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 120)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handleKey(event) ? nil : event }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: focused) { previous, now in
            if let previous { commit(previous) }
            // Only the line that lost the cursor closes; a line just opened for typing stays open.
            if let previous, editing == previous, now != previous { editing = nil }
        }
        .alert("Delete this line and the lines under it?", isPresented: Binding(presenting: $deleting), presenting: deleting) { line in
            Button("Delete", role: .destructive) { remove(line.id); deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { line in
            Text("“\(Self.short(line.text))” goes with everything written under it. Tasks already started stay in the group.")
        }
    }

    private var noGroups: some View {
        VStack(spacing: 6) {
            Text("No groups yet").font(.system(size: 13, weight: .semibold))
            Text("Make a group on the board, then plan it here.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity).padding(.top, 80)
    }

    // MARK: Card

    private func card(_ group: TaskGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showCovers, let image = model.coverImages[group.id] {
                Color.clear.frame(height: Self.coverHeight)
                    .overlay { Image(nsImage: image).resizable().scaledToFill() }
                    // Clipping only hides the picture: filled across a wide card it reaches far above and below the band
                    // and would take the clicks meant for the strips above, which then never open.
                    .clipped().allowsHitTesting(false).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                header(group)
                if lines.isEmpty { emptyHint }
                ForEach(planRows(group), id: \.key) { item in movable(item.key, depth: item.depth, row: item.row, group: group) }
                newLineRow(group)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.rows[Self.newLineKey] = $0 }
                let below = belowRows(group)
                if !below.isEmpty { Color.clear.frame(height: 10) }
                ForEach(below) { task in
                    movable(Self.loosePrefix + task.id, depth: 0, row: .loose(task), group: group)
                }
            }
            .padding(.horizontal, Self.cardInset).padding(.top, 12).padding(.bottom, 8)
            .coordinateSpace(.named(Self.space))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
        .animation(Motion.move, value: hiddenStates)
        .animation(Motion.move, value: onlyNew)
    }

    private func header(_ group: TaskGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            // Lines start on the same choice as the top bar and the composer.
            ModelChoiceMenu(model: model, boxed: true)
            Button { addLine(in: group, parent: nil, after: nil) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }.buttonStyle(.plain).help("New line in " + group.name).accessibilityLabel("New line in " + group.name)
        }.frame(minHeight: 22).padding(.bottom, 6)
    }

    /// The workspace's groups in the board's reading order: column by column, top to bottom.
    private var stack: [TaskGroup] {
        model.groups.enumerated().sorted { a, b in
            (a.element.lane ?? .max, a.element.row ?? .max, a.offset) < (b.element.lane ?? .max, b.element.row ?? .max, b.offset)
        }.map(\.element)
    }

    /// A group that isn't open: its cover, name, how many lines wait to start, and a dot when it has new work. A click opens it.
    private func strip(_ option: TaskGroup) -> some View {
        let waiting = model.planLines.filter { $0.groupId == option.id && $0.launchedTaskId == nil && !$0.text.isEmpty }.count
        let fresh = model.boardTasks(in: option.id).contains(where: model.isUnread)
        let hot = hoveredStrip == option.id
        return Button { open(option) } label: {
            HStack(spacing: 12) {
                Group {
                    if showCovers, let image = model.coverImages[option.id] {
                        Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                    } else { Palette.sidebar }
                }.frame(width: 96, height: 44).accessibilityHidden(true)
                Text(option.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(waiting > 0 ? "\(waiting) to start" : "Nothing planned yet").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                if fresh { Circle().fill(Palette.blue).frame(width: Self.unreadDot, height: Self.unreadDot).accessibilityLabel("New work") }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                    .offset(x: hot ? 2 : 0)
            }
            .padding(.trailing, 16).frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hot ? Palette.firmLine : Palette.line, lineWidth: 1))
        .onHover { inside in if inside { hoveredStrip = option.id } else if hoveredStrip == option.id { hoveredStrip = nil } }
        .animation(Motion.fade, value: hot)
        .help("Plan " + option.name)
    }

    /// Opens another group's plan. The open card folds to a strip as the chosen one unfolds.
    private func open(_ option: TaskGroup) {
        if let focused { commit(focused) }
        focused = nil; editing = nil; drag = nil; choosing = nil; hovered = nil
        withAnimation(Motion.move) { groupID = option.id }
    }

    private var emptyHint: some View {
        Text("Write what this group should get done. Return saves a line and Shift-Return adds one below. Tab tucks it under the one above to make that one a goal. Hover the circle to start a line as a task. Drag any row to move it.")
            .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
    }

    private func newLineRow(_ group: TaskGroup) -> some View {
        Button { addLine(in: group, parent: nil, after: nil) } label: {
            HStack(alignment: .top, spacing: Self.markGap) {
                Circle().strokeBorder(Palette.firmLine, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])).frame(width: 11, height: 11)
                    .frame(width: Self.markWidth, height: 18)
                Text("New line…").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Self.rowPadding).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows

    /// Any row, picked up by pressing anywhere on it and dragging. While lifted it follows the pointer and the others slide aside.
    private func movable(_ key: String, depth: Int, row: Row, group: TaskGroup) -> some View {
        let lifted = drag?.root == key || (drag?.loose == false && drag?.block.contains(key) == true)
        let editingThis = editing == key
        let hot = hovered == key && drag == nil
        return Group {
            switch row {
            case let .line(entry):
                if let id = entry.line.launchedTaskId {
                    if let task = tasksByID[id] { taskRow(task, entry: entry, depth: depth, group: group) } else { departedRow(entry, depth: depth, group: group) }
                } else {
                    lineRow(entry, depth: depth, group: group, hot: hot)
                }
            case let .loose(task):
                taskRow(task, entry: nil, depth: depth, group: group)
            }
        }
        .background(alignment: .topLeading) { guides(depth) }
        .background {
            if lifted { RoundedRectangle(cornerRadius: 8).fill(Palette.card).padding(.horizontal, -8) }
            else if hot && !editingThis { RoundedRectangle(cornerRadius: 7).fill(Palette.selected.opacity(0.55)).padding(.horizontal, -6) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.rows[key] = $0 }
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = key } else if hovered == key { hovered = nil } }
        // The line being edited keeps its drag for selecting text.
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in dragChanged(key, value) }
            .onEnded { value in dragEnded(key, value) }, including: editingThis ? .subviews : .all)
        .offset(y: lifted ? liftOffset : 0)
        .scaleEffect(lifted ? 1.01 : 1)
        .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 12 : 0, y: lifted ? 5 : 0)
        .zIndex(lifted ? 1 : 0)
        .animation(Motion.fade, value: hot)
    }

    /// Hairlines running down from each goal above the row, through the middle of the goal's mark, like a notes outline.
    private func guides(_ depth: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<depth, id: \.self) { level in
                Rectangle().fill(Palette.line).frame(width: 1).frame(maxHeight: .infinity)
                    .offset(x: CGFloat(level) * Self.indent + Self.markWidth / 2 - 0.5)
            }
        }
        .accessibilityHidden(true)
    }

    /// A line not started yet: the empty circle, which turns into the start button under the pointer, then the text,
    /// plain until clicked and editable after.
    private func lineRow(_ entry: PlanOutline.Entry, depth: Int, group: TaskGroup, hot: Bool) -> some View {
        let line = entry.line, goal = !entry.childIDs.isEmpty
        let text = drafts[line.id] ?? line.text
        let startable = !goal && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let font = Font.system(size: 13, weight: goal ? .semibold : .regular)
        return HStack(alignment: .top, spacing: Self.markGap) {
            Group {
                if goal { disclosure(entry) }
                else if launching.contains(line.id) { ProgressView().controlSize(.mini) }
                else if startable {
                    // A goal is reached through its steps; it can still be started whole from its menu.
                    Button { launch(line) } label: {
                        Group {
                            if hot { Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.blue) }
                            else { TaskDot(kind: .notStarted) }
                        }.frame(width: Self.markWidth, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Start as a task in \(group.name) on \(model.composerModel.name)")
                    .accessibilityLabel("Start “\(Self.short(text))” as a task")
                } else { TaskDot(kind: .notStarted) }
            }.frame(width: Self.markWidth, height: 18)
            if editing == line.id {
                TextField("Write what you want done", text: draftBinding(line), selection: $caret, axis: .vertical)
                    .textFieldStyle(.plain).font(font)
                    .focused($focused, equals: line.id)
                    // A line opened for typing takes the cursor as soon as it is on screen, with the cursor at its end.
                    .onAppear { focused = line.id; caret = TextSelection(insertionPoint: text.endIndex) }
                    .onExitCommand { commit(line.id); focused = nil }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(text.isEmpty ? "Write what you want done" : text).font(font)
                        .foregroundStyle(text.isEmpty ? Palette.muted : Palette.ink).fixedSize(horizontal: false, vertical: true)
                    if goal { rollup(entry) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Self.rowPadding).padding(.leading, CGFloat(depth) * Self.indent).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if editing != line.id { edit(line.id) } }
        .contextMenu { lineActions(entry, group: group) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit") { edit(line.id) }
    }

    /// A task row, from the plan or from below it: the board's own glyph and subtitle, so state, unread and choices read the same.
    private func taskRow(_ task: FaciendaTask, entry: PlanOutline.Entry?, depth: Int, group: TaskGroup) -> some View {
        let unread = model.isUnread(task), dot = TaskDot.Kind(model: model, task: task)
        let goal = entry?.childIDs.isEmpty == false
        let detail = model.namingTasks.contains(task.id) ? "Finding a clearer name…" : model.subtitle(for: task)
        return HStack(alignment: .top, spacing: Self.markGap) {
            Group {
                if let entry, goal { disclosure(entry) } else { TaskDot(kind: dot) }
            }.frame(width: Self.markWidth, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.displayName).font(.system(size: 13, weight: unread || goal ? .semibold : .regular))
                        .foregroundStyle(dot == .done ? Palette.muted : Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                    if let entry, goal { rollup(entry) }
                }
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 6)
        }
        .padding(.vertical, Self.rowPadding).padding(.leading, CGFloat(depth) * Self.indent).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if unread { UnreadDot(size: Self.unreadDot).offset(x: -(Self.cardInset + Self.unreadDot) / 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(task) }
        .background {
            Color.clear.popover(isPresented: Binding(get: { choosing == task.id }, set: { if !$0 && choosing == task.id { choosing = nil } }), arrowEdge: .bottom) {
                TaskChoicesPopover(model: model, task: task, done: { model.complete(task) }, parked: { _, _ in }) { choosing = nil }
            }
        }
        .contextMenu {
            if let recovery = model.recoveryDispatch(for: task.id) { DeliveryRecoveryMenu(model: model, item: recovery); Divider() }
            if model.canOpen(task) { Button("Open in \(model.agent(for: task).name)") { model.open(task) } }
            if let entry { if model.canOpen(task) { Divider() }; lineActions(entry, group: group, launched: true) }
        }
        .help(model.offersChoices(task) || !model.canOpen(task) ? "Choose what's next. Drag to move." : "Open in \(model.agent(for: task).name). Drag to move.")
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityLabel(task.displayName + ", " + dot.label + (unread ? ", new" : ""))
    }

    /// A line whose task moved to another workspace. What the user wrote stays readable.
    private func departedRow(_ entry: PlanOutline.Entry, depth: Int, group: TaskGroup) -> some View {
        HStack(alignment: .top, spacing: Self.markGap) {
            Group { if entry.childIDs.isEmpty { Color.clear } else { disclosure(entry) } }.frame(width: Self.markWidth, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.line.text).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(2)
                Text("Its task lives in another workspace now").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, Self.rowPadding).padding(.leading, CGFloat(depth) * Self.indent).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { lineActions(entry, group: group, launched: true) }
    }

    /// A goal's mark: its fold arrow.
    private func disclosure(_ entry: PlanOutline.Entry) -> some View {
        let open = !collapsed.contains(entry.line.id)
        return Button {
            withAnimation(Motion.move) { if open { collapsed.insert(entry.line.id) } else { collapsed.remove(entry.line.id) } }
        } label: {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: Self.markWidth, height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain).help(open ? "Fold the lines under this one" : "Show the lines under this one")
    }

    /// How many of the lines directly under a goal are done.
    private func rollup(_ entry: PlanOutline.Entry) -> some View {
        let children = lines.filter { entry.childIDs.contains($0.id) }
        let done = children.filter { $0.launchedTaskId.flatMap { tasksByID[$0] }?.state == .done }.count
        return Text("\(done)/\(children.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
            .fixedSize().help("\(done) of \(children.count) done")
    }

    @ViewBuilder private func lineActions(_ entry: PlanOutline.Entry, group: TaskGroup, launched: Bool = false) -> some View {
        let line = entry.line
        if !launched {
            Button("Edit") { edit(line.id) }
            Button("Start as a task") { launch(line) }
                .disabled((drafts[line.id] ?? line.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Button("Add a line under this") { collapsed.remove(line.id); addLine(in: group, parent: line.id, after: entry.childIDs.last) }
        Divider()
        Button("Indent") { commit(line.id); withAnimation(Motion.move) { model.indentPlanLine(line.id) } }
        Button("Outdent") { commit(line.id); withAnimation(Motion.move) { model.outdentPlanLine(line.id) } }.disabled(line.parentId == nil)
        Button("Move up") { commit(line.id); withAnimation(Motion.move) { model.movePlanLine(line.id, by: -1) } }
        Button("Move down") { commit(line.id); withAnimation(Motion.move) { model.movePlanLine(line.id, by: 1) } }
        Divider()
        Button(launched ? "Remove from the plan" : "Delete line", role: .destructive) {
            if entry.childIDs.isEmpty { remove(line.id) } else { deleting = line }
        }
    }

    // MARK: Editing

    private func draftBinding(_ line: PlanLine) -> Binding<String> {
        Binding(get: { drafts[line.id] ?? line.text }, set: { drafts[line.id] = $0 })
    }

    /// Saves what was typed into a line, if it changed.
    private func commit(_ id: String) {
        guard let draft = drafts[id] else { return }
        if let line = model.planLines.first(where: { $0.id == id }), line.text != draft.trimmingCharacters(in: .whitespacesAndNewlines) {
            model.setPlanText(id, draft)
        }
        if focused != id { drafts[id] = nil }
    }

    private func addLine(in group: TaskGroup, parent: String?, after: String?) {
        if let line = withAnimation(Motion.move, { model.addPlanLine(in: group.id, parent: parent, after: after) }) { edit(line.id) }
    }

    /// Keys for the line being edited, like a list in a notes app. Returns true when the key was used here.
    /// Return saves the line and closes it; Shift-Return opens a new line below.
    /// Backspace on an empty line removes that line and continues at the end of the one above.
    /// Tab tucks the line under the one above and Shift-Tab brings it out. Lines move with the mouse.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let id = editing, let entry = outline.entries.first(where: { $0.line.id == id }) else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36 where flags.isEmpty, 76 where flags.isEmpty:
            // Return saves the line and closes it, as Escape does.
            commit(id); focused = nil
            return true
        case 36 where flags == .shift, 76 where flags == .shift:
            // Shift-Return opens a new line right below, at the same depth, ready to type in.
            commit(id)
            if let group { addLine(in: group, parent: entry.line.parentId, after: id) }
            return true
        case 51 where flags.isEmpty:
            guard (drafts[id] ?? entry.line.text).isEmpty, entry.childIDs.isEmpty else { return false }
            remove(id)
            return true
        case 48 where flags.subtracting(.shift).isEmpty:
            commit(id)
            withAnimation(Motion.move) { if flags.contains(.shift) { model.outdentPlanLine(id) } else { model.indentPlanLine(id) } }
            edit(id)
            return true
        default:
            return false
        }
    }

    /// Deletes a line and carries on typing at the end of the line above it, if there is one.
    private func remove(_ id: String) {
        let above = previousLine(before: id)
        drafts[id] = nil
        if editing == id { editing = nil; focused = nil }
        withAnimation(Motion.move) { model.deletePlanLine(id) }
        if let above { edit(above) }
    }

    /// Opens a line for typing with the cursor at its end, once the outline has redrawn around it.
    private func edit(_ id: String) {
        guard model.planLines.contains(where: { $0.id == id && $0.launchedTaskId == nil }) else { return }
        caret = nil
        editing = id
        DispatchQueue.main.async {
            let text = drafts[id] ?? model.planLines.first { $0.id == id }?.text ?? ""
            focused = id
            caret = TextSelection(insertionPoint: text.endIndex)
        }
    }

    /// The nearest line above that can still be typed in.
    private func previousLine(before id: String) -> String? {
        let entries = visibleEntries
        guard let index = entries.firstIndex(where: { $0.line.id == id }), index > 0 else { return nil }
        return entries[..<index].last { $0.line.launchedTaskId == nil }?.line.id
    }

    private func launch(_ line: PlanLine) {
        let text = drafts[line.id] ?? line.text
        guard !launching.contains(line.id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        launching.insert(line.id)
        if editing == line.id { focused = nil; editing = nil }
        Task {
            if await model.launchPlanLine(line, text: text) { drafts[line.id] = nil }
            launching.remove(line.id)
        }
    }

    private func choose(_ task: FaciendaTask) {
        // A task with a chat but no choices opens it; one not started yet has no chat, so it gets the choices instead.
        if !model.offersChoices(task), model.canOpen(task) { model.open(task); return }
        model.noteOpened(task); choosing = task.id
    }

    // MARK: Moving

    private func dragChanged(_ key: String, _ value: DragGesture.Value) {
        if drag == nil {
            if let focused { commit(focused) }
            focused = nil; editing = nil; choosing = nil
            let entries = visibleEntries
            let ids = entries.map(\.line.id)
            let depths = Dictionary(entries.map { ($0.line.id, $0.depth) }, uniquingKeysWith: { first, _ in first })
            if key.hasPrefix(Self.loosePrefix) {
                drag = RowDrag(root: key, block: [key], others: ids, frames: frames.rows, depths: depths, rootDepth: 0, origin: nil, target: nil, depth: 0)
            } else {
                guard let index = entries.firstIndex(where: { $0.line.id == key }) else { return }
                let depth = entries[index].depth
                // The lines under it travel with it; folded ones are already out of sight and follow anyway.
                let block = [key] + entries[(index + 1)...].prefix { $0.depth > depth }.map(\.line.id)
                drag = RowDrag(root: key, block: block, others: ids.filter { !block.contains($0) }, frames: frames.rows, depths: depths,
                               rootDepth: depth, origin: index, target: index, depth: depth)
            }
        }
        guard var current = drag else { return }
        current.translation = value.translation
        drag = current
        let landing = landing(for: current)
        guard landing.target != current.target || landing.depth != current.depth else { return }
        // One soft tick for each place passed, like cards crossing columns on the board.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(Motion.move) { drag?.target = landing.target; drag?.depth = landing.depth }
    }

    private func dragEnded(_ key: String, _ value: DragGesture.Value) {
        guard let current = drag, let group else { drag = nil; return }
        let landing = landing(for: current)
        let moved = current.loose ? landing.target != nil : (landing.target != current.origin || landing.depth != current.rootDepth)
        // A click that wobbled a little is still a click.
        if !moved, hypot(value.translation.width, value.translation.height) < 12 {
            drag = nil
            tap(key)
            return
        }
        // The lifted row glides from the pointer into its new place as the outline settles.
        withAnimation(Motion.move) {
            if moved, let target = landing.target {
                let drop = PlanOutline.drop(others: current.others.map { (id: $0, depth: current.depths[$0] ?? 0) }, target: target, wantedDepth: landing.depth)
                if current.loose {
                    model.adoptIntoPlan(String(current.root.dropFirst(Self.loosePrefix.count)), group: group.id, parentId: drop.parent, before: drop.before)
                } else {
                    model.placePlanLine(current.root, parentId: drop.parent, before: drop.before)
                }
            }
            drag = nil
        }
        if moved { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    }

    /// What a plain click on a row does: open a line for typing, or a task's choices.
    private func tap(_ key: String) {
        if key.hasPrefix(Self.loosePrefix) {
            if let task = tasksByID[String(key.dropFirst(Self.loosePrefix.count))] { choose(task) }
        } else if let line = lines.first(where: { $0.id == key }) {
            if let id = line.launchedTaskId, let task = tasksByID[id] { choose(task) } else if line.launchedTaskId == nil { edit(line.id) }
        }
    }

    /// The top of the plan's first row, or of New line when the plan is empty.
    private func planTop(_ drag: RowDrag) -> CGFloat {
        drag.others.compactMap { drag.frames[$0]?.minY }.min()
            ?? (drag.loose ? nil : drag.frames[drag.root]?.minY)
            ?? drag.frames[Self.newLineKey]?.minY ?? 0
    }

    /// Where the lifted row would land: its place among the plan's other lines and how deep it would sit.
    /// Up and down picks the place; sideways tucks it under the line above or brings it back out.
    /// A task from below the plan stays below it until it is dragged up past New line.
    private func landing(for drag: RowDrag) -> (target: Int?, depth: Int) {
        guard let start = drag.frames[drag.root] else { return (drag.target, drag.depth) }
        let blockHeight = drag.block.compactMap { drag.frames[$0]?.height }.reduce(0, +)
        let centre = start.minY + drag.translation.height + min(blockHeight, start.height) / 2
        // The plan's other lines as they sit on screen right now, with a gap where the lifted row currently is.
        var y = planTop(drag), target = 0
        for (index, id) in drag.others.enumerated() {
            if index == drag.target { y += blockHeight }
            let height = drag.frames[id]?.height ?? 0
            if y + height / 2 < centre { target = index + 1 }
            y += height
        }
        if drag.target == drag.others.count { y += blockHeight }
        if drag.loose, centre > y + (drag.frames[Self.newLineKey]?.height ?? 0) / 2 { return (nil, 0) }
        let wanted = drag.rootDepth + Int((drag.translation.width / Self.indent).rounded())
        let others = drag.others.map { (id: $0, depth: drag.depths[$0] ?? 0) }
        return (target, PlanOutline.drop(others: others, target: target, wantedDepth: wanted).depth)
    }

    /// How far the lifted row sits from its slot, so it stays under the pointer while the slot moves.
    private var liftOffset: CGFloat {
        guard let drag, let start = drag.frames[drag.root] else { return 0 }
        guard let target = drag.target else { return drag.translation.height }
        let above = drag.others.prefix(target).compactMap { drag.frames[$0]?.height }.reduce(0, +)
        return start.minY + drag.translation.height - (planTop(drag) + above)
    }

    private static func short(_ text: String) -> String { text.count > 60 ? String(text.prefix(60)) + "…" : text }
}
