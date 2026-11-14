import Foundation
import Testing
@testable import FaciendaCore

private func modelStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "ChatModelChangeTests/\(UUID().uuidString)/test.sqlite"))
}

/// A task whose agent already works in `chat`, on `model`.
private func runningTask(_ store: FaciendaStore, chat: String, provider: AgentProvider, model: String) throws -> FaciendaTask {
    var draft = FaciendaTask(title: "Tidy the garden shed list", state: .running)
    draft.workerModel = model; draft.workerReasoningEffort = "high"; draft.workerProvider = provider
    let task = try store.create(draft)
    try store.write { db in
        try ThreadLink(taskId: task.id, codexThreadId: chat, linkedBy: "native runner", provider: provider).insert(db)
        try NativeDispatch(id: UUID().uuidString, taskId: task.id, state: "started", requestedAt: Date(), threadId: chat, kind: "start").insert(db)
    }
    return task
}

@Test func aCodexChatKeepsItsChatAndWaitsForTheDispatcherToSetTheModel() throws {
    let store = try modelStore()
    let task = try runningTask(store, chat: "shed", provider: .codex, model: "gpt-6.1-sol")
    try store.changeChatModel(taskId: task.id, to: TaskModelChoice(model: "gpt-6-luna", effort: "low", fast: false))
    let changed = try store.task(task.id)
    #expect(changed.workerModel == "gpt-6-luna" && changed.workerReasoningEffort == "low")
    #expect(try store.links(taskId: task.id).map(\.threadId) == ["shed"])
    let change = try #require(try store.chatModelChanges().first)
    #expect(change.threadId == "shed" && change.model == "gpt-6-luna" && change.previousModel == "gpt-6.1-sol")
    #expect(try store.chatModelChangeArrived(after: Date().addingTimeInterval(-60)))

    // A second pick before Codex took the first still remembers the model the chat really had.
    try store.changeChatModel(taskId: task.id, to: TaskModelChoice(model: "gpt-6-astra", effort: "high", fast: false))
    let second = try #require(try store.chatModelChanges().first)
    #expect(try store.chatModelChanges().count == 1 && second.model == "gpt-6-astra" && second.previousModel == "gpt-6.1-sol")

    // Codex refused it: the task shows the model its chat still runs on.
    try store.finishChatModelChange(second, applied: false, note: "unknown model")
    #expect(try store.chatModelChanges().isEmpty)
    #expect(try store.task(task.id).workerModel == "gpt-6.1-sol")
}

@Test func anAppliedChangeLeavesTheNewModelAndANewerPickWaits() throws {
    let store = try modelStore()
    let task = try runningTask(store, chat: "shed", provider: .codex, model: "gpt-6.1-sol")
    try store.changeChatModel(taskId: task.id, to: TaskModelChoice(model: "gpt-6-luna", effort: "high", fast: false))
    let first = try #require(try store.chatModelChanges().first)
    try store.changeChatModel(taskId: task.id, to: TaskModelChoice(model: "gpt-6-astra", effort: "high", fast: false))
    // The dispatcher finished the first pick after the second came in: the second stays to be set.
    try store.finishChatModelChange(first, applied: true)
    #expect(try store.chatModelChanges().map(\.model) == ["gpt-6-astra"])
    try store.finishChatModelChange(try #require(try store.chatModelChanges().first), applied: true)
    #expect(try store.chatModelChanges().isEmpty && store.task(task.id).workerModel == "gpt-6-astra")
}

@Test func anotherAppsModelCannotTakeOverTheChat() throws {
    let store = try modelStore()
    let task = try runningTask(store, chat: "shed", provider: .codex, model: "gpt-6.1-sol")
    #expect(throws: StoreError.self) { try store.changeChatModel(taskId: task.id, to: .claudeStandard) }
    let fresh = try store.create(FaciendaTask(title: "Not started yet", state: .inbox))
    #expect(throws: StoreError.self) { try store.changeChatModel(taskId: fresh.id, to: .standard) }
    #expect(try store.task(task.id).workerModel == "gpt-6.1-sol")
}

@Test func aClaudeSessionGoesBackToTheRunnerForItsModelOnly() throws {
    let store = try modelStore()
    let session = "local_5a0c9e3b-7f21-4d6e-8a1b-2c3d4e5f6a7b"
    let task = try runningTask(store, chat: session, provider: .claude, model: "claude-opus-5-5")
    let setup = try store.prepareClaudeSetup()
    try store.bindClaudeRunner(sessionId: "local_runner", challenge: setup.challenge, canStartSessions: false)
    try store.write { db in
        try ClaudeSession(threadId: session, taskId: task.id, linkedAt: Date(), model: "claude-opus-5-5", effort: "high", fast: true,
                          configureState: "done", configuredAt: Date()).insert(db)
    }
    try store.changeChatModel(taskId: task.id, to: TaskModelChoice(model: "claude-sonnet-5-5", effort: "medium", fast: false))
    let pending = try #require(try store.claudeSession(session))
    #expect(pending.configureState == "pending" && pending.model == "claude-sonnet-5-5" && pending.effort == "medium" && !pending.fast && pending.changedAt != nil)
    #expect(try store.chatModelChanges().isEmpty)
    // A reply sent right after waits behind the settings, and is not sent with them as a start would be.
    _ = try store.enqueueDispatch(taskId: task.id, message: "and the bikes")
    guard case let .configure(claimed, start)? = try store.claimClaudeWork(runnerId: "local_runner") else { Issue.record("Expected the settings first"); return }
    #expect(claimed.threadId == session && start == nil)
    try store.finishClaudeConfigure(threadId: session, runnerId: "local_runner", applied: true, note: "Sonnet, medium")
    guard case let .deliver(reply)? = try store.claimClaudeWork(runnerId: "local_runner") else { Issue.record("Expected the reply next"); return }
    #expect(reply.message == "and the bikes")
}
