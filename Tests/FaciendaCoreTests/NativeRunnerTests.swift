import Foundation
import Testing
import GRDB
@testable import FaciendaCore

private func runnerStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaRunnerTests/\(UUID().uuidString)/test.sqlite"))
}

@Test func nativeQueueDoesNotSweepBacklogAndDeduplicatesStarts() throws {
    let store = try runnerStore()
    let task = try store.create(FaciendaTask(title: "Explicit start", state: .needsMe))
    _ = try store.create(FaciendaTask(title: "Keep in backlog", state: .needsMe))
    try store.bindRunner(threadId: "runner", automationId: nil)
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    let item = try store.enqueueDispatch(taskId: task.id)
    #expect(try store.enqueueDispatch(taskId: task.id).id == item.id)
    #expect(try store.dispatches().count == 1)
    #expect(throws: StoreError.self) { try store.claimDispatch(runnerId: "wrong") }
    #expect(try store.claimDispatch(runnerId: "runner")?.id == item.id)
    try saveEmptyDiscovery(store, item)
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    let reopened = try FaciendaStore(url: store.url)
    #expect(try reopened.claimDispatch(runnerId: "runner")?.state == "dispatching")
    #expect(try reopened.enqueueDispatch(taskId: task.id).id == item.id)
    try reopened.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "native-chat")
    try reopened.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "native-chat")
    #expect(try store.links(taskId: task.id).count == 1)
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    let followup = try store.enqueueDispatch(taskId: task.id, triggerKey: "answer-1")
    #expect(followup.threadId == "native-chat")
    #expect(try store.enqueueDispatch(taskId: task.id, triggerKey: "answer-1").id == followup.id)
    try store.cancelDispatch(followup.id)
    try store.unlink(try #require(store.links(taskId: task.id).first))
    #expect(try store.enqueueDispatch(taskId: task.id).threadId == nil)
}

@Test func cancellingOrSnoozingBeforeDeliveryPreventsStart() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Test"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let cancelled = try store.enqueueDispatch(taskId: task.id)
    _ = try store.claimDispatch(runnerId: "runner")
    try store.cancelDispatch(cancelled.id)
    #expect(throws: StoreError.self) { try store.beginDispatch(cancelled.id, runnerId: "runner") }
    let snoozed = try store.enqueueDispatch(taskId: task.id)
    try store.snooze(task.id, until: Date().addingTimeInterval(3600))
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    #expect(try store.dispatches().first { $0.id == snoozed.id }?.state == "cancelled")
}

@Test(.timeLimit(.minutes(1))) func nativeQueueWaitWakesOnCrossProcessStyleStoreWrite() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Wake"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let producer = try FaciendaStore(url: store.url)
    // The CLI wait blocks a thread; its producer must not depend on Swift's cooperative executor.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        do { _ = try producer.enqueueDispatch(taskId: task.id) }
        catch { Issue.record(error) }
    }
    #expect(try store.waitForDispatch(runnerId: "runner", seconds: 50)?.taskId == task.id)
    #expect(throws: StoreError.self) { try store.bindRunner(threadId: "another-runner", automationId: nil) }
}

@Test func nativeResultNeverCompletesTaskOrClaimsVerifiedActivity() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Report", state: .running))
    _ = try ToolService(store: store).call("facienda_save_result", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "text": .string("# Answer\nComplete report")]))
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.task(task.id).completedBy == nil)
    #expect(try store.latestEvent(taskId: task.id, kind: "codex.result")?.verified == false)
    try store.update(task.id) { $0.state = .done }
    try store.saveResult(taskId: task.id, text: "Late report")
    #expect(try store.task(task.id).state == .done)
}

@Test func preparedHandoffRejectsEditsAndCanResumeBeforeIntentAfterRestart() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Prepare before intent"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let item = try store.enqueueDispatch(taskId: task.id)
    let claimed = try #require(try store.claimDispatch(runnerId: "runner"))
    try saveEmptyDiscovery(store, item)
    let prepared = try NativeDispatchPreparation(dispatch: claimed, task: store.task(task.id), context: store.dispatchContext(item.id))
    let reopened = try FaciendaStore(url: store.url)
    #expect(try reopened.claimDispatch(runnerId: "runner")?.state == "claimed")
    // A naming edit leaves the discovery key unchanged, but must refresh the title
    // in the prepared handoff. The transactional revision check covers it.
    _ = try store.update(task.id) { $0.displayTitle = "New title" }
    #expect(throws: StoreError.self) { try reopened.beginDispatch(item.id, runnerId: "runner", preparation: prepared) }
    #expect(try store.dispatches().first?.state == "claimed")
    let renamed = try NativeDispatchPreparation(dispatch: claimed, task: store.task(task.id), context: store.dispatchContext(item.id))
    var revisedContext = try #require(try store.dispatchContext(item.id))
    revisedContext.searchSummary = "Updated source evidence with the same request key"
    try store.saveDispatchContext(revisedContext, dispatchId: item.id, runnerId: "runner")
    #expect(throws: StoreError.self) { try reopened.beginDispatch(item.id, runnerId: "runner", preparation: renamed) }
    let fresh = try NativeDispatchPreparation(dispatch: claimed, task: store.task(task.id), context: store.dispatchContext(item.id))
    _ = try reopened.beginDispatch(item.id, runnerId: "runner", preparation: fresh)
    #expect(throws: StoreError.self) { try reopened.beginDispatch(item.id, runnerId: "runner", preparation: fresh) }
}

@Test func uncertainDeliveryRequiresExplicitRecoveryEvidenceAndDoesNotSweepOtherTasks() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Interrupted handoff"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let item = try store.enqueueDispatch(taskId: task.id)
    _ = try store.claimDispatch(runnerId: "runner")
    try saveEmptyDiscovery(store, item)
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    #expect(throws: StoreError.self) { try store.retryUndeliveredDispatch(item.id, evidence: "") }
    #expect(throws: StoreError.self) { try store.retryUndeliveredDispatch(item.id, evidence: "Not blocked yet") }
    try store.deferDispatch(item.id, runnerId: "runner", reason: "Interrupted before native call", blocked: true)
    let other = try store.create(FaciendaTask(title: "Unrelated queued request"))
    let next = try store.enqueueDispatch(taskId: other.id)
    #expect(try store.claimDispatch(runnerId: "runner")?.id == next.id)
    try store.cancelDispatch(next.id)
    try store.retryUndeliveredDispatch(item.id, evidence: "Native runner turn has begin but no create/send call; user requested repair.")
    let recovered = try #require(try store.claimDispatch(runnerId: "runner"))
    #expect(recovered.id == item.id && recovered.state == "claimed" && recovered.availableAt == nil)
    // The blocked task changed: stale contextual handoffs cannot be replayed.
    #expect(throws: StoreError.self) { try store.beginDispatch(item.id, runnerId: "runner") }
    #expect(try store.latestEvent(taskId: task.id, kind: "dispatch.recovery")?.source == .user)
    #expect(throws: StoreError.self) { try store.retryUndeliveredDispatch(item.id, evidence: "Repeated retry") }
}

@Test func foundDeliveryLinksItsChatWithoutSendingAgainAndDroppingFreesTheTask() throws {
    let store = try runnerStore()
    try store.bindRunner(threadId: "runner", automationId: nil)
    func parked(_ title: String) throws -> NativeDispatch {
        let task = try store.create(FaciendaTask(title: title))
        let item = try store.enqueueDispatch(taskId: task.id)
        _ = try store.claimDispatch(runnerId: "runner")
        try saveEmptyDiscovery(store, item)
        _ = try store.beginDispatch(item.id, runnerId: "runner")
        return item
    }
    let found = try parked("Delivered but unconfirmed")
    // Mid-delivery belongs to the runner; only a parked delivery is recovered from the app.
    #expect(throws: StoreError.self) { try store.acknowledgeRecoveredDispatch(found.id, threadId: "worker", status: "idle", source: .app) }
    try store.deferDispatch(found.id, runnerId: "runner", reason: "Could not confirm delivery", blocked: true)
    try store.acknowledgeRecoveredDispatch(found.id, threadId: "worker", status: "active", source: .app)
    let started = try #require(try store.dispatches().first { $0.id == found.id })
    #expect(started.state == "started" && started.threadId == "worker")
    #expect(try store.links().contains { $0.taskId == found.taskId && $0.codexThreadId == "worker" })
    #expect(try store.task(found.taskId).state == .running)
    #expect(try store.latestEvent(taskId: found.taskId, kind: "dispatch.recovery")?.source == .app)
    try store.acknowledgeRecoveredDispatch(found.id, threadId: "worker", status: "active", source: .app)
    #expect(try store.claimDispatch(runnerId: "runner") == nil)

    // A chat found long after it finished does not look busy.
    let late = try parked("Delivered long ago")
    try store.deferDispatch(late.id, runnerId: "runner", reason: "Could not confirm delivery", blocked: true)
    try store.acknowledgeRecoveredDispatch(late.id, threadId: "late-worker", status: "idle", source: .user)
    #expect(try store.task(late.taskId).state == .needsMe)

    let dropped = try parked("Never arrived")
    #expect(throws: StoreError.self) { try store.cancelDispatch(dropped.id) }
    try store.deferDispatch(dropped.id, runnerId: "runner", reason: "Could not confirm delivery", blocked: true)
    try store.cancelDispatch(dropped.id)
    #expect(try store.dispatches().first { $0.id == dropped.id }?.state == "cancelled")
    #expect(try store.enqueueDispatch(taskId: dropped.taskId).id != dropped.id)
}

private func hook(_ name: String, thread: String, _ store: FaciendaStore) throws {
    _ = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"session_id":"\#(thread)","hook_event_name":"\#(name)"}"#.utf8)).apply(to: store)
}

/// Claims and begins a start, returning it ready for the runner's ack.
private func deliveringStart(_ store: FaciendaStore, _ task: FaciendaTask) throws -> NativeDispatch {
    let item = try store.enqueueDispatch(taskId: task.id)
    _ = try #require(try store.claimDispatch(runnerId: "runner"))
    try saveEmptyDiscovery(store, item)
    return try store.beginDispatch(item.id, runnerId: "runner")
}

@Test func turnStartedBeforeAckIsShownRunning() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Summarise the contract"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let item = try deliveringStart(store, task)
    // Codex starts the turn while the runner is still creating the chat, so the hook finds no linked task.
    try hook("UserPromptSubmit", thread: "native-chat", store)
    #expect(try store.task(task.id).state == .inbox)
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "native-chat")
    #expect(try store.task(task.id).state == .running)
    try hook("Stop", thread: "native-chat", store)
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.task(task.id).nextAction == "Review the latest Codex result")
}

@Test func confirmedDeliveryWithoutHooksIsShownRunning() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Draft the reply"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let item = try deliveringStart(store, task)
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "native-chat")
    #expect(try store.task(task.id).state == .running)
    try store.saveResult(taskId: task.id, text: "Draft ready")
    #expect(try store.task(task.id).state == .needsMe)
}

@Test func turnThatEndedBeforeAckKeepsWhatTheWorkerDecided() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Ask the landlord"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let item = try deliveringStart(store, task)
    try hook("UserPromptSubmit", thread: "native-chat", store)
    let later = Date().addingTimeInterval(86400)
    try store.update(task.id, source: .mcp) { $0.state = .scheduled; $0.nextAction = "Chase the landlord"; $0.returnAt = later }
    try hook("Stop", thread: "native-chat", store)
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "native-chat")
    #expect(try store.task(task.id).state == .scheduled)
    #expect(try store.task(task.id).nextAction == "Chase the landlord")
}

@Test func taskModelChoiceSurvivesStorageAndDefaultsToSolHighStandard() throws {
    let store = try runnerStore()
    #expect(TaskModelChoice.standard == TaskModelChoice(model: "gpt-6.1-sol", effort: "high", fast: false))
    var draft = FaciendaTask(title: "Fast one", state: .needsMe)
    draft.workerModel = "gpt-6-luna"; draft.workerReasoningEffort = "low"; draft.workerServiceTier = TaskModelChoice.fastTier
    let saved = try store.task(try store.create(draft).id)
    #expect(saved.workerModel == "gpt-6-luna" && saved.workerReasoningEffort == "low" && saved.workerServiceTier == "priority")
    #expect(try store.task(try store.create(FaciendaTask(title: "Plain", state: .needsMe)).id).workerModel == nil)
}

@Test func overlappingScheduledRunsNeverHoldTheQueueTogether() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Deliver once"))
    let id = try store.bindScheduledRunner(id: "runner-sched")
    let now = Date()
    #expect(try store.beginRunnerTurn(runnerId: id, holder: "run-a", now: now))
    #expect(try store.runnerState()?.lastSeen != nil)
    // A second run while the first delivers stays out of the queue, even with work waiting.
    let item = try store.enqueueDispatch(taskId: task.id)
    #expect(try !store.beginRunnerTurn(runnerId: id, holder: "run-b", now: now.addingTimeInterval(60)))
    #expect(try store.beginRunnerTurn(runnerId: id, holder: "run-a", now: now.addingTimeInterval(60)))
    #expect(try store.waitForDispatch(runnerId: id, seconds: 0)?.id == item.id)
    // Renewing keeps the hold; a run that vanished loses it once the lease runs out.
    try store.renewRunnerLease(runnerId: id, holder: "run-a", now: now.addingTimeInterval(200))
    #expect(try !store.beginRunnerTurn(runnerId: id, holder: "run-b", now: now.addingTimeInterval(400)))
    #expect(try store.beginRunnerTurn(runnerId: id, holder: "run-b", now: now.addingTimeInterval(600)))
    try store.endRunnerTurn(runnerId: id, holder: "run-a")
    #expect(try store.runnerState()?.leaseHolder == "run-b")
    try store.endRunnerTurn(runnerId: id, holder: "run-b")
    #expect(try store.beginRunnerTurn(runnerId: id, holder: "run-c", now: now.addingTimeInterval(601)))
    #expect(throws: StoreError.self) { try store.beginRunnerTurn(runnerId: "runner-retired", holder: "run-d") }
}

@Test func aDispatcherThatIsGoneLosesItsHoldAtOnce() throws {
    let store = try runnerStore()
    let id = try store.bindScheduledRunner(id: "runner-sched")
    let exited = Process(); exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try exited.run(); exited.waitUntilExit()
    let living = FaciendaStore.dispatcherHolder(), gone = FaciendaStore.dispatcherHolder(pid: exited.processIdentifier)
    // A living dispatcher keeps the queue for its whole lease.
    #expect(try store.beginRunnerTurn(runnerId: id, holder: living))
    #expect(try !store.beginRunnerTurn(runnerId: id, holder: "run-b"))
    try store.endRunnerTurn(runnerId: id, holder: living)
    // One that quit or crashed while it held the queue does not hold up the next.
    #expect(try store.beginRunnerTurn(runnerId: id, holder: gone))
    #expect(try store.beginRunnerTurn(runnerId: id, holder: "run-b"))
    #expect(try store.runnerState()?.leaseHolder == "run-b")
}

@Test func unreportedChecksReachTheRunnerAtMostEveryTenMinutes() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Watch fixture"))
    let id = try store.bindScheduledRunner(id: "runner-sched")
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    let start = Date()
    let plan = try store.planCheck(taskId: task.id, threadId: "owner", expectedRevision: 0, nextCheck: start.addingTimeInterval(1), purpose: "Inspect fixture", reason: "Fixture test", waitingOn: "Fixture")
    try store.enqueueDueChecks(runnerId: id, now: plan.nextCheck)
    let check = try #require(try store.claimDispatch(runnerId: id))
    _ = try store.beginDispatch(check.id, runnerId: id)
    try store.acknowledgeDispatch(check.id, runnerId: id, threadId: "owner")
    #expect(try store.unreportedChecksToInspect(now: start.addingTimeInterval(60)).isEmpty)
    let later = start.addingTimeInterval(300)
    #expect(try store.unreportedChecksToInspect(now: later).map(\.id) == [check.id])
    #expect(try store.unreportedChecksToInspect(now: later.addingTimeInterval(300)).isEmpty)
    #expect(try store.unreportedChecksToInspect(now: later.addingTimeInterval(601)).map(\.id) == [check.id])
}

@Test func parkedUncertainDeliveryStaysWithRecoveryAndNeedsItsMarkerToAck() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Reply", state: .needsMe))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let item = try store.enqueueDispatch(taskId: task.id)
    _ = try store.claimDispatch(runnerId: "runner")
    try saveEmptyDiscovery(store, item)
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    // An interrupted delivery gets one reconciliation by the runner.
    #expect(try store.claimDispatch(runnerId: "runner")?.id == item.id)
    try store.deferDispatch(item.id, runnerId: "runner", reason: "Marker not found", blocked: true, now: Date().addingTimeInterval(-7200))
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    #expect(try store.task(task.id).state == .needsMe)
    #expect(throws: StoreError.self) { try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "owner") }
    #expect(throws: StoreError.self) { try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "owner", markerEvidence: "Yes, cheaper sets are below.") }
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "dispatching")
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "owner", markerEvidence: "Facienda dispatch: \(item.id)\nWork on the user's Facienda task")
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "started")
    #expect(try store.events(taskId: task.id).contains { $0.kind == "dispatch.recovery" })
}

@Test func aDeliveryTheUserSendsAgainAfterABlockSaysSo() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Question", state: .needsMe))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let first = try store.enqueueDispatch(taskId: task.id)
    #expect(try store.userRestartNote(for: first) == nil)
    _ = try store.claimDispatch(runnerId: "runner")
    try saveEmptyDiscovery(store, first)
    _ = try store.beginDispatch(first.id, runnerId: "runner")
    try store.deferDispatch(first.id, runnerId: "runner", reason: "create_thread received invalid arguments", blocked: true)
    let parked = try #require(try store.dispatches().first { $0.id == first.id })
    #expect(try store.userRestartNote(for: parked) == nil)
    try store.retryUndeliveredDispatch(first.id, evidence: "Validation failed before any chat was created.")
    let resent = try #require(try store.dispatches().first { $0.id == first.id })
    #expect(try store.userRestartNote(for: resent)?.contains("invalid arguments") == true)
}

@Test func turnTypedInCodexWithdrawsAReplyStillWaitingForTheChat() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Say hello"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let start = try deliveringStart(store, task)
    try store.acknowledgeDispatch(start.id, runnerId: "runner", threadId: "native-chat")
    let reply = try store.enqueueDispatch(taskId: task.id, message: "lets do something cool")
    #expect(try store.claimDispatch(runnerId: "runner")?.id == reply.id)
    // The Codex app holds the chat while it shows it: the reply is put off, and says why only once per reason.
    let open = "The chat is open in the Codex app. Facienda sends this once Codex lets go of it, or send it there yourself."
    try store.deferDispatch(reply.id, runnerId: "runner", reason: open)
    try store.deferDispatch(reply.id, runnerId: "runner", reason: open)
    #expect(try store.events(taskId: task.id).filter { $0.kind == "dispatch.deferred" }.map(\.payload) == [open])
    #expect(try store.dispatches().first { $0.id == reply.id }?.state == "claimed")

    // The user carries on in Codex instead: the reply is withdrawn, not sent late, and the task says so.
    try hook("UserPromptSubmit", thread: "native-chat", store)
    #expect(try store.dispatches().first { $0.id == reply.id }?.state == "cancelled")
    #expect(try store.task(task.id).brief.contains("lets do something cool"))
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
}

@Test func faciendasOwnTurnLeavesItsReplyAlone() throws {
    let store = try runnerStore(), task = try store.create(FaciendaTask(title: "Say hello"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let start = try deliveringStart(store, task)
    try store.acknowledgeDispatch(start.id, runnerId: "runner", threadId: "native-chat")
    let reply = try store.enqueueDispatch(taskId: task.id, message: "Make it shorter")
    _ = try #require(try store.claimDispatch(runnerId: "runner"))
    // Facienda's own send is already dispatching when its turn starts.
    try store.write { db in
        var item = try #require(try NativeDispatch.fetchOne(db, key: reply.id))
        item.state = "dispatching"; try item.update(db)
    }
    try hook("UserPromptSubmit", thread: "native-chat", store)
    #expect(try store.dispatches().first { $0.id == reply.id }?.state == "dispatching")
}
