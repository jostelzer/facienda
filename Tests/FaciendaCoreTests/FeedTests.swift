import Foundation
import Testing
@testable import FaciendaCore

@Test func theFeedReadsEveryWorkspaceAndPointsAtLiveTasks() throws {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaFeedTests/\(UUID().uuidString)/test.sqlite"))
    let home = library.scoped(to: try library.createWorkspace(name: "Home").id)
    let work = library.scoped(to: try library.createWorkspace(name: "Work").id)
    let move = try home.createGroup(name: "House move")
    let deed = try home.create(FaciendaTask(title: "Deed transfer", state: .running, nextAction: "Wait"))
    try home.assignGroup(taskId: deed.id, groupId: move.id)
    let notes = try work.create(FaciendaTask(title: "Release notes", state: .running, nextAction: "Write"))

    try home.recordIntake(text: "tell the deed task proxy signing is fine", reading: "Reply · Deed transfer", decidedBy: .model, taskId: deed.id)
    try work.recordIntake(text: "write the release notes", reading: "New task", decidedBy: .rule, taskId: notes.id)
    try home.recordIntake(text: "remember prices in euro", reading: "Remember · prices in euro", decidedBy: .rule, taskId: nil)

    // The release notes came back for review; the deed task is still running.
    _ = try work.update(notes.id) { $0.state = .needsMe }

    let feed = try library.feed()
    #expect(feed.map(\.entry.text) == ["remember prices in euro", "write the release notes", "tell the deed task proxy signing is fine"])
    #expect(feed[0].task == nil && feed[0].workspaceId == home.workspaceID)
    #expect(feed[1].workspaceId == work.workspaceID && feed[1].task?.state == .needsMe && feed[1].isNew)
    #expect(feed[1].groupName == nil)
    #expect(feed[2].groupName == "House move" && feed[2].groupId == move.id && !feed[2].isNew)

    // A request recorded before the bar said where it came from may have been a group's +, so the Feed leaves it out.
    try home.record(TaskEvent(taskId: deed.id, source: .user, kind: "intake.read",
                              payload: #"{"text":"written on the group's plus","reading":"New task","by":"rule"}"#))
    #expect(try library.feed().count == 3)

    // Opening the task makes it seen; the Feed follows the board.
    try work.markSeen([notes.id: Date().addingTimeInterval(5)])
    #expect(try library.feed()[1].isNew == false)
}
