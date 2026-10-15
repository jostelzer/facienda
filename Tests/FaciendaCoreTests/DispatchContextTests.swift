import Foundation
import Testing
@testable import FaciendaCore

// Existing queue tests can explicitly complete an empty, bounded investigation.
func saveEmptyDiscovery(_ store: FaciendaStore, _ item: NativeDispatch) throws {
    let task = try store.task(item.taskId)
    let context = DispatchContext(contextKey: DispatchContext.key(task: task, dispatch: item), searchStatus: .complete, searchSummary: "Isolated test inventory contains no prior chats.", route: .new, project: nil, chats: [], uncertainties: [])
    try store.saveDispatchContext(context, dispatchId: item.id, runnerId: "runner")
}

private func contextFixture() throws -> (FaciendaStore, FaciendaTask, NativeDispatch) {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "context-tests-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let task = try store.create(FaciendaTask(title: "Check the passport cancellation reply"))
    _ = try store.enqueueDispatch(taskId: task.id)
    let item = try #require(try store.claimDispatch(runnerId: "runner"))
    return (store, task, item)
}
private func context(_ task: FaciendaTask, _ item: NativeDispatch, reuse: Bool = false) -> DispatchContext {
    .init(contextKey: DispatchContext.key(task: task, dispatch: item), searchStatus: .complete, searchSummary: "Read the explicit passport chat; checked the local project inventory.", route: reuse ? .reuse : .new, project: nil,
          chats: [.init(threadId: "passport", title: "Passport discussion", projectId: nil, hostId: "local", role: reuse ? .owner : .background, status: .idle, relevance: reuse ? "Same cancellation correspondence" : "Prior passport preparation", evidence: [.init(sourceReference: "turn 7, user message", excerpt: "I asked the embassy to cancel the early appointment.", supports: "A cancellation was requested; not proof it succeeded.")])],
          uncertainties: ["The applicant's identity has not been established."])
}

@Test func discoveryIsRequiredPersistsAndDoesNotPromoteBackgroundChats() throws {
    let (store, task, item) = try contextFixture()
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    let receipt = context(task, item)
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    let reopened = try FaciendaStore(url: store.url)
    #expect(try reopened.dispatchContext(item.id) == receipt)
    #expect(try reopened.links().isEmpty)
    _ = try reopened.nameTask(task.id, runnerID: "runner", expectedTitle: task.title, displayTitle: "Check passport cancellation", context: "turn 7")
    #expect(try reopened.beginDispatch(item.id, runnerId: "runner").threadId == nil)
    try reopened.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "new-owner")
    #expect(try reopened.links().map(\.codexThreadId) == ["new-owner"])
    #expect(try reopened.latestDispatchContext(taskId: task.id)?.uncertainties == receipt.uncertainties)
}

@Test func editedRequestsAndBlockedDiscoveriesCannotBeDelivered() throws {
    let (store, task, item) = try contextFixture()
    var receipt = context(task, item)
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    _ = try store.update(task.id) { $0.title = "Check a different appointment" }
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner") }
    receipt.contextKey = DispatchContext.key(task: try store.task(task.id), dispatch: item)
    receipt.route = .blocked; receipt.searchStatus = .blocked
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
}

@Test func busyOwnerIsReservedAndCannotBeReplacedOrDeliveredUntilIdle() throws {
    let (store, task, item) = try contextFixture()
    var receipt = context(task, item, reuse: true)
    receipt.chats[0].status = .active
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    #expect(try store.dispatches().first?.threadId == "passport")
    #expect(try store.links().isEmpty)
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    #expect(throws: StoreError.self) { try store.saveDispatchContext(context(task, item), dispatchId: item.id, runnerId: "runner") }
    receipt.chats[0].status = .idle
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    #expect(throws: StoreError.self) { try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "replacement") }
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "passport")
    #expect(try store.links().first?.title == "Passport discussion")
}

@Test func discoveryRejectsOwnershipConflictsArchivalAndUserUnlink() throws {
    let (store, task, item) = try contextFixture()
    var receipt = context(task, item, reuse: true)
    receipt.chats[0].status = .archived
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner") }
    receipt.chats[0].status = .idle
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "other-runner") }
    let other = try store.create(FaciendaTask(title: "Another task"))
    try store.link(ThreadLink(taskId: other.id, codexThreadId: "passport"))
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner") }
    try store.unlink(try #require(try store.links(taskId: other.id).first))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "passport"))
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    try store.unlink(try #require(try store.links(taskId: task.id).first))
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    #expect(try store.excludedOwningThreads(taskId: task.id) == ["passport"])
}

@Test func contextRoutingPreservesExplicitFoldersAndEvidenceBounds() throws {
    let (store, task, item) = try contextFixture()
    let updated = try store.update(task.id) { $0.cwd = "/projects/Orchid" }
    var receipt = context(updated, item)
    receipt.project = .init(id: "project", path: "/projects/Other", reason: "Topic match")
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner") }
    receipt.project?.path = "/projects"
    receipt.chats[0].evidence = []
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner") }
    receipt.chats = []
    try store.saveDispatchContext(receipt, dispatchId: item.id, runnerId: "runner")
    _ = try store.beginDispatch(item.id, runnerId: "runner")
}

@Test func ownerLinkedAfterDiscoveryPreventsDuplicateCreation() throws {
    let (store, _, item) = try contextFixture()
    try saveEmptyDiscovery(store, item)
    try store.link(ThreadLink(taskId: item.taskId, codexThreadId: "user-selected-owner"))
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
}

@Test func taskEditDuringContextRetrievalRejectsThePreparedPrompt() throws {
    let (store, task, item) = try contextFixture()
    let preparedKey = DispatchContext.key(task: task, dispatch: item)
    _ = try store.update(task.id) { $0.intention = "A revised request" }
    try saveEmptyDiscovery(store, item)
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner", expectedContextKey: preparedKey) }
    #expect(try store.dispatches().first?.state == "claimed")
}

@Test func changedAttachmentsRequireFreshDiscoveryBeforeDelivery() throws {
    let (store, task, item) = try contextFixture()
    try store.saveDispatchContext(context(task, item), dispatchId: item.id, runnerId: "runner")
    _ = try store.update(task.id) {
        $0.attachments = [TaskAttachment(name: "Reference.png", path: "/tmp/reference.png")]
    }
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    let updated = try store.task(task.id)
    let key = DispatchContext.key(task: updated, dispatch: item)
    for _ in 0..<32 { #expect(DispatchContext.key(task: updated, dispatch: item) == key) }
    try store.saveDispatchContext(context(updated, item), dispatchId: item.id, runnerId: "runner")
    #expect(try store.beginDispatch(item.id, runnerId: "runner").state == "dispatching")
}
