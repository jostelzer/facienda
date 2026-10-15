import Foundation
import Testing
@testable import FaciendaCore

private func dependencyStore() throws -> FaciendaStore {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "blockers-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    return store
}
private func reportCondition(_ store: FaciendaStore, task: FaciendaTask, reports: [BlockerObservation], now: Date = Date()) throws {
    let plan = try #require(try store.checkPlan(task.id))
    try store.enqueueDueChecks(runnerId: "runner", now: max(now, plan.nextCheck))
    let check = try #require(try store.claimDispatch(runnerId: "runner"))
    #expect(check.kind == "check")
    _ = try store.beginDispatch(check.id, runnerId: "runner")
    try store.acknowledgeDispatch(check.id, runnerId: "runner", threadId: "owner")
    _ = try store.reportCheck(taskId: task.id, dispatchId: check.id, expectedRevision: plan.revision, outcome: "changed", summary: "Checked fixture source", nextCheck: now.addingTimeInterval(3600), reason: "Wait for remaining conditions", blockerReports: reports, now: now)
}

@Test func dependenciesRequireAllDoneAndExplicitArming() throws {
    let store = try dependencyStore()
    let a = try store.create(FaciendaTask(title: "A")), b = try store.create(FaciendaTask(title: "B")), target = try store.create(FaciendaTask(title: "C"))
    try store.addTaskDependencies(taskId: target.id, prerequisiteIDs: [a.id, b.id, a.id])
    #expect(try store.blockers(taskId: target.id).count == 2)
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    _ = try store.update(a.id) { $0.state = .done }
    _ = try store.update(b.id) { $0.state = .dropped }
    _ = try store.setReadiness(taskId: target.id, armed: true, userInstruction: "Start when both are done")
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    #expect(try store.claimDue(now: Date().addingTimeInterval(86400)).isEmpty)
    _ = try store.update(b.id) { $0.state = .done }
    let ready = try #require(try store.claimDispatch(runnerId: "runner"))
    #expect(ready.taskId == target.id)
    try saveEmptyDiscovery(store, ready)
    _ = try store.beginDispatch(ready.id, runnerId: "runner")
    try store.acknowledgeDispatch(ready.id, runnerId: "runner", threadId: "target-chat")
    #expect(try store.readiness(target.id).armed == false)
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
}

@Test func cyclesAndAgentCompletionCannotSatisfyPrerequisites() throws {
    let store = try dependencyStore()
    let a = try store.create(FaciendaTask(title: "A")), b = try store.create(FaciendaTask(title: "B")), c = try store.create(FaciendaTask(title: "C"))
    try store.addTaskDependencies(taskId: a.id, prerequisiteIDs: [b.id])
    try store.addTaskDependencies(taskId: b.id, prerequisiteIDs: [c.id])
    #expect(throws: StoreError.self) { try store.addTaskDependencies(taskId: c.id, prerequisiteIDs: [a.id]) }
    #expect(throws: StoreError.self) { try store.addTaskDependencies(taskId: a.id, prerequisiteIDs: [a.id]) }
    #expect(throws: StoreError.self) { try store.update(b.id, source: .mcp) { $0.state = .done } }
    _ = try store.requestDecision(Decision(taskId: b.id, question: "Done?", context: "Agent says done", recommendation: "Yes", options: ["Yes"], kind: "completion"))
    #expect(try store.blockers(taskId: a.id).first?.isMet(tasks: store.tasks()) == false)
    #expect(throws: StoreError.self) { try store.update(a.id, source: .mcp) { $0.state = .running } }
}

@Test func scheduledDateAndReopenedPrerequisiteGateEvenClaimedWork() throws {
    let store = try dependencyStore()
    let a = try store.create(FaciendaTask(title: "A")), target = try store.create(FaciendaTask(title: "Later", state: .scheduled, returnAt: Date().addingTimeInterval(3600)))
    try store.addTaskDependencies(taskId: target.id, prerequisiteIDs: [a.id])
    _ = try store.setReadiness(taskId: target.id, armed: true, notBefore: Date().addingTimeInterval(3600), userInstruction: "Start later")
    _ = try store.update(a.id) { $0.state = .done }
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    _ = try store.setReadiness(taskId: target.id, armed: true, notBefore: Date().addingTimeInterval(-1), userInstruction: "Start now when ready")
    let claimed = try #require(try store.claimDispatch(runnerId: "runner"))
    _ = try store.update(a.id) { $0.state = .inbox; $0.returnAt = Date() }
    #expect(throws: StoreError.self) { try store.beginDispatch(claimed.id, runnerId: "runner") }
    #expect(try store.dispatches().first { $0.id == claimed.id }?.state == "held")
    try store.cancelDispatch(claimed.id)
    _ = try store.update(a.id) { $0.state = .done }
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    #expect(try store.task(target.id).state.isOpen)
}

@Test func externalEvidenceIsAtomicPartialAndFreshnessAware() throws {
    let store = try dependencyStore()
    let target = try store.create(FaciendaTask(title: "Release"))
    try store.link(ThreadLink(taskId: target.id, codexThreadId: "owner"))
    let a = try store.setExternalBlocker(taskId: target.id, kind: "person", title: "Approval", sourceReference: "Mail fixture", criterion: "Explicit yes", freshnessSeconds: nil)
    let b = try store.setExternalBlocker(taskId: target.id, kind: "condition", title: "Service healthy", sourceReference: "Health fixture", criterion: "All checks pass", freshnessSeconds: 60)
    _ = try store.setReadiness(taskId: target.id, armed: true, userInstruction: "Start when ready")
    try reportCondition(store, task: target, reports: [.init(blockerId: a.id, expectedRevision: 1, status: "met", evidence: "Mail: yes"), .init(blockerId: b.id, expectedRevision: 1, status: "unknown", evidence: "Health source unavailable")])
    #expect(try store.checkPlan(target.id)?.paused == false)
    #expect(try store.dispatches().filter { $0.kind == "ready" }.first?.state == "held")
    let plan = try #require(try store.checkPlan(target.id))
    _ = try store.controlCheck(taskId: target.id, expectedRevision: plan.revision, paused: false, pinned: false, nextCheck: Date())
    try reportCondition(store, task: target, reports: [.init(blockerId: b.id, expectedRevision: 1, status: "met", evidence: "Health: passing")], now: Date().addingTimeInterval(-120))
    // By delivery time the observation has expired: the execution is held and a fresh check wins.
    let next = try #require(try store.claimDispatch(runnerId: "runner"))
    #expect(next.kind == "check")
    #expect(try store.dispatches().first { $0.kind == "ready" }?.state == "held")
}

@Test func editsRejectLateConditionReportsWithoutLosingEvidence() throws {
    let store = try dependencyStore()
    let target = try store.create(FaciendaTask(title: "Check"))
    try store.link(ThreadLink(taskId: target.id, codexThreadId: "owner"))
    let b = try store.setExternalBlocker(taskId: target.id, kind: "person", title: "Reply", sourceReference: "Mail", criterion: "Yes", freshnessSeconds: nil)
    let check = try #require(try store.claimDispatch(runnerId: "runner"))
    _ = try store.beginDispatch(check.id, runnerId: "runner")
    try store.acknowledgeDispatch(check.id, runnerId: "runner", threadId: "owner")
    _ = try store.setExternalBlocker(taskId: target.id, id: b.id, expectedRevision: 1, kind: "person", title: "Reply", sourceReference: "Mail", criterion: "Signed approval", freshnessSeconds: nil)
    #expect(throws: StoreError.self) { try store.reportCheck(taskId: target.id, dispatchId: check.id, expectedRevision: check.checkRevision!, outcome: "changed", summary: "Old yes", nextCheck: nil, reason: "", blockerReports: [.init(blockerId: b.id, expectedRevision: 1, status: "met", evidence: "Old condition")]) }
    #expect(try store.blockers(taskId: target.id).first?.status == "unknown")
}

@Test func newConditionGetsOneOwningChatWithoutStartingBlockedWork() throws {
    let store = try dependencyStore()
    let target = try store.create(FaciendaTask(title: "Wait then act"))
    _ = try store.setExternalBlocker(taskId: target.id, kind: "condition", title: "Ready", sourceReference: "Fixture", criterion: "Ready flag", freshnessSeconds: nil)
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    _ = try store.setReadiness(taskId: target.id, armed: true, userInstruction: "Start when ready")
    let setup = try #require(try store.claimDispatch(runnerId: "runner"))
    #expect(setup.kind == "assess")
    try saveEmptyDiscovery(store, setup)
    _ = try store.beginDispatch(setup.id, runnerId: "runner")
    try store.acknowledgeDispatch(setup.id, runnerId: "runner", threadId: "owner")
    #expect(try store.checkPlan(target.id)?.threadId == "owner")
    #expect(try store.claimDispatch(runnerId: "runner")?.kind == "check")
}

@Test func repeatedReconciliationDoesNotChangeTaskRevision() throws {
    let store = try dependencyStore()
    let a = try store.create(FaciendaTask(title: "A")), b = try store.create(FaciendaTask(title: "B"))
    try store.addTaskDependencies(taskId: b.id, prerequisiteIDs: [a.id])
    let revision = try store.task(b.id).revision
    for _ in 0..<3 { _ = try store.claimDispatch(runnerId: "runner") }
    #expect(try store.task(b.id).revision == revision)
}

@Test func volatileConditionsWaitUntilOtherPrerequisitesAreReadyToRecheck() throws {
    let store = try dependencyStore()
    let prerequisite = try store.create(FaciendaTask(title: "Prepare"))
    let target = try store.create(FaciendaTask(title: "Execute later"))
    try store.link(ThreadLink(taskId: target.id, codexThreadId: "owner"))
    try store.addTaskDependencies(taskId: target.id, prerequisiteIDs: [prerequisite.id])
    let condition = try store.setExternalBlocker(taskId: target.id, kind: "condition", title: "Healthy", sourceReference: "Fixture", criterion: "Healthy now", freshnessSeconds: 60)
    _ = try store.setReadiness(taskId: target.id, armed: true, userInstruction: "Start when ready")
    try reportCondition(store, task: target, reports: [.init(blockerId: condition.id, expectedRevision: 1, status: "met", evidence: "Healthy")], now: Date().addingTimeInterval(-120))
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    _ = try store.update(prerequisite.id) { $0.state = .done }
    #expect(try store.claimDispatch(runnerId: "runner")?.kind == "check")
}
