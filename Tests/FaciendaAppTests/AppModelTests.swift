import AppKit
import Foundation
import Testing
import FaciendaCore
import FaciendaBridge

@MainActor @Test func setupConnectsInOneStepWithNothingToSendInCodex() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "app-setup-\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: "facienda.sqlite"))
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    struct Page: Decodable { let data: [CodexProject] }
    var started = 0
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge)) { _ in started += 1 }
    model.connected = true; model.accountReady = true
    #expect(model.workspaceSetup == nil && !model.workspaceReady)
    await model.connectWorkspace()
    #expect(model.workspaceSetupError == nil && !model.connectingWorkspace)
    // Facienda made the project for the data folder itself and hands delivery to its dispatcher.
    let projects = try await bridge.request("project/list", params: .object([:])).decoded(Page.self).data
    #expect(projects.map(\.name) == ["facienda"])
    #expect(model.workspaceSetup?.projectId == projects.first?.id)
    #expect(try store.runnerState()?.isDispatcher == true)
    #expect(model.workspaceReady && !model.codexNeedsReconnect && started == 1)
    #expect(try store.dispatches().isEmpty)
    // Repairing keeps the same project.
    await model.connectWorkspace(repair: true)
    #expect(try await bridge.request("project/list", params: .object([:])).decoded(Page.self).data.count == 1)
    #expect(model.workspaceReady && started == 2)
    await bridge.disconnect()
}

@MainActor @Test func connectingRetiresARunnerThatLivedInCodex() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "app-runner-\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: "facienda.sqlite"))
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    let first = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "runner-sched", automationId: "old-automation")
    try store.verifyWorkspaceSetup(challenge: first.challenge, projectId: "project", runnerId: "runner-sched", automationId: "old-automation")
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge)) { _ in }
    model.connected = true; model.accountReady = true
    #expect(model.workspaceReady && model.codexNeedsReconnect)
    await model.connectWorkspace(repair: true)
    #expect(model.workspaceSetupError == nil)
    #expect(try store.runnerState()?.isDispatcher == true)
    #expect(model.workspaceSetup?.retiredRunnerId == "runner-sched")
    #expect(model.workspaceSetup?.retiredAutomationId == "old-automation")
    #expect(model.workspaceReady && !model.codexNeedsReconnect)
    await bridge.disconnect()
}

@MainActor @Test func aSetupWhoseProjectNameWasNeverConfirmedIsNamedOnceCodexKnowsTheFolder() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "app-name-\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    struct Page: Decodable { let data: [CodexProject] }
    func projectName() async throws -> String? { try await bridge.request("project/list", params: .object([:])).decoded(Page.self).data.first?.name }
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge)) { _ in }
    model.connected = true; model.accountReady = true
    // Codex knows the folder under its own label.
    _ = try await bridge.request("fixture/registerProject", params: .object([
        "name": .string("org"), "roots": .array([.object(["path": .string(folder.resolvingSymlinksInPath().path)])])
    ]))
    // A library that never ran setup keeps its Codex project as it is.
    await model.confirmPendingProjectName()
    #expect(try await projectName() == "org")
    #expect(model.workspaceSetup == nil)
    // Setup was opened, but Facienda stopped waiting before Codex registered the folder.
    _ = try store.prepareWorkspaceSetup()
    model.refresh()
    await model.confirmPendingProjectName()
    #expect(try await projectName() == "facienda")
    #expect(model.workspaceSetup?.confirmedProjectName == "facienda")
    #expect(model.workspaceSetup?.codexProjectId?.isEmpty == false)
    #expect(model.workspaceSetup?.verifiedAt == nil)
    #expect(try store.runnerState() == nil)
    await bridge.disconnect()
}

@MainActor @Test func theRunnersFinishedRunsAreArchivedButNeverTheRunnerItself() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "app-runs-\(UUID().uuidString)")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    try store.bindRunner(threadId: "runner", automationId: "automation")
    let earlier = Date().addingTimeInterval(-120)
    try store.recordFinishedRun("run-1", now: earlier)
    try store.recordFinishedRun("runner", now: earlier)
    try store.recordFinishedRun("run-just-ended")
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge)) { _ in }
    model.connected = true
    await model.archiveRunnerRuns()
    let archived = try await bridge.request("fixture/archived")["threads"].array?.compactMap(\.string)
    #expect(archived == ["run-1"])
    #expect(try store.runnerRunsToArchive(now: Date().addingTimeInterval(120)) == ["run-just-ended"])
    await bridge.disconnect()
}

@MainActor @Test func aConnectedLibraryRenamesItsProjectFromAnOlderName() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "app-rename-\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    struct Page: Decodable { let data: [CodexProject] }
    func projectName() async throws -> String? { try await bridge.request("project/list", params: .object([:])).decoded(Page.self).data.first?.name }
    // Connected before the project had a fixed name.
    let setup = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "runner", automationId: "heartbeat")
    try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "runner", automationId: "heartbeat")
    _ = try await bridge.request("fixture/registerProject", params: .object([
        "name": .string("facienda-org"), "roots": .array([.object(["path": .string(folder.resolvingSymlinksInPath().path)])])
    ]))
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge)) { _ in }
    model.connected = true; model.accountReady = true
    await model.confirmPendingProjectName()
    #expect(try await projectName() == "facienda")
    #expect(model.workspaceSetup?.confirmedProjectName == "facienda")
    #expect(model.workspaceSetup?.verifiedAt != nil)
    await bridge.disconnect()
}

@MainActor @Test func aFailedConnectionIsVisibleAndCanBeRetried() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-setup-failure-\(UUID().uuidString)/facienda.sqlite"))
    var started = 0
    let model = try AppModel(store: store) { _ in started += 1 }
    // Codex looks signed in, but its connection is gone.
    model.connected = true; model.accountReady = true
    await model.connectWorkspace()
    #expect(model.workspaceSetupError != nil && !model.connectingWorkspace)
    await model.connectWorkspace()
    #expect(model.workspaceSetupError != nil)
    #expect(try store.runnerState() == nil && started == 0 && !model.workspaceReady)
}

@MainActor @Test func blockedUncertainDeliveryAppearsInForYouAndExplicitRetryReturnsToProcessing() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-recovery-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let task = try store.create(FaciendaTask(title: "Interrupted request"))
    let item = try store.enqueueDispatch(taskId: task.id)
    _ = try store.claimDispatch(runnerId: "runner")
    let context = try JSONValue.object([
        "contextKey": .string(DispatchContext.key(task: task, dispatch: item)), "searchStatus": .string("complete"),
        "searchSummary": .string("Isolated app fixture; no prior owner"), "route": .string("new"),
        "project": .null, "chats": .array([]), "uncertainties": .array([])
    ]).decoded(DispatchContext.self)
    try store.saveDispatchContext(context, dispatchId: item.id, runnerId: "runner")
    _ = try store.beginDispatch(item.id, runnerId: "runner")
    try store.deferDispatch(item.id, runnerId: "runner", reason: "Native call never happened", blocked: true)
    let model = try AppModel(store: store)
    model.showTask(try store.task(task.id))
    #expect(model.destination == .dashboard && model.selection == task.id)
    #expect(model.taskStatus(try store.task(task.id)) == "Needs recovery")
    #expect(model.count(.processing) == 0 && model.count(.forYou) == 1)
    model.retryUndelivered(try #require(model.recoveryDispatch(for: task.id)))
    #expect(try model.error == nil && model.belongs(store.task(task.id), to: .processing))
    #expect(model.recoveryDispatch(for: task.id) == nil)
    #expect(model.pendingDispatch(for: task.id)?.id == item.id)
}

@MainActor @Test func cancelReplyKeepsSelectionAndRestoresDraft() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-model-\(UUID().uuidString)/tasks.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "runner", automationId: "heartbeat")
    try store.runnerHeartbeat("runner")
    try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "runner", automationId: "heartbeat")
    let task = try store.create(FaciendaTask(title: "Keep this task", state: .needsMe))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "existing-chat"))
    let model = try AppModel(store: store)
    model.showTask(task)
    #expect(model.destination == .dashboard && model.selection == task.id)
    #expect(!model.reply(to: task, text: "   "))
    #expect(try store.dispatches().isEmpty)
    let text = "Please also compare the second option"
    model.replyDrafts[task.id] = text
    #expect(model.reply(to: task, text: text))
    #expect(model.belongs(try store.task(task.id), to: .processing))
    let queued = try #require(model.pendingDispatch(for: task.id))
    #expect(queued.message == text)
    model.cancelStart(queued.id)
    #expect(model.belongs(try store.task(task.id), to: .forYou))
    #expect(model.destination == .dashboard && model.selection == task.id)
    #expect(model.replyDrafts[task.id] == text)
    #expect(try store.task(task.id).state == .needsMe)
    #expect(model.error == nil)
}

@MainActor @Test func cancellingInitialStartReturnsToForYouWithoutClosingTask() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-cancel-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "My new request", state: .inbox))
    let queued = try store.enqueueDispatch(taskId: task.id)
    let model = try AppModel(store: store)
    model.showTask(task)
    #expect(model.belongs(task, to: .processing))
    model.cancelStart(queued.id)
    #expect(model.belongs(try store.task(task.id), to: .forYou))
    #expect(model.destination == .dashboard && model.selectedTask?.id == task.id)
    #expect(try store.task(task.id).state == .inbox)
}

@MainActor @Test func existingRunnerRemainsUsableBeforeProjectOnboarding() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-upgrade-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "existing-runner", automationId: "existing-heartbeat")
    let model = try AppModel(store: store)
    #expect(model.workspaceReady)
    _ = try store.prepareWorkspaceSetup()
    model.refresh()
    #expect(!model.workspaceReady)
}

@MainActor @Test func activeCheckStaysInProgressAndFollowsResultToForYou() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-check-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let task = try store.create(FaciendaTask(title: "Watch fixture"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    let plan = try store.planCheck(taskId: task.id, threadId: "owner", expectedRevision: 0, nextCheck: Date().addingTimeInterval(10), purpose: "Inspect fixture", reason: "Fixture test", waitingOn: "Fixture")
    try store.enqueueDueChecks(runnerId: "runner", now: plan.nextCheck)
    let queued = try #require(try store.claimDispatch(runnerId: "runner"))
    _ = try store.beginDispatch(queued.id, runnerId: "runner")
    try store.acknowledgeDispatch(queued.id, runnerId: "runner", threadId: "owner")
    let model = try AppModel(store: store)
    model.showTask(try store.task(task.id))
    #expect(model.belongs(try store.task(task.id), to: .processing))
    #expect(model.taskStatus(try store.task(task.id)) == "Checking")
    _ = try store.reportCheck(taskId: task.id, dispatchId: queued.id, expectedRevision: plan.revision, outcome: "changed", summary: "Fixture changed", nextCheck: nil, reason: "")
    model.refresh()
    #expect(model.belongs(try store.task(task.id), to: .forYou))
    #expect(model.selectedTask?.id == task.id)
    #expect(model.result == "Fixture changed")
}

@MainActor @Test func aWatchedTaskStaysParkedWhileItsCheckWaitsItsTurn() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-watch-\(UUID().uuidString)/tasks.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let task = try store.create(FaciendaTask(title: "Hear back from the lawyer", state: .needsMe))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    try store.park(task.id, plan: WaitPlan(conditions: [.observed("Lourival", source: "Mail", criterion: "A reply arrives")]))
    try store.enqueueDueChecks(runnerId: "runner")
    let check = try #require(try store.claimDispatch(runnerId: "runner"))
    try store.deferDispatch(check.id, runnerId: "runner", reason: "The chat is busy.")
    let model = try AppModel(store: store)
    // Put off: still parked, and still saying what the agent watches for.
    #expect(model.belongs(try store.task(task.id), to: .waiting))
    #expect(model.taskStatus(try store.task(task.id)).hasPrefix("Until Lourival"))
    _ = try store.beginDispatch(check.id, runnerId: "runner")
    try store.acknowledgeDispatch(check.id, runnerId: "runner", threadId: "owner")
    model.refresh()
    #expect(model.belongs(try store.task(task.id), to: .processing))
    #expect(model.taskStatus(try store.task(task.id)) == "Checking")
}

@MainActor @Test func newTaskIsOnlyComposerAndSavedRequestsStayInForYou() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "new-task-\(UUID().uuidString)/tasks.sqlite"))
    let model = try AppModel(store: store)
    #expect(await model.capture(title: "Keep my draft", intention: "", area: "Personal", date: Date(), startNow: false))
    #expect(model.destination == .dashboard)
    #expect(model.taskStatus(try #require(model.selectedTask)) == "Not started")
    #expect(model.count(.inbox) == 0)
    #expect(model.count(.forYou) == 1)
}

@MainActor @Test func viewingMarksReviewedAndOnlyNewResultsMakeTasksNewAgain() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "review-order-\(UUID().uuidString)/tasks.sqlite"))
    var earlier = FaciendaTask(title: "Earlier decision", state: .needsMe, returnAt: .distantPast)
    earlier.updatedAt = Date().addingTimeInterval(-100)
    var latest = FaciendaTask(title: "Latest draft", state: .inbox, returnAt: .distantFuture)
    latest.updatedAt = Date().addingTimeInterval(-10)
    try store.create(earlier); try store.create(latest)
    let model = try AppModel(store: store)
    #expect(!model.hasReviewed(earlier))
    let savedUpdate = try store.task(earlier.id).updatedAt
    model.select(earlier.id, reviewed: true)
    #expect(model.hasReviewed(earlier))
    #expect(try store.task(earlier.id).updatedAt == savedUpdate)
    let reopened = try AppModel(store: store)
    #expect(reopened.hasReviewed(earlier))
    // Edits after opening, such as Codex recording the chat's name, leave the task opened.
    let updated = try store.update(earlier.id) { $0.brief = "Renamed" }
    model.refresh()
    #expect(model.hasReviewed(updated) && model.newCount == 0)
    // A further result makes it new again; so does a run that finishes. Dates are stored to the millisecond.
    usleep(2000)
    try store.saveResult(taskId: earlier.id, text: "New result")
    model.refresh()
    #expect(!model.hasReviewed(earlier) && model.newCount == 1)
    model.select(earlier.id, reviewed: true)
    _ = try store.update(earlier.id) { $0.state = .running }
    model.refresh()
    #expect(!model.isUnread(try store.task(earlier.id)))
    usleep(2000)
    try store.saveResult(taskId: earlier.id, text: "Done again")
    model.refresh()
    #expect(model.isUnread(try store.task(earlier.id)))
    // An inbox task the user added is never new.
    #expect(!model.isUnread(latest))
}

@MainActor @Test func composeClearsSelectionAndRequestsFocusEvenWhenAlreadyComposing() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "composer-focus-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Selected task"))
    let model = try AppModel(store: store)
    model.showTask(task); model.search = "Selected"
    model.composerRequest = "Keep my unfinished request"
    model.compose()
    #expect(model.destination == .inbox && model.selection == nil && model.search.isEmpty)
    let firstRequest = model.composerFocusRequest
    model.compose()
    #expect(model.composerFocusRequest > firstRequest)
    #expect(model.composerRequest == "Keep my unfinished request")
}

@MainActor @Test func captureCopiesSameNamedMediaAndPersistsAttachmentsForDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "media-capture-\(UUID().uuidString)")
    let store = try FaciendaStore(url: root.appending(path: "workspace/tasks.sqlite"))
    let sources = [root.appending(path: "first/reference.png"), root.appending(path: "second/reference.png")]
    for (index, source) in sources.enumerated() {
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media-\(index)".utf8).write(to: source)
    }
    let model = try AppModel(store: store)
    #expect(await model.capture(title: "Compare these references", intention: "Keep the context", area: "Personal", date: Date(), startNow: false, attachments: sources))
    let task = try #require(model.selectedTask)
    let attachments = try #require(task.attachments)
    #expect(attachments.count == 2 && Set(attachments.map(\.path)).count == 2)
    #expect(task.intention == "Keep the context")
    for (index, attachment) in attachments.enumerated() {
        #expect(attachment.name == "reference.png")
        #expect(attachment.path.hasPrefix(try #require(task.cwd)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: attachment.path)) == Data("media-\(index)".utf8))
        #expect(try Data(contentsOf: sources[index]) == Data("media-\(index)".utf8))
    }
    #expect(try store.task(task.id).attachments == attachments)
    #expect(try JSONValue.encoded(task)["attachments"].array?.count == 2)
    let reopened = try AppModel(store: store)
    #expect(reopened.tasks.first?.attachments == attachments)
}

@MainActor @Test func invalidAttachmentDoesNotCreateTaskOrLoseDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "bad-attachment-\(UUID().uuidString)")
    let store = try FaciendaStore(url: root.appending(path: "tasks.sqlite"))
    let model = try AppModel(store: store)
    model.composerRequest = "Keep this request"
    model.composerAttachments = [root]
    #expect(!(await model.capture(title: model.composerRequest, intention: "", area: "Personal", date: Date(), startNow: false, attachments: model.composerAttachments)))
    #expect(try store.tasks().isEmpty)
    #expect(model.composerRequest == "Keep this request" && model.composerAttachments == [root])
    #expect(model.error != nil)
}

@MainActor @Test func reviewDistinguishesReadyFromNeedsInput() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "review-status-\(UUID().uuidString)/tasks.sqlite"))
    let ready = try store.create(FaciendaTask(title: "Completed preparation"))
    let input = try store.create(FaciendaTask(title: "Choose an option"))
    try store.requestDecision(Decision(taskId: ready.id, question: "Finished?", recommendation: "Mark done", options: ["Mark done"], kind: "completion"))
    try store.requestDecision(Decision(taskId: input.id, question: "Which option?", recommendation: "A", options: ["A", "B"]))
    let allow = try store.create(FaciendaTask(title: "Send the venue email"))
    try store.requestDecision(Decision(taskId: allow.id, question: "May I send it?", recommendation: "Send", options: ["Send", "Not yet"], kind: "permission"))
    let prompt = try store.create(FaciendaTask(title: "Fix the widget", state: .running))
    try store.link(ThreadLink(taskId: prompt.id, codexThreadId: "local_prompt", provider: .claude))
    try store.observe(threadId: "local_prompt", status: "waitingOnApproval", source: .hook, verified: true)
    let read = try store.create(FaciendaTask(title: "Lamp return", state: .needsMe))
    let model = try AppModel(store: store)
    #expect(model.status(for: ready) == .ready)
    #expect(model.status(for: input) == .needsInput)
    let current = { (task: FaciendaTask) in try #require(model.tasks.first { $0.id == task.id }) }
    // The board draws its question, hand, thumbs-up and eye from these.
    #expect(try model.status(for: current(allow)) == .needsPermission && model.status(for: current(read)) == .needsReview)
    // A session stopped at a permission prompt shows it while the task still counts as running.
    #expect(try current(prompt).state == .running && model.status(for: current(prompt)) == .needsPermission)
    #expect(try model.subtitle(for: current(prompt)) == "Allow it in Claude to carry on")
    #expect(try [ready, input, allow, prompt, read].map { try model.status(for: current($0)).label } == ["Ready to close", "Has a question", "Needs permission", "Needs permission", "For review"])
}

@MainActor @Test func runningTurnOutranksEarlierQuestionsOnTheBoard() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "running-turn-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Animate the tide"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "tide"))
    try store.requestDecision(Decision(taskId: task.id, question: "May I deploy?", recommendation: "Deploy", options: ["Deploy", "Not yet"], kind: "permission"))
    // The user carries on in the chat without answering: the new turn runs, and the board says so.
    try store.observe(threadId: "tide", status: "active", source: .hook, verified: true)
    let model = try AppModel(store: store)
    let current = { try #require(model.tasks.first { $0.id == task.id }) }
    #expect(try current().state == .running && model.status(for: current()) == .working)
    // Once the turn stops, the open question shows again.
    try store.observe(threadId: "tide", status: "idle", source: .hook, verified: true)
    model.refresh()
    #expect(try current().state == .needsMe && model.status(for: current()) == .needsPermission)
}

private func conversationResponse(_ threadID: String, answer: String) -> JSONValue {
    .object(["thread": .object(["id": .string(threadID), "name": .string("Original chat"), "turns": .array([
        .object(["id": .string("turn"), "status": .string("completed"), "items": .array([
            .object(["id": .string("user"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string("Original exact request")])])]),
            .object(["id": .string("answer"), "type": .string("agentMessage"), "phase": .string("final_answer"), "text": .string(answer)])
        ])])
    ])])])
}

@MainActor @Test func linkedConversationRefreshesDespiteImportedReportAndKeepsOfflineCopy() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-conversation-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Original", state: .needsMe))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "background", role: "research"))
    try store.saveResult(taskId: task.id, text: "Compressed imported summary")
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge))
    model.connected = true; model.showTask(task)
    let full = "# Original answer\n\n- [Application](https://example.org/application)\n- Bring **originals**"
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("owner"), "response": conversationResponse("owner", answer: full)]))
    await model.loadConversation(for: task)
    #expect(model.conversation?.turns[0].items[1]["text"].string == full)
    #expect(model.result == "Compressed imported summary")
    #expect(model.resultErrors[task.id] == nil && model.loadingResults.isEmpty)
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("owner"), "response": conversationResponse("owner", answer: "New follow-up answer")]))
    await model.loadConversation(for: task)
    #expect(model.conversation?.turns[0].items[1]["text"].string == "New follow-up answer")
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("owner"), "response": conversationResponse("wrong-owner", answer: "Wrong content")]))
    await model.loadConversation(for: task)
    #expect(model.resultErrors[task.id] != nil)
    #expect(model.conversation?.threadId == "owner")
    #expect(model.conversation?.turns[0].items[1]["text"].string == "New follow-up answer")
    let reads = try await bridge.request("fixture/threadReads")
    #expect(reads["ids"].array?.compactMap(\.string) == ["owner", "owner", "owner"])
    await bridge.disconnect(); model.connected = false
    let reopened = try AppModel(store: store)
    reopened.showTask(task)
    #expect(reopened.conversation == model.conversation)
    let other = try store.create(FaciendaTask(title: "Another task"))
    reopened.showTask(other)
    #expect(reopened.conversation == nil && reopened.result == nil)
}

@MainActor @Test func directChatImportReadsExactConversationAndCreatesNoDispatch() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-import-\(UUID().uuidString)/tasks.sqlite"))
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("owner"), "response": conversationResponse("owner", answer: "Full source answer")]))
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge))
    model.connected = true
    let thread = try JSONValue.object(["id": .string("owner"), "name": .string("Short chat title"), "preview": .string("Preview"), "cwd": .string("/tmp"), "updatedAt": .number(1), "status": .object(["type": .string("idle")])]).decoded(CodexThread.self)
    await model.importThread(thread)
    #expect(model.error == nil)
    #expect(model.selectedTask?.title == "Original exact request")
    #expect(model.selectedTask?.displayName == "Short chat title")
    #expect(model.selectedTask?.returnAt == nil && model.selectedTask?.definitionOfDone == "")
    #expect(model.conversation?.turns[0].items[1]["text"].string == "Full source answer")
    #expect(try store.dispatches().isEmpty)
    await model.importThread(thread)
    #expect(try store.tasks().count == 1)
    await bridge.disconnect()
}

@MainActor @Test func aChatKnownOnlyByItsLinkTakesItsTitleFromCodexAndJoinsTheGroup() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-link-import-\(UUID().uuidString)/tasks.sqlite"))
    let group = try store.createGroup(name: "Home")
    let bridge = CodexBridge()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "FaciendaBridgeTests/Fixtures/server.py")
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("linked"), "response": conversationResponse("linked", answer: "Done")]))
    let model = try AppModel(store: store, codex: CodexConnection(bridge: bridge))
    model.connected = true
    #expect(await model.importThread(CodexThread(id: "linked", title: "", cwd: "", updatedAt: Date()), groupID: group.id))
    #expect(model.error == nil)
    let task = try #require(model.selectedTask)
    #expect(task.displayName == "Original chat")
    #expect(try store.groupMembers().first { $0.taskId == task.id }?.groupId == group.id)
    await bridge.disconnect()
}

@MainActor @Test func dashboardGroupsTasksTracksUnreadAndKeepsEmptyGroups() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "dashboard-\(UUID().uuidString)/tasks.sqlite"))
    let review = try store.create(FaciendaTask(title: "Review the lease", state: .needsMe))
    let running = try store.create(FaciendaTask(title: "Compare movers", state: .running))
    let archived = try store.create(FaciendaTask(title: "Old idea"))
    try store.update(archived.id) { $0.state = .dropped }
    let model = try AppModel(store: store)
    #expect(model.destination == .dashboard)
    #expect(Set(model.boardTasks(in: nil).map(\.id)) == [review.id, running.id])
    #expect(model.isUnread(review) && !model.isUnread(running))

    let move = try #require(model.createGroup(name: "Flat move"))
    // A task dropped on another card arrives at its top.
    model.move(taskID: review.id, to: move.id); model.move(taskID: running.id, to: move.id)
    #expect(model.boardTasks(in: move.id).map(\.id) == [running.id, review.id] && model.boardTasks(in: nil).isEmpty)
    model.renameGroup(move, name: "Moving house")
    #expect(model.groups.map(\.name) == ["Moving house"])

    // Opening a task without a chat clears its unread mark; there is no chat to show.
    model.open(review)
    #expect(!model.isUnread(review) && model.destination == .dashboard)

    model.move(taskID: review.id, to: nil); model.move(taskID: running.id, to: nil)
    #expect(model.groups.count == 1 && model.boardTasks(in: move.id).isEmpty)
    // Launching into the resting group wakes it up without leaving the dashboard.
    model.destination = .dashboard; model.select(nil)
    #expect(await model.capture(title: "Book the van", intention: "", area: "Personal", date: Date(), startNow: false, groupID: move.id, reveal: false))
    #expect(model.destination == .dashboard && model.selection == nil)
    #expect(model.boardTasks(in: move.id).map(\.title) == ["Book the van"])
    #expect(model.error == nil)
}

@MainActor @Test func boardTasksStayWhereTheUserPutsThem() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "board-places-\(UUID().uuidString)/tasks.sqlite"))
    let model = try AppModel(store: store)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    let group = try #require(model.createGroup(name: "Flat move"))
    let lease = try store.create(FaciendaTask(title: "Review the lease", state: .running))
    let movers = try store.create(FaciendaTask(title: "Compare movers", state: .running))
    let van = try store.create(FaciendaTask(title: "Book the van", state: .running))
    model.refresh()
    for task in [lease, movers, van] { model.move(taskID: task.id, to: group.id) }
    #expect(model.boardTasks(in: group.id).map(\.id) == [van.id, movers.id, lease.id])

    model.place(taskID: lease.id, in: group.id, at: .top)
    model.place(taskID: van.id, in: group.id, at: .below(movers.id))
    #expect(model.boardTasks(in: group.id).map(\.id) == [lease.id, movers.id, van.id])
    // Work coming back, or a task needing the user, never moves it.
    try store.update(van.id) { $0.state = .needsMe }
    try store.update(lease.id) { $0.state = .done }
    model.refresh()
    #expect(model.boardTasks(in: group.id).map(\.id) == [lease.id, movers.id, van.id])
    // Undo puts the order back.
    model.place(taskID: movers.id, in: group.id, at: .bottom)
    #expect(model.boardTasks(in: group.id).map(\.id) == [lease.id, van.id, movers.id])
    undo.undo()
    #expect(model.boardTasks(in: group.id).map(\.id) == [lease.id, movers.id, van.id])

    // A new task arrives at the top; one dropped between two rows of another card lands there.
    let creche = try store.create(FaciendaTask(title: "Ask the creche", state: .running))
    try store.assignGroup(taskId: creche.id, groupId: group.id)
    model.refresh()
    #expect(model.boardTasks(in: group.id).first?.id == creche.id)
    let loose = try store.create(FaciendaTask(title: "Renew the passport", state: .running))
    model.refresh()
    model.place(taskID: loose.id, in: group.id, at: .above(van.id))
    #expect(model.boardTasks(in: group.id).map(\.id) == [creche.id, lease.id, movers.id, loose.id, van.id] && model.boardTasks(in: nil).isEmpty)
    // The order lives in the library.
    #expect(try AppModel(store: FaciendaStore(url: store.url)).boardTasks(in: group.id).map(\.id) == [creche.id, lease.id, movers.id, loose.id, van.id])
}

@MainActor @Test func dashboardGroupsCanBeRearrangedSearchedAndTasksArchivedInPlace() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "dashboard-order-\(UUID().uuidString)/tasks.sqlite"))
    let lease = try store.create(FaciendaTask(title: "Review the lease", state: .needsMe))
    let movers = try store.create(FaciendaTask(title: "Compare movers", state: .needsMe))
    let model = try AppModel(store: store)
    let ids = ["A", "B", "C", "D"].compactMap { model.createGroup(name: $0)?.id }
    #expect(model.groups.allSatisfy { $0.lane == nil && $0.row == nil })
    // B above C in the first column, A alone in the second. D was not on screen and keeps its place.
    model.placeGroups([GroupPlacement(id: ids[1], lane: 0, row: 0), GroupPlacement(id: ids[2], lane: 0, row: 1), GroupPlacement(id: ids[0], lane: 1, row: 0)])
    #expect(model.groups.map(\.name) == ["B", "C", "A", "D"])
    #expect(model.groups.map(\.lane) == [0, 0, 1, nil] && model.groups.map(\.row) == [0, 1, 0, nil])
    #expect(try FaciendaStore(url: store.url).groups().map(\.row) == [0, 1, 0, nil])

    model.search = "lease"
    #expect(model.boardTasks(in: nil).map(\.id) == [lease.id])
    model.search = ""
    model.archive(movers, reveal: false)
    #expect(model.destination == .dashboard && model.selection == nil)
    #expect(model.boardTasks(in: nil).map(\.id) == [lease.id])
    #expect(try store.task(movers.id).state == .dropped)
}

private actor PaintLog {
    var calls: [(name: String, tasks: [String], style: String?, notes: [String], instruction: String?)] = []
    func add(_ name: String, _ tasks: [String], _ style: String?, _ notes: [String], _ instruction: String?) { calls.append((name, tasks, style, notes, instruction)) }
}

private struct FakePainter: CoverPainting {
    let log: PaintLog
    let pixel: Data
    func paint(executable: String, name: String, tasks: [String], style: String?, notes: [String]) async throws -> GroupCover {
        await log.add(name, tasks, style, notes, nil); return GroupCover(image: pixel, style: "Precisionism")
    }
    func edit(executable: String, cover: URL, name: String, tasks: [String], instruction: String, style: String?, notes: [String]) async throws -> GroupCover {
        #expect(FileManager.default.fileExists(atPath: cover.path))
        await log.add(name, [], style, notes, instruction); return GroupCover(image: pixel, style: "Precisionism in green")
    }
}

@MainActor @Test func groupsGetACoverOnceTheyHoldOpenWorkAndRepaintOnlyWhenAsked() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-covers-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    let log = PaintLog()
    let pixel = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .jpeg, properties: [:]))
    model.coverPainter = FakePainter(log: log, pixel: pixel)
    let group = try store.createGroup(name: "Shipping"), task = try store.create(FaciendaTask(title: "Return the chairs"))
    try store.assignGroup(taskId: task.id, groupId: group.id)
    // Nothing is painted until Codex is connected and signed in.
    model.refresh()
    #expect(model.paintingCovers.isEmpty)
    model.connected = true; model.accountReady = true
    let empty = try store.createGroup(name: "Resting")
    model.refresh()
    #expect(model.paintingCovers == [group.id])
    for _ in 0..<200 where model.coverImages[group.id] == nil { try await Task.sleep(for: .milliseconds(10)) }
    let painted = try #require(model.groups.first { $0.id == group.id })
    #expect(painted.coverStyle == "Precisionism" && painted.coverPaintedAt != nil && model.coverImages[group.id] != nil)
    #expect(model.coverImages[empty.id] == nil && !model.paintingCovers.contains(empty.id))
    let calls = await log.calls
    #expect(calls.map(\.name) == ["Shipping"] && calls.first?.tasks == ["Return the chairs"] && calls.first?.style == nil)
    // A painted group stays painted through renames; repainting keeps its style unless a new one is asked for.
    model.renameGroup(painted, name: "Returns")
    model.refresh()
    #expect(await log.calls.count == 1)
    model.paintCover(painted)
    for _ in 0..<200 where await log.calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    model.paintCover(painted, newStyle: true)
    for _ in 0..<200 where await log.calls.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    let later = await log.calls.dropFirst().map(\.style)
    #expect(later == ["Precisionism", nil])
    // A wish edits the picture, is remembered for later repaints, and can be undone together with its note.
    for _ in 0..<200 where !model.paintingCovers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let before = try #require(model.groups.first { $0.id == group.id })
    #expect(model.canUndoCover(before))
    model.adjustCover(before, instruction: " more green ")
    for _ in 0..<200 where await log.calls.count < 4 || !model.paintingCovers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let wish = try #require(await log.calls.last)
    #expect(wish.instruction == "more green" && wish.notes.isEmpty)
    let adjusted = try #require(model.groups.first { $0.id == group.id })
    #expect(adjusted.coverNoteList == ["more green"] && adjusted.coverStyle == "Precisionism in green")
    model.paintCover(adjusted)
    for _ in 0..<200 where await log.calls.count < 5 || !model.paintingCovers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await log.calls.last?.notes == ["more green"])
    #expect(model.canUndoCover(adjusted))
    model.undoCover(adjusted)
    let restored = try #require(model.groups.first { $0.id == group.id })
    #expect(restored.coverNoteList == ["more green"] && restored.coverStyle == "Precisionism in green" && !model.canUndoCover(restored))
    model.forgetCoverNotes(restored)
    #expect(model.groups.first { $0.id == group.id }?.coverNoteList == [])
}

@MainActor @Test func newGroupCardTakesDroppedTasksAndItsSpot() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "new-group-\(UUID().uuidString)/tasks.sqlite"))
    let chairs = try store.create(FaciendaTask(title: "Return the chairs")), lamp = try store.create(FaciendaTask(title: "Fix the lamp"))
    let model = try AppModel(store: store)
    let group = try #require(model.createGroup(name: AppModel.newGroupName, holding: [chairs.id, lamp.id], lane: 1, row: 2))
    #expect(model.groupMembers[chairs.id] == group.id && model.groupMembers[lamp.id] == group.id)
    let saved = try #require(model.groups.first { $0.id == group.id })
    #expect(saved.lane == 1 && saved.row == 2)
    // A named card with nothing dropped on it is simply an empty group, placed wherever there is room.
    let reading = try #require(model.createGroup(name: "Reading"))
    #expect(model.boardTasks(in: reading.id).isEmpty && model.groups.count == 2)
}

@MainActor @Test func claudeTasksOpenInClaudeAndRelayRepliesThroughItsRunner() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-claude-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }
    model.claudeAppAvailable = { true }
    #expect(await model.capture(title: "Draft the venue email", intention: "", area: "Personal", date: Date(), startNow: false,
                                model: TaskModelChoice.claudeStandard.choosing("claude-sonnet-5-5")))
    let task = try #require(model.tasks.first { $0.title == "Draft the venue email" })
    #expect(task.provider == .claude && task.workerModel == "claude-sonnet-5-5" && task.workerServiceTier == nil)
    // Codex is not connected and neither is Claude: the task waits in Facienda instead of opening Claude's composer.
    #expect(!model.workspaceReady)
    await model.dispatch(task)
    #expect(model.error == nil)
    #expect(opened.isEmpty)
    #expect(model.status(for: task) == .waitingForClaude)
    #expect(!model.canOpen(task))
    #expect(model.agent(for: task) == .claude)
    let item = try #require(model.pendingDispatch(for: task.id))
    // Sending it yourself is still there, on request.
    model.openInClaude(item)
    let url = try #require(opened.last)
    #expect(url.scheme == "claude" && url.path == "/new")
    #expect(model.status(for: task) == .awaitingSend)
    #expect(FileManager.default.fileExists(atPath: store.taskFolder(task.id).appending(path: ".mcp.json").path))
    // Pressing Send again on a stale composer must not start a second session.
    _ = try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_worker", cliSessionId: nil, cwd: nil)
    model.refresh()
    #expect(model.resultLink(for: task)?.provider == .claude)
    model.openThread("local_worker")
    #expect(opened.last == FaciendaStore.claudeSessionURL("local_worker"))
    // Replies need the Claude runner, not the Codex connection.
    #expect(!model.reply(to: task, text: "Make it shorter"))
    #expect(model.error?.contains("Connect Claude") == true)
    model.error = nil
    let setup = try store.prepareClaudeSetup()
    try store.bindClaudeRunner(sessionId: "local_runner", challenge: setup.challenge, canStartSessions: false)
    model.refresh()
    #expect(model.reply(to: task, text: "Make it shorter"))
    let reply = try #require(model.pendingDispatch(for: task.id))
    #expect(reply.agent == .claude && reply.threadId == "local_worker" && reply.message == "Make it shorter")
}

@MainActor @Test func anAwakeRunnerLetsATaskStartInClaudeWithoutASend() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-claude-import-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }
    model.claudeAppAvailable = { true }
    var adopted = true
    model.claudeSessionAdopted = { _ in adopted }
    let setup = try store.prepareClaudeSetup()
    try store.bindClaudeRunner(sessionId: "local_runner", challenge: setup.challenge, canStartSessions: false)
    model.refresh()
    #expect(await model.capture(title: "Draft the venue email", intention: "", area: "Personal", date: Date(), startNow: false, model: .claudeStandard))
    let task = try #require(model.tasks.first { $0.title == "Draft the venue email" })
    await model.dispatch(task)
    #expect(model.error == nil)
    #expect(opened.last?.host == "resume")
    #expect(model.status(for: task) == .startingInClaude)
    #expect(try store.claudeSession(try #require(model.resultLink(for: task)?.threadId))?.configureState == "pending")
    // When the app ignores the hand-off, the task waits for the user; the composer never opens by itself.
    adopted = false
    #expect(await model.capture(title: "Second task", intention: "", area: "Personal", date: Date(), startNow: false, model: .claudeStandard))
    let second = try #require(model.tasks.first { $0.title == "Second task" })
    await model.dispatch(second)
    #expect(opened.allSatisfy { $0.path != "/new" })
    #expect(model.status(for: second) == .waitingForClaude)
    #expect(model.resultLink(for: second) == nil)
    // Nor is it handed over again on every refresh, only when the user tries again.
    let handedOver = opened.count
    model.refresh(); await model.startWaitingClaudeTasks()
    #expect(opened.count == handedOver)
    adopted = true
    await model.retryClaudeStart(try #require(model.pendingDispatch(for: second.id)))
    #expect(opened.last?.host == "resume" && opened.count == handedOver + 1)
    #expect(model.status(for: second) == .startingInClaude)
}

@MainActor @Test func aSlowClaudeHandOffLetsTheNextTaskStart() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-claude-slow-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }
    model.claudeAppAvailable = { true }
    var release: CheckedContinuation<Void, Never>?
    var asked = 0
    model.claudeSessionAdopted = { _ in
        asked += 1
        if asked == 1 { await withCheckedContinuation { release = $0 } }
        return true
    }
    let setup = try store.prepareClaudeSetup()
    try store.bindClaudeRunner(sessionId: "local_runner", challenge: setup.challenge, canStartSessions: false)
    model.refresh()
    #expect(await model.capture(title: "Draft the venue email", intention: "", area: "Personal", date: Date(), startNow: false, model: .claudeStandard))
    let first = try #require(model.tasks.first { $0.title == "Draft the venue email" })
    let starting = Task { await model.dispatch(first) }
    while release == nil { await Task.yield() }
    // The Claude app is still adopting the first session; the omnibar may start the next task meanwhile.
    #expect(!model.dispatching)
    #expect(await model.capture(title: "Second task", intention: "", area: "Personal", date: Date(), startNow: false, model: .claudeStandard))
    let second = try #require(model.tasks.first { $0.title == "Second task" })
    await model.dispatch(second)
    #expect(model.error == nil)
    release?.resume()
    await starting.value
    // The start already under way picks up the second task once the first is in.
    #expect(asked == 2)
    #expect(model.status(for: first) == .startingInClaude && model.status(for: second) == .startingInClaude)
}

@MainActor @Test func pickingOneOfTwoFoundChatsEndsTheOffer() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-handover-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    let task = try store.create(FaciendaTask(title: "Find the thread where we drafted the venue email", state: .needsMe))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "finder", title: task.title))
    try store.saveResult(taskId: task.id, text: "Two candidates: codex://threads/venue-draft and codex://threads/venue-reply.")
    model.refresh()
    let found = model.linkedChats(for: try store.task(task.id))
    #expect(found.map(\.threadId) == ["venue-draft", "venue-reply"])

    #expect(model.handOver(found[0], taskID: task.id))
    #expect(model.links(for: task.id).map(\.threadId) == ["venue-draft"])
    // The other chat, and the chat it left, are no longer offered; the ⋯ menu still switches on request.
    #expect(model.linkedChats(for: try store.task(task.id)).isEmpty)
    // A later answer naming chats doesn't bring the offer back.
    try store.saveResult(taskId: task.id, text: "Carried on; the reply is in codex://threads/venue-reply and codex://threads/finder.")
    model.refresh()
    #expect(model.linkedChats(for: try store.task(task.id)).isEmpty)
}

@MainActor @Test func claudeTasksWaitForTheRunnerAndStartOnceItWakes() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-claude-wake-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }
    model.claudeAppAvailable = { true }
    model.claudeSessionAdopted = { _ in true }
    let setup = try store.prepareClaudeSetup()
    try store.bindClaudeRunner(sessionId: "local_runner", challenge: setup.challenge, canStartSessions: false, now: Date().addingTimeInterval(-3600))
    model.refresh()
    #expect(model.claudeConnected && model.claudeRunner?.isAwake() == false)
    #expect(await model.capture(title: "Draft the venue email", intention: "", area: "Personal", date: Date(), startNow: false, model: .claudeStandard))
    let task = try #require(model.tasks.first { $0.title == "Draft the venue email" })
    await model.dispatch(task)
    #expect(opened.isEmpty && model.status(for: task) == .waitingForClaude)
    // The runner checks in: the waiting task starts without a click.
    try store.claudeRunnerHeartbeat("local_runner")
    model.refresh(); await model.startWaitingClaudeTasks()
    #expect(opened.last?.host == "resume")
    #expect(model.status(for: task) == .startingInClaude)
}

@MainActor @Test func aClaudeTaskWaitingInAnotherWorkspaceStartsToo() async throws {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-claude-elsewhere-\(UUID().uuidString)/facienda.sqlite"))
    let home = try library.defaultWorkspace()
    let work = try library.createWorkspace(name: "Work", memorySpaceID: try library.createMemorySpace(name: "Work").id)
    let model = try AppModel(store: library.scoped(to: home.id)) { _ in }
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }
    model.claudeAppAvailable = { true }
    model.claudeSessionAdopted = { _ in true }
    let setup = try library.prepareClaudeSetup()
    try library.bindClaudeRunner(sessionId: "local_runner", challenge: setup.challenge, canStartSessions: false, now: Date().addingTimeInterval(-3600))
    // Queued in Work while the runner sleeps; the user is looking at Home.
    let elsewhere = library.scoped(to: work.id)
    var task = FaciendaTask(title: "Draft the venue email", state: .needsMe)
    task.workerProvider = .claude; task.workerModel = "claude-sonnet-5-5"
    task = try elsewhere.create(task)
    let item = try elsewhere.enqueueDispatch(taskId: task.id)
    model.refresh()
    #expect(model.tasks.isEmpty && model.nativeDispatches.isEmpty)
    // The runner serves the whole library, so the task starts from here without opening Work.
    try library.claudeRunnerHeartbeat("local_runner")
    model.refresh(); await model.startWaitingClaudeTasks()
    #expect(opened.last?.host == "resume")
    #expect(try library.dispatches().first { $0.id == item.id }?.threadId != nil)
}

@MainActor @Test func takingAStepOnShowsOnTheRowAndDidItBringsTheTaskBack() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "own-step-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Get the deposit back", state: .needsMe, nextAction: "Review"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "deposit-chat", title: "Deposit"))
    let model = try AppModel(store: store)
    #expect(model.offersChoices(task))
    #expect(model.takeOn(task, step: "Call the landlord", at: nil))
    let taken = try store.task(task.id)
    #expect(model.ownStep(for: taken)?.text == "Call the landlord")
    #expect(model.subtitle(for: taken) == "You: Call the landlord")
    // Did it without a note: nothing goes to the chat and the task is back for review.
    model.didStep(taken, note: "")
    let back = try store.task(task.id)
    #expect(model.ownStep(for: back) == nil && back.state == .needsMe)
    #expect(model.pendingDispatch(for: task.id) == nil)
}

@MainActor @Test func aLitGroupShowsOnlyOnTheBoardAndLettingGoClearsIt() async throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "app-spotlight-\(UUID().uuidString)/facienda.sqlite"))
    let model = try AppModel(store: store) { _ in }
    model.destination = .dashboard
    model.omnibarGroup = "ordering"
    #expect(model.spotlitGroup == "ordering")
    model.destination = .done
    #expect(model.spotlitGroup == nil)
    model.destination = .dashboard
    model.releaseSpotlight()
    #expect(model.omnibarGroup == nil)
    model.omnibarGroup = AppModel.unsortedGroup
    #expect(model.spotlitGroup == AppModel.unsortedGroup)
}

@MainActor @Test func acceptingTheRecommendationAnswersOnlyTheOneCardShownAndNeverAPermission() {
    let question = Decision(taskId: "t", question: "Which shop?", recommendation: "The first", options: ["The first", "The second"])
    let permission = Decision(taskId: "t", question: "May I pay?", recommendation: "Yes, pay", options: ["Yes, pay", "No"], kind: "permission")
    let completion = Decision(taskId: "t", question: "Done?", recommendation: "Mark done", options: ["Mark done", "Keep open"], kind: "completion")
    #expect(AppModel.acceptable([question])?.id == question.id)
    #expect(AppModel.acceptable([completion, question])?.id == question.id)
    #expect(AppModel.acceptable([permission]) == nil)
    #expect(AppModel.acceptable([question, permission]) == nil)
    #expect(AppModel.acceptable([question, Decision(taskId: "t", question: "And when?", recommendation: "Today", options: ["Today"])]) == nil)
    #expect(AppModel.acceptable([completion]) == nil)
    #expect(AppModel.acceptable([Decision(taskId: "t", question: "Which?", recommendation: " ", options: [])]) == nil)
}

@MainActor @Test func commandNOpensUnsortedsSheetOnTheBoard() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "compose-unsorted-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Selected task"))
    let model = try AppModel(store: store)
    model.showTask(task); model.search = "Selected"; model.destination = .inbox
    model.composeUnsorted()
    #expect(model.destination == .dashboard && model.selection == nil && model.search.isEmpty)
    #expect(model.spotlitGroup == AppModel.unsortedGroup)
}

@MainActor @Test func boardPlusMakesTheGroupNamedOrNamedAfterItsFirstTask() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "board-plus-\(UUID().uuidString)/tasks.sqlite"))
    let model = try AppModel(store: store)
    // A name and no task: just the group, and the sheet folds into its card.
    let studio = try #require(model.makeGroup(named: "  Studio ", firstTask: ""))
    #expect(studio.name == "Studio" && model.sheetLanding == studio.id && model.boardTasks(in: studio.id).isEmpty)
    // No name: called after the first task until Facienda names it, and the task can go into its plan.
    let desk = try #require(model.makeGroup(named: "", firstTask: "Order a monitor arm that fits the Studio Display"))
    #expect(desk.name == "monitor arm" && model.sheetLanding == desk.id)
    #expect(model.planTask("Order a monitor arm that fits the Studio Display", in: desk.id))
    #expect(model.plannedLines(in: desk.id).map(\.text) == ["Order a monitor arm that fits the Studio Display"])
    // New groups join the board wherever there is room, after the others.
    #expect(model.groups.map(\.name) == ["Studio", "monitor arm"])
}
