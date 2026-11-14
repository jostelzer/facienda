import Foundation
import Testing
@testable import FaciendaCore

private func handoverStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "ChatHandoverTests/\(UUID().uuidString)/test.sqlite"))
}

/// A task whose agent already worked in `chat`, as a delivered start leaves it.
private func startedTask(_ store: FaciendaStore, chat: String = "finder", title: String = "Find the thread about the venue") throws -> FaciendaTask {
    let task = try store.create(FaciendaTask(title: title, state: .needsMe))
    try store.write { db in
        try ThreadLink(taskId: task.id, codexThreadId: chat, linkedBy: "native runner").insert(db)
        try NativeDispatch(id: UUID().uuidString, taskId: task.id, state: "started", requestedAt: Date(), threadId: chat, kind: "start").insert(db)
    }
    return task
}

private let sessionID = "local_0b5e1f5a-2c1d-4a4e-9b55-6d1f3c2a9e10"
private let cliID = "7d3c2b1a-0f9e-4d8c-a7b6-5e4d3c2b1a09"

@Test func aHandedOverChatReplacesTheTasksChatAndGetsItsReplies() throws {
    let store = try handoverStore()
    let task = try startedTask(store)
    #expect(try store.enqueueDispatch(taskId: task.id, message: "before").threadId == "finder")
    try store.write { try $0.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE kind = 'reply'") }

    try store.handOver(taskId: task.id, to: ChatCandidate(threadId: "found", provider: .codex, title: "Venue email"))
    let links = try store.links(taskId: task.id)
    #expect(links.map(\.threadId) == ["found"] && links[0].role == "work")
    // The replaced chat is never made the task's chat again by discovery.
    #expect(try store.excludedOwningThreads(taskId: task.id) == ["finder"])
    let reply = try store.enqueueDispatch(taskId: task.id, message: "carry on")
    #expect(reply.threadId == "found" && reply.agent == .codex)
    // The choice is made: the task offers no more chats to continue in.
    #expect(try store.handedOverTasks() == [task.id])
}

@Test func waitingRepliesAndChecksFollowTheNewChat() throws {
    let store = try handoverStore()
    let task = try startedTask(store)
    let waiting = try store.enqueueDispatch(taskId: task.id, message: "queued before the switch")
    try store.write { db in
        try db.execute(sql: "INSERT INTO dispatchContext(dispatchId, taskId, payload, savedAt) VALUES (?, ?, '{}', ?)", arguments: [waiting.id, task.id, Date()])
    }
    try store.handOver(taskId: task.id, to: ChatCandidate(threadId: sessionID, provider: .claude, title: "Venue", cwd: "/tmp", cliSessionId: cliID))
    let moved = try #require(try store.dispatches().first { $0.id == waiting.id })
    #expect(moved.threadId == sessionID && moved.agent == .claude)
    #expect(try store.dispatchContext(waiting.id) == nil)
    // A session started outside Facienda keeps its own model.
    let session = try #require(try store.claudeSession(sessionID))
    #expect(session.taskId == task.id && session.cliSessionId == cliID && session.configureState == "skipped")
}

@Test func aChatOfAnotherTaskOrARunnerCannotBeHandedOver() throws {
    let store = try handoverStore()
    let task = try startedTask(store)
    let other = try startedTask(store, chat: "theirs", title: "Another task")
    #expect(throws: StoreError.self) { try store.handOver(taskId: task.id, to: ChatCandidate(threadId: "theirs", provider: .codex, title: "")) }
    try store.bindRunner(threadId: "runner", automationId: nil)
    #expect(throws: StoreError.self) { try store.handOver(taskId: task.id, to: ChatCandidate(threadId: "runner", provider: .codex, title: "")) }
    #expect(throws: StoreError.self) { try store.handOver(taskId: task.id, to: ChatCandidate(threadId: "not-a-session", provider: .claude, title: "")) }
    #expect(try store.links(taskId: other.id).map(\.threadId) == ["theirs"])
    #expect(try store.links(taskId: task.id).map(\.threadId) == ["finder"])
}

@Test func aTakenChatSaysWhichTaskHasItAndWhere() throws {
    let library = try handoverStore()
    let home = try library.defaultWorkspace()
    let studio = try library.createWorkspace(name: "Studio")
    let task = try startedTask(library.scoped(to: home.id))
    let other = try startedTask(library.scoped(to: studio.id), chat: "theirs", title: "Fix the swoosh lines")
    _ = try library.update(other.id) { $0.state = .done }
    do {
        try library.scoped(to: home.id).handOver(taskId: task.id, to: ChatCandidate(threadId: "theirs", provider: .codex, title: ""))
        Issue.record("A taken chat was handed over")
    } catch {
        #expect(error.localizedDescription == "This chat is taken by “Fix the swoosh lines” (done, in Studio). A chat carries one task.")
    }
}

@Test func aDeliveryUnderwayHoldsTheSwitch() throws {
    let store = try handoverStore()
    let task = try startedTask(store)
    let reply = try store.enqueueDispatch(taskId: task.id, message: "now")
    try store.write { try $0.execute(sql: "UPDATE dispatches SET state = 'dispatching' WHERE id = ?", arguments: [reply.id]) }
    #expect(throws: StoreError.self) { try store.handOver(taskId: task.id, to: ChatCandidate(threadId: "found", provider: .codex, title: "")) }
}

@Test func chatLinksAreFoundInAnswersInOrderOnce() {
    let text = """
    Found it: “Venue email” (codex://threads/019a-venue_2) and the Claude session local_\(sessionID.dropFirst(6).uppercased()).
    Also claude://code/continue?session=\(sessionID) and codex://threads/019a-venue_2 again; not xlocal_\(cliID) nor local_123.
    """
    #expect(ChatLinks.find(in: text) == [.init(threadId: "019a-venue_2", provider: .codex), .init(threadId: sessionID, provider: .claude)])
    #expect(ChatLinks.find(in: "No chat here.").isEmpty)
}

@Test func claudeSessionsAreReadFromTheAppsRecordsAndLinks() throws {
    let registry = FileManager.default.temporaryDirectory.appending(path: "claude-registry-\(UUID().uuidString)")
    let organisation = registry.appending(path: "account/org")
    try FileManager.default.createDirectory(at: organisation, withIntermediateDirectories: true)
    let record: [String: Any] = ["sessionId": sessionID, "cliSessionId": cliID, "cwd": "/Users/me/project", "title": "Venue email",
                                 "lastActivityAt": 1_792_045_838_810.0, "isArchived": false, "model": "claude-sonnet-5-5", "effort": "medium",
                                 "lastTurnEdgeAt": 1_792_045_840_000.0, "lastFocusedAt": 1_792_045_850_000.0]
    try JSONSerialization.data(withJSONObject: record).write(to: organisation.appending(path: sessionID + ".json"))
    let archived = "local_11111111-2222-4333-8444-555555555555"
    try JSONSerialization.data(withJSONObject: ["sessionId": archived, "cliSessionId": cliID, "cwd": "/", "title": "Old",
                                                "error": "You've hit your session limit", "errorAt": 1_792_045_900_000.0]).write(to: organisation.appending(path: archived + ".json"))
    try JSONSerialization.data(withJSONObject: ["v": 1, "archived": [archived]]).write(to: organisation.appending(path: "archived-sessions.idx"))

    let sessions = ClaudeDesktop.sessions(registry: registry)
    #expect(sessions.count == 2 && sessions.first { $0.id == archived }?.archived == true)
    let session = try #require(ClaudeDesktop.session(id: sessionID, registry: registry))
    #expect(session.title == "Venue email" && session.cwd == "/Users/me/project" && !session.archived)
    #expect(session.model == "claude-sonnet-5-5" && session.effort == "medium")
    #expect(sessions.first { $0.id == archived }?.model == nil)
    // The error that ended a session's last turn, such as a usage limit.
    #expect(session.error == nil && sessions.first { $0.id == archived }?.error == "You've hit your session limit")
    #expect(sessions.first { $0.id == archived }?.errorAt == Date(timeIntervalSince1970: 1_792_045_900))
    #expect(session.chat.provider == .claude && session.chat.cliSessionId == cliID)
    // Opened after its latest turn ended, the session has been read; one never opened has not.
    #expect(session.turnEndedAt == Date(timeIntervalSince1970: 1_792_045_840) && session.focusedAt == Date(timeIntervalSince1970: 1_792_045_850))
    #expect(ChatReading(claude: session) == ChatReading(turnEndedAt: Date(timeIntervalSince1970: 1_792_045_840), read: true))
    #expect(sessions.first { $0.id == archived }.map(ChatReading.init(claude:))?.read == false)
    var reopened = session
    reopened.turnEdgeAt = Date(timeIntervalSince1970: 1_792_045_900)
    #expect(!ChatReading(claude: reopened).read)

    #expect(ClaudeDesktop.sessionID(inLink: sessionID) == sessionID)
    #expect(ClaudeDesktop.sessionID(inLink: "claude://code/continue?session=\(sessionID)") == sessionID)
    #expect(ClaudeDesktop.sessionID(inLink: "local_nope") == nil)
    #expect(ClaudeDesktop.sessionID(inLink: "see \(sessionID)") == nil)
}

@Test func aClaudeSessionBecomesATaskFromItsFirstMessage() throws {
    let store = try handoverStore()
    let transcripts = FileManager.default.temporaryDirectory.appending(path: "claude-projects-\(UUID().uuidString)")
    let cwd = "/Users/me/project"
    let folder = transcripts.appending(path: ClaudeTranscript.projectFolderName(cwd))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let lines = [
        #"{"type":"user","uuid":"u1","timestamp":"2026-10-15T06:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"Draft the venue email"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-15T06:01:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Here is a draft."}]}}"#
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: cliID + ".jsonl"))
    let session = ClaudeDesktop.Session(id: sessionID, cliSessionId: cliID, title: "Venue email", cwd: cwd, lastActivityAt: Date(), archived: false)

    let task = try store.importClaudeSession(session, transcripts: transcripts)
    #expect(task.title == "Draft the venue email" && task.displayName == "Venue email" && task.provider == .claude)
    let link = try #require(try store.links(taskId: task.id).first)
    #expect(link.threadId == sessionID && link.provider == .claude)
    #expect(try store.claudeSession(sessionID)?.cliSessionId == cliID)
    // Importing it again gives the same task back.
    #expect(try store.importClaudeSession(session, transcripts: transcripts).id == task.id)
}

@Test func deletingAHandedOverTaskLeavesTheBoardLoadable() throws {
    let store = try handoverStore()
    let task = try startedTask(store)
    try store.handOver(taskId: task.id, to: ChatCandidate(threadId: "found", provider: .codex, title: "Venue email"))
    // Deleting keeps the task's events with no task; they must not break loading.
    try store.deleteTask(task.id)
    #expect(try store.handedOverTasks().isEmpty)
}

private func message(_ type: String, _ text: String) -> JSONValue {
    type == "userMessage"
        ? .object(["type": .string(type), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
        : .object(["type": .string(type), "text": .string(text)])
}

@Test func aTaskCarriesOnInANewChatOnAnotherModelWithAHandoverNote() async throws {
    let library = try handoverStore(), home = try library.defaultWorkspace(), store = library.scoped(to: home.id)
    let task = try startedTask(store)
    try store.write { db in
        try TaskEvent(taskId: task.id, source: .mcp, kind: "codex.result", payload: "The venue thread is from 3 March.").insert(db)
        try CheckPlan(taskId: task.id, threadId: "finder", revision: 1, nextCheck: Date().addingTimeInterval(3600), purpose: "Look for a reply", reason: "They answer in the morning",
                      paused: false, pinned: false, minimumInterval: 3600, deadline: Date().addingTimeInterval(86400 * 7), failures: 0, checks: 0).insert(db)
    }
    try store.saveConversation(taskId: task.id, conversation: CodexConversation(threadId: "finder", title: "Venue", turns: [
        CodexConversationTurn(id: "t1", status: "completed", startedAt: Date(), completedAt: Date(), error: .null,
                              items: [message("userMessage", "Which mail had the venue?"), message("agentMessage", "The one from Ada, 3 March.")])
    ]))

    let file = try store.continueInNewChat(taskId: task.id, on: TaskModelChoice(model: "claude-opus-5-5", effort: "high", fast: false))
    let note = try String(contentsOf: file, encoding: .utf8)
    #expect(note.contains("The venue thread is from 3 March.") && note.contains("**User:**\nWhich mail had the venue?") && note.contains("**Codex:**\nThe one from Ada, 3 March."))
    #expect(note.contains("codex://threads/finder"))
    // The old chat has left the task for good, and the task now runs on the new model.
    #expect(try store.links(taskId: task.id).isEmpty && store.excludedOwningThreads(taskId: task.id) == ["finder"])
    let moved = try store.task(task.id)
    #expect(moved.provider == .claude && moved.workerModel == "claude-opus-5-5" && moved.workerReasoningEffort == "high")
    #expect(try store.checkPlan(task.id)?.paused == true)

    // Its start opens a new Claude session and points it to the note.
    let start = try store.enqueueDispatch(taskId: task.id)
    #expect(start.threadId == nil && start.agent == .claude)
    let prompt = try await DispatchPrompt.payload(start, store: library, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(prompt.contains("HANDOVER: The user moved this task here") && prompt.contains(file.path))

    // Once the new session carries the task, it may take the paused checks on, and the note is no longer offered.
    try store.write { try ThreadLink(taskId: task.id, codexThreadId: sessionID, provider: .claude).insert($0) }
    let plan = try store.planCheck(taskId: task.id, threadId: sessionID, expectedRevision: 2, nextCheck: Date().addingTimeInterval(7200),
                                   purpose: "Look for a reply", reason: "Morning", waitingOn: "Ada")
    #expect(plan.threadId == sessionID && !plan.paused)
    #expect(try store.pendingHandoverNote(taskId: task.id) == nil)
}

@Test func aNewChatNeedsAnOldOneAndNoDeliveryUnderway() throws {
    let store = try handoverStore()
    let fresh = try store.create(FaciendaTask(title: "Never started", state: .needsMe))
    let claude = TaskModelChoice(model: "claude-sonnet-5-5", effort: "medium", fast: false)
    #expect(throws: StoreError.self) { try store.continueInNewChat(taskId: fresh.id, on: claude) }
    let task = try startedTask(store)
    _ = try store.enqueueDispatch(taskId: task.id, message: "still on its way")
    #expect(throws: StoreError.self) { try store.continueInNewChat(taskId: task.id, on: claude) }
    #expect(try store.links(taskId: task.id).map(\.threadId) == ["finder"] && store.task(task.id).provider == .codex)
}
