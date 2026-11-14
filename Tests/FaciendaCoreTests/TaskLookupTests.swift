import Foundation
import Testing
@testable import FaciendaCore

@Test func recentSearchPrioritizesTheWorkspaceBeforeLimitingAndUsesActivity() throws {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "TaskLookupTests/\(UUID().uuidString)/tasks.sqlite"))
    let here = library.scoped(to: try library.createWorkspace(name: "Here").id)
    let elsewhere = library.scoped(to: try library.createWorkspace(name: "Elsewhere").id)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func make(_ store: FaciendaStore, _ id: String, title: String, updated: TimeInterval, created: TimeInterval = 0, state: TaskState = .inbox) throws -> FaciendaTask {
        var task = FaciendaTask(title: title, state: state, brief: "Omnibar search")
        task.id = id; task.createdAt = date.addingTimeInterval(created); task.updatedAt = date.addingTimeInterval(updated)
        return try store.create(task)
    }
    let old = try make(here, "old", title: "Omnibar search", updated: 1, created: 10)
    let recent = try make(here, "recent", title: "Finished work", updated: 3, state: .done)
    let tiedA = try make(here, "a", title: "Another change", updated: 2)
    let tiedB = try make(here, "b", title: "Another change", updated: 2)
    let away = try make(elsewhere, "away", title: "Omnibar search", updated: 20)
    _ = try make(here, "dropped", title: "Omnibar search", updated: 30, state: .dropped)

    let order = TaskLookup.Order.recent(preferredWorkspaceID: try #require(here.workspaceID))
    let found = try library.lookUpTasks("omnibar search", order: order)
    #expect(found.map(\.task.id) == [recent.id, tiedA.id, tiedB.id, old.id, away.id])
    #expect(found.allSatisfy { $0.complete })
    #expect(try library.lookUpTasks("omnibar search", limit: 2, order: order).map(\.task.id) == [recent.id, tiedA.id])
    #expect(try library.lookUpTasks("omnibar search", order: .recent(preferredWorkspaceID: try #require(elsewhere.workspaceID))).first?.task.id == away.id)
    // Other callers still rank by relevance, and a scoped store never leaks another workspace.
    #expect(try library.lookUpTasks("omnibar search").first?.task.id == away.id)
    #expect(try !here.lookUpTasks("omnibar search", order: order).contains { $0.task.id == away.id })
}
