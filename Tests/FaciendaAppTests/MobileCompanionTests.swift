import Foundation
import SwiftData
import Testing
import FaciendaCore
import FaciendaCompanion

@MainActor @Test func companionReportsCloudDownloadsRatherThanLocalPolling() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaCloudStatusTests/\(UUID().uuidString)/test.sqlite"))
    let companion = try MobileCompanion(store: store, cloudEnabled: false)
    try companion.synchronize(ready: false, status: { _ in "" }, isProcessing: { _ in false })
    #expect(companion.lastCloudDownload == nil)
    #expect(companion.cloudStatus.contains("first iCloud download"))
    companion.recordCloudEvent(type: .import, completedAt: nil, error: nil)
    #expect(companion.cloudStatus == "Downloading from iCloud…")
    companion.recordCloudEvent(type: .import, completedAt: Date(), error: "Download failed")
    companion.recordCloudEvent(type: .export, completedAt: Date(), error: nil)
    #expect(companion.cloudStatus == "Download failed")
    #expect(companion.lastCloudDownload == nil)
    let downloadedAt = Date()
    companion.recordCloudEvent(type: .import, completedAt: downloadedAt, error: nil)
    #expect(companion.lastCloudDownload == downloadedAt)
    #expect(companion.cloudStatus.hasPrefix("Last iCloud download:"))
}

@MainActor @Test func companionReconnectionPreservesOutboxAndNeverStartsTheTask() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaReconnectTests/\(UUID().uuidString)/test.sqlite"))
    var companion: MobileCompanion? = try MobileCompanion(store: store, cloudEnabled: false)
    let request = CompanionRequest(text: "Find headphones")
    let id = request.requestID
    do {
        let context = ModelContext(try #require(companion).container)
        context.insert(request); try context.save()
    }
    companion = nil
    companion = try MobileCompanion(store: store, cloudEnabled: false)
    try #require(companion).synchronize(ready: true, status: { _ in "Queued" }, isProcessing: { _ in true })
    companion = nil
    companion = try MobileCompanion(store: store, cloudEnabled: false)
    try #require(companion).synchronize(ready: true, status: { _ in "Queued" }, isProcessing: { _ in true })
    #expect(try store.tasks().map(\.id) == [id])
    #expect(try store.dispatches().isEmpty)
    #expect(try ModelContext(try #require(companion).container).fetch(FetchDescriptor<CompanionRequest>()).first?.receivedAt != nil)
}

@MainActor @Test func mobileCompanionImportsOnceWaitsForTheUserThenPublishesStatus() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaMobileBridgeTests/\(UUID().uuidString)/test.sqlite"))
    let companion = try MobileCompanion(store: store, cloudEnabled: false)
    let id = UUID().uuidString
    let context = ModelContext(companion.container)
    context.insert(CompanionRequest(id: id, text: "Check the kitchen capture"))
    try context.save()
    try companion.synchronize(ready: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    #expect(try store.tasks().count == 1)
    #expect(try store.dispatches().isEmpty)
    #expect(try ModelContext(companion.container).fetch(FetchDescriptor<CompanionRequest>()).first?.receivedAt != nil)
    try store.bindRunner(threadId: "test-runner", automationId: nil)
    try companion.synchronize(ready: true, status: { _ in "Not started" }, isProcessing: { _ in false })
    try companion.synchronize(ready: true, status: { _ in "Not started" }, isProcessing: { _ in false })
    // A connected Mac still never starts a phone request: it waits for Start on the Mac.
    #expect(try store.dispatches().isEmpty)
    #expect(try store.task(id).state == .inbox)
    #expect(try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>()).first?.status == "Start it on your Mac")
    _ = try store.enqueueDispatch(taskId: id)
    try companion.synchronize(ready: true, status: { _ in "Queued" }, isProcessing: { _ in true })
    #expect(try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>()).first?.status == "Queued")
    #expect(try store.dispatches().count == 1)
    _ = try store.update(id) { $0.state = .done }
    try companion.synchronize(ready: true, status: { _ in "Done" }, isProcessing: { _ in false })
    let summaries = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>())
    #expect(summaries.count == 1)
    #expect(summaries.first?.section == "done")
    let foreign = CompanionRequest(text: "Already received by another workspace")
    foreign.receivedAt = Date()
    let foreignContext = ModelContext(companion.container)
    foreignContext.insert(foreign); try foreignContext.save()
    try companion.synchronize(ready: true, status: { _ in "Done" }, isProcessing: { _ in false })
    #expect(try store.tasks().count == 1)
    #expect(try store.dispatches().count == 1)
}

/// A library with Home, its first workspace, and Work.
@MainActor private func twoWorkspaces() throws -> (library: FaciendaStore, home: FaciendaStore, work: FaciendaStore) {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaMobileWorkspaceTests/\(UUID().uuidString)/facienda.sqlite"))
    let first = try library.defaultWorkspace()
    try library.renameWorkspace(first.id, to: "Home")
    let work = try library.createWorkspace(name: "Work", memorySpaceID: try library.createMemorySpace(name: "Work").id)
    return (library, library.scoped(to: first.id), library.scoped(to: work.id))
}

@MainActor @Test func companionRoutesAcrossWorkspacesAndSyncsPhoneNamesAndCreation() throws {
    let (library, home, work) = try twoWorkspaces()
    let workID = try #require(work.workspaceID)
    let companion = try MobileCompanion(store: home, cloudEnabled: false)
    try companion.synchronize(ready: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    let context = ModelContext(companion.container)
    let request = CompanionRequest(text: "For work only", workspaceID: workID)
    context.insert(request)
    let catalog = try context.fetch(FetchDescriptor<CompanionWorkspace>())
    #expect(catalog.first { $0.isDefault }?.workspaceID == home.workspaceID)
    let renamed = try #require(catalog.first { $0.workspaceID == workID })
    renamed.name = "Studio"; renamed.nameUpdatedAt = Date().addingTimeInterval(1)
    let phoneWorkspace = CompanionWorkspace(name: "Phone workspace")
    context.insert(phoneWorkspace)
    let phoneRequest = CompanionRequest(text: "For the new workspace", workspaceID: phoneWorkspace.workspaceID)
    context.insert(phoneRequest)
    try context.save()
    try companion.synchronize(ready: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    try companion.synchronize(ready: true, status: { _ in "Not started" }, isProcessing: { _ in false })
    #expect(try home.tasks().isEmpty)
    #expect(try work.tasks().map(\.id) == [request.requestID])
    // The phone can add workspaces but not rename one the Mac has; its record gets the Mac's name back.
    #expect(try library.workspace(workID).name == "Work")
    #expect(try ModelContext(companion.container).fetch(FetchDescriptor<CompanionWorkspace>()).first { $0.workspaceID == workID }?.name == "Work")
    // A workspace made on the phone joins the library, with the phone's owner's memory.
    let created = try library.workspace(phoneWorkspace.workspaceID)
    let homeMemory = try library.workspace(home.workspaceID ?? "").memorySpaceId
    #expect(created.name == "Phone workspace" && created.memorySpaceId == homeMemory)
    #expect(try library.scoped(to: created.id).tasks().map(\.id) == [phoneRequest.requestID])
    // Even with the runner ready, nothing starts until the user starts it on the Mac.
    #expect(try library.dispatches().isEmpty)
    let summaries = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>())
    #expect(summaries.first { $0.taskID == request.requestID }?.workspaceID == workID)
    let localRenameDate = Date().addingTimeInterval(10)
    try library.renameWorkspace(created.id, to: "From Mac", updatedAt: localRenameDate)
    try companion.synchronize(ready: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    let synced = try #require(ModelContext(companion.container).fetch(FetchDescriptor<CompanionWorkspace>()).first { $0.workspaceID == created.id })
    #expect(synced.name == "From Mac")
    // The library keeps dates to the millisecond.
    #expect(abs(synced.nameUpdatedAt.timeIntervalSince(localRenameDate)) < 0.001)
    try companion.synchronize(ready: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    #expect(try library.workspace(created.id).name == "From Mac")
}

@MainActor @Test func companionLeavesRequestsForUnknownWorkspacesPending() throws {
    let (library, home, _) = try twoWorkspaces()
    let companion = try MobileCompanion(store: home, cloudEnabled: false)
    let context = ModelContext(companion.container)
    // Not a workspace ID the phone could have made, so it is never created here.
    let request = CompanionRequest(text: "Wait for the catalog", workspaceID: "not-a-workspace")
    context.insert(request); try context.save()
    try companion.synchronize(ready: true, status: { _ in "Working" }, isProcessing: { _ in true })
    #expect(try library.tasks().isEmpty)
    #expect(try ModelContext(companion.container).fetch(FetchDescriptor<CompanionRequest>()).first?.receivedAt == nil)
}

@MainActor @Test func companionDoesNotRestoreADeletedWorkspaceFromItsCloudCatalog() throws {
    let (library, home, work) = try twoWorkspaces()
    let workID = try #require(work.workspaceID)
    let companion = try MobileCompanion(store: home, cloudEnabled: false)
    try companion.synchronize(ready: false, status: { _ in "" }, isProcessing: { _ in false })
    try library.removeWorkspace(workID)
    try companion.synchronize(ready: false, status: { _ in "" }, isProcessing: { _ in false })
    try companion.synchronize(ready: false, status: { _ in "" }, isProcessing: { _ in false })
    #expect(try library.workspaces().map(\.name) == ["Home"])
    #expect(try ModelContext(companion.container).fetch(FetchDescriptor<CompanionWorkspace>()).allSatisfy { $0.workspaceID != workID })
}

@MainActor @Test func companionPublishesSeparateReviewWaitingScheduledAndCompletedCategories() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaCategoryTests/\(UUID().uuidString)/test.sqlite"))
    let companion = try MobileCompanion(store: store, cloudEnabled: false)
    let cases: [(TaskState, String)] = [(.inbox, "review"), (.running, "processing"), (.needsMe, "review"), (.waiting, "waiting"), (.scheduled, "scheduled"), (.done, "done"), (.dropped, "done")]
    for (state, _) in cases { try store.create(FaciendaTask(id: state.rawValue, title: state.label, state: state)) }
    try companion.synchronize(ready: true, sharesAllTasks: true, status: { $0.state.label }, isProcessing: { _ in false })
    let summaries = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>())
    for (state, section) in cases {
        #expect(summaries.first { $0.taskID == state.rawValue }?.section == section)
    }
    let items = CompanionItem.merged(tasks: summaries, requests: [], cloudEnabled: false)
    #expect(items.count == cases.count)
    #expect(Set(items.map(\.category)) == Set(CompanionSection.allCases))
}

@MainActor @Test func companionPublishesOnlyPhoneTasksWithThePhonesTextUnlessAllAreShared() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaPublishTests/\(UUID().uuidString)/test.sqlite"))
    let companion = try MobileCompanion(store: store, cloudEnabled: false)
    let local = try store.create(FaciendaTask(id: UUID().uuidString, title: "Salary negotiation notes", brief: "Ask for 20% more"))
    let request = CompanionRequest(text: "Book the dentist")
    // A request reusing a Mac task's ID is refused: it neither starts nor reveals that task.
    let collision = CompanionRequest(id: local.id, text: "Start it")
    let context = ModelContext(companion.container)
    context.insert(request); context.insert(collision); try context.save()
    try companion.synchronize(ready: true, sharesAllTasks: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    _ = try store.update(request.requestID) { $0.displayTitle = "Dentist, renamed on the Mac"; $0.brief = "Private brief" }
    try companion.synchronize(ready: true, sharesAllTasks: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    var summaries = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>())
    #expect(summaries.map(\.taskID) == [request.requestID])
    #expect(summaries.first?.title == "Book the dentist" && summaries.first?.detail == "")
    #expect(try store.task(local.id).title == "Salary negotiation notes")
    #expect(try store.dispatches().isEmpty)
    let requests = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionRequest>())
    #expect(requests.first { $0.requestID == local.id }?.receivedAt == nil)
    // Shared on request, then withdrawn again when sharing is turned off.
    try companion.synchronize(ready: true, sharesAllTasks: true, status: { _ in "Not started" }, isProcessing: { _ in false })
    summaries = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>())
    #expect(Set(summaries.map(\.taskID)) == [request.requestID, local.id])
    #expect(summaries.first { $0.taskID == request.requestID }?.title == "Dentist, renamed on the Mac")
    try companion.synchronize(ready: true, sharesAllTasks: false, status: { _ in "Not started" }, isProcessing: { _ in false })
    summaries = try ModelContext(companion.container).fetch(FetchDescriptor<CompanionTask>())
    #expect(summaries.map(\.taskID) == [request.requestID])
}
