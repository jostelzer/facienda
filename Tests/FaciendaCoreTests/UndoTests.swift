import Foundation
import Testing
import GRDB
@testable import FaciendaCore

private func store() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/undo.sqlite"))
}

@Test func deletingATaskComesBackWholeAndGoesAgainOnRedo() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Renew the passport", intention: "Before the trip"))
    let group = try db.createGroup(name: "Paperwork")
    try db.assignGroup(taskId: task.id, groupId: group.id)
    let undo = try UndoStep.recording { try db.deleteTask(task.id) }
    #expect(try db.tasks().isEmpty && db.groupMembers().isEmpty)
    let redo = try db.replay(undo)
    #expect(try db.task(task.id).title == "Renew the passport")
    #expect(try db.groupMembers().map(\.groupId) == [group.id])
    // The search index rebuilds from the restored row.
    #expect(try db.tasks(search: "passport").map(\.id) == [task.id])
    _ = try db.replay(redo)
    #expect(try db.tasks().isEmpty && db.groupMembers().isEmpty)
}

@Test func undoingAnEditKeepsLaterChangesToOtherColumnsAndCountsTheRevisionOn() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Book the flat"))
    let undo = try UndoStep.recording { _ = try db.update(task.id) { $0.state = .done } }
    // Something else, outside the step, changes the same row.
    _ = try db.update(task.id) { $0.intention = "Two bedrooms" }
    let revision = try db.task(task.id).revision
    _ = try db.replay(undo)
    let restored = try db.task(task.id)
    #expect(restored.state == task.state && restored.intention == "Two bedrooms" && restored.revision > revision)
}

@Test func onlyWritesInsideTheStepAreRecordedAndAConflictChangesNothing() throws {
    let db = try store()
    let step = try UndoStep.recording { _ = try db.createGroup(name: "Trips") }
    _ = try db.createGroup(name: "Garden")
    #expect(!step.isEmpty)
    let redo = try db.replay(step)
    #expect(try db.groups().map(\.name) == ["Garden"])
    // Recording leaves no triggers behind on the connection.
    #expect(try db.db.write { try Int.fetchOne($0, sql: "SELECT count(*) FROM temp.sqlite_master") } == 0)
    let before = try db.groups().map(\.id)
    _ = try db.replay(redo)
    #expect(throws: (any Error).self) { try db.replay(redo) }
    #expect(try db.groups().count == before.count + 1)
}

@Test func deletedGroupsAndPlanLinesComeBackWithEverythingUnderThem() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Pack the books"))
    let group = try db.createGroup(name: "Move")
    try db.assignGroup(taskId: task.id, groupId: group.id)
    let goal = try db.addPlanLine(groupId: group.id, text: "Empty the flat")
    let step = try db.addPlanLine(groupId: group.id, parentId: goal.id, text: "Boxes from the shop")
    let next = try db.addPlanLine(groupId: group.id, text: "Hand back the keys")
    try Data("cover".utf8).write(to: { try FileManager.default.createDirectory(at: db.coversDirectory, withIntermediateDirectories: true); return db.coverURL(groupId: group.id) }())

    _ = try db.replay(UndoStep.recording { try db.deletePlanLine(goal.id) })
    #expect(try db.planLines().map(\.id) == [goal.id, step.id, next.id])
    #expect(try db.planLines().first { $0.id == next.id }?.position == 1)

    _ = try db.replay(UndoStep.recording { try db.deleteGroup(group.id) })
    #expect(try db.groups().map(\.id) == [group.id] && db.groupMembers().map(\.taskId) == [task.id])
    #expect(try db.planLines().count == 3)
    #expect(FileManager.default.fileExists(atPath: db.coverURL(groupId: group.id).path))

    // The cover a recorded delete kept is swept away when the app next opens.
    _ = try UndoStep.recording { try db.deleteGroup(group.id) }
    let other = try db.createGroup(name: "Garden")
    try Data("cover".utf8).write(to: db.coverURL(groupId: other.id))
    db.sweepGroupCovers()
    #expect(!FileManager.default.fileExists(atPath: db.coverURL(groupId: group.id).path))
    #expect(FileManager.default.fileExists(atPath: db.coverURL(groupId: other.id).path))
}
