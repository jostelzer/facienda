import Foundation
import Testing
@testable import FaciendaCore

private func dispatcherStore() throws -> FaciendaStore {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaDispatchTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    _ = try store.prepareWorkspaceSetup()
    try store.bindCodexDispatcher()
    try store.verifyDispatcherSetup(projectId: "workspace-project")
    return store
}

private let dispatcher = FaciendaStore.codexDispatcherId

@Test func theDispatcherRetiresTheBoundRunnerAndNeedsNoAutomation() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaDispatchTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "old-runner", automationId: "old-automation")
    try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "old-runner", automationId: "old-automation")
    let task = try store.create(FaciendaTask(title: "Claimed by the old runner"))
    let item = try store.enqueueDispatch(taskId: task.id)
    #expect(try store.claimDispatch(runnerId: "old-runner")?.id == item.id)

    _ = try store.prepareWorkspaceSetup(repair: true)
    try store.bindCodexDispatcher()
    // The old runner's next run finds itself retired; what it claimed but never delivered is queued again.
    #expect(try store.runnerState()?.isDispatcher == true)
    #expect(try store.workspaceSetup()?.retiredRunnerId == "old-runner")
    #expect(try store.workspaceSetup()?.retiredAutomationId == "old-automation")
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "queued")
    #expect(throws: StoreError.self) { try store.claimDispatch(runnerId: "old-runner") }
    #expect(try store.workspaceSetup()?.isReady(runner: store.runnerState()) == false)

    try store.verifyDispatcherSetup(projectId: "facienda-project")
    let ready = try #require(try store.workspaceSetup())
    #expect(ready.isReady(runner: try store.runnerState()))
    #expect(ready.projectId == "facienda-project" && ready.confirmedProjectName == "facienda" && ready.automationId == nil)
    #expect(try store.claimDispatch(runnerId: dispatcher)?.id == item.id)
    // Binding again keeps the dispatcher as it is.
    try store.bindCodexDispatcher()
    #expect(try store.workspaceSetup()?.retiredRunnerId == "old-runner")
}

@Test func aNewTaskStartsInItsOwnFolderAndARepliesGoToItsChat() throws {
    let store = try dispatcherStore()
    let task = try store.create(FaciendaTask(title: "Book the flights"))
    let start = try store.enqueueDispatch(taskId: task.id)
    let claimed = try #require(try store.claimDispatch(runnerId: dispatcher))
    let context = try store.directContext(for: claimed, owner: nil, projects: [])
    #expect(context.route == .new && context.chats.isEmpty)
    #expect(context.project?.id == "workspace-project")
    #expect(context.project?.path == store.taskFolder(task.id).path)
    #expect(FileManager.default.fileExists(atPath: store.taskFolder(task.id).path))
    try store.saveDispatchContext(context, dispatchId: start.id, runnerId: dispatcher)
    _ = try store.beginDispatch(start.id, runnerId: dispatcher)
    try store.acknowledgeDispatch(start.id, runnerId: dispatcher, threadId: "chat-1")

    let reply = try store.enqueueDispatch(taskId: task.id, message: "Make it Tuesday")
    #expect(reply.threadId == "chat-1")
    let claimedReply = try #require(try store.claimDispatch(runnerId: dispatcher))
    let chat = FaciendaStore.ChatState(threadId: "chat-1", title: "Book flights", status: .idle)
    let reuse = try store.directContext(for: claimedReply, owner: chat, projects: [])
    #expect(reuse.route == .reuse && reuse.owner?.threadId == "chat-1" && reuse.project == nil)
    try store.saveDispatchContext(reuse, dispatchId: reply.id, runnerId: dispatcher)
    #expect(try store.beginDispatch(reply.id, runnerId: dispatcher).threadId == "chat-1")
    // Another chat can never stand in for the task's own.
    #expect(throws: StoreError.self) {
        try store.directContext(for: claimedReply, owner: .init(threadId: "chat-2", title: "Other", status: .idle), projects: [])
    }
}

@Test func aChosenFolderKeepsItsProjectOrNone() throws {
    let store = try dispatcherStore()
    let chosen = try store.create(FaciendaTask(title: "Fix the build", cwd: "/Users/someone/git/app/Sources"))
    let item = try store.enqueueDispatch(taskId: chosen.id)
    let claimed = try #require(try store.claimDispatch(runnerId: dispatcher))
    let inside = try store.directContext(for: claimed, owner: nil, projects: [.init(id: "app", paths: ["/Users/someone/git/app"])])
    #expect(inside.project?.id == "app" && inside.project?.path == chosen.cwd)
    // A folder outside every Codex project still works there, without a project.
    let outside = try store.directContext(for: claimed, owner: nil, projects: [.init(id: "other", paths: ["/Users/someone/git/other"])])
    #expect(outside.project == nil)
    try store.saveDispatchContext(outside, dispatchId: item.id, runnerId: dispatcher)
}

@Test func linkedFoldersStartInTheProjectSpanningThem() throws {
    let store = try dispatcherStore()
    var linked = FaciendaTask(title: "Compare both repositories")
    linked.folders = ["/Users/someone/a", "/Users/someone/b"]
    let saved = try store.create(linked)
    _ = try store.enqueueDispatch(taskId: saved.id)
    let both = try #require(try store.claimDispatch(runnerId: dispatcher))
    let spanning = try store.directContext(for: both, owner: nil, projects: [.init(id: "pair", paths: ["/Users/someone/b", "/Users/someone/a"])])
    #expect(spanning.project?.id == "pair" && spanning.project?.path == "/Users/someone/a")
    #expect(throws: StoreError.self) { try store.directContext(for: both, owner: nil, projects: []) }
}

@Test func aDeliveryCodexRefusedGoesBackToTheQueue() throws {
    let store = try dispatcherStore()
    let task = try store.create(FaciendaTask(title: "Refused once"))
    let item = try store.enqueueDispatch(taskId: task.id)
    let claimed = try #require(try store.claimDispatch(runnerId: dispatcher))
    try store.saveDispatchContext(store.directContext(for: claimed, owner: nil, projects: []), dispatchId: item.id, runnerId: dispatcher)
    _ = try store.beginDispatch(item.id, runnerId: dispatcher)
    try store.releaseUndelivered(item.id, runnerId: dispatcher, reason: "Unknown model", now: Date().addingTimeInterval(-120))
    let released = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(released.state == "queued" && released.runnerId == nil)
    #expect(try store.claimDispatch(runnerId: dispatcher)?.id == item.id)
    // Only a delivery that is under way can be released.
    #expect(throws: StoreError.self) { try store.releaseUndelivered(item.id, runnerId: dispatcher, reason: "again") }
}

@Test func whatARunningTurnAsksWaitsForTheUserAndGoesBackOnce() throws {
    let store = try dispatcherStore()
    let task = try store.create(FaciendaTask(title: "Clean the build folder"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "chat-1"))
    let params: JSONValue = .object(["threadId": .string("chat-1"), "turnId": .string("turn-1"), "itemId": .string("exec-1"),
                                     "command": .string("/bin/bash -lc 'rm -rf build'"), "cwd": .string("/tmp/app"), "startedAtMs": .number(1)])
    let asked = try store.recordCodexApproval(method: "item/commandExecution/requestApproval", params: params, requestId: .number(7))
    #expect(asked.taskId == task.id && asked.kind == .command && asked.summary == "Run /bin/bash -lc 'rm -rf build'")
    #expect(try store.openCodexApprovals(taskId: task.id).map(\.id) == [asked.id])
    #expect(try store.links(taskId: task.id).first?.lastKnownStatus == "waitingOnApproval")
    #expect(try store.codexApprovalsToSend().isEmpty)

    try store.answerCodexApproval(asked.id, response: asked.response(for: .allowForChat))
    #expect(try store.openCodexApprovals(taskId: task.id).isEmpty)
    let toSend = try #require(try store.codexApprovalsToSend().first)
    #expect(toSend.response == JSONValue.object(["decision": .string("acceptForSession")]).json)
    // A reconnect before the answer went out: Codex asks again under a new ID, and the answer goes on that one.
    let again = try store.recordCodexApproval(method: "item/commandExecution/requestApproval", params: params, requestId: .number(2))
    #expect(again.id == asked.id)
    #expect(try store.codexApprovalsToSend().first?.requestId == "2")
    try store.markCodexApprovalSent(asked.id)
    #expect(try store.codexApprovalsToSend().isEmpty)
    #expect(throws: StoreError.self) { try store.answerCodexApproval(asked.id, response: .null) }

    // A turn that ends closes what it still asked.
    let other = try store.recordCodexApproval(method: "item/fileChange/requestApproval",
                                              params: .object(["threadId": .string("chat-1"), "turnId": .string("turn-2"), "itemId": .string("patch-1")]), requestId: .number(9))
    #expect(try store.codexChatsToFollow(since: .distantPast).contains("chat-1"))
    try store.closeCodexApprovals(threadId: "chat-1")
    #expect(try store.openCodexApprovals().isEmpty)
    #expect(throws: StoreError.self) { try store.answerCodexApproval(other.id, response: other.response(for: .decline)) }
}

@Test func eachKindOfRequestGetsTheAnswerCodexExpects() throws {
    func approval(_ method: String, _ extra: [String: JSONValue] = [:]) -> CodexApproval {
        var params: [String: JSONValue] = ["threadId": .string("t"), "turnId": .string("u"), "itemId": .string("i")]
        params.merge(extra) { $1 }
        return CodexApproval(id: "a", taskId: nil, threadId: "t", turnId: "u", itemId: "i", method: method, params: JSONValue.object(params).json, requestId: "1", requestedAt: Date())
    }
    #expect(try approval("item/fileChange/requestApproval").response(for: .decline) == .object(["decision": .string("decline")]))
    let access: JSONValue = .object(["network": .object(["enabled": .bool(true)])])
    let permissions = approval("item/permissions/requestApproval", ["permissions": access])
    #expect(try permissions.response(for: .allow) == .object(["permissions": access, "scope": .string("turn")]))
    #expect(try permissions.response(for: .decline) == .object(["permissions": .object([:]), "scope": .string("turn")]))
    let tool = approval("mcpServer/elicitation/request", ["message": .string("Allow facienda_task_update?")])
    #expect(tool.choices == [.allow, .decline] && tool.summary == "Allow facienda_task_update?")
    #expect(try tool.response(for: .allow) == .object(["action": .string("accept"), "content": .object([:])]))
    let question = approval("item/tool/requestUserInput", ["questions": .array([.object(["id": .string("q"), "header": .string("Pick"), "question": .string("Which branch?")])])])
    #expect(question.choices.isEmpty && question.summary == "Which branch?")
    #expect(throws: StoreError.self) { try question.response(answers: [:]) }
    #expect(try question.response(answers: ["q": "main"]) == .object(["answers": .object(["q": .object(["answers": .array([.string("main")])])])]))
}

@Test func backgroundWorkRunsOnTheChosenModelAndRecommendsWhatIsThere() throws {
    #expect(ServiceModelChoice.recommended(codex: true, claude: false) == .luna)
    #expect(ServiceModelChoice.recommended(codex: false, claude: true) == .haiku)
    #expect(ServiceModelChoice.recommended(codex: true, claude: true) == .luna)
    #expect(ServiceModelChoice.haiku.name == "Haiku 5.5" && ServiceModelChoice.luna.name == "GPT-6 Luna")
    let store = try dispatcherStore()
    #expect(try store.serviceModel() == nil)
    store.adoptServiceModel()
    #expect(ServiceModelChoice.current == .luna)
    try store.saveServiceModel(.haiku)
    #expect(try FaciendaStore(url: store.url).serviceModel() == .haiku)
    #expect(ServiceModelChoice.current == .haiku)
    #expect(throws: StoreError.self) { try store.saveServiceModel(ServiceModelChoice(provider: .codex, model: "")) }
    ServiceModelChoice.current = .luna
}

@Test func nativeQueuePersistsDestinationBeforeAcceptanceAndDoesNotBlockOtherTasks() throws {
    let store = try dispatcherStore()
    let task = try store.create(FaciendaTask(title: "Native queue first"))
    let first = try store.enqueueDispatch(taskId: task.id)
    let claimed = try #require(try store.claimDispatch(runnerId: dispatcher))
    try store.saveDispatchContext(store.directContext(for: claimed, owner: nil, projects: []), dispatchId: first.id, runnerId: dispatcher)
    _ = try store.beginDispatch(first.id, runnerId: dispatcher)
    try store.prepareCodexQueue(first.id, runnerId: dispatcher, threadId: "native-queue-chat")
    #expect(try store.claimDispatch(runnerId: dispatcher)?.threadId == "native-queue-chat")
    #expect(try store.task(task.id).state != .running)
    #expect(throws: StoreError.self) { try store.prepareCodexQueue(first.id, runnerId: dispatcher, threadId: "replacement-chat") }
    #expect(throws: StoreError.self) { try store.recordCodexQueue(first.id, runnerId: "wrong-runner", queuedSubmissionId: "receipt") }
    try store.recordCodexQueue(first.id, runnerId: dispatcher, queuedSubmissionId: "receipt")
    try store.recordCodexQueue(first.id, runnerId: dispatcher, queuedSubmissionId: "receipt")
    #expect(throws: StoreError.self) { try store.recordCodexQueue(first.id, runnerId: dispatcher, queuedSubmissionId: "different-receipt") }
    #expect(throws: StoreError.self) { try store.releaseUndelivered(first.id, runnerId: dispatcher, reason: "Must not repeat an accepted message") }
    let other = try store.create(FaciendaTask(title: "Native queue second"))
    let second = try store.enqueueDispatch(taskId: other.id)
    #expect(try store.claimDispatch(runnerId: dispatcher)?.id == second.id)
    let reopened = try FaciendaStore(existing: store.url)
    #expect(try reopened.codexQueuedDeliveries(runnerId: dispatcher).map(\.id) == [first.id])
    try reopened.acknowledgeDispatch(first.id, runnerId: dispatcher, threadId: "native-queue-chat", status: "idle")
    #expect(try reopened.task(task.id).state != .running)
    #expect(try reopened.codexQueuedDeliveries(runnerId: dispatcher).isEmpty)
}
