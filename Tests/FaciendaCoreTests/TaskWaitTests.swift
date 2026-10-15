import Foundation
import Testing
@testable import FaciendaCore

private func waitStore() throws -> FaciendaStore {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "waits-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    return store
}
private let hour: TimeInterval = 3600

@Test func reminderParksThenReturnsWithItsNote() throws {
    let store = try waitStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Lighting", state: .needsMe, nextAction: "Review"))
    try store.park(task.id, plan: WaitPlan(conditions: [.time(now.addingTimeInterval(hour))], note: "Ask Robin", summary: "Until later"), now: now)
    #expect(try store.task(task.id).state == .scheduled)
    // The plain reminder sweep leaves parked tasks to their wait.
    #expect(try store.claimDue(now: now.addingTimeInterval(2 * hour)).isEmpty)
    #expect(try store.claimWaitNotices(now: now.addingTimeInterval(60)).isEmpty)
    let ended = try store.claimWaitNotices(now: now.addingTimeInterval(2 * hour))
    #expect(ended.map(\.state) == ["met"])
    let woken = try store.task(task.id)
    #expect(woken.state == .needsMe && woken.nextAction == "Ask Robin")
    #expect(try store.claimWaitNotices(now: now.addingTimeInterval(3 * hour)).isEmpty)
}

@Test func dependencyWaitStartsWorkWhenThePrerequisiteIsDone() throws {
    let store = try waitStore()
    let first = try store.create(FaciendaTask(title: "Measure")), task = try store.create(FaciendaTask(title: "Order", state: .needsMe, nextAction: "Order"))
    try store.park(task.id, plan: WaitPlan(conditions: [.task(first.id)], then: .work))
    #expect(try store.task(task.id).state == .waiting)
    #expect(try store.task(task.id).waitingOn == "Measure")
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    _ = try store.update(first.id) { $0.state = .done }
    let start = try #require(try store.claimDispatch(runnerId: "runner"))
    #expect(start.taskId == task.id && start.kind == "start")
    #expect(try store.wait(task.id)?.state == "met")
    // Handed-over work is not announced as a reminder.
    #expect(try store.claimWaitNotices().isEmpty)
}

@Test func droppedPrerequisiteBringsTheTaskBackInsteadOfStartingIt() throws {
    let store = try waitStore()
    let first = try store.create(FaciendaTask(title: "Measure")), task = try store.create(FaciendaTask(title: "Order", state: .needsMe, nextAction: "Order"))
    try store.park(task.id, plan: WaitPlan(conditions: [.task(first.id)], then: .work))
    _ = try store.update(first.id) { $0.state = .dropped }
    #expect(try store.claimDispatch(runnerId: "runner") == nil)
    #expect(try store.wait(task.id)?.state == "blocked")
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.task(task.id).nextAction == "Measure is not happening")
    #expect(try store.blockers(taskId: task.id).isEmpty)
}

@Test func observedWaitChecksInTheTaskChatAndGivesUp() throws {
    let store = try waitStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Mail Robin", state: .needsMe, nextAction: "Wait"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    let plan = WaitPlan(conditions: [.observed("Robin", source: "Mail", criterion: "Robin replied")], giveUpAt: now.addingTimeInterval(72 * hour))
    try store.park(task.id, plan: plan, now: now)
    let check = try #require(try store.checkPlan(task.id))
    #expect(abs(check.deadline.timeIntervalSince(now.addingTimeInterval(72 * hour))) < 0.01 && !check.paused)
    #expect(try store.task(task.id).state == .waiting)
    #expect(try store.claimWaitNotices(now: now.addingTimeInterval(hour)).isEmpty)
    let ended = try store.claimWaitNotices(now: now.addingTimeInterval(73 * hour))
    #expect(ended.first?.state == "gaveUp" && ended.first?.outcome == "Gave up waiting for Robin")
    #expect(try store.task(task.id).state == .needsMe)
    // Giving up removes what parking added.
    #expect(try store.checkPlan(task.id) == nil)
    #expect(try store.blockers(taskId: task.id).isEmpty)
}

@Test func observedWaitWithoutAChatAsksForACheckingChat() throws {
    let store = try waitStore()
    let task = try store.create(FaciendaTask(title: "Mail Robin", state: .needsMe, nextAction: "Wait"))
    try store.park(task.id, plan: WaitPlan(conditions: [.observed("Robin", source: "Mail", criterion: "Robin replied")]))
    #expect(try store.claimDispatch(runnerId: "runner")?.kind == "assess")
    #expect(throws: StoreError.self) { try store.park(task.id, plan: WaitPlan(conditions: [.time(Date().addingTimeInterval(hour))], then: .tell, note: "Continue")) }
}

@Test func aResultArrivingWhileParkedStaysQuietUntilTheWaitEnds() throws {
    let store = try waitStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Draft", state: .running, nextAction: "Draft"))
    try store.park(task.id, plan: WaitPlan(conditions: [.time(now.addingTimeInterval(hour))]), now: now)
    #expect(try store.task(task.id).state == .running)
    try store.saveResult(taskId: task.id, text: "Done drafting")
    #expect(try store.task(task.id).state == .scheduled)
    _ = try store.claimWaitNotices(now: now.addingTimeInterval(2 * hour))
    #expect(try store.task(task.id).state == .needsMe)
}

@Test func wakingReplyingAndClosingEndTheWait() throws {
    let store = try waitStore()
    let other = try store.create(FaciendaTask(title: "Other")), task = try store.create(FaciendaTask(title: "A", state: .needsMe, nextAction: "A"))
    try store.park(task.id, plan: WaitPlan(conditions: [.task(other.id)]))
    try store.wake(task.id)
    #expect(try store.task(task.id).state == .needsMe && store.wait(task.id)?.state == "cancelled")
    #expect(try store.blockers(taskId: task.id).isEmpty)
    try store.park(task.id, plan: WaitPlan(conditions: [.task(other.id)]))
    _ = try store.enqueueDispatch(taskId: task.id)
    #expect(try store.wait(task.id)?.state == "cancelled")
    try store.park(task.id, plan: WaitPlan(conditions: [.time(Date().addingTimeInterval(hour))]))
    _ = try store.update(task.id) { $0.state = .done }
    #expect(try store.wait(task.id)?.state == "cancelled")
    #expect(try store.claimWaitNotices().isEmpty)
}

@Test func parkingDoesNotChurnTheTaskOnEveryTick() throws {
    let store = try waitStore(), now = Date()
    let other = try store.create(FaciendaTask(title: "Other")), task = try store.create(FaciendaTask(title: "A", state: .needsMe, nextAction: "A"))
    try store.park(task.id, plan: WaitPlan(conditions: [.task(other.id), .time(now.addingTimeInterval(hour))]), now: now)
    let revision = try store.task(task.id).revision
    for _ in 0..<3 { _ = try store.claimDispatch(runnerId: "runner"); _ = try store.claimWaitNotices(now: now.addingTimeInterval(60)) }
    #expect(try store.task(task.id).revision == revision)
}

@Test func plansAreValidatedBeforeAnythingIsSaved() throws {
    let now = Date()
    #expect(throws: StoreError.self) { try WaitPlan(conditions: []).validate(now: now) }
    #expect(throws: StoreError.self) { try WaitPlan(conditions: [.time(now.addingTimeInterval(-60))]).validate(now: now) }
    #expect(throws: StoreError.self) { try WaitPlan(conditions: [.time(now.addingTimeInterval(hour))], giveUpAt: now.addingTimeInterval(2 * hour)).validate(now: now) }
    #expect(throws: StoreError.self) { try WaitPlan(conditions: [.observed("X", source: "", criterion: "replied")]).validate(now: now) }
    #expect(throws: StoreError.self) { try WaitPlan(conditions: [.time(now.addingTimeInterval(hour))], then: .tell).validate(now: now) }
}

@Test func modelRepliesAreCheckedAgainstKnownTasksAndTheClock() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let task = FaciendaTask(title: "Order"), other = FaciendaTask(title: "Measure")
    let candidates = WaitCompiler.candidates(for: task, among: [task, other])
    #expect(candidates.map(\.handle) == ["T1"] && candidates.first?.taskId == other.id)
    let good = #"{"question":null,"wait":{"conditions":[{"kind":"task","at":null,"task":"T1","what":null,"source":null,"criterion":null},{"kind":"observed","at":null,"task":null,"what":"Robin","source":"Mail","criterion":"Robin replied"}],"giveUpAt":"2027-01-20T08:00:00+01:00","then":"surface","note":"Ask Robin"}}"#
    guard case .plan(let plan) = try WaitCompiler.resolve(good, candidates: candidates, hasChat: false, now: now) else { Issue.record("Expected a plan"); return }
    #expect(plan.conditions.map(\.kind) == [.task, .observed] && plan.conditions.first?.taskId == other.id)
    #expect(plan.giveUpAt == WaitCompiler.parseDate("2027-01-20T07:00:00Z") && plan.summary.hasPrefix("Until “Measure” is done and Robin replied, or "))
    #expect(try WaitCompiler.resolve(#"{"question":"Which mail?","wait":null}"#, candidates: candidates, hasChat: false, now: now) == .question("Which mail?"))
    // An invented task, a past time, or telling a chat that does not exist is refused.
    #expect(throws: StoreError.self) { try WaitCompiler.resolve(good.replacingOccurrences(of: "T1", with: other.id), candidates: candidates, hasChat: false, now: now) }
    #expect(throws: StoreError.self) { try WaitCompiler.resolve(good.replacingOccurrences(of: "2027-01-20", with: "2020-01-20"), candidates: candidates, hasChat: false, now: now) }
    #expect(throws: StoreError.self) { try WaitCompiler.resolve(good.replacingOccurrences(of: "\"surface\"", with: "\"tell\""), candidates: candidates, hasChat: false, now: now) }
    #expect(throws: StoreError.self) { try WaitCompiler.resolve("not json", candidates: candidates, hasChat: true, now: now) }
}

@Test func cadenceSetsTheCheckRhythmAndTheCapFollowsIt() throws {
    let store = try waitStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Mail Robin", state: .needsMe, nextAction: "Wait"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    let plan = WaitPlan(conditions: [.observed("Robin", source: "Mail", criterion: "Robin replied")], giveUpAt: now.addingTimeInterval(72 * hour))
    #expect(plan.checkInterval == 4 * hour)
    try store.park(task.id, plan: plan, now: now)
    let check = try #require(try store.checkPlan(task.id))
    #expect(check.minimumInterval == 4 * hour && check.reason.hasPrefix("Look about every 4 hours"))
    // Hourly for three days needs more than twenty looks; a plain plan still stops at twenty.
    var hourly = check; hourly.minimumInterval = hour
    #expect(hourly.checkLimit(now: now) >= 72 && check.checkLimit(now: now) == 20)
    #expect(throws: StoreError.self) { try WaitPlan(conditions: plan.conditions, checkEvery: 600).validate(now: now) }
    let said = #"{"question":null,"wait":{"conditions":[{"kind":"observed","at":null,"task":null,"what":"Robin","source":"Mail","criterion":"replied"}],"giveUpAt":null,"then":"surface","note":"","checkEveryHours":12}}"#
    guard case .plan(let parsed) = try WaitCompiler.resolve(said, candidates: [], hasChat: true, now: now) else { Issue.record("Expected a plan"); return }
    #expect(parsed.checkEvery == 12 * hour && parsed.summary.hasSuffix("checking every 12 hours; then bring it to me."))
}

@Test func headlinesFollowTheLatestResultAndStayOneShortLine() throws {
    let store = try waitStore()
    let task = try store.create(FaciendaTask(title: "Track the PostX parcel", state: .running, nextAction: "Watch"))
    try store.saveResult(taskId: task.id, text: "## Delivery\n- PostX replied today.\n- They plan to deliver on 6 October but will not leave it outside 3B.")
    let first = try #require(try store.latestResults().first { $0.taskId == task.id })
    #expect(TaskHeadline.fallback(first.excerpt) == "PostX replied today. They plan to deliver on 6 October but…")
    try store.saveHeadline(taskId: task.id, eventId: first.eventId, text: "PostX: delivering today, 6 Oct;\nwon't leave it outside **3B**")
    #expect(try store.headlines().first?.text == "PostX: delivering today, 6 Oct; won't leave it outside 3B")
    // A newer result makes the old headline stale, and a late write for the old one is refused.
    try store.saveResult(taskId: task.id, text: "Delivered at 14:10.")
    #expect(throws: StoreError.self) { try store.saveHeadline(taskId: task.id, eventId: first.eventId, text: "Old") }
    #expect(try store.latestResults().first { $0.taskId == task.id }?.excerpt == "Delivered at 14:10.")
    #expect(TaskHeadline.clip(String(repeating: "word ", count: 60)).count <= TaskHeadline.maximumLength)
    #expect(try HeadlineWriter.read(#"{"headline":"PostX: today, 6 Oct"}"#) == "PostX: today, 6 Oct")
}

@Test func anOpenQuestionNewerThanTheResultIsWhatTheHeadlineSays() throws {
    let store = try waitStore()
    let task = try store.create(FaciendaTask(title: "Plan a weekend", state: .running, nextAction: "Plan"))
    try store.saveResult(taskId: task.id, text: "Three hotels shortlisted.")
    try store.requestDecision(Decision(taskId: task.id, question: "Which dates should I check?", recommendation: "First weekend", options: ["First weekend", "Second weekend"]))
    let source = try #require(try store.latestResults().first { $0.taskId == task.id })
    #expect(source.isQuestion && source.excerpt == "Which dates should I check?")
    try store.saveHeadline(taskId: task.id, eventId: source.eventId, text: "Needs: dates")
    // Once answered, the question no longer counts and the result is the source again.
    try store.answerDecision(try #require(try store.decisions(taskId: task.id).first).id, answer: "First weekend")
    #expect(try store.latestResults().first { $0.taskId == task.id }?.isQuestion == false)
}

@Test func optionsKeepOnlyValidWaitsAndTheChatExcerptKeepsTheNewestMessages() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reply = #"{"options":[{"label":"Until Simon replies · give up Tue","conditions":[{"kind":"observed","at":null,"task":null,"what":"Simon","source":"Gmail thread 'Order 5120'","criterion":"Simon replied"}],"giveUpAt":"2027-01-20T08:00:00+01:00","then":"surface","note":"","checkEveryHours":null},{"label":"Yesterday","conditions":[{"kind":"time","at":"2020-01-01T08:00:00Z","task":null,"what":null,"source":null,"criterion":null}],"giveUpAt":null,"then":"surface","note":"","checkEveryHours":null}]}"#
    let options = WaitCompiler.options(reply, candidates: [], hasChat: true, now: now)
    #expect(options.map(\.label) == ["Until Simon replies · give up Tue"])
    #expect(options.first?.plan.conditions.first?.source == "Gmail thread 'Order 5120'")
    let turn = { (id: String, user: String, answer: String) in
        CodexConversationTurn(id: id, status: "completed", startedAt: nil, completedAt: nil, error: .null, items: [
            .object(["type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string(user)])])]),
            .object(["type": .string("agentMessage"), "text": .string(answer)])])
    }
    let conversation = CodexConversation(threadId: "chat", title: "Chairs", turns: [turn("1", "find the thread", "Found it"), turn("2", "send it", "Sent to Simon at 11:52")])
    let excerpt = WaitCompiler.chatExcerpt(conversation, originalRequest: "Chairs", dispatches: [], latestResult: "Sent to Simon at 11:52", limit: 60)
    #expect(excerpt == "USER: send it\n\nASSISTANT: Sent to Simon at 11:52")
}

@Test func storedOptionsBelongToTheLatestSourceAndDropOncePast() throws {
    let store = try waitStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Return chairs", state: .running, nextAction: "Return"))
    try store.saveResult(taskId: task.id, text: "Sent the return request to Simon.")
    let source = try #require(try store.latestResults().first { $0.taskId == task.id })
    let soon = WaitCompiler.Option(label: "Remind me in a minute", plan: WaitPlan(conditions: [.time(now.addingTimeInterval(60))]))
    let later = WaitCompiler.Option(label: "Until Simon replies", plan: WaitPlan(conditions: [.observed("Simon", source: "Gmail", criterion: "Simon replied")]))
    try store.saveWaitOptions(taskId: task.id, eventId: source.eventId, options: [soon, later])
    let stored = try #require(try store.waitOptions().first)
    #expect(stored.options.map(\.label) == [soon.label, later.label])
    #expect(stored.current(now: now.addingTimeInterval(120)).map(\.label) == ["Until Simon replies"])
    try store.saveResult(taskId: task.id, text: "Simon answered.")
    #expect(throws: StoreError.self) { try store.saveWaitOptions(taskId: task.id, eventId: source.eventId, options: [later]) }
}

@Test func parkingIsUndoneAndTheOutcomeIsDecidedNotAsked() throws {
    let store = try waitStore()
    let first = try store.create(FaciendaTask(title: "Measure")), task = try store.create(FaciendaTask(title: "Order", state: .needsMe, nextAction: "Order"))
    try store.park(task.id, plan: WaitPlan(conditions: [.task(first.id)]))
    #expect(try store.task(task.id).state == .waiting)
    try store.unpark(task.id)
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.wait(task.id)?.state == "cancelled")
    #expect(try store.blockers(taskId: task.id).isEmpty)
    // A task nobody started yet starts when what it waits on is done; anything else comes back to the user.
    let fresh = FaciendaTask(title: "New", state: .inbox)
    #expect(WaitCompiler.settled(WaitPlan(conditions: [.task(first.id)]), task: fresh, hasChat: false).then == .work)
    #expect(WaitCompiler.settled(WaitPlan(conditions: [.task(first.id)]), task: task, hasChat: true).then == .surface)
    #expect(WaitCompiler.settled(WaitPlan(conditions: [.time(Date().addingTimeInterval(60))]), task: fresh, hasChat: false).then == .surface)
}
