import SwiftUI
import FaciendaCore

/// Goals: the window's other side. The island and the board show work by where it lives; Goals shows it by what it is
/// for: a map of the few goals, each a painted circle with its subgoals around it, and a ledger of what was reached.
/// A subgoal holds minigoals: lines in the user's words, each a box that holds the work toward it, tasks that start
/// wherever they belong. Board work that seems to fit a minigoal is shown in its box until the user keeps it or sends
/// it away. A minigoal never becomes a task itself.
/// It belongs to the window, as the bar does, since goals span every workspace.
@MainActor @Observable final class GoalsModel {
    @ObservationIgnored weak var workspaces: WorkspaceController?
    private(set) var goals: [Goal] = []
    private(set) var items: [GoalItem] = []
    /// Every workspace's groups, for choosing where a subgoal's lines start.
    private(set) var groups: [TaskGroup] = []
    /// Goals is open in place of the island and the board. A line waiting in the bar is let go when Goals closes, so
    /// the bar never starts work toward something out of sight.
    private(set) var isOpen = false { didSet { if !isOpen, aim != nil { aim = nil } } }
    /// Goals whose subgoals are out on their orbit, named. The rest sit folded, their subgoals only beads on the rim.
    private(set) var unfolded: Set<String> = []
    /// Subgoals whose minigoals hang open under their dot on the map.
    private(set) var opened: Set<String> = []
    /// With Today open everything is out for picking, except the goals and subgoals folded away by hand there.
    private(set) var foldedToday: Set<String> = []
    /// The box open beside its line on the map.
    private(set) var openBox: OpenBox?
    /// Where planned lines might start, by line, with the words they were worked out for.
    private(set) var suggestions: [String: (text: String, places: [BarPlace])] = [:]
    /// A goal or subgoal whose name is being written.
    var renaming: String?
    /// The task's picture, in the window's space, that the board grows out of and shrinks back into. Nil when the
    /// window turns the usual way, sliding.
    private(set) var boardOrigin: CGRect?
    /// The subgoal a task's picture opened the board from, for the way back in the bar.
    private(set) var cameFrom: Goal?
    /// The boards of the workspaces that goals' work lives in, which a task's choices act through.
    private(set) var boards: [String: AppModel] = [:]
    /// Lines being started as tasks right now.
    private(set) var launching: Set<String> = []
    /// Board work on no goal yet that seems to belong to a line or a subgoal. Only shown; the user keeps it or not.
    private(set) var guesses: [GoalGuess] = []
    @ObservationIgnored private var guessedAt = Date.distantPast
    @ObservationIgnored private var suggesting: Task<Void, Never>?
    @ObservationIgnored private var boarding: Task<Void, Never>?
    /// The line the bar is taking detail for. Return there starts a task toward it.
    var aim: Aim?
    /// Today is open beside the map: every subgoal's minigoals hang out, a click picks one for the day, and the list
    /// on the right holds what was picked. Kept between launches, since the day is usually planned the same way.
    private(set) var today = UserDefaults.standard.bool(forKey: GoalsModel.todayKey)
    /// The lines on today's list that serve no goal.
    private(set) var todayLines: [TodayLine] = []
    /// The day whose morning has already been cleared of what was done before it.
    @ObservationIgnored private var cleared: Date?
    private static let todayKey = "goalsToday"
    /// What was reached shows, faint, on the map and on today's list. Off, both hold only what is still open. The
    /// Reached button is the switch.
    private(set) var showReached = UserDefaults.standard.bool(forKey: GoalsModel.reachedKey)
    private static let reachedKey = "goalsShowReached"
    /// Goals whose picture is being painted.
    private(set) var painting: Set<String> = []
    @ObservationIgnored private var paintFailures: Set<String> = []
    @ObservationIgnored private var covers: [String: (stamp: Date?, image: NSImage?, colour: NSColor?)] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?

    /// A box on the map: a minigoal's, or, with no line, the work on its subgoal alone.
    struct OpenBox: Hashable {
        var subgoalID: String
        var lineID: String?
    }

    /// One of a subgoal's lines on the map: a minigoal, or the work on the subgoal alone, with what its box holds.
    struct Leaf: Identifiable, Equatable {
        var box: OpenBox
        /// The minigoal; nil for the work on no minigoal.
        var entry: Entry?
        var work: [GoalItem]
        /// Board work found for it.
        var found: Int
        var id: String { box.lineID ?? "loose:" + box.subgoalID }
        var isDone: Bool { entry?.isDone ?? false }
        var finished: Int { work.filter { $0.task.map { !$0.state.isOpen } ?? false }.count }
        var isNew: Bool { work.contains(where: \.isNew) }
    }

    /// A line put in the bar to start work toward it: its words, and where that work starts.
    struct Aim: Equatable {
        var lineID: String
        var text: String
        var place: BarPlace
    }

    /// A line of a subgoal with the work it holds.
    struct Entry: Identifiable, Equatable {
        var line: GoalItem
        var work: [GoalItem] = []
        var id: String { line.id }
        /// Ticked by hand, on today's list or from its menu.
        var isTicked: Bool { line.line.tickedAt != nil }
        var isPicked: Bool { line.line.pickedAt != nil }
        /// Only written so far: no task of its own, none under it, and not ticked.
        var isPlanned: Bool { line.task == nil && work.isEmpty && !isTicked }
        var finished: Int { work.filter { $0.task.map { !$0.state.isOpen } ?? false }.count }
        /// All it stands for is finished: its work is, or the user ticked it by hand.
        var isDone: Bool { isTicked || (!isPlanned && (line.task.map { !$0.state.isOpen } ?? true) && finished == work.count) }
        /// A line the user wrote, rather than a task on the subgoal alone.
        var isMinigoal: Bool { line.task == nil }
    }

    /// A subgoal's card as boxes: each open minigoal with its work, the work on the subgoal alone, and the minigoals
    /// whose work is all done, for the foot.
    struct Boxes: Equatable {
        var open: [Entry] = []
        var loose: [GoalItem] = []
        var done: [Entry] = []
        var minigoals: [Entry] { open + done }
    }

    /// One row of today's list: a minigoal picked on the map, or a line that serves no goal.
    struct TodayRow: Identifiable, Equatable {
        var id: String
        var text: String
        /// The minigoal on the map; nil for a line with no goal.
        var entry: Entry?
        var isTicked: Bool
        var isDone: Bool { isTicked || entry?.isDone == true }
        /// Work toward it came back and has not been looked at.
        var isNew: Bool { entry?.work.contains(where: \.isNew) ?? false }
    }

    /// The rows under one heading of today's list: a goal's, or those with no goal.
    struct TodaySection: Identifiable, Equatable {
        var goal: Goal?
        var rows: [TodayRow]
        var id: String { goal?.id ?? "none" }
    }

    /// Reads the library every few seconds while Goals is open: the tasks that serve a goal change state on their own.
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isOpen == true { self?.load() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func load() {
        guard let library = workspaces?.library else { return }
        do {
            // The first read of a day lets go of what was picked and done before it began.
            let day = Calendar.current.startOfDay(for: Date())
            if cleared != day { try library.clearToday(before: day); cleared = day }
            let goals = try library.goals(), items = try library.goalItems(), groups = try library.groups(), own = try library.todayLines()
            if own != todayLines { todayLines = own }
            if goals != self.goals { self.goals = goals }
            if items != self.items { self.items = items }
            if groups != self.groups { self.groups = groups }
            prune()
            // Guessing reads the words of every recent task, so it runs on opening, after a change, and now and then.
            if Date().timeIntervalSince(guessedAt) >= Self.guessEvery {
                guessedAt = Date()
                let guesses = try library.goalGuesses()
                if guesses != self.guesses { self.guesses = guesses }
            }
        } catch { workspaces?.error = error.localizedDescription }
        keepBoards()
        suggest()
        paintMissingCovers()
    }

    /// Each workspace the work lives in keeps its board ready, as one the bar sends work to does. A board takes a while
    /// to make, so the first ones are made once Goals has come in, not while it is coming.
    private func keepBoards() {
        let missing = Set(items.compactMap { $0.task?.workspaceId ?? $0.line.workspaceId }).filter { boards[$0] == nil }
        guard !missing.isEmpty, boarding == nil else { return }
        boarding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard let self else { return }
            for id in missing where boards[id] == nil {
                if let model = workspaces?.model(for: id) { boards[id] = model }
            }
            boarding = nil
        }
    }

    /// Works out suggestions for planned lines that have no place yet, once per wording. Each one searches the board's
    /// work, which takes long enough to hold up the window, so they are worked out away from it and come in after.
    private func suggest() {
        guard suggesting == nil, let library = workspaces?.library else { return }
        let wanted = items.filter { $0.task == nil && $0.line.workspaceId == nil && suggestions[$0.line.id]?.text != $0.line.text }
            .map { (id: $0.line.id, text: $0.line.text) }
        guard !wanted.isEmpty else { return }
        suggesting = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                wanted.map { (id: $0.id, text: $0.text, places: (try? library.suggestedPlaces(for: $0.id)) ?? []) }
            }.value
            guard let self else { return }
            for line in found { suggestions[line.id] = (line.text, line.places) }
            suggesting = nil
        }
    }

    /// The best place for a planned line: the one chosen, else the first suggestion.
    func place(of item: GoalItem) -> (place: BarPlace, chosen: Bool)? {
        if let workspaceID = item.line.workspaceId, let workspace = workspaces?.workspaces.first(where: { $0.id == workspaceID }) {
            let group = group(item.line.groupId)
            return (BarPlace(workspaceID: workspaceID, workspaceName: workspace.name, groupID: group?.id, groupName: group?.name), true)
        }
        return suggestions[item.line.id]?.places.first.map { ($0, false) }
    }
    func suggestedPlaces(_ item: GoalItem) -> [BarPlace] { suggestions[item.line.id]?.places ?? [] }

    func toggle() { isOpen ? close() : open() }

    private static let guessEvery: TimeInterval = 20

    func open() {
        guessedAt = .distantPast
        load()
        workspaces?.feed.close()
        cameFrom = nil
        settle(origin: nil)
        isOpen = true
    }

    func close() {
        guard boardOrigin != nil else { isOpen = false; return }
        // Turned from a miniature before: slide the usual way this time.
        settle(origin: nil)
        DispatchQueue.main.async { self.isOpen = false }
    }

    /// Opens a workspace's board by growing it out of its miniature beside a subgoal. The way back in the bar shrinks it
    /// back in, with the subgoal still close.
    /// Turns to the board on a line's row: its workspace opens, the board grows out of the picture that was clicked,
    /// and the row lights on its card. A planned line with only a suggested place lands on that group's card.
    func land(_ item: GoalItem, from frame: CGRect, subgoal: Goal) {
        guard let workspaces, let target = item.task?.workspaceId ?? place(of: item)?.place.workspaceID else { return }
        if let home = workspaces.workspaces.first(where: { $0.id == target }), home.id != workspaces.current?.id {
            guard workspaces.open(home) else { return }
        }
        if let model = workspaces.model {
            UserDefaults.standard.set("board", forKey: "dashboardMode")
            model.search = ""; model.destination = .dashboard
            model.boardLandRequest = item.task?.id ?? item.line.planLineId.map(AppModel.plannedRowKey) ?? place(of: item)?.place.groupID
        }
        // The board waits, unseen, over the picture, and grows from there a moment later.
        settle(origin: frame)
        cameFrom = subgoal
        DispatchQueue.main.async { self.isOpen = false }
    }
    /// Back from the board to the map, with the minigoals of the subgoal it was opened from hanging open.
    func returnToSubgoal() {
        guard let sub = cameFrom else { return }
        load()
        workspaces?.feed.close()
        cameFrom = nil
        if let parent = sub.parentId { unfolded.insert(parent) }
        opened.insert(sub.id)
        isOpen = true
    }

    private func settle(origin: CGRect?) {
        guard boardOrigin != origin else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { boardOrigin = origin }
    }

    // MARK: Reading

    var openGoals: [Goal] { goals.filter { $0.parentId == nil && $0.reachedAt == nil } }
    func goal(_ id: String?) -> Goal? { goals.first { $0.id == id } }
    /// A goal's subgoals still open, in their order. Reached ones are in the ledger.
    func subgoals(of goalID: String) -> [Goal] { goals.filter { $0.parentId == goalID && $0.reachedAt == nil } }
    func items(of subgoalID: String) -> [GoalItem] { items.filter { $0.line.subgoalId == subgoalID } }
    /// A subgoal's lines, each with the work under it. The library hands work over right after its line.
    func entries(of subgoalID: String) -> [Entry] {
        var entries: [Entry] = []
        for item in items(of: subgoalID) {
            if let parent = item.line.parentLineId, let last = entries.indices.last, entries[last].id == parent { entries[last].work.append(item) }
            else { entries.append(Entry(line: item)) }
        }
        return entries
    }
    /// Open work first, then what is finished, each in the order it came.
    func boxes(of subgoalID: String) -> Boxes {
        func order(_ items: [GoalItem]) -> [GoalItem] { items.filter { $0.task?.state.isOpen != false } + items.filter { $0.task?.state.isOpen == false } }
        var boxes = Boxes()
        for var entry in entries(of: subgoalID) {
            guard entry.isMinigoal else { boxes.loose += [entry.line] + entry.work; continue }
            entry.work = order(entry.work)
            if entry.isDone { boxes.done.append(entry) } else { boxes.open.append(entry) }
        }
        boxes.loose = order(boxes.loose)
        return boxes
    }
    /// A subgoal's lines on the map, in the order of its boxes: open minigoals, the work on no minigoal when there is
    /// any or some was found, then finished minigoals.
    func leaves(of subgoalID: String) -> [Leaf] {
        let boxes = boxes(of: subgoalID), loose = guesses(subgoal: subgoalID).count
        func leaf(_ entry: Entry) -> Leaf {
            Leaf(box: OpenBox(subgoalID: subgoalID, lineID: entry.id), entry: entry, work: entry.work, found: guesses(line: entry.id).count)
        }
        // Finished minigoals only while Reached is on.
        let done = showReached ? boxes.done.map(leaf) : []
        // With Today open the map shows what can be picked.
        if today { return boxes.open.map(leaf) + done }
        let none = boxes.loose.isEmpty && loose == 0 ? [] : [Leaf(box: OpenBox(subgoalID: subgoalID, lineID: nil), work: boxes.loose, found: loose)]
        return boxes.open.map(leaf) + none + done
    }
    /// Whether a subgoal's minigoals hang under its dot: opened by hand, or while Today is open, unless folded there.
    func hangs(_ subgoalID: String) -> Bool { today ? !foldedToday.contains(subgoalID) : opened.contains(subgoalID) }
    /// Whether a goal's subgoals are out on its orbit: unfolded by hand, or while Today is open, unless folded there.
    func spreads(_ goalID: String) -> Bool { today ? !foldedToday.contains(goalID) : unfolded.contains(goalID) }
    /// Today's list: what was picked, under the goal it serves, goals in the map's order and rows in the order they
    /// were picked, done ones at the foot while Reached is on. Lines with no goal come last; their heading always shows,
    /// since that is where they are written.
    var todaySections: [TodaySection] {
        func sunk(_ rows: [TodayRow]) -> [TodayRow] { rows.filter { !$0.isDone } + (showReached ? rows.filter(\.isDone) : []) }
        var sections = openGoals.compactMap { goal -> TodaySection? in
            let picked = subgoals(of: goal.id).flatMap { entries(of: $0.id) }.filter { $0.isMinigoal && $0.isPicked }
                .sorted { ($0.line.line.pickedAt ?? .distantPast) < ($1.line.line.pickedAt ?? .distantPast) }
            return picked.isEmpty ? nil : TodaySection(goal: goal, rows: sunk(picked.map { TodayRow(id: $0.id, text: $0.line.line.text, entry: $0, isTicked: $0.isTicked) }))
        }
        sections.append(TodaySection(goal: nil, rows: sunk(todayLines.map { TodayRow(id: $0.id, text: $0.text, entry: nil, isTicked: $0.tickedAt != nil) })))
        return sections
    }
    /// Board work that seems to belong under a line, or to a subgoal without fitting any of its lines.
    func guesses(line id: String) -> [GoalGuess] { guesses.filter { $0.lineId == id } }
    func guesses(subgoal id: String) -> [GoalGuess] { guesses.filter { $0.subgoalId == id && $0.lineId == nil } }
    func found(subgoal id: String) -> Int { guesses.filter { $0.subgoalId == id }.count }
    func group(_ id: String?) -> TaskGroup? { groups.first { $0.id == id } }

    private static let week: TimeInterval = 7 * 86400
    /// How much moved this week: lines written and tasks that changed in the last seven days.
    func moved(subgoal id: String, now: Date = Date()) -> Int {
        items(of: id).filter { item in
            now.timeIntervalSince(item.task?.updatedAt ?? item.line.updatedAt) < Self.week || now.timeIntervalSince(item.line.createdAt) < Self.week
        }.count
    }
    func moved(goal id: String, now: Date = Date()) -> Int { subgoals(of: id).reduce(0) { $0 + moved(subgoal: $1.id, now: now) } }
    /// Whole weeks since anything under the goal last moved, once it has been a week. Nil while it is moving or empty.
    func quietWeeks(goal id: String, now: Date = Date()) -> Int? {
        let subs = Set(goals.filter { $0.parentId == id }.map(\.id))
        guard let last = items.filter({ subs.contains($0.line.subgoalId) }).map({ max($0.task?.updatedAt ?? .distantPast, $0.line.updatedAt) }).max() else { return nil }
        let weeks = Int(now.timeIntervalSince(last) / Self.week)
        return weeks >= 1 ? weeks : nil
    }
    func hasNew(subgoal id: String) -> Bool { items(of: id).contains(where: \.isNew) }

    /// The workspaces a goal draws on, where its tasks live, in the island's order.
    func workspaceIDs(goal id: String) -> [String] { workspaceIDs(subgoals: goals.filter { $0.parentId == id }.map(\.id)) }
    func workspaceIDs(subgoals: [String]) -> [String] {
        let subs = Set(subgoals)
        let ids = Set(items.filter { subs.contains($0.line.subgoalId) }.compactMap(\.task?.workspaceId))
        let order = workspaces?.ordered.map(\.id) ?? []
        return order.filter(ids.contains) + ids.subtracting(order).sorted()
    }


    /// One line of the ledger: a subgoal or a whole goal the user said was reached.
    struct LedgerEntry: Identifiable, Equatable {
        var goal: Goal
        /// The goal a subgoal served; nil for a goal.
        var parent: Goal?
        var tasks: Int
        var weeks: Int
        var workspaceIDs: [String]
        var id: String { goal.id }
        var reachedAt: Date { goal.reachedAt ?? .distantPast }
    }

    /// Everything reached, newest first. A reached goal counts the work of all its subgoals.
    var ledger: [LedgerEntry] {
        goals.filter { $0.reachedAt != nil }.map { goal in
            let subs = goal.parentId == nil ? goals.filter { $0.parentId == goal.id }.map(\.id) : [goal.id]
            let count = items.filter { subs.contains($0.line.subgoalId) && $0.task != nil }.count
            let span = (goal.reachedAt ?? goal.createdAt).timeIntervalSince(goal.createdAt)
            return LedgerEntry(goal: goal, parent: self.goal(goal.parentId), tasks: count, weeks: max(1, Int((span / Self.week).rounded(.up))),
                               workspaceIDs: workspaceIDs(subgoals: subs))
        }.sorted { $0.reachedAt > $1.reachedAt }
    }

    // MARK: Opening

    /// A subgoal's minigoals hang under its dot, or fold away again with their open box. Nothing zooms: the map stays.
    func toggle(subgoal id: String, reduceMotion: Bool) {
        withAnimation(reduceMotion ? Motion.fade : Motion.move) {
            if today {
                if foldedToday.contains(id) { foldedToday.remove(id) } else { foldedToday.insert(id) }
            } else if opened.contains(id) { opened.remove(id) } else {
                opened.insert(id)
                if let parent = goal(id)?.parentId { unfolded.insert(parent) }
            }
            prune()
        }
    }

    /// A goal sends its subgoals out onto its orbit, or folds them back to beads on its rim with their minigoals.
    func toggle(goal id: String, reduceMotion: Bool) {
        withAnimation(reduceMotion ? Motion.fade : Motion.move) {
            if today {
                // Out again with Today open, all its minigoals are out for picking too.
                if foldedToday.contains(id) { foldedToday.subtract([id] + subgoals(of: id).map(\.id)) } else { foldedToday.insert(id) }
            } else if unfolded.contains(id) {
                unfolded.remove(id)
                opened.subtract(subgoals(of: id).map(\.id))
            } else { unfolded.insert(id) }
            prune()
        }
    }

    /// A minigoal's box opens beside its line, in place of any other; a second click closes it.
    func toggle(box: OpenBox, reduceMotion: Bool) {
        withAnimation(reduceMotion ? Motion.fade : Motion.move) {
            opened.insert(box.subgoalID)
            if let parent = goal(box.subgoalID)?.parentId { unfolded.insert(parent) }
            openBox = openBox == box ? nil : box
        }
    }

    /// A click on the empty map closes the open box, in place.
    func closeBox() {
        guard openBox != nil else { return }
        withAnimation(Motion.fade) { openBox = nil }
    }

    /// Esc folds one step at a time: the open box, then every open subgoal, then every goal, then turns back to the
    /// board. With Today open Esc turns straight back, and Today is there again next time.
    func back(reduceMotion: Bool) {
        if today { close() }
        else if openBox != nil { withAnimation(reduceMotion ? Motion.fade : Motion.move) { openBox = nil } }
        else if !opened.isEmpty { withAnimation(reduceMotion ? Motion.fade : Motion.move) { opened.removeAll() } }
        else if !unfolded.isEmpty { withAnimation(reduceMotion ? Motion.fade : Motion.move) { unfolded.removeAll() } }
        else { close() }
    }

    /// Shows what was reached, faint, or hides it, on the map and on today's list together.
    func setShowReached(_ on: Bool, reduceMotion: Bool) {
        guard showReached != on else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.move) {
            showReached = on
            // A box left open on a minigoal that is now hidden would hang from nothing.
            if let box = openBox, !leaves(of: box.subgoalID).contains(where: { $0.box == box }) { openBox = nil }
        }
        UserDefaults.standard.set(on, forKey: Self.reachedKey)
    }

    /// Today slides in beside the map, or away again. A box left open would sit under lines that now pick, so it closes.
    func setToday(_ on: Bool, reduceMotion: Bool) {
        guard today != on else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.travel) {
            today = on
            if on { openBox = nil }
        }
        UserDefaults.standard.set(on, forKey: Self.todayKey)
    }

    /// Lets go of what is no longer on the map: a subgoal reached or deleted, a box whose line is gone or empty.
    private func prune() {
        let open = Set(goals.filter { $0.parentId != nil && $0.reachedAt == nil }.map(\.id))
        if !opened.isSubset(of: open) { opened.formIntersection(open) }
        let tops = Set(goals.filter { $0.parentId == nil && $0.reachedAt == nil }.map(\.id))
        if !unfolded.isSubset(of: tops) { unfolded.formIntersection(tops) }
        if !foldedToday.isSubset(of: open.union(tops)) { foldedToday.formIntersection(open.union(tops)) }
        if let box = openBox, !opened.contains(box.subgoalID) || !leaves(of: box.subgoalID).contains(where: { $0.box == box }) { openBox = nil }
    }

    // MARK: Changing

    private func change(guessAgain: Bool = true, _ body: (FaciendaStore) throws -> Void) {
        guard let library = workspaces?.library else { return }
        do { try body(library) } catch { workspaces?.error = error.localizedDescription }
        // What was linked, written or removed changes what is left to guess. Picking and ticking do not.
        if guessAgain { guessedAt = .distantPast }
        load()
    }

    func newGoal(_ text: String) { change { try $0.addGoal(text) } }
    /// A new subgoal comes out on its goal's orbit, with its siblings.
    func newSubgoal(_ text: String, in goalID: String) {
        unfolded.insert(goalID); foldedToday.remove(goalID)
        change { try $0.addGoal(text, parentId: goalID) }
    }
    /// Writes a subgoal where the user put it, as an offset from its goal. Siblings that still sit where the fan put them
    /// are kept there, so they don't spread out again around the new one.
    func newSubgoal(_ text: String, in goalID: String, at offset: CGSize, keeping places: [String: CGSize]) {
        unfolded.insert(goalID); foldedToday.remove(goalID)
        change { library in
            for (id, place) in places { try library.placeGoal(id, x: Double(place.width), y: Double(place.height)) }
            let sub = try library.addGoal(text, parentId: goalID)
            try library.placeGoal(sub.id, x: Double(offset.width), y: Double(offset.height))
        }
    }
    func rename(_ id: String, to text: String) { change { try $0.renameGoal(id, to: text) } }
    func place(_ id: String, x: Double, y: Double) { change { try $0.placeGoal(id, x: x, y: y) } }
    func move(subgoal id: String, by step: Int) {
        guard let sub = goal(id), let parent = sub.parentId, let index = subgoals(of: parent).firstIndex(where: { $0.id == id }) else { return }
        change { try $0.moveSubgoal(id, to: index + step) }
    }
    func delete(_ id: String) { change { try $0.deleteGoal(id) } }
    func reach(_ id: String) { change { try $0.setGoalReached(id, at: Date()) } }
    func reopen(_ id: String) { change { try $0.setGoalReached(id, at: nil) } }

    /// Writes a minigoal under a subgoal and hands back its id.
    @discardableResult func addLine(_ text: String, to subgoalID: String, startNow: Bool = false) -> String? {
        var made: GoalLine?
        change {
            // Written on the map, it waits there to be picked like any other, also with Today open.
            made = try $0.addGoalLine(text, to: subgoalID)
        }
        if startNow, let made, let item = items.first(where: { $0.line.id == made.id }) { start(item) }
        return made?.id
    }
    func editLine(_ id: String, text: String) { change { try $0.setGoalLineText(id, text: text) } }
    func removeLine(_ id: String) { change { try $0.deleteGoalLine(id) } }
    /// Moves a minigoal past the next one up or down. Work on the subgoal alone has a box of its own, so it is skipped.
    func moveLine(_ item: GoalItem, by step: Int) {
        let minigoals = entries(of: item.line.subgoalId).filter(\.isMinigoal).map(\.line.line)
        guard let index = minigoals.firstIndex(where: { $0.id == item.line.id }), minigoals.indices.contains(index + step) else { return }
        change { try $0.moveGoalLine(item.line.id, to: item.line.subgoalId, at: minigoals[index + step].position) }
    }
    /// Puts a task in a minigoal's box, or on its subgoal alone: work moved from another box, or board work found for
    /// one and kept where it was dropped.
    func file(task id: String, under lineID: String?, subgoal subgoalID: String) {
        change {
            if let lineID { try $0.serve(taskId: id, lineId: lineID) } else { try $0.serve(taskId: id, subgoalId: subgoalID) }
        }
    }

    // MARK: Today

    /// Puts a minigoal on today's list, or takes it off again.
    func pick(_ item: GoalItem) {
        let picked = item.line.pickedAt != nil
        change(guessAgain: false) { try $0.setGoalLinePicked(item.line.id, !picked) }
    }
    /// Ticks a minigoal by hand, or unticks it. One that is done by its work has nothing to untick.
    func tick(_ item: GoalItem) {
        let ticked = item.line.tickedAt != nil
        change(guessAgain: false) { try $0.setGoalLineTicked(item.line.id, !ticked) }
    }
    func tick(_ row: TodayRow) {
        if let entry = row.entry { if row.isTicked || !row.isDone { tick(entry.line) } }
        else { change(guessAgain: false) { try $0.setTodayLineTicked(row.id, !row.isTicked) } }
    }
    /// Takes a row off today's list. A minigoal stays on the map; a line with no goal lives nowhere else.
    func takeOff(_ row: TodayRow) {
        change(guessAgain: false) { if row.entry != nil { try $0.setGoalLinePicked(row.id, false) } else { try $0.deleteTodayLine(row.id) } }
    }
    /// Writes a line that serves no goal onto today's list.
    func addToday(_ text: String) { change(guessAgain: false) { try $0.addTodayLine(text) } }

    /// Where a planned line will start, or nil to have it suggested again.
    func setPlace(_ item: GoalItem, to place: BarPlace?) {
        change { try $0.setGoalLinePlace(item.line.id, workspaceId: place?.workspaceID, groupId: place?.groupID) }
    }

    /// Starts a task toward a minigoal, named like it: where the minigoal was put, else at `place`, a suggestion the
    /// user took. The minigoal stays as written and holds the task.
    /// `text` is the minigoal's words as just changed, before the change has come back from the library.
    func start(_ item: GoalItem, at place: BarPlace? = nil, text: String? = nil) {
        guard item.task == nil, let target = place ?? self.place(of: item)?.place else { return }
        let aim = Aim(lineID: item.line.id, text: text ?? item.line.text, place: target)
        Task { _ = await start(toward: aim, detail: "", files: [], choice: workspaces?.model(for: target.workspaceID)?.composerModel) }
    }

    /// Puts a line in the bar, which then asks for the detail the line lacks. A place picked here is the line's from
    /// now on; a suggested one is only where this task starts.
    func detail(_ item: GoalItem, at place: BarPlace? = nil) {
        guard item.task == nil, let target = place ?? self.place(of: item)?.place else { return }
        if place != nil { setPlace(item, to: target) }
        aim = Aim(lineID: item.line.id, text: item.line.text, place: target)
        workspaces?.model?.omnibarFocusRequest += 1
    }

    /// Starts work toward the minigoal the bar held, with what was added there; with nothing added, the task is named
    /// like the minigoal. Either way the minigoal stays as written and holds the new task.
    func start(toward aim: Aim, detail: String, files: [URL], choice: TaskModelChoice?) async -> Bool {
        guard let item = items.first(where: { $0.line.id == aim.lineID }), item.task == nil, !launching.contains(aim.lineID),
              let sub = goal(item.line.subgoalId) else { return false }
        guard let model = workspaces?.model(for: aim.place.workspaceID) else {
            workspaces?.error = "That workspace can't start tasks right now."
            return false
        }
        let path = [goal(sub.parentId)?.text, sub.text].compactMap { $0 }.joined(separator: " › ")
        let words = detail.isEmpty ? aim.text : aim.text + "\n\n" + detail
        launching.insert(aim.lineID)
        defer { launching.remove(aim.lineID) }
        // A minigoal placed in a group is also a planned row on that group's card. Started as it is, it starts as that
        // row, the way the board starts it, and the library puts the task in the minigoal's box.
        if detail.isEmpty, files.isEmpty, let id = (try? workspaces?.library?.goalLine(aim.lineID))??.planLineId {
            model.refresh()
            if let row = model.planLines.first(where: { $0.id == id && $0.launchedTaskId == nil && $0.groupId == aim.place.groupID }) {
                let started = await model.launchPlanLine(row, text: aim.text)
                if !started, let error = model.error { workspaces?.error = error; model.error = nil }
                guessedAt = .distantPast
                load()
                return started
            }
        }
        // One start at a time, as for a line started as it is.
        while model.capturing || model.dispatching { try? await Task.sleep(for: .milliseconds(150)) }
        guard await model.capture(title: words, intention: "Part of the goal: " + path, area: "Personal", date: Date(), startNow: true, attachments: files,
                                  groupID: aim.place.groupID, reveal: false, model: choice, nextAction: words), let made = model.lastCaptured else {
            if let error = model.error { workspaces?.error = error; model.error = nil }
            return false
        }
        change { try $0.serve(taskId: made, lineId: aim.lineID) }
        return true
    }

    /// Board work Facienda found for a line or a subgoal becomes that line's, or the subgoal's.
    func keep(_ guess: GoalGuess) {
        change {
            if let line = guess.lineId { try $0.serve(taskId: guess.task.id, lineId: line) }
            else { try $0.serve(taskId: guess.task.id, subgoalId: guess.subgoalId) }
        }
    }
    /// Not for this line or subgoal: it is not offered there again.
    func dismiss(_ guess: GoalGuess) { change { try $0.dismissGoalGuess(taskId: guess.task.id, targetId: guess.targetId) } }

    /// Lets a task stop serving its subgoal. It stays where it lives.
    func unserve(_ item: GoalItem) { change { try $0.deleteGoalLine(item.line.id) } }

    /// Opens a task's chat in Codex or Claude. A task with no chat yet shows where it lives instead.
    func openChat(_ task: FaciendaTask) {
        guard let model = task.workspaceId.flatMap({ workspaces?.model(for: $0) }) else { show(task); return }
        if model.canOpen(task) { model.open(task) } else { show(task) }
    }

    /// Shows a task where it lives: Goals turns back to the island and the board, its workspace comes forward and the
    /// task opens on the board, or in its panel when it is finished.
    func show(_ task: FaciendaTask) {
        guard let workspaces else { return }
        close()
        if let home = workspaces.workspaces.first(where: { $0.id == task.workspaceId }), home.id != workspaces.current?.id {
            guard workspaces.open(home) else { return }
        }
        guard let model = workspaces.model else { return }
        UserDefaults.standard.set("board", forKey: "dashboardMode")
        model.search = ""; model.destination = .dashboard
        if task.state.isOpen { model.boardOpenRequest = task.id } else { model.showTask(task) }
    }

    // MARK: Pictures

    /// A goal's picture, read again only when it was repainted.
    func cover(_ goal: Goal) -> NSImage? { coverEntry(goal).image }
    /// The picture's mean colour: the glow round the open goal, as round the open planet.
    func coverColour(_ goal: Goal) -> NSColor? { coverEntry(goal).colour }

    private func coverEntry(_ goal: Goal) -> (stamp: Date?, image: NSImage?, colour: NSColor?) {
        if let kept = covers[goal.id], kept.stamp == goal.coverPaintedAt { return kept }
        let image = goal.coverPaintedAt == nil ? nil : workspaces?.library.flatMap { NSImage(contentsOf: $0.coverURL(goalId: goal.id)) }
        let entry = (goal.coverPaintedAt, image, image.flatMap(WorkspaceController.meanColour))
        covers[goal.id] = entry
        return entry
    }

    /// Every goal gets a picture once Codex is ready, one at a time. Renaming later never repaints on its own.
    func paintMissingCovers() {
        guard let workspaces, isOpen, !workspaces.demo, workspaces.codex.connected, workspaces.codex.accountReady, painting.isEmpty,
              UserDefaults.standard.object(forKey: "groupCovers") as? Bool ?? true else { return }
        if let next = openGoals.first(where: { $0.coverPaintedAt == nil && !paintFailures.contains($0.id) }) { paint(next, requested: false) }
    }

    /// Paints a goal's picture from its name and subgoals, keeping its style unless a new one is asked for.
    func paint(_ goal: Goal, newStyle: Bool = false, requested: Bool = true) {
        guard let workspaces, !workspaces.demo, let library = workspaces.library, !painting.contains(goal.id) else { return }
        let painter = CodexCoverPainter(subject: .goal), executable = workspaces.codex.executable
        let name = goal.text, contents = subgoals(of: goal.id).map(\.text), style = newStyle ? nil : goal.coverStyle, notes = goal.coverNoteList
        painting.insert(goal.id); paintFailures.remove(goal.id)
        Task {
            do {
                let cover = try await painter.paint(executable: executable, name: name, tasks: contents, style: style, notes: notes)
                try library.saveCover(goalId: goal.id, image: cover.image, style: cover.style)
            } catch {
                paintFailures.insert(goal.id)
                if requested { workspaces.error = error.localizedDescription }
            }
            painting.remove(goal.id)
            load()
        }
    }
}
