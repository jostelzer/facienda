import Foundation
import Testing
import FaciendaCore
@testable import FaciendaBridge

private func dispatchFixture() async throws -> (FaciendaStore, CodexBridge, CodexDispatcher, NativeDispatch) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaDispatcherTests/\(UUID().uuidString)")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    _ = try store.prepareWorkspaceSetup()
    try store.bindCodexDispatcher()
    try store.verifyDispatcherSetup(projectId: "fixture-project")
    let task = try store.create(FaciendaTask(title: "Release this fixture chat"))
    let runner = CodexDispatcher.runnerId
    let first = try store.enqueueDispatch(taskId: task.id)
    let claimed = try #require(try store.claimDispatch(runnerId: runner))
    try store.saveDispatchContext(store.directContext(for: claimed, owner: nil, projects: []), dispatchId: first.id, runnerId: runner)
    _ = try store.beginDispatch(first.id, runnerId: runner)
    try store.acknowledgeDispatch(first.id, runnerId: runner, threadId: "fixture-chat")
    _ = try store.enqueueDispatch(taskId: task.id, message: "Continue")
    let reply = try #require(try store.claimDispatch(runnerId: runner))
    let bridge = CodexBridge()
    let fixture = try #require(Bundle.module.url(forResource: "dispatcher", withExtension: "py", subdirectory: "Fixtures"))
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    return (store, bridge, CodexDispatcher(store: store, helper: "/fixture/facienda-mcp", executable: nil, bridge: bridge, wake: { _ in }), reply)
}

private func requestCount(_ bridge: CodexBridge, _ method: String) async throws -> Int {
    try await bridge.request("fixture/requests")["methods"].array?.filter { $0.string == method }.count ?? 0
}

@Test func dispatcherNeverAcquiresTheNativeAppsWriter() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    await dispatcher.deliver(item)
    let accepted = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(accepted.state == "dispatching" && accepted.codexQueueId != nil)
    #expect(accepted.codexQueuePreparedAt != nil)
    #expect(try store.claimDispatch(runnerId: CodexDispatcher.runnerId) == nil)
    for method in ["thread/resume", "thread/start", "thread/fork", "turn/start", "thread/unsubscribe"] {
        #expect(try await requestCount(bridge, method) == 0)
    }
    #expect(try await requestCount(bridge, "thread/queue/add") == 1)
    await bridge.disconnect()
}

@Test func dispatcherDoesNotSendCancelledPreparation() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    try store.cancelDispatch(item.id)
    await dispatcher.deliver(item)
    #expect(try await requestCount(bridge, "thread/queue/add") == 0)
    await bridge.disconnect()
}

@Test func dispatcherRetriesAnExplicitlyRefusedQueueAdd() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    _ = try await bridge.request("fixture/configure", params: .object(["refuseAdd": .bool(true)]))
    await dispatcher.deliver(item)
    let refused = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(refused.state == "queued" && refused.codexQueuePreparedAt == nil)
    #expect(try await requestCount(bridge, "thread/resume") == 0)
    await bridge.disconnect()
}

@Test func dispatcherRecoversAcceptedQueueAfterLostReceiptWithoutResending() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    _ = try await bridge.request("fixture/configure", params: .object(["omitReceipt": .bool(true)]))
    await dispatcher.deliver(item)
    let interrupted = try #require(try store.claimDispatch(runnerId: CodexDispatcher.runnerId))
    #expect(interrupted.codexQueueId == nil && interrupted.codexQueuePreparedAt != nil)
    let restarted = CodexDispatcher(store: store, helper: "/fixture/helper", executable: nil, bridge: bridge, wake: { _ in })
    await restarted.deliver(interrupted)
    let recovered = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(recovered.codexQueueId != nil)
    #expect(try await requestCount(bridge, "thread/queue/add") == 1)
    let found = try await DeliveryFinder.find(recovered, runnerThreadId: nil, bridge: bridge)
    #expect(found.chats.isEmpty && !found.complete)
    await bridge.disconnect()
}

@Test func dispatcherRecognizesNativeCompletionBeforeQueueAddReturns() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    _ = try await bridge.request("fixture/configure", params: .object(["consumeBeforeResponse": .bool(true)]))
    await dispatcher.deliver(item)
    await dispatcher.reconcileQueuedDeliveries()
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "started")
    #expect(try store.task(item.taskId).state != .running)
    #expect(try await requestCount(bridge, "thread/resume") == 0)
    await bridge.disconnect()
}

@Test func dispatcherNeverReadsAWholeChat() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    _ = try await bridge.request("fixture/configure", params: .object(["consumeBeforeResponse": .bool(true)]))
    await dispatcher.deliver(item)
    await dispatcher.reconcileQueuedDeliveries()
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "started")
    _ = try await bridge.request("fixture/configure", params: .object(["status": .string("active")]))
    try await dispatcher.followIfActive("fixture-chat")
    #expect(try await requestCount(bridge, "thread/resume") == 1)
    _ = try await DeliveryFinder.find(try #require(try store.dispatches().first { $0.id == item.id }), runnerThreadId: nil, bridge: bridge)
    #expect(try await requestCount(bridge, "thread/turns/list") >= 2)
    #expect(try await requestCount(bridge, "whole history") == 0)
    await bridge.disconnect()
}

@Test func recentTurnsStopAtTheFirstTurnBeforeTheDelivery() async throws {
    let (_, bridge, _, _) = try await dispatchFixture()
    let turns = (1...50).map { index -> JSONValue in
        .object(["id": .string("turn-\(index)"), "status": .string("completed"), "startedAt": .number(Double(1_000 + index * 10)), "items": .array([])])
    }
    _ = try await bridge.request("fixture/setTurns", params: .object(["turns": .array(turns)]))
    let recent = try await ThreadConversation.recent("fixture-chat", since: Date(timeIntervalSince1970: 1_449), bridge: bridge, pageSize: 5)
    #expect(recent.turns.map(\.id) == (41...50).map { "turn-\($0)" })
    #expect(recent.settledStatus == "idle")
    #expect(try await requestCount(bridge, "thread/turns/list") == 2)
    await bridge.disconnect()
}

@Test func dispatcherRestartWithFailedWakeKeepsOneDelivery() async throws {
    let (store, bridge, _, item) = try await dispatchFixture()
    let first = CodexDispatcher(store: store, helper: "/fixture/helper", executable: nil, bridge: bridge, wake: { _ in throw BridgeError.unavailable })
    await first.deliver(item)
    let restarted = CodexDispatcher(store: store, helper: "/fixture/helper", executable: nil, bridge: bridge, wake: { _ in })
    await restarted.reconcileQueuedDeliveries()
    _ = try await bridge.request("fixture/configure", params: .object(["turnStatus": .string("interrupted")]))
    _ = try await bridge.request("fixture/consume")
    await restarted.reconcileQueuedDeliveries()
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "started")
    #expect(try store.task(item.taskId).state == .running)
    #expect(try await requestCount(bridge, "thread/queue/add") == 1)
    await bridge.disconnect()
}

@Test func queuedDeliveryCannotBeMistakenForMissingDuringConsumption() async throws {
    let (store, bridge, dispatcher, item) = try await dispatchFixture()
    await dispatcher.deliver(item)
    _ = try await bridge.request("fixture/remove")
    let accepted = try #require(try store.dispatches().first { $0.id == item.id })
    let found = try await DeliveryFinder.find(accepted, runnerThreadId: nil, bridge: bridge)
    #expect(!found.complete && found.chats.isEmpty)
    await dispatcher.reconcileQueuedDeliveries()
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "dispatching")
    #expect(try await requestCount(bridge, "thread/queue/add") == 1)
    await bridge.disconnect()
}

@Test func dispatcherReconcilesLegacyCompletionAndRetriesFailedRelease() async throws {
    let (_, bridge, dispatcher, _) = try await dispatchFixture()
    _ = try await bridge.request("fixture/configure", params: .object(["status": .string("active")]))
    try await dispatcher.followIfActive("fixture-chat")
    await dispatcher.releaseFinishedChats()
    #expect(try await requestCount(bridge, "thread/unsubscribe") == 0)
    _ = try await bridge.request("fixture/configure", params: .object(["status": .string("idle"), "failRelease": .bool(true)]))
    await dispatcher.releaseFinishedChats()
    #expect(try await requestCount(bridge, "thread/unsubscribe") == 1)
    await dispatcher.releaseFinishedChats()
    #expect(try await requestCount(bridge, "thread/unsubscribe") == 2)
    await dispatcher.releaseFinishedChats()
    #expect(try await requestCount(bridge, "thread/unsubscribe") == 2)
    await bridge.disconnect()
}

@Test func dispatcherReleasesLegacyChatThatFinishesDuringReconnect() async throws {
    let (_, bridge, dispatcher, _) = try await dispatchFixture()
    _ = try await bridge.request("fixture/configure", params: .object(["status": .string("active"), "statusAfterRead": .string("idle")]))
    try await dispatcher.followIfActive("fixture-chat")
    #expect(try await requestCount(bridge, "thread/unsubscribe") == 1)
    await bridge.disconnect()
}
