import Foundation
import SwiftData
import Testing
@testable import FaciendaCompanion

@MainActor @Test func outboxSurvivesReopeningAndPreservesText() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaCompanionTests/\(UUID().uuidString)/companion.store")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let id = UUID().uuidString
    do {
        let container = try CompanionStorage.makeContainer(cloudEnabled: false, url: url)
        let context = ModelContext(container)
        context.insert(CompanionRequest(id: id, text: "Original request\nwith detail"))
        try context.save()
    }
    let reopened = try CompanionStorage.makeContainer(cloudEnabled: false, url: url)
    let context = ModelContext(reopened)
    let requests = try context.fetch(FetchDescriptor<CompanionRequest>())
    #expect(requests.count == 1)
    #expect(requests.first?.requestID == id)
    #expect(requests.first?.text == "Original request\nwith detail")
}

@MainActor @Test func mergedProjectionDeduplicatesAndDoesNotResurrectCompletedRequests() throws {
    let request = CompanionRequest(id: "one", text: "Original request")
    let stale = CompanionTask(id: "one", title: "Old", detail: "", section: "processing", status: "Working", revision: 1)
    let current = CompanionTask(id: "one", title: "New", detail: "", section: "waiting", status: "Needs you", revision: 2)
    let items = CompanionItem.merged(tasks: [current, stale], requests: [request, request], cloudEnabled: true)
    #expect(items.count == 1)
    #expect(items.first?.title == "New")
    current.section = "done"
    let completed = CompanionItem.merged(tasks: [stale, current], requests: [request], cloudEnabled: true)
    #expect(completed.count == 1)
    #expect(completed.first?.category == .done)
    let pending = CompanionRequest(id: "two", text: "Another task")
    #expect(CompanionItem.merged(tasks: [], requests: [pending, pending], cloudEnabled: false).count == 1)
    #expect(CompanionItem.merged(tasks: [], requests: [pending], cloudEnabled: false).first?.status == "Saved on this iPhone")
}

@MainActor @Test func workspaceProjectionSeparatesRequestsSummariesAndLegacyItems() {
    let personal = CompanionTask(id: "personal", title: "Home task", detail: "", section: "processing", status: "Working", workspaceID: "home")
    let work = CompanionTask(id: "work", title: "Work task", detail: "", section: "waiting", status: "Waiting", workspaceID: "work")
    let draft = CompanionRequest(id: "draft", text: "Work request", workspaceID: "work")
    let legacy = CompanionRequest(id: "legacy", text: "Older request")
    #expect(CompanionItem.merged(tasks: [personal, work], requests: [draft, legacy], cloudEnabled: true, workspaceID: "home").map(\.id) == ["personal"])
    #expect(Set(CompanionItem.merged(tasks: [personal, work], requests: [draft, legacy], cloudEnabled: true, workspaceID: "work").map(\.id)) == ["work", "draft"])
    #expect(Set(CompanionItem.merged(tasks: [personal, work], requests: [draft, legacy], cloudEnabled: true, workspaceID: "home", includeUnassigned: true).map(\.id)) == ["personal", "legacy"])
}

@MainActor @Test func companionWorkspaceCatalogAndRoutingPersistAcrossReopening() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaCompanionTests/\(UUID().uuidString)/companion.store")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let identifier = UUID().uuidString
    do {
        let container = try CompanionStorage.makeContainer(cloudEnabled: false, url: url)
        let context = ModelContext(container)
        context.insert(CompanionWorkspace(id: identifier, name: "Research"))
        context.insert(CompanionRequest(text: "Review findings", workspaceID: identifier))
        try context.save()
    }
    let reopened = try CompanionStorage.makeContainer(cloudEnabled: false, url: url)
    let context = ModelContext(reopened)
    #expect(try context.fetch(FetchDescriptor<CompanionWorkspace>()).first?.name == "Research")
    #expect(try context.fetch(FetchDescriptor<CompanionRequest>()).first?.workspaceID == identifier)
}
