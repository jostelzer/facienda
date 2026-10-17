import Foundation
import Testing
@testable import FaciendaCore

private func store() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/plan.sqlite"))
}

private func outline(_ db: FaciendaStore, _ group: String) throws -> [String] {
    PlanOutline(try db.planLines().filter { $0.groupId == group }).entries.map { String(repeating: "  ", count: $0.depth) + $0.line.text }
}

@Test func planLinesNestReorderAndKeepTheirPlaces() throws {
    let db = try store(), group = try db.createGroup(name: "Immersion Demo hub")
    let goal = try db.addPlanLine(groupId: group.id, text: "  Pixelo demo finished ")
    let polish = try db.addPlanLine(groupId: group.id, text: "Final scene polish")
    let record = try db.addPlanLine(groupId: group.id, after: polish.id, text: "Record a take")
    let delta = try db.addPlanLine(groupId: group.id, text: "Delta")
    #expect(try outline(db, group.id) == ["Pixelo demo finished", "Final scene polish", "Record a take", "Delta"])

    // Tab puts a line under the one above it; the second one joins as its last child.
    #expect(try db.indentPlanLine(polish.id))
    #expect(try db.indentPlanLine(record.id))
    #expect(try outline(db, group.id) == ["Pixelo demo finished", "  Final scene polish", "  Record a take", "Delta"])
    // The first line has nothing above it to go under.
    #expect(try db.indentPlanLine(goal.id) == false)

    // A new line right after a child stays among the children.
    let writeUp = try db.addPlanLine(groupId: group.id, parentId: goal.id, after: polish.id, text: "Write-up")
    #expect(try outline(db, group.id) == ["Pixelo demo finished", "  Final scene polish", "  Write-up", "  Record a take", "Delta"])

    #expect(try db.movePlanLine(record.id, by: -1))
    #expect(try outline(db, group.id) == ["Pixelo demo finished", "  Final scene polish", "  Record a take", "  Write-up", "Delta"])
    #expect(try db.movePlanLine(polish.id, by: -1) == false)

    // Shift-Tab brings a line out to sit right after its parent.
    #expect(try db.outdentPlanLine(record.id))
    #expect(try outline(db, group.id) == ["Pixelo demo finished", "  Final scene polish", "  Write-up", "Record a take", "Delta"])
    #expect(try db.outdentPlanLine(delta.id) == false)

    try db.setPlanText(writeUp.id, text: "Short write-up for the site")
    let lines = try db.planLines()
    #expect(lines.first { $0.id == writeUp.id }?.text == "Short write-up for the site")
    // Positions stay dense within each set of siblings.
    for parent in Set(lines.map(\.parentId)) {
        #expect(lines.filter { $0.parentId == parent }.map(\.position).sorted() == Array(0..<lines.filter { $0.parentId == parent }.count))
    }

    let entries = PlanOutline(lines).entries
    #expect(entries.first { $0.line.id == goal.id }?.childIDs.count == 2)
    #expect(PlanOutline(lines).ancestors(of: writeUp.id).map(\.id) == [goal.id])
    #expect(PlanOutline(lines).descendants(of: goal.id).map(\.id) == [polish.id, writeUp.id])
}

@Test func deletingAGoalTakesItsLinesButLeavesTheirTasks() throws {
    let db = try store(), group = try db.createGroup(name: "Orbit Stack")
    let goal = try db.addPlanLine(groupId: group.id, text: "Start the refactor")
    let step = try db.addPlanLine(groupId: group.id, parentId: goal.id, text: "Map module boundaries")
    let task = try db.create(FaciendaTask(title: "Map module boundaries"))
    try db.assignGroup(taskId: task.id, groupId: group.id)
    try db.linkPlanLine(step.id, taskId: task.id)
    #expect(try db.planLines().first { $0.id == step.id }?.launchedTaskId == task.id)
    // A line launches once.
    #expect(throws: StoreError.self) { try db.linkPlanLine(step.id, taskId: task.id) }

    try db.deletePlanLine(goal.id)
    #expect(try db.planLines().isEmpty)
    #expect(try db.task(task.id).title == "Map module boundaries")
    #expect(try db.groupMembers().map(\.taskId) == [task.id])
}

@Test func deletingATaskKeepsTheLineAndDeletingTheGroupTakesThePlan() throws {
    let db = try store(), group = try db.createGroup(name: "Modern GL")
    let line = try db.addPlanLine(groupId: group.id, text: "Shading pass")
    let task = try db.create(FaciendaTask(title: "Shading pass"))
    try db.linkPlanLine(line.id, taskId: task.id)
    try db.deleteTask(task.id)
    // What the user wrote survives; the line can be launched again.
    #expect(try db.planLines().map(\.text) == ["Shading pass"])
    #expect(try db.planLines().first?.launchedTaskId == nil)

    _ = try db.addPlanLine(groupId: group.id, parentId: line.id, text: "Look-dev")
    try db.deleteGroup(group.id)
    #expect(try db.planLines().isEmpty)
}

@Test func plansStayInTheirWorkspace() throws {
    let db = try store(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: home.memorySpaceId)
    let personal = db.scoped(to: home.id), office = db.scoped(to: work.id)
    let trips = try personal.createGroup(name: "Trips"), launch = try office.createGroup(name: "Launch")
    _ = try personal.addPlanLine(groupId: trips.id, text: "Book the train")
    _ = try office.addPlanLine(groupId: launch.id, text: "Draft the announcement")
    #expect(try personal.planLines().map(\.text) == ["Book the train"])
    #expect(try office.planLines().map(\.text) == ["Draft the announcement"])
    #expect(try db.planLines().count == 2)
    // One workspace cannot write into another's group.
    #expect(throws: StoreError.self) { try office.addPlanLine(groupId: trips.id, text: "Sneak in") }
    #expect(throws: StoreError.self) { try personal.addPlanLine(groupId: trips.id, parentId: "missing", text: "Orphan") }
}

@Test func draggingALinePlacesItWithItsStepsAnywhereButUnderItself() throws {
    let db = try store(), group = try db.createGroup(name: "Immersion Demo hub")
    let pixelo = try db.addPlanLine(groupId: group.id, text: "Pixelo demo")
    let take = try db.addPlanLine(groupId: group.id, parentId: pixelo.id, text: "Record a take")
    let delta = try db.addPlanLine(groupId: group.id, text: "Delta")
    let rig = try db.addPlanLine(groupId: group.id, parentId: delta.id, text: "Rig the skeleton")
    let polish = try db.addPlanLine(groupId: group.id, text: "Quality pass")

    // Up to the top, steps and all.
    try db.placePlanLine(delta.id, parentId: nil, before: pixelo.id)
    #expect(try outline(db, group.id) == ["Delta", "  Rig the skeleton", "Pixelo demo", "  Record a take", "Quality pass"])
    // Into another goal, before its first step.
    try db.placePlanLine(polish.id, parentId: pixelo.id, before: take.id)
    #expect(try outline(db, group.id) == ["Delta", "  Rig the skeleton", "Pixelo demo", "  Quality pass", "  Record a take"])
    // Out to the end of the top level.
    try db.placePlanLine(rig.id, parentId: nil, before: nil)
    #expect(try outline(db, group.id) == ["Delta", "Pixelo demo", "  Quality pass", "  Record a take", "Rig the skeleton"])

    #expect(throws: StoreError.self) { try db.placePlanLine(pixelo.id, parentId: take.id, before: nil) }
    #expect(throws: StoreError.self) { try db.placePlanLine(pixelo.id, parentId: pixelo.id, before: nil) }
    #expect(throws: StoreError.self) { try db.placePlanLine(delta.id, parentId: nil, before: take.id) }
    let lines = try db.planLines()
    for parent in Set(lines.map(\.parentId)) {
        #expect(lines.filter { $0.parentId == parent }.map(\.position).sorted() == Array(0..<lines.filter { $0.parentId == parent }.count))
    }
}

/// Drags a line the way the Plan view does: lift it with its lines, land it among the rest, then place it.
private func drag(_ db: FaciendaStore, _ group: String, _ id: String, to target: Int, depth: Int) throws {
    let entries = PlanOutline(try db.planLines().filter { $0.groupId == group }).entries
    let index = try #require(entries.firstIndex { $0.line.id == id })
    let block = [id] + entries[(index + 1)...].prefix { $0.depth > entries[index].depth }.map(\.line.id)
    let others = entries.filter { !block.contains($0.line.id) }.map { (id: $0.line.id, depth: $0.depth) }
    let drop = PlanOutline.drop(others: others, target: target, wantedDepth: depth)
    try db.placePlanLine(id, parentId: drop.parent, before: drop.before)
}

@Test func droppingALineFollowsTheLinesAroundTheGap() throws {
    let db = try store(), group = try db.createGroup(name: "Orbit Stack")
    let refactor = try db.addPlanLine(groupId: group.id, text: "Refactor")
    _ = try db.addPlanLine(groupId: group.id, parentId: refactor.id, text: "Map modules")
    _ = try db.addPlanLine(groupId: group.id, parentId: refactor.id, text: "Render path")
    let docs = try db.addPlanLine(groupId: group.id, text: "Docs")
    let release = try db.addPlanLine(groupId: group.id, text: "Release")

    // Straight up between two steps: it can't stay at the top level there, so it becomes a step.
    try drag(db, group.id, docs.id, to: 2, depth: 0)
    #expect(try outline(db, group.id) == ["Refactor", "  Map modules", "  Docs", "  Render path", "Release"])
    // Dragged left at the end of the goal's steps: back out to the top level, after the goal.
    try drag(db, group.id, docs.id, to: 3, depth: 0)
    #expect(try outline(db, group.id) == ["Refactor", "  Map modules", "  Render path", "Docs", "Release"])
    // Dragged right under "Docs": it becomes Docs' first step.
    try drag(db, group.id, release.id, to: 4, depth: 1)
    #expect(try outline(db, group.id) == ["Refactor", "  Map modules", "  Render path", "Docs", "  Release"])
    // The whole goal with its steps moves to the bottom; it goes no deeper than one under the line above.
    try drag(db, group.id, refactor.id, to: 2, depth: 5)
    #expect(try outline(db, group.id) == ["Docs", "  Release", "    Refactor", "      Map modules", "      Render path"])
    try drag(db, group.id, refactor.id, to: 0, depth: 0)
    #expect(try outline(db, group.id) == ["Refactor", "  Map modules", "  Render path", "Docs", "  Release"])

    #expect(PlanOutline.drop(others: [], target: 3, wantedDepth: 2) == (depth: 0, parent: nil, before: nil))
}

@Test func aTaskFromOutsideThePlanCanBeDraggedIntoItOnce() throws {
    let db = try store(), group = try db.createGroup(name: "Immersion Demo hub")
    let goal = try db.addPlanLine(groupId: group.id, text: "Demo quality")
    let later = try db.addPlanLine(groupId: group.id, text: "Later")
    let task = try db.create(FaciendaTask(title: "Review power controls"))
    try db.assignGroup(taskId: task.id, groupId: group.id)
    let line = try db.adoptIntoPlan(taskId: task.id, groupId: group.id, parentId: goal.id, before: nil)
    #expect(line.launchedTaskId == task.id && line.text == "Review power controls")
    #expect(try outline(db, group.id) == ["Demo quality", "  Review power controls", "Later"])
    #expect(throws: StoreError.self) { try db.adoptIntoPlan(taskId: task.id, groupId: group.id, parentId: nil, before: later.id) }
    // Deleting its line leaves the task where it was.
    try db.deletePlanLine(line.id)
    #expect(try db.task(task.id).title == "Review power controls")
    _ = try db.adoptIntoPlan(taskId: task.id, groupId: group.id, parentId: nil, before: later.id)
    #expect(try outline(db, group.id) == ["Demo quality", "Review power controls", "Later"])
}

@Test func aLineMovesToAnotherGroupsPlanWithItsSteps() throws {
    let db = try store(), trips = try db.createGroup(name: "Trips"), launch = try db.createGroup(name: "Launch")
    let book = try db.addPlanLine(groupId: trips.id, text: "Book the train")
    let pack = try db.addPlanLine(groupId: trips.id, text: "Pack")
    let list = try db.addPlanLine(groupId: trips.id, parentId: pack.id, text: "Write the list")
    let draft = try db.addPlanLine(groupId: launch.id, text: "Draft the announcement")

    // A planned line carried to another card lands just above the line it was dropped before.
    try db.placePlanLine(book.id, groupId: launch.id, parentId: nil, before: draft.id)
    #expect(try outline(db, launch.id) == ["Book the train", "Draft the announcement"])
    #expect(try outline(db, trips.id) == ["Pack", "  Write the list"])
    // A goal takes its steps along, here to the end of the other plan.
    try db.placePlanLine(pack.id, groupId: launch.id, parentId: nil, before: nil)
    #expect(try outline(db, launch.id) == ["Book the train", "Draft the announcement", "Pack", "  Write the list"])
    #expect(try outline(db, trips.id).isEmpty)
    // Naming the group it is already in just moves it within that plan.
    try db.placePlanLine(book.id, groupId: launch.id, parentId: nil, before: nil)
    #expect(try outline(db, launch.id) == ["Draft the announcement", "Pack", "  Write the list", "Book the train"])
    let lines = try db.planLines()
    for parent in Set(lines.map(\.parentId)) {
        #expect(lines.filter { $0.parentId == parent }.map(\.position).sorted() == Array(0..<lines.filter { $0.parentId == parent }.count))
    }

    // It can't go under a line of the plan it isn't joining.
    let home = try db.addPlanLine(groupId: trips.id, text: "Back home")
    #expect(throws: StoreError.self) { try db.placePlanLine(draft.id, groupId: trips.id, parentId: list.id, before: nil) }
    #expect(throws: StoreError.self) { try db.placePlanLine(draft.id, groupId: "missing", parentId: nil, before: nil) }
    #expect(try outline(db, trips.id) == ["Back home"])

    // A started line moves as words only; its task stays in its group.
    let task = try db.create(FaciendaTask(title: "Back home"))
    try db.assignGroup(taskId: task.id, groupId: trips.id)
    try db.linkPlanLine(home.id, taskId: task.id)
    try db.placePlanLine(home.id, groupId: launch.id, parentId: nil, before: nil)
    #expect(try db.planLines().first { $0.id == home.id }?.groupId == launch.id)
    #expect(try db.groupMembers().first { $0.taskId == task.id }?.groupId == trips.id)
}

@Test func aLineMovesOnlyToAGroupInItsWorkspace() throws {
    let db = try store(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: home.memorySpaceId)
    let personal = db.scoped(to: home.id), office = db.scoped(to: work.id)
    let trips = try personal.createGroup(name: "Trips"), launch = try office.createGroup(name: "Launch")
    let train = try personal.addPlanLine(groupId: trips.id, text: "Book the train")
    #expect(throws: StoreError.self) { try personal.placePlanLine(train.id, groupId: launch.id, parentId: nil, before: nil) }
    #expect(throws: StoreError.self) { try db.placePlanLine(train.id, groupId: launch.id, parentId: nil, before: nil) }
    #expect(try personal.planLines().map(\.text) == ["Book the train"])
}
