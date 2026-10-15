import Foundation
import Testing
@testable import FaciendaCore

private func conversation(_ thread: String = "owner", text: String = "Exact answer") -> CodexConversation {
    CodexConversation(threadId: thread, title: "Chat title", turns: [
        CodexConversationTurn(id: "turn", status: "completed", startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2), error: .null,
            items: [.object(["type": .string("agentMessage"), "id": .string("answer"), "text": .string(text)])])
    ])
}

@Test func conversationCacheSurvivesReopenAndPreservesTaskMetadataAndReports() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "conversation-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Original request", state: .waiting, returnAt: Date(timeIntervalSince1970: 300)))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    try store.saveResult(taskId: task.id, text: "Imported summary")
    let before = try store.task(task.id)
    let transcript = conversation()
    try store.saveConversation(taskId: task.id, conversation: transcript, fetchedAt: Date(timeIntervalSince1970: 100))
    try store.saveConversation(taskId: task.id, conversation: conversation(text: "New answer"), fetchedAt: Date(timeIntervalSince1970: 200))
    try store.saveConversation(taskId: task.id, conversation: transcript, fetchedAt: Date(timeIntervalSince1970: 150))
    let reopened = try FaciendaStore(url: store.url)
    #expect(try reopened.conversationSnapshot(taskId: task.id, threadId: "owner")?.conversation == conversation(text: "New answer"))
    #expect(try reopened.conversationSnapshot(taskId: task.id, threadId: "owner")?.fetchedAt == Date(timeIntervalSince1970: 200))
    #expect(try reopened.latestEvent(taskId: task.id, kind: "codex.result")?.payload == "Imported summary")
    #expect(try reopened.task(task.id) == before)
    #expect(try reopened.events(taskId: task.id).count == 3)
    #expect(try reopened.conversationSnapshot(taskId: "another", threadId: "owner") == nil)
    #expect(throws: StoreError.self) { try reopened.saveConversation(taskId: task.id, conversation: conversation("unlinked")) }
    try reopened.unlink(try #require(try reopened.links(taskId: task.id).first))
    #expect(try reopened.conversationSnapshot(taskId: task.id, threadId: "owner") == nil)
}

@Test func directImportPreservesRequestAndConversationWithoutCreatingWorkOrDeadlines() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString)/tasks.sqlite"))
    let original = "What documents do I need?\nPlease prepare a checklist."
    let task = try store.importThread(originalRequest: original, title: "Birth registration", cwd: "/tmp/project", conversation: conversation())
    #expect(task.title == original && task.displayName == "Birth registration")
    #expect(task.definitionOfDone.isEmpty && task.returnAt == nil && task.checkAt == nil)
    #expect(task.automationScope == .prepareOnly && task.state == .needsMe)
    #expect(task.ruleViolations.isEmpty)
    #expect(try store.conversationSnapshot(taskId: task.id, threadId: "owner")?.conversation == conversation())
    #expect(try store.dispatches().isEmpty && store.checkPlans().isEmpty)
    #expect(try store.importThread(originalRequest: "Different", title: "Different", cwd: "", conversation: conversation()).id == task.id)
    #expect(try store.tasks().count == 1)
    try store.update(task.id) { $0.nextAction = "Answer the questions" }
    #expect(try store.task(task.id).returnAt == nil)
    #expect(throws: StoreError.self) { try store.update(task.id) { $0.state = .scheduled } }
    let created = try ToolService(store: store).call("facienda_task_create", arguments: .object(["title": .string("Prepare only"), "nextAction": .string("Review")]))
    #expect(created["returnAt"] == .null)
}

@Test func readingMessagesIncludeBothSpeakersInOrderAndPreserveAttachments() {
    let attachment: JSONValue = .object(["type": .string("localImage"), "path": .string("/tmp/reference.png")])
    let turn = CodexConversationTurn(id: "turn", status: "completed", startedAt: nil, completedAt: nil, error: .null, items: [
        .object(["id": .string("user"), "type": .string("userMessage"), "content": .array([
            .object(["type": .string("text"), "text": .string("Keep **my words**\nexactly.")]), attachment])]),
        .object(["id": .string("progress"), "type": .string("agentMessage"), "phase": .string("commentary"), "text": .string("Checking the reference.")]),
        .object(["type": .string("commandExecution"), "aggregatedOutput": .string("Private command output")]),
        .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("## Result\n\nReady.")]),
        .object(["type": .string("userMessage"), "content": .array([attachment])]),
        .object(["type": .string("agentMessage"), "text": .string(" \n ")])
    ])
    let messages = turn.messages(originalRequest: "Unused", dispatches: [])
    #expect(messages.map(\.role) == [.user, .codex, .codex, .user])
    #expect(messages.map(\.text) == ["Keep **my words**\nexactly.", "Checking the reference.", "## Result\n\nReady.", ""])
    #expect(messages[0].attachments == [attachment] && messages[3].attachments == [attachment])
    #expect(messages[1].isCommentary && !messages[2].isCommentary)
    #expect(Set(messages.map(\.id)).count == messages.count)
}

@Test func readingMessagesUnwrapPersistedDeliveriesWithoutLeakingRunnerContext() {
    let dispatchId = UUID().uuidString
    let envelope = "Facienda dispatch: \(dispatchId)\nGenerated instructions and retrieved memory"
    let turn = CodexConversationTurn(id: "turn", status: "completed", startedAt: nil, completedAt: nil, error: .null, items: [
        .object(["type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string(envelope)])])])
    ])
    var dispatch = NativeDispatch(id: dispatchId, taskId: "task", state: "started", requestedAt: Date(), kind: "start")
    #expect(turn.messages(originalRequest: "Original\nrequest", dispatches: [dispatch]).first?.text == "Original\nrequest")
    dispatch.kind = "reply"; dispatch.message = "My exact\nfollow-up"
    let reply = turn.messages(originalRequest: "Original", dispatches: [dispatch])
    #expect(reply.first?.role == .user && reply.first?.text == dispatch.message)
    dispatch.kind = "check"; dispatch.message = nil
    let check = turn.messages(originalRequest: "Original", dispatches: [dispatch])
    #expect(check.first?.role == .automation && check.first?.text == "Scheduled check")
    let imported = turn.messages(originalRequest: "Original", dispatches: [])
    #expect(imported.first?.role == .automation && imported.first?.text == envelope)
    #expect(turn.items[0]["content"].array?.first?["text"].string == envelope)
}

@Test func readingMessagesKeepUnansweredTurnsAndRepeatedUserText() {
    let item: JSONValue = .object(["type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string("Try again")])])])
    let conversation = CodexConversation(threadId: "owner", title: "Title", turns: [
        CodexConversationTurn(id: "first", status: "completed", startedAt: nil, completedAt: nil, error: .null, items: [item]),
        CodexConversationTurn(id: "second", status: "inProgress", startedAt: nil, completedAt: nil, error: .null, items: [item])
    ])
    let messages = conversation.turns.flatMap { $0.messages(originalRequest: "Original", dispatches: []) }
    #expect(messages.map(\.text) == ["Try again", "Try again"])
    #expect(messages.map(\.id) == ["first:0", "second:0"])
}

@Test func readingMessagesIncludeNativeDelegationsAndDoNotTreatToolLogsAsRequests() {
    let dispatchId = UUID().uuidString
    let envelope = "Facienda dispatch: \(dispatchId)\nDelivery instructions"
    let makeItem: (String, String, String) -> JSONValue = { name, namespace, input in
        .object(["id": .string("delivery"), "type": .string("functionCallOutput"), "name": .string(name),
            "namespace": .string(namespace), "output": .string("<codex_delegation>\n<source_thread_id>runner</source_thread_id>\n<input>\(input)</input>\n</codex_delegation>")])
    }
    let turn = CodexConversationTurn(id: "turn", status: "completed", startedAt: nil, completedAt: nil, error: .null,
        items: [makeItem("send_message_to_thread", "codex_app", envelope)])
    let dispatch = NativeDispatch(id: dispatchId, taskId: "task", state: "started", requestedAt: Date(), kind: "reply", message: "Exact follow-up\nwith & links")
    let messages = turn.messages(originalRequest: "Original", dispatches: [dispatch])
    #expect(messages.count == 1 && messages[0].role == .user && messages[0].text == dispatch.message)
    let legacy = CodexConversationTurn(id: "initial", status: "completed", startedAt: nil, completedAt: nil, error: .null,
        items: [makeItem("create_thread", "codex_app", "Dispatcher prompt & unescaped URLs"),
            makeItem("other_tool", "codex_app", "Not a request"), makeItem("create_thread", "other", "Not a request")])
    let first = legacy.messages(originalRequest: "Saved original request", dispatches: [])
    #expect(first.map(\.role) == [.user, .automation])
    #expect(first.map(\.text) == ["Saved original request", "Dispatcher prompt & unescaped URLs"])
}

@Test func nativeFileCitationsKeepTheirDestinationAndSurroundingAnswer() {
    let text = "**Answer.** :codex-file-citation{path=\"/tmp/Shared_JC/Child_SNS.pdf\" purpose=\"source\"} Next paragraph."
    let rendered = CodexMarkdown.render(text)
    #expect(rendered == "**Answer.** [Child\\_SNS.pdf](<file:///tmp/Shared_JC/Child_SNS.pdf>) Next paragraph.")
    #expect(text.contains(":codex-file-citation"))
    let ordinary = "[Existing link](https://example.org)\n\n`unchanged code`"
    #expect(CodexMarkdown.render(ordinary) == ordinary)
    let unsupported = ":codex-file-citation{path=\"relative.pdf\" purpose=\"source\"}"
    #expect(CodexMarkdown.render(unsupported) == unsupported)
}

@Test func finishedTurnInAnotherCodexAppSettlesRunningTask() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "settle-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Explore controls", state: .running))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    try store.observe(threadId: "owner", status: "notLoaded", source: .app, verified: false)
    #expect(try store.task(task.id).state == .running)
    func turn(_ status: String) -> CodexConversationTurn {
        CodexConversationTurn(id: status, status: status, startedAt: nil, completedAt: nil, error: .null, items: [])
    }
    #expect(CodexConversation(threadId: "owner", title: "", turns: [turn("completed"), turn("interrupted")]).settledStatus == nil)
    #expect(CodexConversation(threadId: "owner", title: "", turns: [turn("inProgress")]).settledStatus == nil)
    #expect(CodexConversation(threadId: "owner", title: "", turns: [turn("failed")]).settledStatus == "error")
    let finished = CodexConversation(threadId: "owner", title: "", turns: [turn("interrupted"), turn("completed")])
    try store.observe(threadId: "owner", status: try #require(finished.settledStatus), source: .app, verified: true)
    let settled = try store.task(task.id)
    #expect(settled.state == .needsMe && settled.nextAction == "Review the latest Codex result")
}

@Test func turnStartedInAnotherCodexAppRunsTaskUntilItFinishes() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "follow-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Check lamp status", state: .needsMe))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    func chat(_ status: String, startedAt: Date) -> CodexConversation {
        CodexConversation(threadId: "owner", title: "", turns: [CodexConversationTurn(id: "turn", status: status, startedAt: startedAt, completedAt: nil, error: .null, items: [])])
    }
    let reported = try store.task(task.id)
    // A turn the agent already reported on, still writing its last lines, is not new work.
    #expect(chat("interrupted", startedAt: reported.updatedAt.addingTimeInterval(-5)).observedStatus(for: reported) == nil)
    #expect(chat("completed", startedAt: reported.updatedAt.addingTimeInterval(5)).observedStatus(for: reported) == nil)
    let fresh = chat("interrupted", startedAt: reported.updatedAt.addingTimeInterval(5))
    try store.observe(threadId: "owner", status: try #require(fresh.observedStatus(for: reported)), source: .app, verified: true)
    let running = try store.task(task.id)
    #expect(running.state == .running)
    #expect(fresh.observedStatus(for: running) == nil)
    let done = chat("completed", startedAt: reported.updatedAt.addingTimeInterval(5))
    try store.observe(threadId: "owner", status: try #require(done.observedStatus(for: running)), source: .app, verified: true)
    #expect(try store.task(task.id).state == .needsMe)
}

@Test func runningTurnOutranksAnOpenCompletionProposal() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "proposal-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Find Pixelo's last status", state: .running))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "owner"))
    try store.requestDecision(Decision(taskId: task.id, question: "Ready to mark this task done?", recommendation: "Mark done", options: ["Mark done"], kind: "completion"))
    #expect(try store.task(task.id).state == .needsMe)
    try store.observe(threadId: "owner", status: "active", source: .app, verified: true)
    #expect(try store.task(task.id).state == .running)
    try store.observe(threadId: "owner", status: "idle", source: .app, verified: true)
    #expect(try store.task(task.id).state == .needsMe)
}

// MARK: Agent-written text: links, pictures and approval requests

@Test func agentLinksOpenOnlyTheWebMailAndFaciendasOwnChatLinks() throws {
    func action(_ text: String) -> CodexMarkdown.LinkAction { CodexMarkdown.action(for: URL(string: text)!) }
    #expect(action("https://example.org/a?b=1") == .web(URL(string: "https://example.org/a?b=1")!))
    #expect(action("HTTP://example.org") == .web(URL(string: "HTTP://example.org")!))
    #expect(action("mailto:someone@example.org") == .mail(URL(string: "mailto:someone@example.org")!))
    #expect(action("https://good.example@evil.example/") == .ignore)
    #expect(action("https:///nohost") == .ignore)
    // Files are only shown in Finder, however they are written.
    #expect(action("file:///Applications/Calculator.app") == .reveal("/Applications/Calculator.app"))
    #expect(action("/tmp/run.command") == .reveal("/tmp/run.command"))
    #expect(action("/tmp/a/../b.txt") == .reveal("/tmp/b.txt"))
    #expect(action("file://evil.example/share/x") == .ignore)
    #expect(action("relative/notes.md") == .ignore)
    // Chat links open by their ID only, in the forms Facienda writes.
    #expect(action("codex://threads/019a-b_c") == .codexThread("019a-b_c"))
    #expect(action("codex://threads/x?open=/tmp") == .ignore)
    #expect(action("codex://settings") == .ignore)
    let session = "local_" + UUID().uuidString.lowercased()
    #expect(action("claude://code/continue?session=\(session)") == .claudeSession(session))
    #expect(action("claude://code/run?session=\(session)") == .ignore)
    for other in ["x-apple.systempreferences:com.apple.preference.security", "javascript:alert(1)", "ssh://host", "vnc://host", "smb://host/share", "tel:123"] {
        #expect(action(other) == .ignore)
    }
    // Rendered citations become file links, which only reveal.
    let cited = CodexMarkdown.render(":codex-file-citation{path=\"/tmp/x.pdf\"}")
    #expect(cited == "[x.pdf](<file:///tmp/x.pdf>)")
}

@Test func webLinksWhoseTextHidesTheirAddressAskFirst() {
    let url = URL(string: "https://evil.example/p?k=SECRET")!
    #expect(CodexMarkdown.linkNeedsConfirmation(url, in: "[Your invoice](https://evil.example/p?k=SECRET)"))
    #expect(CodexMarkdown.linkNeedsConfirmation(url, in: "[evil.example](https://evil.example/p?k=SECRET) and [docs](https://evil.example/p?k=SECRET)"))
    #expect(CodexMarkdown.linkNeedsConfirmation(url, in: "[Invoice][1]\n\n[1]: https://evil.example/p?k=SECRET"))
    #expect(CodexMarkdown.linkNeedsConfirmation(url, in: "Nothing here names it."))
    #expect(!CodexMarkdown.linkNeedsConfirmation(url, in: "See https://evil.example/p?k=SECRET."))
    #expect(!CodexMarkdown.linkNeedsConfirmation(url, in: "[https://evil.example/p?k=SECRET](https://evil.example/p?k=SECRET)"))
    #expect(!CodexMarkdown.linkNeedsConfirmation(URL(string: "https://example.org")!, in: "[example.org](https://example.org)"))
}

@Test func picturesLoadOnlyFromFilesInsideTheDataFolder() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pictures-\(UUID().uuidString)").standardizedFileURL
    let data = root.appending(path: "data"), outside = root.appending(path: "outside")
    try FileManager.default.createDirectory(at: data.appending(path: "task/Attachments"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let picture = data.appending(path: "task/Attachments/shot.png"), secret = outside.appending(path: "secret.png")
    try Data("png".utf8).write(to: picture); try Data("png".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(at: data.appending(path: "task/link.png"), withDestinationURL: secret)
    try FileManager.default.createDirectory(at: data.appending(path: "task/Fake.app"), withIntermediateDirectories: true)
    #expect(CodexMarkdown.localImage(picture, within: [data]) != nil)
    #expect(CodexMarkdown.localImage(URL(string: picture.path)!, within: [data]) != nil)
    #expect(CodexMarkdown.localImage(picture, within: []) == nil)
    #expect(CodexMarkdown.localImage(secret, within: [data]) == nil)
    #expect(CodexMarkdown.localImage(data.appending(path: "task/link.png"), within: [data]) == nil)
    #expect(CodexMarkdown.localImage(data.appending(path: "task/Fake.app"), within: [data]) == nil)
    #expect(CodexMarkdown.localImage(data.appending(path: "task/../../outside/secret.png"), within: [data]) == nil)
    #expect(CodexMarkdown.localImage(URL(string: "https://evil.example/p.png?k=SECRET")!, within: [data]) == nil)
    #expect(CodexMarkdown.localImage(URL(string: "data:image/png;base64,AAAA")!, within: [data]) == nil)
}

private func approval(_ method: String, _ extra: [String: JSONValue]) -> CodexApproval {
    var params: [String: JSONValue] = ["threadId": .string("t"), "turnId": .string("u"), "itemId": .string("i")]
    params.merge(extra) { $1 }
    return CodexApproval(id: "a", taskId: nil, threadId: "t", turnId: "u", itemId: "i", method: method, params: JSONValue.object(params).json, requestId: "1", requestedAt: Date())
}

@Test func approvalCardsShowExactlyWhatAllowWouldPermit() {
    // A command shows in full with its folder; the agent's reason is shown beside them, never in their place.
    let line = approval("item/commandExecution/requestApproval", ["command": .string("rm -rf build"), "cwd": .string("/tmp/app"), "reason": .string("Clean up")]).display
    #expect(line.command == "rm -rf build" && line.cwd == "/tmp/app" && line.reason == "Clean up" && line.canAllow)
    let argv = approval("execCommandApproval", ["command": .array([.string("/bin/sh"), .string("-c"), .string("echo 'hi' > x")]), "cwd": .string("/tmp")]).display
    #expect(argv.command == #"/bin/sh -c 'echo '\''hi'\'' > x'"#)
    let unknown = approval("item/commandExecution/requestApproval", ["command": .object(["x": .number(1)]), "cwd": .string("/tmp"), "reason": .string("Harmless")]).display
    #expect(unknown.command == nil && !unknown.canAllow)
    #expect(!approval("item/commandExecution/requestApproval", ["command": .string("ls")]).display.canAllow)

    // File changes list their files; without a list there is nothing to allow.
    let bare = approval("item/fileChange/requestApproval", ["grantRoot": .string("/Users/me")]).display
    #expect(bare.files.isEmpty && !bare.canAllow && bare.grantRoot == "/Users/me")
    let listed = approval("item/fileChange/requestApproval", ["changes": .array([
        .object(["path": .string("/tmp/a.swift"), "kind": .object(["type": .string("update")]), "diff": .string("-a\n+b")]),
        .object(["path": .string("/tmp/b.swift"), "kind": .object(["type": .string("add")])])])]).display
    #expect(listed.files == [.init(path: "/tmp/a.swift", change: "update", diff: "-a\n+b"), .init(path: "/tmp/b.swift", change: "add", diff: nil)] && listed.canAllow)
    let legacy = approval("applyPatchApproval", ["fileChanges": .object(["/tmp/c": .object(["type": .string("delete"), "content": .string("old")])])]).display
    #expect(legacy.files == [.init(path: "/tmp/c", change: "delete", diff: "old")])

    // Permissions show exactly what Allow echoes back.
    let access = approval("item/permissions/requestApproval", ["permissions": .object([
        "network": .object(["enabled": .bool(true)]), "fileSystem": .object(["write": .array([.string("/a"), .string("/b")])])])]).display
    #expect(access.permissions == ["fileSystem · write: /a, /b", "network · enabled: yes"] && access.canAllow)
    #expect(!approval("item/permissions/requestApproval", [:]).display.canAllow)
}

@Test func hiddenCharactersAreSpelledOut() {
    #expect(CodexApproval.visible("rm\u{202E}fdp.exe") == "rm⟨U+202E⟩fdp.exe")
    #expect(CodexApproval.visible("a\u{200B}b\u{FEFF}c\u{2066}d\u{0007}e") == "a⟨U+200B⟩b⟨U+FEFF⟩c⟨U+2066⟩d⟨U+0007⟩e")
    #expect(CodexApproval.visible("line one\n\tindented — ünïcode") == "line one\n\tindented — ünïcode")
    let shown = approval("item/commandExecution/requestApproval", ["command": .string("echo \u{202E}hi"), "cwd": .string("/tmp")]).display
    #expect(shown.command == "echo ⟨U+202E⟩hi")
}

@Test func nextStepsNeverOfferPurchasesOrMessagesAsOneClick() {
    let prompt = NextStepWriter.developerInstructions
    #expect(!prompt.contains("Order the oak desk"))
    for word in ["buying", "paying", "sending", "cannot be undone"] { #expect(prompt.contains(word)) }
}
