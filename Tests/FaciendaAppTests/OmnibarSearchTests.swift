import Foundation
import Testing
import FaciendaCore

private func searchStore() throws -> FaciendaStore {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "OmnibarSearchTests/\(UUID().uuidString)/tasks.sqlite"))
    return library.scoped(to: try library.defaultWorkspace().id)
}

@MainActor @Test func omnibarSearchSharesAllBoardMatchesAndLoadsPlaces() async throws {
    let store = try searchStore(), search = OmnibarSearch()
    let group = try store.createGroup(name: "Search work")
    var tasks: [FaciendaTask] = []
    for index in 0..<12 {
        let task = try store.create(FaciendaTask(title: "Omnibar search \(index)"))
        try store.assignGroup(taskId: task.id, groupId: group.id)
        tasks.append(task)
    }
    var partial = FaciendaTask(title: "Omnibar colors")
    partial.updatedAt = Date(timeIntervalSince1970: 0)
    partial = try store.create(partial)
    let elsewhere = store.library.scoped(to: try store.library.createWorkspace(name: "Elsewhere").id)
    let duplicate = try elsewhere.create(FaciendaTask(title: "Omnibar search"))
    let found = try #require(await search.find("omnibar search", in: store, debounce: false))
    #expect(found.hits.count == 8 && found.matchesHere)
    #expect(found.boardMatches == Set(tasks.map(\.id)))
    #expect(!found.boardMatches.contains(partial.id))
    #expect(found.hits.allSatisfy { $0.task.workspaceId == store.workspaceID })
    #expect(found.hits.allSatisfy { found.places[$0.task.id]?.groupID == group.id })
    // An exact open task still guards Return even when workspace priority leaves it outside the visible eight.
    #expect(found.duplicate?.id == duplicate.id)
    #expect(found.places[duplicate.id]?.workspaceID == elsewhere.workspaceID)

    let model = try AppModel(demo: true, seed: false, store: store)
    model.filterBoard("omnibar search", matching: found.boardMatches)
    #expect(Set(model.boardTasks(in: group.id).map(\.id)) == Set(tasks.map(\.id)))
    // A changed query invalidates only the lists, retaining the status lookups each visible row uses.
    _ = model.tasksByID
    model.filterBoard("colors", matching: [partial.id])
    #expect(model.derived.tasks != nil)
    #expect(model.boardTasks(in: nil).map(\.id) == [partial.id])
    model.search = ""
    #expect(model.boardTasks(in: group.id).count == tasks.count)
}

@MainActor @Test func omnibarSearchDiscardsSupersededAndCancelledQueries() async throws {
    let store = try searchStore(), search = OmnibarSearch()
    _ = try store.create(FaciendaTask(title: "Omnibar colors"))
    let latest = try store.create(FaciendaTask(title: "Keyboard focus"))
    let old = Task { await search.find("omnibar", in: store) }
    try await Task.sleep(for: .milliseconds(10))
    let found = await search.find("keyboard", in: store, debounce: false)
    #expect(found?.hits.map(\.task.id) == [latest.id])
    #expect(await old.value == nil)

    let cancelled = Task { await search.find("omnibar", in: store) }
    try await Task.sleep(for: .milliseconds(10))
    cancelled.cancel()
    #expect(await cancelled.value == nil)

    let cleared = Task { await search.find("keyboard", in: store) }
    try await Task.sleep(for: .milliseconds(10))
    search.cancel()
    #expect(await cleared.value == nil)
    #expect(await search.find("?!", in: store, debounce: false)?.hits.isEmpty == true)
}
