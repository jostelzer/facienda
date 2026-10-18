import Foundation
import Testing
@testable import FaciendaCore

private func store() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/test.sqlite"))
}

/// The library's first workspace, as the app sees it.
private func workspaceStore() throws -> FaciendaStore {
    let library = try store()
    return library.scoped(to: try library.defaultWorkspace().id)
}

@Test func resultSurvivesTimelineWindowAndReopen() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Find a conversation", state: .needsMe))
    let result = TaskEvent(taskId: task.id, source: .appServer, kind: "codex.result", payload: "Found the conversation", verified: false, at: Date(timeIntervalSince1970: 1))
    try db.record(result)
    for index in 0..<101 {
        try db.record(TaskEvent(taskId: task.id, source: .app, kind: "thread.notLoaded", at: Date(timeIntervalSince1970: Double(index + 2))))
    }
    #expect(try !db.events(taskId: task.id).contains { $0.kind == "codex.result" })
    let reopened = try FaciendaStore(url: db.url)
    #expect(try reopened.latestEvent(taskId: task.id, kind: "codex.result")?.payload == "Found the conversation")
    #expect(try reopened.latestEvent(taskId: task.id, kind: "codex.result")?.verified == false)
    #expect(try reopened.latestEvent(taskId: "another-task", kind: "codex.result") == nil)
}

@Test func agentCannotCompleteOrEscalateScope() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Call home", state: .needsMe))
    #expect(throws: StoreError.self) { try db.update(task.id, source: .mcp) { $0.state = .done } }
    #expect(throws: StoreError.self) { try db.update(task.id, source: .mcp) { $0.automationScope = .autonomous } }
    #expect(try db.task(task.id).state == .needsMe)
    #expect(try db.events(taskId: task.id).count == 1) // Failed writes roll back their events too.
    try db.update(task.id) { $0.state = .done }
    #expect(try db.task(task.id).completedBy == "user")
    #expect(throws: StoreError.self) { try db.update(task.id, source: .mcp) { $0.state = .running } }
}

@Test func optimisticEditsAndFTSSearch() throws {
    let db = try store(), original = try db.create(FaciendaTask(title: "Trip", brief: "Azores itinerary"))
    try db.update(original.id, expectedRevision: original.revision) { $0.brief = "Madeira ferry" }
    #expect(throws: StoreError.self) { try db.update(original.id, expectedRevision: original.revision) { $0.title = "Stale edit" } }
    #expect(try db.tasks(search: "Azores").isEmpty)
    #expect(try db.tasks(search: "Madeira").count == 1)
    try db.link(ThreadLink(taskId: original.id, codexThreadId: "thread1", title: "Find a hotel", preview: "Funchal balcony"))
    #expect(try db.tasks(search: "Funchal").first?.id == original.id)
    #expect(try db.tasks(search: "\" OR *").isEmpty)
}

@Test func proposalsNeedHumanSignoffAndFollowupsClaimOnce() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Prepare", state: .scheduled, returnAt: .distantPast))
    #expect(try db.claimDue().count == 1)
    #expect(try db.claimDue().isEmpty)
    let api = ToolService(store: db)
    _ = try api.call("facienda_propose_completion", arguments: .object(["taskId": .string(try db.taskHandle(task.id)), "evidence": .string("Draft ready")]))
    _ = try api.call("facienda_propose_completion", arguments: .object(["taskId": .string(try db.taskHandle(task.id)), "evidence": .string("Draft ready")]))
    #expect(try db.decisions().count == 1)
    #expect(try db.task(task.id).state == .needsMe)
    #expect(try db.events(taskId: task.id).filter { $0.source == .mcp }.allSatisfy { !$0.verified })
    try db.update(task.id) { $0.state = .done }
    #expect(try db.decisions().isEmpty)
    #expect(try db.claimDue().isEmpty)
}

@Test func verifiedStatusBeatsPollAndTurnEndDoesNotCompleteTask() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Work", state: .needsMe))
    try db.link(ThreadLink(taskId: task.id, codexThreadId: "thread"))
    try db.observe(threadId: "thread", status: "active", source: .hook, verified: true)
    try db.observe(threadId: "thread", status: "notLoaded", source: .app, verified: false)
    #expect(try db.links().first?.lastKnownStatus == "active")
    #expect(try db.task(task.id).state == .running)
    try db.observe(threadId: "thread", status: "idle", source: .appServer, verified: true)
    #expect(try db.task(task.id).state == .needsMe)
    try db.update(task.id) { $0.state = .done }
    try db.observe(threadId: "thread", status: "active", source: .hook, verified: true)
    #expect(try db.task(task.id).state == .done)
}

@Test func approvalPromptsKeepTaskRunningUntilLeftUnanswered() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Work", state: .needsMe))
    try db.link(ThreadLink(taskId: task.id, codexThreadId: "thread"))
    try db.observe(threadId: "thread", status: "active", source: .hook, verified: true)
    let seenAt = Date()
    try db.markSeen([task.id: seenAt])
    // Approved at the chat within seconds: the task stays running and does not come back as new.
    try db.observe(threadId: "thread", status: "waitingOnApproval", source: .hook, verified: true)
    #expect(try db.task(task.id).state == .running)
    try db.observe(threadId: "thread", status: "active", source: .hook, verified: true)
    #expect(try db.task(task.id).state == .running)
    #expect(try db.readMarks()[task.id]?.isNew != true)
    // Left unanswered, the prompt brings the task to the user.
    try db.observe(threadId: "thread", status: "waitingOnApproval", source: .hook, verified: true)
    try db.surfaceStaleApprovals(now: Date().addingTimeInterval(FaciendaStore.approvalGrace - 5))
    #expect(try db.task(task.id).state == .running)
    try db.surfaceStaleApprovals(now: Date().addingTimeInterval(FaciendaStore.approvalGrace + 5))
    #expect(try db.task(task.id).state == .needsMe)
    try db.observe(threadId: "thread", status: "active", source: .hook, verified: true)
    #expect(try db.task(task.id).state == .running)
}

/// A rollout file as Codex writes it: one JSON object per line, each turn's settings at its start.
private func rollout(_ reviewers: [String], trailing: Int = 0) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/rollout.jsonl")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var text = #"{"timestamp":"2026-10-13T06:08:42.553Z","type":"session_meta","payload":{"id":"chat"}}"# + "\n"
    for reviewer in reviewers {
        text += #"{"timestamp":"2026-10-13T06:08:43.579Z","type":"turn_context","payload":{"turn_id":"turn","approval_policy":"on-request","approvals_reviewer":"\#(reviewer)","model":"gpt"}}"# + "\n"
        text += #"{"timestamp":"2026-10-13T06:08:44.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Checking \"type\":\"turn_context\""}}"# + "\n"
    }
    // A busy turn's output after its settings, across several of the reader's chunks.
    let line = #"{"timestamp":"2026-10-13T06:09:00.000Z","type":"response_item","payload":{"type":"function_call_output","output":""# + String(repeating: "x", count: 4000) + "\"}}\n"
    text += String(repeating: line, count: trailing)
    try Data(text.utf8).write(to: url)
    return url
}

@Test func codexRolloutNamesTheLatestTurnsReviewer() throws {
    #expect(CodexRollout.approvalsReviewer(transcript: try rollout(["user", "auto_review"], trailing: 700)) == "auto_review")
    #expect(CodexRollout.approvalsReviewer(transcript: try rollout(["auto_review", "user"])) == "user")
    #expect(CodexRollout.approvalsReviewer(transcript: try rollout([], trailing: 3)) == nil)
    #expect(CodexRollout.approvalsReviewer(transcript: try rollout(["auto_review"], trailing: 700), window: 1 << 20) == nil)
    #expect(CodexRollout.approvalsReviewer(transcript: URL(fileURLWithPath: "/nonexistent/rollout.jsonl")) == nil)
}

@Test func codexRolloutIsFoundByTheChatsID() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
    // 01a133e0-a217… started at 06:08:42 UTC on 13 October 2026, 07:08:42 in London.
    let folder = home.appending(path: "sessions/2026/10/13"), id = "01a133e0-a217-72a1-87b1-ab443b1f534d"
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "rollout-2026-10-13T07-08-42-\(id).jsonl")
    try Data().write(to: file)
    #expect(CodexRollout.locate(threadId: id.uppercased(), home: home, calendar: calendar)?.lastPathComponent == file.lastPathComponent)
    #expect(CodexRollout.locate(threadId: "01a133e0-a217-72a1-87b1-ab443b1f5340", home: home, calendar: calendar) == nil)
    #expect(CodexRollout.locate(threadId: "chat", home: home, calendar: calendar) == nil)
}

@Test func autoReviewedPermissionRequestsKeepTheTaskRunning() throws {
    let db = try store(), task = try db.create(FaciendaTask(title: "Work", state: .needsMe))
    try db.link(ThreadLink(taskId: task.id, codexThreadId: "thread"))
    let send = { (name: String, transcript: URL) in
        let json = #"{"session_id":"thread","hook_event_name":"\#(name)","turn_id":"turn","transcript_path":"\#(transcript.path)"}"#
        _ = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)).apply(to: db)
    }
    let reviewed = try rollout(["auto_review"], trailing: 2), asked = try rollout(["user"])
    try send("UserPromptSubmit", reviewed)
    // Codex's own reviewer answers: the chat keeps working, even past the grace for prompts the user answers.
    try send("PermissionRequest", reviewed)
    #expect(try db.threadLink(threadId: "thread")?.lastKnownStatus == "active")
    #expect(try db.latestEvent(taskId: task.id, kind: "hook.AutoReview") != nil)
    try db.surfaceStaleApprovals(now: Date().addingTimeInterval(FaciendaStore.approvalGrace + 5))
    #expect(try db.task(task.id).state == .running)
    // A chat that asks the user still waits on their approval.
    try send("PermissionRequest", asked)
    #expect(try db.threadLink(threadId: "thread")?.lastKnownStatus == "waitingOnApproval")
}

@Test func memoryIsSharedWithinAMemoryAndRetainsProvenance() throws {
    let db = try workspaceStore(), task = try db.create(FaciendaTask(title: "Shared memory"))
    let fact = MemoryFact(text: "Blue", taskId: task.id, source: "User message 2026-10-04")
    try db.remember(fact)
    let otherThread = try FaciendaStore(url: db.url).scoped(to: try #require(db.workspaceID))
    #expect(try otherThread.memory().first?.id == fact.id)
    #expect(try otherThread.memory().first?.confirmedAt == nil)
    #expect(try workspaceStore().memory().isEmpty)
    // A whole-library store must say which memory it means.
    #expect(throws: StoreError.self) { try FaciendaStore(url: db.url).memory() }
    try db.correctMemory(fact.id, text: "Green")
    let current = try #require(otherThread.memory().first)
    #expect(current.text == "Green")
    #expect(current.taskId == task.id)
    #expect(current.source.contains(fact.source))
    #expect(current.confirmedAt != nil)
    #expect(current.spaceId == (try db.resolvedMemorySpace(nil).id))
    #expect(throws: StoreError.self) { try db.remember(MemoryFact(text: "No source", source: "")) }
}

@Test func existingMemoryCategoriesMigrateWithoutLosingFactsOrHistory() throws {
    let db = try workspaceStore(), task = try db.create(FaciendaTask(title: "Legacy task"))
    let fact = MemoryFact(text: "Old fact", taskId: task.id, source: "Original evidence")
    try db.remember(fact)
    try db.correctMemory(fact.id, text: "Corrected fact")
    let corrected = try #require(db.memory().first)
    // Restore the pre-migration column/marker in this isolated fixture.
    try db.db.write { database in
        try database.execute(sql: "UPDATE memoryFacts SET originScope = 'task'")
        try database.execute(sql: "ALTER TABLE memoryFacts RENAME COLUMN originScope TO scope")
        try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5_workspace_memory'")
    }
    let migrated = try FaciendaStore(url: db.url).scoped(to: try #require(db.workspaceID))
    let recalled = try #require(migrated.memory().first)
    #expect(recalled.id == corrected.id)
    #expect(recalled.originScope == "task")
    #expect(recalled.taskId == task.id)
    #expect(recalled.confirmedAt == corrected.confirmedAt)
    #expect(recalled.source == corrected.source)
    let original = try migrated.db.read { try MemoryFact.fetchOne($0, key: fact.id) }
    #expect(original?.supersededBy == corrected.id)
    #expect(original?.text == fact.text)
    try migrated.correctMemory(recalled.id, text: "Latest fact")
    #expect(try migrated.memory().count == 1)
}

@Test func memoryToolsReachOnlyTheTasksOwnMemory() throws {
    let db = try store(), other = try store(), api = ToolService(store: db)
    let personal = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work")
    let home = try db.scoped(to: personal.id).create(FaciendaTask(title: "Origin"))
    let job = try db.scoped(to: work.id).create(FaciendaTask(title: "Quarterly plan"))
    let args: JSONValue = .object(["text": .string("Use Sardinia"), "source": .string("User request 2026-10-04"), "taskId": .string(try db.taskHandle(home.id))])
    _ = try api.call("facienda_memory_remember", arguments: args)
    let reader = ToolService(store: try FaciendaStore(url: db.url))
    #expect(try reader.call("facienda_memory_recall", arguments: .object(["taskId": .string(try db.taskHandle(home.id)), "query": .string("Sardinia")])).array?.count == 1)
    // A task in another memory never sees it, and nothing is reachable without naming a task.
    #expect(try reader.call("facienda_memory_recall", arguments: .object(["taskId": .string(try db.taskHandle(job.id)), "query": .string("Sardinia")])).array?.isEmpty == true)
    #expect(throws: StoreError.self) { try api.call("facienda_memory_recall", arguments: .object(["query": .string("")])) }
    // A database path no longer selects a memory: only the task does.
    #expect(throws: StoreError.self) { try api.call("facienda_memory_recall", arguments: .object(["workspace": .string(other.url.path), "query": .string("")])) }
    #expect(throws: StoreError.self) { try ToolService(store: other).call("facienda_memory_remember", arguments: args) }
    #expect(try db.memory(spaceID: work.memorySpaceId).isEmpty)
    // Search stays within the workspaces sharing the task's memory.
    let found = try api.call("facienda_task_search", arguments: .object(["query": .string(""), "taskId": .string(try db.taskHandle(job.id))]))
    #expect(found.array?.compactMap { $0["id"].string } == [job.id])
    let created = try api.call("facienda_task_create", arguments: .object(["title": .string("Follow-up"), "nextAction": .string("Draft"), "fromTaskId": .string(try db.taskHandle(job.id))]))
    #expect(created["workspaceId"].string == work.id)
}

@Test func chatSearchReadsOnlyTheChatsOfTheTasksMemory() throws {
    let db = try store()
    let personal = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work")
    let home = try db.scoped(to: personal.id).create(FaciendaTask(title: "Trip"))
    let job = try db.scoped(to: work.id).create(FaciendaTask(title: "Hire"))
    try db.link(ThreadLink(taskId: home.id, codexThreadId: "trip", role: "work", linkedBy: "user"), source: .user)
    try db.link(ThreadLink(taskId: job.id, codexThreadId: "hire", role: "work", linkedBy: "user"), source: .user)
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaChatSearch/\(UUID().uuidString)/ChatIndex.sqlite")
    let api = ToolService(store: db, chatIndexURL: url)
    let search: (String) throws -> JSONValue = { try api.call("facienda_chat_search", arguments: .object(["query": .string("ferry"), "taskId": .string(try db.taskHandle($0))])) }
    // With chat search off there is no index, and the chat learns why.
    #expect(try search(home.id)["passages"].array?.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let index = try ChatIndex(url: url)
    try index.record([ChatListing(threadId: "trip", title: "Sardinia", cwd: "/", updatedAt: 1), ChatListing(threadId: "hire", title: "Hiring", cwd: "/", updatedAt: 1)])
    try index.replace(threadId: "trip", messages: [ChatText(messageId: "t:1", role: .user, at: nil, text: "Book the ferry to La Gomera")], updatedAt: 1)
    try index.replace(threadId: "hire", messages: [ChatText(messageId: "t:1", role: .codex, at: nil, text: "The ferry company is hiring too")], updatedAt: 1)
    let found = try search(home.id)["passages"].array ?? []
    #expect(found.map { $0["threadId"].string } == ["trip"])
    #expect(found.first?["speaker"].string == "user")
    #expect(try search(job.id)["passages"].array?.map { $0["threadId"].string } == ["hire"])
    #expect(throws: StoreError.self) { try api.call("facienda_chat_search", arguments: .object(["query": .string("ferry")])) }
}

@Test func memorySearchTreatsWildcardsAndBackslashesLiterally() throws {
    let db = try workspaceStore()
    try db.remember(MemoryFact(text: #"path\name_100%"#, source: "Test"))
    try db.remember(MemoryFact(text: "pathXnameY100Z", source: "Test"))
    #expect(try db.memory(search: #"\name_100%"#).count == 1)
}

@Test func malformedToolsCannotWriteOrGuessIdentity() throws {
    let db = try store(), api = ToolService(store: db)
    #expect(throws: StoreError.self) { try api.call("facienda_current_task", arguments: .object([:])) }
    #expect(throws: StoreError.self) { try api.call("facienda_task_create", arguments: .object(["title": .string("X"), "nextAction": .string("Y"), "returnAt": .string("tomorrow")])) }
    #expect(throws: StoreError.self) { try api.call("facienda_task_create", arguments: .object(["title": .string("X"), "nextAction": .string("Y"), "returnAt": .string("2030-01-01T12:00:00Z"), "state": .string("done")])) }
    #expect(try db.tasks().isEmpty)
}

@Test func waitingRequiresOwnerAndCheckDateAndThreadOwnershipIsUnique() throws {
    let db = try store(), a = try db.create(FaciendaTask(title: "A")), b = try db.create(FaciendaTask(title: "B"))
    #expect(throws: StoreError.self) { try db.update(a.id) { $0.state = .waiting } }
    try db.link(ThreadLink(taskId: a.id, codexThreadId: "one"))
    #expect(throws: StoreError.self) { try db.link(ThreadLink(taskId: b.id, codexThreadId: "one")) }
    #expect(try db.currentTask(threadId: "one")?.id == a.id)
}

@Test func concurrentProcessesShareDurableStateWithoutLostUpdates() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/shared.sqlite")
    let app = try FaciendaStore(url: url), mcp = try FaciendaStore(url: url)
    let task = try app.create(FaciendaTask(title: "Shared task"))
    try mcp.update(task.id, source: .mcp) { $0.brief = "Prepared by the agent" }
    #expect(try app.task(task.id).brief == "Prepared by the agent")
    #expect(throws: StoreError.self) { try app.update(task.id, expectedRevision: task.revision) { $0.brief = "Stale form" } }
    let persisted = try FaciendaStore(url: url)
    #expect(try persisted.task(task.id).brief == "Prepared by the agent")
    #expect(try persisted.events(taskId: task.id).count == 2)
}

@Test func lookingUpAnEarlierTaskIgnoresFillerAndRanksTheName() throws {
    let db = try store()
    var named = FaciendaTask(title: "currently there is a strict line limit", state: .done)
    named.displayTitle = "Omnibar line limit and group focus"
    let omnibar = try db.create(named)
    let mentions = try db.create(FaciendaTask(title: "Model chooser stays open", brief: "Shared by the composer, omnibar and plan board"))
    _ = try db.create(FaciendaTask(title: "Calibrate the LED"))
    let dropped = try db.create(FaciendaTask(title: "Old omnibar sketch", state: .dropped))
    let text = "we had a task on the omnibar, where was it?"
    #expect(TaskLookup.terms(text) == ["omnibar"])
    #expect(TaskLookup.looksBack(text))
    #expect(!TaskLookup.looksBack("omnibar"))
    #expect(!TaskLookup.looksBack("we had some lamp offers recently added to the storeroom order sheet"))
    let hits = try db.lookUpTasks(text)
    #expect(hits.map(\.task.id) == [omnibar.id, mentions.id])
    #expect(hits.allSatisfy { $0.complete })
    #expect(!hits.contains { $0.task.id == dropped.id })
    // Half the words are enough to be listed; only all of them make a complete match.
    let partial = try db.lookUpTasks("omnibar group sheet")
    #expect(partial.first?.task.id == omnibar.id)
    #expect(partial.first?.complete == false)
    #expect(try db.lookUpTasks("omnibar group").first?.complete == true)
    // A word found only in a chat's title still finds the task.
    try db.link(ThreadLink(taskId: mentions.id, codexThreadId: "thread1", title: "Popover timing"))
    #expect(try db.lookUpTasks("where was the popover chat").map(\.task.id) == [mentions.id])
    #expect(try db.lookUpTasks("?!").isEmpty)
    // Asking for it once more finds the task, not the earlier asking.
    let asked = try db.create(FaciendaTask(title: "we had a task on the omnibar where was it"))
    #expect(try db.lookUpTasks(text).map(\.task.id) == [omnibar.id, asked.id, mentions.id])
}

@Test func taskFinderReadsWhichEarlierTaskIsMeant() throws {
    var named = FaciendaTask(title: "currently there is a strict line limit", state: .done)
    named.displayTitle = "Omnibar line limit and group focus"
    let tasks = [named, FaciendaTask(title: "Calibrate the LED")]
    let prompt = TaskFinder.prompt(text: "where was the omnibar thing", tasks: tasks)
    #expect(prompt.contains("1. Omnibar line limit and group focus (asked: \"currently there is a strict line limit\") — done"))
    #expect(prompt.contains("2. Calibrate the LED — open"))
    let found = TaskFinder.read(#"{"intent":"earlier","pick":1,"sure":true,"message":" make it wider "}"#, tasks: tasks)
    #expect(found?.task?.id == named.id && found?.sure == true && found?.message == "make it wider")
    // A pick outside the list is no pick, and so not sure.
    let outside = TaskFinder.read(#"{"intent":"earlier","pick":7,"sure":true,"message":""}"#, tasks: tasks)
    #expect(outside?.task == nil && outside?.sure == false)
    // New work never carries a task or message along.
    let new = TaskFinder.read(#"{"intent":"new","pick":2,"sure":true,"message":"x"}"#, tasks: tasks)
    #expect(new?.intent == .new && new?.task == nil && new?.message == "")
    #expect(TaskFinder.read("not json", tasks: tasks) == nil)
    #expect(TaskLookup.asksForEarlier("we had some lamp offers recently added to the storeroom order sheet"))
}
