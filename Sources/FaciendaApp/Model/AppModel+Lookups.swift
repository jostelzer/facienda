import Foundation
import FaciendaCore

extension AppModel {
    /// Lookups and lists derived from the loaded state, built on first use after any of it changes.
    /// Each board row asks for its status, section and subtitle several times per frame; scanning every
    /// dispatch, blocker and link for each made the board slow to redraw.
    struct Derived {
        var dispatches: [String: [NativeDispatch]]?
        var blockers: [String: [TaskBlocker]]?
        var decisions: [String: [Decision]]?
        var links: [String: [ThreadLink]]?
        var checkPlans: [String: [CheckPlan]]?
        var libraryTasks: [String: FaciendaTask]?
        var tasks: [String: FaciendaTask]?
        var search: (query: String, ids: Set<String>)?
        var board: [String?: [FaciendaTask]]?
    }
    /// The dashboard shows open work and what was finished in the last three days. A search also reaches older finished tasks.
    func boardTasks(in groupID: String?) -> [FaciendaTask] { boardLists[groupID] ?? [] }
    // Each reads its source before the cache, so a view that asks through it still follows that source.
    private var dispatchesByTask: [String: [NativeDispatch]] { cached(\.dispatches, from: nativeDispatches) { Dictionary(grouping: $0, by: \.taskId) } }
    var checkPlansByTask: [String: [CheckPlan]] { cached(\.checkPlans, from: checkPlans) { Dictionary(grouping: $0, by: \.taskId) } }
    private var blockersByTask: [String: [TaskBlocker]] { cached(\.blockers, from: blockers) { Dictionary(grouping: $0, by: \.taskId) } }
    private var decisionsByTask: [String: [Decision]] { cached(\.decisions, from: decisions) { Dictionary(grouping: $0, by: \.taskId) } }
    private var linksByTask: [String: [ThreadLink]] { cached(\.links, from: links) { Dictionary(grouping: $0, by: \.taskId) } }
    private var libraryTasksByID: [String: FaciendaTask] { cached(\.libraryTasks, from: libraryTasks, Self.byID) }
    /// This workspace's tasks by ID.
    var tasksByID: [String: FaciendaTask] { cached(\.tasks, from: tasks, Self.byID) }

    /// The value derived from `source`, built once until the state it came from changes.
    private func cached<Source, Value>(_ slot: WritableKeyPath<Derived, Value?>, from source: Source, _ build: (Source) -> Value) -> Value {
        if let value = derived[keyPath: slot] { return value }
        let value = build(source)
        derived[keyPath: slot] = value
        return value
    }
    private static func byID(_ tasks: [FaciendaTask]) -> [String: FaciendaTask] {
        Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    func dispatches(for taskID: String) -> [NativeDispatch] { dispatchesByTask[taskID] ?? [] }
    func checkPlan(for taskID: String) -> CheckPlan? { checkPlansByTask[taskID]?.first }
    func blockers(of taskID: String) -> [TaskBlocker] { blockersByTask[taskID] ?? [] }
    func decisions(for taskID: String) -> [Decision] { decisionsByTask[taskID] ?? [] }
    func links(for taskID: String) -> [ThreadLink] { linksByTask[taskID] ?? [] }
    /// Any task in the library, for prerequisites and waits that name one in another workspace.
    func libraryTask(_ id: String) -> FaciendaTask? { libraryTasksByID[id] }
    func isMet(_ blocker: TaskBlocker) -> Bool {
        blocker.kind == "task" ? blocker.prerequisiteId.flatMap(libraryTask)?.state == .done : blocker.isMet(tasks: [])
    }

    /// The IDs of the tasks matching every word of the search that counts, read once per query. Nil without a search.
    var searchMatches: Set<String>? {
        let query = search
        _ = tasks; _ = links
        guard !query.isEmpty else { return nil }
        if let cached = derived.search, cached.query == query { return cached.ids }
        let ids = Set((try? store.lookUpTasks(query))?.filter(\.complete).map(\.task.id) ?? [])
        derived.search = (query, ids)
        return ids
    }

    /// When a task in the group last changed, finished ones included; nil holds the ungrouped ones, like the board.
    func lastActive(in groupID: String?) -> Date? {
        let known = Set(groups.map(\.id)), members = groupMembers
        return tasks.filter { members[$0.id].flatMap { known.contains($0) ? $0 : nil } == groupID }.map(\.updatedAt).max()
    }

    /// Where a task sits in its card: where the user put it, or by when it was made, newest first.
    func boardKey(_ task: FaciendaTask) -> Double { taskPlaces[task.id] ?? TaskBoardPlace.unplaced(task) }

    /// The board's tasks for every group at once, keyed by group ID; nil holds the ungrouped ones.
    /// Each card keeps the user's order: a task's state or activity never moves it.
    var boardLists: [String?: [FaciendaTask]] {
        let tasks = tasks, groups = groups, members = groupMembers, found = searchMatches
        _ = taskPlaces
        if let board = derived.board { return board }
        let known = Set(groups.map(\.id))
        let recent = Date().addingTimeInterval(-3 * 86400)
        var lists: [String?: [(task: FaciendaTask, key: Double)]] = [:]
        for task in tasks {
            if let found { guard found.contains(task.id), task.state != .dropped else { continue } }
            else { guard task.state.isOpen || (task.state == .done && task.updatedAt > recent) else { continue } }
            lists[members[task.id].flatMap { known.contains($0) ? $0 : nil }, default: []].append((task, boardKey(task)))
        }
        let board = lists.mapValues { list in
            list.sorted { $0.key != $1.key ? $0.key < $1.key : $0.task.id < $1.task.id }.map(\.task)
        }
        derived.board = board
        return board
    }
}
