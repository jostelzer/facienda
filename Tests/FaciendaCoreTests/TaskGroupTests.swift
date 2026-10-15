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
