import Foundation
import Testing
@testable import FaciendaCore

private func stepStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/steps.sqlite"))
}

@Test func aStepWithoutATimeStaysQuietUntilTheUserSaysHowItWent() throws {
    let store = try stepStore()
    let task = try store.create(FaciendaTask(title: "Get the deposit back", state: .needsMe, nextAction: "Review"))
    #expect(throws: StoreError.self) { try store.takeOn(task.id, step: "  ") }
    try store.takeOn(task.id, step: "Call the landlord")
    #expect(try store.ownSteps().map(\.text) == ["Call the landlord"])
    #expect(try store.task(task.id).nextAction == "Call the landlord")
    // No reminder was asked for, so nothing is parked and nothing will notify.
    #expect(try store.waits().isEmpty)
    #expect(try store.claimWaitNotices(now: Date().addingTimeInterval(7 * 86400)).isEmpty)
    try store.finishStep(task.id, done: true)
    #expect(try store.ownSteps().isEmpty)
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.events(taskId: task.id).contains { $0.kind == "step.done" && $0.payload == "Call the landlord" })
}

@Test func aStepWithATimeRemindsOnceWithTheStepAsWhatToDo() throws {
    let store = try stepStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Get the deposit back", state: .needsMe, nextAction: "Review"))
    #expect(throws: StoreError.self) { try store.takeOn(task.id, step: "Call the landlord", remindAt: now.addingTimeInterval(-60), now: now) }
    #expect(try store.ownSteps().isEmpty)
    try store.takeOn(task.id, step: "Call the landlord", remindAt: now.addingTimeInterval(3600), now: now)
    #expect(try store.waits().first?.isActive == true)
    #expect(try store.claimWaitNotices(now: now.addingTimeInterval(60)).isEmpty)
    // At the time: one notice, the task is back with the step as its next action, and the step stays until the user answers.
    let notices = try store.claimWaitNotices(now: now.addingTimeInterval(3700))
    #expect(notices.count == 1)
    #expect(try store.claimWaitNotices(now: now.addingTimeInterval(7200)).isEmpty)
    let back = try store.task(task.id)
    #expect(back.state == .needsMe && back.nextAction == "Call the landlord")
    #expect(try store.ownSteps().count == 1)
}

@Test func doingItEarlyOrDroppingItEndsTheReminderAndClosingClearsTheStep() throws {
    let store = try stepStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Get the deposit back", state: .needsMe, nextAction: "Review"))
    try store.takeOn(task.id, step: "Call the landlord", remindAt: now.addingTimeInterval(86400), now: now)
    try store.finishStep(task.id, done: false, now: now.addingTimeInterval(60))
    #expect(try store.waits().allSatisfy { !$0.isActive })
    #expect(try store.task(task.id).state == .needsMe)
    #expect(try store.claimWaitNotices(now: now.addingTimeInterval(2 * 86400)).isEmpty)
    #expect(throws: StoreError.self) { try store.finishStep(task.id, done: true) }
    try store.takeOn(task.id, step: "Sign the form")
    try store.update(task.id) { $0.state = .done }
    #expect(try store.ownSteps().isEmpty)
}

@Test func typedStepsAreSplitIntoTheActionAndAFutureTime() {
    let now = Date()
    let soon = ISO8601DateFormatter().string(from: now.addingTimeInterval(86400))
    let read = OwnStepReader.read(#"{"step":"Call the landlord","at":"\#(soon)"}"#, typed: "call landlord tmrw", now: now)
    #expect(read.step == "Call the landlord" && read.at != nil)
    let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400))
    #expect(OwnStepReader.read(#"{"step":"Call the landlord","at":"\#(past)"}"#, typed: "x", now: now).at == nil)
    #expect(OwnStepReader.read("not json", typed: " call the landlord ", now: now) == ("call the landlord", nil))
    #expect(OwnStepReader.prompt(task: "Deposit", text: "call\nlandlord").contains("TEXT: call landlord"))
}

@Test func continuationsBelongToTheLatestResult() throws {
    let store = try stepStore()
    let task = try store.create(FaciendaTask(title: "Buy a desk", state: .running, nextAction: "Shortlist"))
    try store.saveResult(taskId: task.id, text: "The oak desk is best value. Nothing ordered.")
    let first = try #require(try store.latestResults().first { $0.taskId == task.id })
    let read = NextStepWriter.read(#"{"continuation":{"label":"Order the oak desk.","instruction":"Order the oak desk and tell me the delivery date."},"yourStep":null}"#, taskId: task.id, eventId: first.eventId)
    #expect(read.label == "Order the oak desk" && read.instruction?.hasPrefix("Order") == true && read.yourStep == nil)
    #expect(NextStepWriter.read(#"{"continuation":null,"yourStep":"Measure the alcove"}"#, taskId: task.id, eventId: first.eventId).yourStep == "Measure the alcove")
    #expect(NextStepWriter.read("garbage", taskId: task.id, eventId: first.eventId).label == nil)
    try store.saveNextSteps(read)
    try store.saveResult(taskId: task.id, text: "Ordered. Arrives Thursday.")
    #expect(throws: StoreError.self) { try store.saveNextSteps(read) }
    var note = MemoryFact(kind: "preference", text: "Prefers oak", source: "user"); note.confirmedAt = Date()
    #expect(NextStepWriter.memoryExcerpt(notes: [MemoryFact(text: "Budget 300 €", source: "chat"), note]).hasPrefix("CONFIRMED (preference): Prefers oak\nNOTE (fact): Budget 300 €"))
}

@Test func agentWatchesDefaultToEveryFourHoursForAWeekAndGiveUpIntoTheUsersCheck() throws {
    let now = Date()
    let watched = WaitPlan(conditions: [.observed("Robin", source: "Gmail, thread 'Lighting quote'", criterion: "Robin replied in that thread")])
    let plan = WaitCompiler.watch(watched, now: now)
    #expect(plan.checkInterval == 4 * 3600 && plan.giveUpAt == now.addingTimeInterval(7 * 86400))
    let changed = WaitCompiler.watch(watched, cadence: 86400, span: 3 * 86400, now: now)
    #expect(changed.checkInterval == 86400 && changed.giveUpAt == now.addingTimeInterval(3 * 86400))
    // A monthly check set for a week still gets its one look.
    let monthly = WaitCompiler.watch(watched, cadence: 30 * 86400, span: 7 * 86400, now: now)
    #expect(monthly.giveUpAt == now.addingTimeInterval(30 * 86400))
    #expect((try? monthly.validate(now: now)) != nil)
    #expect(WaitCompiler.watchCadences.map(\.label) == ["every hour", "every 4 hours", "daily", "once a week", "once a month"])
    // What the user typed ("or Friday") is kept unless they change it in the menu; plain reminders are left alone.
    var typed = watched; typed.giveUpAt = now.addingTimeInterval(2 * 86400)
    #expect(WaitCompiler.watch(typed, now: now).giveUpAt == typed.giveUpAt)
    let reminder = WaitPlan(conditions: [.time(now.addingTimeInterval(3600))])
    #expect(WaitCompiler.watch(reminder, now: now) == reminder)

    let store = try stepStore()
    let task = try store.create(FaciendaTask(title: "Studio lighting", state: .needsMe, nextAction: "Review"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "lighting-chat", title: "Lighting"))
    try store.park(task.id, plan: plan, now: now)
    _ = try store.claimWaitNotices(now: now.addingTimeInterval(8 * 86400))
    #expect(try store.ownSteps().first?.text == "Check: Robin replied in that thread")
    #expect(try store.task(task.id).state == .needsMe)
}

@Test func anEarlyDraftsSuggestionTableIsRebuilt() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/draft.sqlite")
    var store = try FaciendaStore(url: url)
    // As an early draft left it: the migration recorded, the table with other columns.
    try store.db.write { db in
        try db.execute(sql: "DROP TABLE nextSteps")
        try db.execute(sql: "CREATE TABLE nextSteps (taskId TEXT PRIMARY KEY NOT NULL, eventId TEXT NOT NULL, steps TEXT NOT NULL, finished BOOLEAN NOT NULL, at DATETIME NOT NULL)")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'next_steps_columns'")
    }
    store = try FaciendaStore(url: url)
    let task = try store.create(FaciendaTask(title: "Buy a desk", state: .running, nextAction: "Shortlist"))
    try store.saveResult(taskId: task.id, text: "The oak desk is best value.")
    let source = try #require(try store.latestResults().first { $0.taskId == task.id })
    try store.saveNextSteps(StoredNextSteps(taskId: task.id, eventId: source.eventId, label: "Order it", instruction: "Order the oak desk."))
    #expect(try store.nextSteps().first?.label == "Order it")
}

@Test func pausingAnswersWhatWasPendingSoTheTaskReallyParks() throws {
    let store = try stepStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Check lamp order status", state: .needsMe, nextAction: "Review"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "lamp-chat", title: "lamp"))
    try store.requestDecision(Decision(taskId: task.id, question: "Ready to mark this task done?", recommendation: "Mark done", options: ["Mark done", "Keep open"], kind: "completion"))
    let watch = WaitCompiler.watch(WaitPlan(conditions: [.observed("Beatrice", source: "Google Sheets comment", criterion: "Beatrice replies")]), now: now)
    try store.park(task.id, plan: watch, now: now)
    #expect(try store.decisions(taskId: task.id).isEmpty)
    #expect([TaskState.waiting, .scheduled].contains(try store.task(task.id).state))
    // An ask that arrives while paused still brings the task back.
    try store.requestDecision(Decision(taskId: task.id, question: "Which supplier?", recommendation: "RHPro", options: ["RHPro", "Other"]))
    #expect(try store.task(task.id).state == .needsMe)

    let other = try store.create(FaciendaTask(title: "Deposit", state: .needsMe, nextAction: "Review"))
    try store.requestDecision(Decision(taskId: other.id, question: "Which account?", recommendation: "Joint", options: ["Joint", "Mine"]))
    try store.takeOn(other.id, step: "Call the landlord")
    #expect(try store.decisions(taskId: other.id).isEmpty)
}

@Test func writingInTheChatYourselfFinishesTheStepAndRunsAsUsual() throws {
    let store = try stepStore(), now = Date()
    let task = try store.create(FaciendaTask(title: "Review the recording", state: .needsMe, nextAction: "Review"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "chat"))
    let prompt = { _ = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"session_id":"chat","hook_event_name":"UserPromptSubmit"}"#.utf8)).apply(to: store) }
    try store.takeOn(task.id, step: "Review the recording", remindAt: now.addingTimeInterval(3600), now: now)
    try prompt()
    #expect(try store.ownSteps().isEmpty)
    #expect(try store.waits().first?.state == "cancelled")
    #expect(try store.task(task.id).state == .running)
    #expect(try store.events(taskId: task.id).contains { $0.kind == "step.done" && $0.payload == "Review the recording" })
    // Facienda delivering into the chat is not the user carrying on.
    try store.takeOn(task.id, step: "Check the frames")
    try store.db.write { try $0.execute(sql: "INSERT INTO dispatches (id, taskId, state, requestedAt) VALUES ('delivery', ?, 'dispatching', ?)", arguments: [task.id, now]) }
    try prompt()
    #expect(try store.ownSteps().map(\.text) == ["Check the frames"])
}
