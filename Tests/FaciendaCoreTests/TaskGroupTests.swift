import Foundation
import Testing
@testable import FaciendaCore

private func store() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/groups.sqlite"))
}

@Test func groupsKeepOrderSurviveEmptyingAndNeverTouchTasks() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Register the address"))
    let admin = try db.createGroup(name: "  London admin "), trips = try db.createGroup(name: "Trips")
    #expect(try db.groups().map(\.name) == ["London admin", "Trips"])
    try db.assignGroup(taskId: task.id, groupId: admin.id)
    try db.assignGroup(taskId: task.id, groupId: trips.id)
    #expect(try db.groupMembers() == [TaskGroupMember(taskId: task.id, groupId: trips.id, assignedBy: "user")])
    try db.assignGroup(taskId: task.id, groupId: nil)
    #expect(try db.groupMembers().isEmpty)
    // An emptied group stays, so a later task can wake it up.
    #expect(try db.groups().map(\.id) == [admin.id, trips.id])
    try db.renameGroup(admin.id, name: "Paperwork")
    #expect(try db.groups().first?.name == "Paperwork")
    // Stored dates keep millisecond precision.
    #expect(try db.task(task.id).revision == task.revision && abs(db.task(task.id).updatedAt.timeIntervalSince(task.updatedAt)) < 0.01)
    #expect(throws: StoreError.self) { try db.createGroup(name: "  ") }
    #expect(throws: StoreError.self) { try db.assignGroup(taskId: task.id, groupId: "missing") }
    try db.assignGroup(taskId: task.id, groupId: trips.id)
    try db.deleteGroup(trips.id)
    #expect(try db.groupMembers().isEmpty && db.groups().map(\.id) == [admin.id])
    #expect(try db.task(task.id).title == "Register the address")
}

@Test func runnerFilesUngroupedTasksButNeverMovesTheUsersChoice() throws {
    let db = try store()
    try db.bindRunner(threadId: "runner", automationId: nil)
    let chosen = try db.create(FaciendaTask(title: "Compare movers")), fresh = try db.create(FaciendaTask(title: "Ask the creche"))
    let move = try db.createGroup(name: "Flat move")
    try db.assignGroup(taskId: chosen.id, groupId: move.id)
    #expect(try db.proposeGroup(taskId: chosen.id, runnerID: "runner", name: "Childcare") == nil)
    #expect(try db.groups().count == 1)
    // An existing group is reused whatever its capitalisation.
    #expect(try db.proposeGroup(taskId: fresh.id, runnerID: "runner", name: "flat MOVE")?.id == move.id)
    #expect(try db.groupMembers().first { $0.taskId == fresh.id }?.assignedBy == "runner")
    let third = try db.create(FaciendaTask(title: "Find a nanny"))
    #expect(try db.proposeGroup(taskId: third.id, runnerID: "runner", name: "Childcare")?.name == "Childcare")
    #expect(try db.groups().map(\.name) == ["Flat move", "Childcare"])
    #expect(throws: StoreError.self) { try db.proposeGroup(taskId: third.id, runnerID: "someone-else", name: "Other") }
}

@Test func groupCoverIsStoredBesideTheDatabaseAndLeavesWithItsGroup() throws {
    let db = try store(), group = try db.createGroup(name: "Paperwork")
    #expect(try db.groups().first?.coverPaintedAt == nil)
    try db.saveCover(groupId: group.id, image: Data([1, 2, 3]), style: "New Objectivity")
    let saved = try #require(try db.groups().first)
    #expect(saved.coverStyle == "New Objectivity" && saved.coverPaintedAt != nil)
    let file = db.coverURL(groupId: group.id)
    #expect(file.deletingLastPathComponent().deletingLastPathComponent() == db.url.deletingLastPathComponent())
    #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
    #expect(throws: StoreError.self) { try db.saveCover(groupId: "missing", image: Data([1]), style: "") }
    #expect(!FileManager.default.fileExists(atPath: db.coverURL(groupId: "missing").path))
    try db.deleteGroup(group.id)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func coverChangesKeepThePreviousPictureAndRememberWishesUntilUndone() throws {
    let db = try store(), group = try db.createGroup(name: "Shipping")
    try db.saveCover(groupId: group.id, image: Data([1]), style: "Precisionism")
    #expect(!FileManager.default.fileExists(atPath: db.previousCoverURL(groupId: group.id).path))
    try db.saveCover(groupId: group.id, image: Data([2]), style: "Precisionism in green", note: " more green\n")
    try db.saveCover(groupId: group.id, image: Data([3]), style: "Precisionism in green", note: "no people")
    var saved = try #require(try db.groups().first)
    #expect(saved.coverNoteList == ["more green", "no people"] && saved.coverStyle == "Precisionism in green")
    #expect(try Data(contentsOf: db.coverURL(groupId: group.id)) == Data([3]))
    #expect(try Data(contentsOf: db.previousCoverURL(groupId: group.id)) == Data([2]))
    // Undo swaps the pictures and restores the style and wishes that went with the earlier one.
    try db.restorePreviousCover(groupId: group.id, style: "Precisionism in green", notes: ["more green"])
    saved = try #require(try db.groups().first)
    #expect(saved.coverNoteList == ["more green"])
    #expect(try Data(contentsOf: db.coverURL(groupId: group.id)) == Data([2]))
    #expect(try Data(contentsOf: db.previousCoverURL(groupId: group.id)) == Data([3]))
    try db.setCoverNotes(groupId: group.id, notes: [])
    #expect(try db.groups().first?.coverNotes == nil)
    try db.deleteGroup(group.id)
    #expect(!FileManager.default.fileExists(atPath: db.previousCoverURL(groupId: group.id).path))
    #expect(throws: StoreError.self) { try db.restorePreviousCover(groupId: group.id, style: nil, notes: []) }
}

@Test func placedTasksKeepTheirOrderAndNewOnesArriveAbove() throws {
    let db = try store()
    let first = try db.create(FaciendaTask(title: "Register the address")), second = try db.create(FaciendaTask(title: "Book the van"))
    #expect(try db.boardPlaces().isEmpty)
    try db.placeTasks([first.id, second.id])
    let places = try db.boardPlaces()
    #expect(places[first.id]! < places[second.id]!)
    // Placing never touches the task itself.
    #expect(try db.task(first.id).revision == first.revision)
    // Anything made later sorts above the placed card.
    var later = FaciendaTask(title: "Ask the creche"); later.createdAt = Date().addingTimeInterval(1)
    #expect(TaskBoardPlace.unplaced(later) < places.values.min()!)
    #expect(throws: StoreError.self) { try db.placeTasks(["missing"]) }
    try db.deleteTask(first.id)
    #expect(try db.boardPlaces().keys.sorted() == [second.id])
}

@Test func archivingAGroupTakesItsOpenTasksAlongAndRestoreBringsThemBackAsTheyWere() throws {
    let db = try store(), group = try db.createGroup(name: "Garden"), other = try db.createGroup(name: "Kitchen")
    let check = Date().addingTimeInterval(3 * 86400), later = Date().addingTimeInterval(7 * 86400)
    let fresh = try db.create(FaciendaTask(title: "Plan the beds"))
    let waiting = try db.update(try db.create(FaciendaTask(title: "Order seeds")).id) { $0.state = .waiting; $0.waitingOn = "The seed shop"; $0.checkAt = check }
    let scheduled = try db.update(try db.create(FaciendaTask(title: "Prune the hedge")).id) { $0.state = .scheduled; $0.returnAt = later }
    let running = try db.update(try db.create(FaciendaTask(title: "Compare sheds")).id) { $0.state = .running }
    let asked = try db.create(FaciendaTask(title: "Pick a fence"))
    let question = try db.requestDecision(Decision(taskId: asked.id, question: "Wood or metal?", recommendation: "Wood", options: ["Wood", "Metal"]))
    let mine = try db.create(FaciendaTask(title: "Measure the lawn"))
    try db.takeOn(mine.id, step: "Borrow a tape")
    let finished = try db.update(try db.create(FaciendaTask(title: "Buy gloves")).id) { $0.state = .done }
    let elsewhere = try db.create(FaciendaTask(title: "Fix the tap"))
    let members = [fresh, waiting, scheduled, running, asked, mine, finished]
    for task in members { try db.assignGroup(taskId: task.id, groupId: group.id) }
    try db.assignGroup(taskId: elsewhere.id, groupId: other.id)

    try db.archiveGroup(group.id)
    #expect(try db.groups().map(\.id) == [other.id] && db.archivedGroups().map(\.id) == [group.id])
    #expect(try db.groupMembers().map(\.taskId) == [elsewhere.id])
    #expect(try db.archivedGroupTasks() == Set(members.map(\.id)))
    for task in members where task.id != finished.id { #expect(try db.task(task.id).state == .dropped) }
    #expect(try db.task(finished.id).state == .done && db.task(elsewhere.id).state == .inbox)
    #expect(try db.decisions(taskId: asked.id).isEmpty && db.ownSteps().isEmpty)
    // Nothing new lands in an archived group, whoever files it.
    let stray = try db.create(FaciendaTask(title: "Water the roses"))
    #expect(throws: StoreError.self) { try db.assignGroup(taskId: stray.id, groupId: group.id) }
    try db.bindRunner(threadId: "runner", automationId: nil)
    #expect(try db.proposeGroup(taskId: stray.id, runnerID: "runner", name: "garden")?.id != group.id)

    try db.restoreGroup(group.id)
    #expect(try db.archivedGroups().isEmpty && db.archivedGroupTasks().isEmpty)
    #expect(try db.groups().map(\.name) == ["Garden", "Kitchen", "garden"])
    #expect(try db.task(fresh.id).state == .inbox)
    let back = try db.task(waiting.id)
    #expect(back.state == .waiting && back.checkAt.map { abs($0.timeIntervalSince(check)) < 0.01 } == true)
    #expect(try db.task(scheduled.id).state == .scheduled && db.task(scheduled.id).returnAt.map { abs($0.timeIntervalSince(later)) < 0.01 } == true)
    // Its agent was stopped, so running work comes back to the user.
    #expect(try db.task(running.id).state == .needsMe)
    #expect(try db.task(asked.id).state == .needsMe && db.decisions(taskId: asked.id).map(\.id) == [question.id])
    #expect(try db.ownSteps().map(\.text) == ["Borrow a tape"])
    #expect(try db.task(finished.id).state == .done)
    // Restoring twice changes nothing.
    try db.restoreGroup(group.id)
    #expect(try db.task(fresh.id).state == .inbox)
}

@Test func aTaskReopenedWhileItsGroupWasArchivedIsLeftAsItIs() throws {
    let db = try store(), group = try db.createGroup(name: "Garage")
    let task = try db.create(FaciendaTask(title: "Sort the tools"))
    try db.assignGroup(taskId: task.id, groupId: group.id)
    try db.archiveGroup(group.id)
    _ = try db.update(task.id) { $0.state = .done }
    try db.restoreGroup(group.id)
    #expect(try db.task(task.id).state == .done)
}
