import Foundation
import Testing
@testable import FaciendaCore

private func monitoredTask() throws -> (FaciendaStore, FaciendaTask, CheckPlan) {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "check-tests-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let task = try store.create(FaciendaTask(title: "Wait for supplier", state: .needsMe))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    let plan = try store.planCheck(taskId: task.id, threadId: "owner", expectedRevision: 0, nextCheck: Date().addingTimeInterval(600), purpose: "Check for the promised quote", reason: "Supplier promised it today", waitingOn: "Supplier")
    return (store, task, plan)
}

private func deliver(_ store: FaciendaStore, _ plan: CheckPlan) throws -> NativeDispatch {
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck)
    let item = try #require(try store.claimDispatch(runnerId: "runner"))
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "owner")
    return item
}

@Test func dueChecksSurviveReopenCoalesceAndAvoidLegacyReminder() throws {
    let (store, task, plan) = try monitoredTask()
    let reopened = try FaciendaStore(url: store.url)
    try reopened.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck.addingTimeInterval(86400))
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck.addingTimeInterval(2 * 86400))
    let items = try store.dispatches()
    #expect(items.count == 1)
    #expect(items.first?.threadId == "owner")
    #expect(items.first?.kind == "check")
    #expect(try store.claimDue(now: plan.nextCheck.addingTimeInterval(86400)).isEmpty)
    #expect(try store.task(task.id).state == .waiting)
    #expect(try store.checkPlan(task.id) == plan)
}

@Test func checkOutcomeAndRescheduleAreAtomicAndReplaySafe() throws {
    let (store, task, plan) = try monitoredTask()
    let item = try deliver(store, plan)
    let now = plan.nextCheck
    // The chat's proposed date is ignored: the next check is one cadence later.
    let next = try store.reportCheck(taskId: task.id, dispatchId: item.id, expectedRevision: plan.revision, outcome: "unchanged", summary: "No reply", nextCheck: now.addingTimeInterval(5 * 86400), reason: "Give supplier more time", now: now)
    #expect(next.nextCheck == now.addingTimeInterval(plan.minimumInterval))
    #expect(next.reason == plan.reason)
    #expect(next.checks == 1)
    #expect(try store.task(task.id).state == .waiting)
    #expect(try store.latestEvent(taskId: task.id, kind: "codex.result") == nil)
    _ = try store.reportCheck(taskId: task.id, dispatchId: item.id, expectedRevision: plan.revision, outcome: "unchanged", summary: "Replay", nextCheck: nil, reason: "")
    #expect(try store.checkPlan(task.id) == next)
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "owner")
}

@Test func userChangesPauseAndClosureWinOverLateAgentReports() throws {
    let (store, task, plan) = try monitoredTask()
    let item = try deliver(store, plan)
    let user = try store.controlCheck(taskId: task.id, expectedRevision: plan.revision, paused: true, pinned: true, nextCheck: plan.nextCheck.addingTimeInterval(86400))
    #expect(throws: StoreError.self) { try store.reportCheck(taskId: task.id, dispatchId: item.id, expectedRevision: plan.revision, outcome: "changed", summary: "Late result", nextCheck: nil, reason: "") }
    #expect(throws: StoreError.self) { try store.planCheck(taskId: task.id, threadId: "owner", expectedRevision: user.revision, nextCheck: plan.nextCheck, purpose: "Override", reason: "Override", waitingOn: "Supplier") }
    #expect(try store.checkPlan(task.id) == user)
    _ = try store.update(task.id) { $0.state = .done }
    #expect(throws: StoreError.self) { try store.reportCheck(taskId: task.id, dispatchId: item.id, expectedRevision: user.revision, outcome: "changed", summary: "Reopen", nextCheck: nil, reason: "") }
    #expect(try store.task(task.id).state == .done)
}

@Test func busyDispatchDefersWithoutBlockingOtherTasksOrRepeatingIntent() throws {
    let (store, _, plan) = try monitoredTask()
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck)
    let busy = try #require(try store.claimDispatch(runnerId: "runner"))
    try store.deferDispatch(busy.id, runnerId: "runner", reason: "Waiting for user")
    let other = try store.create(FaciendaTask(title: "Independent task"))
    let next = try store.enqueueDispatch(taskId: other.id)
    #expect(try store.claimDispatch(runnerId: "runner")?.id == next.id)
    try saveEmptyDiscovery(store, next)
    _ = try store.beginDispatch(next.id, runnerId: "runner")
    try store.deferDispatch(next.id, runnerId: "runner", reason: "Uncertain delivery", blocked: true)
    #expect(try store.dispatches().first { $0.id == next.id }?.state == "dispatching")
    #expect(throws: StoreError.self) { try store.beginDispatch(next.id, runnerId: "runner") }
}

@Test func repeatedFailuresBackOffAndEscalateInsteadOfPollingForever() throws {
    let (store, task, first) = try monitoredTask()
    var plan = first
    for attempt in 1...3 {
        let item = try deliver(store, plan)
        let now = plan.nextCheck
        plan = try store.reportCheck(taskId: task.id, dispatchId: item.id, expectedRevision: plan.revision, outcome: "failed", summary: "Mail unavailable", nextCheck: now.addingTimeInterval(1), reason: "Retry later", now: now)
        #expect(plan.failures == attempt)
        if attempt < 3 { #expect(plan.nextCheck >= now.addingTimeInterval(first.minimumInterval * pow(2, Double(attempt)))) }
    }
    #expect(plan.paused)
    #expect(try store.task(task.id).state == .needsMe)
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck.addingTimeInterval(86400))
    #expect(try store.dispatches().count == 3)
}

@Test func cancelRunPreservesTaskAndReplyAndPausesCancelledCheck() throws {
    let (store, task, plan) = try monitoredTask()
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck)
    let check = try #require(try store.dispatches().first)
    try store.cancelDispatch(check.id)
    #expect(try store.task(task.id).state == .waiting)
    #expect(try store.checkPlan(task.id)?.paused == true)
    let reply = try store.enqueueDispatch(taskId: task.id, message: "Please check the other supplier instead")
    #expect(reply.threadId == "owner")
    #expect(reply.message == "Please check the other supplier instead")
    #expect(throws: StoreError.self) { try store.enqueueDispatch(taskId: task.id, message: "Do not lose this") }
    try store.cancelDispatch(reply.id)
    #expect(try store.tasks().count == 1)
    #expect(try store.task(task.id).state.isOpen)
    #expect(try store.latestEvent(taskId: task.id, kind: "user.reply")?.payload == reply.message)
}

@Test func deadlineAndMissingChatSurfaceWithoutCreatingReplacement() throws {
    let (store, task, plan) = try monitoredTask()
    try store.enqueueDueChecks(runnerId: "runner", now: plan.deadline)
    #expect(try store.checkPlan(task.id)?.paused == true)
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.dispatches().isEmpty)
    let (another, otherTask, otherPlan) = try monitoredTask()
    try another.unlink(try #require(try another.links().first))
    try another.enqueueDueChecks(runnerId: "runner", now: otherPlan.nextCheck)
    #expect(try another.task(otherTask.id).state == .needsMe)
    #expect(try another.dispatches().isEmpty)
}

@Test func userCanPauseAnAppointmentAtItsReviewDeadline() throws {
    let (store, task, plan) = try monitoredTask()
    let paused = try store.controlCheck(taskId: task.id, expectedRevision: plan.revision, paused: true, pinned: true, nextCheck: plan.deadline)
    #expect(paused.paused)
    #expect(paused.nextCheck == paused.deadline)
}

@Test func aReplyPausesChecksButTheChatMayPlanAgainWhileAUserPauseHolds() throws {
    let (store, task, plan) = try monitoredTask()
    _ = try store.enqueueDispatch(taskId: task.id, message: "They still haven't come by")
    let paused = try #require(try store.checkPlan(task.id))
    #expect(paused.pausedForReply)
    let later = Date().addingTimeInterval(3600)
    let replanned = try store.planCheck(taskId: task.id, threadId: "owner", expectedRevision: paused.revision, nextCheck: later, purpose: "Look for the pickup scan", reason: "The window ends at 19:00", waitingOn: "Courier")
    #expect(!replanned.paused && abs(replanned.nextCheck.timeIntervalSince(later)) < 1 && replanned.failures == 0)
    #expect(try store.task(task.id).state == .waiting)

    let held = try store.controlCheck(taskId: task.id, expectedRevision: replanned.revision, paused: true, pinned: false, nextCheck: later)
    #expect(throws: StoreError.self) {
        try store.planCheck(taskId: task.id, threadId: "owner", expectedRevision: held.revision, nextCheck: later.addingTimeInterval(60), purpose: "Again", reason: "Again", waitingOn: "Courier")
    }
    _ = plan
}

@Test func aCheckWhoseChatTheCodexAppHoldsRunsInAnUnlinkedCopy() throws {
    let (store, task, plan) = try monitoredTask()
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck)
    let item = try #require(try store.claimDispatch(runnerId: "runner"))
    // Put off while Codex held the chat, as before copies.
    try store.deferDispatch(item.id, runnerId: "runner", reason: "The chat is open in the Codex app.")
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    try store.runCheckInCopy(item.id, runnerId: "runner", threadId: "copy")
    // What the copy's turn asks reaches the task.
    let asked = try store.recordCodexApproval(method: "item/fileChange/requestApproval",
                                              params: .object(["threadId": .string("copy"), "turnId": .string("turn-1"), "itemId": .string("patch-1")]), requestId: .number(1))
    #expect(asked.taskId == task.id)
    try store.acknowledgeDispatch(item.id, runnerId: "runner", threadId: "copy")
    let started = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(started.state == "started" && started.threadId == "copy" && store.isCheckCopy(started))
    // The task keeps its own chat, and its next check goes there.
    #expect(try store.links(taskId: task.id).map(\.codexThreadId) == ["owner"])
    let next = try store.reportCheck(taskId: task.id, dispatchId: item.id, expectedRevision: plan.revision, outcome: "unchanged", summary: "No reply yet", nextCheck: nil, reason: "", now: plan.nextCheck)
    #expect(next.threadId == "owner" && next.checks == 1)
    #expect(try store.task(task.id).state == .waiting)
}

@Test func aCheckCodexRefusedInACopyGoesBackToItsChat() throws {
    let (store, _, plan) = try monitoredTask()
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck)
    let item = try #require(try store.claimDispatch(runnerId: "runner"))
    // Only a check on its way can move to a copy.
    #expect(throws: StoreError.self) { try store.runCheckInCopy(item.id, runnerId: "runner", threadId: "copy") }
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    try store.runCheckInCopy(item.id, runnerId: "runner", threadId: "copy")
    try store.releaseUndelivered(item.id, runnerId: "runner", reason: "Refused")
    let released = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(released.state == "queued" && released.threadId == "owner" && !store.isCheckCopy(released))
}
