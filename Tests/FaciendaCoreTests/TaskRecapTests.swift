import Foundation
import Testing
@testable import FaciendaCore

private func user(_ id: String, _ text: String) -> JSONValue {
    .object(["type": .string("userMessage"), "id": .string(id), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
}
private func agent(_ id: String, _ text: String, commentary: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = ["type": .string("agentMessage"), "id": .string(id), "text": .string(text)]
    if commentary { fields["phase"] = .string("commentary") }
    return .object(fields)
}
private func turn(_ id: String, _ status: String = "completed", at minute: Double, _ items: [JSONValue]) -> CodexConversationTurn {
    let start = Date(timeIntervalSinceReferenceDate: minute * 60)
    return CodexConversationTurn(id: id, status: status, startedAt: start, completedAt: status == "completed" ? start.addingTimeInterval(30) : nil, error: .null, items: items)
}

@Test func recapSourceReadsTheUsersOwnWordsAndTheFinalAnswer() throws {
    let start = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "started", requestedAt: Date(), kind: "start")
    let reply = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "started", requestedAt: Date(), kind: "reply", message: "Make five\nvariants")
    let check = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "started", requestedAt: Date(), kind: "check")
    let conversation = CodexConversation(threadId: "chat", title: "Chat", turns: [
        // The session's opening and the runner's relay of the same start count once, as the request.
        turn("t1", at: 0, [user("u1", "Facienda dispatch: \(start.id)\nFacienda task: …"), user("u2", "Facienda dispatch: \(start.id)\nRun this command"), agent("a1", "Five ideas.")]),
        turn("t2", at: 10, [user("u3", "i like the group sheet"), agent("a2", "Working on it", commentary: true), agent("a3", "Here it is.")]),
        turn("t3", at: 20, [user("u4", "Facienda dispatch: \(check.id)\nScheduled"), agent("a4", "Nothing changed.")]),
        turn("t4", at: 30, [user("u5", "Facienda dispatch: \(reply.id)\nThe user replied"), agent("a5", "Five variants are ready. Which one?")])
    ])
    let source = try #require(RecapSource(conversation, originalRequest: "Show the group focus better", dispatches: [start, reply, check], after: nil))
    #expect(source.turnId == "t4")
    #expect(source.newMessages == ["Show the group focus better", "i like the group sheet", "Make five variants"])
    #expect(source.said == "Make five variants")
    #expect(source.saidAt == Date(timeIntervalSinceReferenceDate: 30 * 60))
    #expect(source.answer == "Five variants are ready. Which one?")
    #expect(source.answeredAt == Date(timeIntervalSinceReferenceDate: 30 * 60 + 30))
    // After an earlier recap only the messages since its turn are new.
    #expect(RecapSource(conversation, originalRequest: "Show the group focus better", dispatches: [start, reply, check], after: "t2")?.newMessages == ["Make five variants"])
    // A turn still running has nothing to recap yet.
    var running = conversation.turns; running.append(turn("t5", "inProgress", at: 40, [user("u6", "and another")]))
    #expect(RecapSource(CodexConversation(threadId: "chat", title: "Chat", turns: running), originalRequest: "x", dispatches: [], after: nil) == nil)

    // The opened task reads the chat's last exchanges in full, line breaks and all. The request counts once, and a
    // scheduled check is not the user speaking.
    let tail = ChatTail(conversation, originalRequest: "Show the group focus better", dispatches: [start, reply, check])
    #expect(tail.exchanges.map(\.said) == ["Show the group focus better", "i like the group sheet", nil, "Make five\nvariants"])
    #expect(tail.exchanges.last?.answer == "Five variants are ready. Which one?" && tail.earlier == 0)
    // What the agent found on a check stands apart, and the answer to the words before it stays theirs.
    #expect(tail.exchanges[1].answer == "Here it is." && tail.exchanges[2] == .init(id: 2, answer: "Nothing changed.", note: "Scheduled check"))
    // Only the last few are kept, and it says how many came before.
    let short = ChatTail(conversation, originalRequest: "Show the group focus better", dispatches: [start, reply, check], limit: 2)
    #expect(short.exchanges.map(\.id) == [2, 3] && short.earlier == 2)
    // Words just sent show at once, without the answer to the words before them.
    let sent = ChatTail(CodexConversation(threadId: "chat", title: "Chat", turns: running), originalRequest: "x", dispatches: [start, reply, check])
    #expect(sent.exchanges.last?.said == "and another" && sent.exchanges.last?.answer == nil)
}

@Test func recapPathOnlyGrowsAndShowsTheStepTheTipDoesNotSay() throws {
    let source = RecapSource(CodexConversation(threadId: "chat", title: "Chat", turns: [turn("t1", at: 0, [user("u1", "why do we need hindsight running?"), agent("a1", "We don't.")])]),
                             originalRequest: "todo list for testers", dispatches: [], after: nil)!
    let previous = TaskRecap(taskId: "task", turnId: "t0", steps: ["name and license", "built-in memory"], tip: "build memory tailoring", said: nil, saidAt: nil, answer: "Built.", ask: nil, answeredAt: nil)
    let reply = #"{"turn":"Hindsight","tip":"decide whether **Hindsight** can go.","answer":"Not needed, only a fallback: 213 MB RAM and 2 GB disk while idle.","ask":"Stop it now?"}"#
    let recap = try RecapWriter.read(reply, taskId: "task", taskName: "Prepare Facienda for first testers and…", source: source, previous: previous)
    #expect(recap.steps == ["name and license", "built-in memory", "Hindsight"])
    #expect(recap.tip == "decide whether Hindsight can go")
    #expect(recap.said == "why do we need hindsight running?")
    #expect(recap.ask == "Stop it now?")
    #expect(recap.turnId == "t1")
    // The tip already names Hindsight, so the step before it is shown.
    #expect(recap.shownStep == "built-in memory")
    // A turn that only rephrases the name or an earlier step adds nothing.
    for repeated in ["first testers", "native memory"] {
        #expect(try RecapWriter.read(#"{"turn":"\#(repeated)","tip":"stop it","answer":"Done.","ask":null}"#, taskId: "task", taskName: "Prepare Facienda for first testers and…", source: source, previous: previous).steps == previous.steps)
    }
    #expect(try RecapWriter.read(#"{"turn":null,"tip":"choose a design","answer":"Five variants.","ask":null}"#, taskId: "task", taskName: "Group focus", source: source, previous: nil).shownStep == nil)
    #expect(throws: StoreError.self) { try RecapWriter.read(#"{"turn":null,"tip":"","answer":"x","ask":null}"#, taskId: "task", taskName: "Group focus", source: source, previous: nil) }
    let prompt = RecapWriter.prompt(taskName: "Prepare for testers", request: "todo list", steps: previous.steps, source: source, language: "English")
    #expect(prompt.contains("1. name and license\n2. built-in memory"))
    #expect(prompt.contains("- why do we need hindsight running?"))
}

@Test func recapIsSavedOnlyOnTopOfTheOneItFollows() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "recap-\(UUID().uuidString)/tasks.sqlite")
    let store = try FaciendaStore(url: url)
    let task = try store.create(FaciendaTask(title: "Prepare for testers", state: .needsMe))
    let when = Date(timeIntervalSinceReferenceDate: 813_000_000)
    let first = TaskRecap(taskId: task.id, turnId: "t1", steps: ["name and license"], tip: "pick a name", said: "names?", saidAt: when, answer: "Three names.", ask: "Which one?", answeredAt: when, at: when)
    try store.saveRecap(first, after: nil)
    #expect(try store.recaps() == [first])
    var second = first; second.turnId = "t2"; second.steps.append("built-in memory")
    // A write from an older recap would drop a step, so it is refused.
    #expect(throws: StoreError.self) { try store.saveRecap(second, after: nil) }
    try store.saveRecap(second, after: "t1")
    #expect(try store.recaps().first?.steps == ["name and license", "built-in memory"])
    try store.deleteTask(task.id)
    #expect(try store.recaps().isEmpty)
}

@Test func onlyTheUsersOwnWordsAreShownAsTheirs() {
    let summary = "This session is being continued from a previous conversation that ran out of context.\n<system-reminder>\n<tools-used-before-summary>Bash</tools-used-before-summary>\n</system-reminder>\nSummary:\n1. Paint the shed"
    let page = "<in-app-browser-context source=\"ambient-ui-state\">\n# In app browser:\n- Current URL: https://example.org/paint\n</in-app-browser-context>\n\n## My request:\nis the green one in stock?&#x20;\nand the brush"
    let files = "# Files mentioned by the user:\n\n## shed.pdf: /Users/ada/Documents/shed.pdf\n\n## My request:\nuse this plan"
    let choice = "<send_user_message_question_reply>\n[{\"questionItemId\":\"q1\",\"question\":\"Order the paint?\",\"answer\":\"Order two tins\"}]\n</send_user_message_question_reply>"
    let conversation = CodexConversation(threadId: "chat", title: "Chat", turns: [
        turn("t1", at: 0, [user("u1", "paint the shed"), agent("a1", "Which colour?")]),
        // A summary, a slash command and its output are the agent app's, and the work they interrupt goes on.
        turn("t2", at: 10, [user("u2", summary), agent("a2", "Green it is.")]),
        turn("t3", at: 20, [user("u3", "<command-name>/model</command-name>\n<command-message>model</command-message>")]),
        turn("t4", at: 21, [user("u4", "<local-command-stdout>Set model</local-command-stdout>")]),
        // A reminder ahead of the user's words is taken off, and so is what Codex's composer puts around them.
        turn("t5", at: 30, [user("u5", "<system-reminder>\nThis chat moved to the desktop app.\n</system-reminder>\n\n\nA, build it"), agent("a5", "Built.")]),
        turn("t6", at: 40, [user("u6", page), agent("a6", "Yes.")]),
        turn("t7", at: 50, [user("u7", files), agent("a7", "Read it.")]),
        turn("t8", at: 60, [user("u8", choice), agent("a8", "Ordered.")]),
        // An automation waking the chat is not the user speaking.
        turn("t9", at: 70, [user("u9", "<heartbeat>\n  <automation_id>paint-watch</automation_id>\n</heartbeat>"), agent("a9", "Still drying.\n\n<heartbeat>\n  <decision>NOTIFY</decision>\n  <message>Still drying.</message>\n</heartbeat>")])
    ])
    #expect(CodexConversationTurn.withoutHeartbeat("<heartbeat>\n<decision>NOTIFY</decision>\n<message>Dry now.</message>\n</heartbeat>") == "Dry now.")
    let tail = ChatTail(conversation, originalRequest: "paint the shed", dispatches: [], limit: 10)
    #expect(tail.exchanges.map(\.said) == ["paint the shed", "A, build it", "is the green one in stock? \nand the brush", "use this plan", "Order two tins", nil])
    #expect(tail.exchanges.map(\.answer) == ["Green it is.", "Built.", "Yes.", "Read it.", "Ordered.", "Still drying."])
    #expect(tail.exchanges.last?.note == "Automation run")
    #expect(RecapSource(conversation, originalRequest: "paint the shed", dispatches: [], after: nil)?.newMessages.contains(where: { $0.contains("<") || $0.contains("Summary") }) == false)
}

@Test func chatEndIsTheUsersLastWordsAndTheAnswerToThemKeptBesideTheChat() throws {
    let start = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "started", requestedAt: Date(), kind: "start")
    let reply = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "started", requestedAt: Date(), kind: "reply", message: "Make five\nvariants")
    let check = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "started", requestedAt: Date(), kind: "check")
    let turns = [
        turn("t1", at: 0, [user("u1", "Facienda dispatch: \(start.id)\nFacienda task: …"), user("u2", "Facienda dispatch: \(start.id)\nRun this command"), agent("a1", "Five **ideas**.")]),
        turn("t2", at: 10, [user("u3", "Facienda dispatch: \(reply.id)\nThe user replied"), agent("a2", "Working on it", commentary: true), agent("a3", "Five variants are ready.\n\n- Which one?")]),
        turn("t3", at: 20, [user("u4", "Facienda dispatch: \(check.id)\nScheduled"), agent("a4", "Nothing changed.")])
    ]
    let end = ChatEnd(CodexConversation(threadId: "chat", title: "Chat", turns: turns), originalRequest: "Show the group focus better", dispatches: [start, reply, check])
    // The user's own words, on one line; a check is not the user, and what it found is the agent's last answer.
    #expect(end.said == "Make five variants" && end.saidAt == Date(timeIntervalSinceReferenceDate: 10 * 60))
    #expect(end.answer == "Nothing changed." && end.answeredAt == Date(timeIntervalSinceReferenceDate: 20 * 60 + 30))
    // A new task's opening, still running: the request, with no answer yet.
    let first = ChatEnd(CodexConversation(threadId: "chat", title: "Chat", turns: [turn("t1", "inProgress", at: 0, [user("u1", "Facienda dispatch: \(start.id)\nFacienda task: …")])]),
                        originalRequest: "Show the group focus better", dispatches: [start])
    #expect(first == ChatEnd(said: "Show the group focus better", saidAt: Date(timeIntervalSinceReferenceDate: 0)))
    // Words sent while the answer before them stands take its place, unanswered.
    let more = ChatEnd(CodexConversation(threadId: "chat", title: "Chat", turns: Array(turns.prefix(2)) + [turn("t3", "inProgress", at: 30, [user("u5", "and another")])]),
                       originalRequest: "x", dispatches: [start, reply])
    #expect(more.said == "and another" && more.answer == nil)
    #expect(ChatEnd(CodexConversation(threadId: "chat", title: "Chat", turns: Array(turns.prefix(2))), originalRequest: "x", dispatches: [start, reply]).answer == "Five variants are ready. Which one?")

    // Kept beside the saved chat, read with the task's own request and deliveries.
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "chat-end-\(UUID().uuidString)/tasks.sqlite"))
    let task = try store.create(FaciendaTask(title: "Show the group focus better", state: .running))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "chat"))
    let opening = turn("t1", "inProgress", at: 0, [user("u1", "Facienda dispatch: \(UUID().uuidString)\nFacienda task: …"), user("u2", "Paint it blue")])
    try store.saveConversation(taskId: task.id, conversation: CodexConversation(threadId: "chat", title: "Chat", turns: [opening]))
    #expect(try store.chatEnds()[task.id]?.said == "Paint it blue")
    // Chats saved before ends were kept are read afterwards, once.
    try store.db.write { db in try db.execute(sql: "UPDATE threadSnapshots SET chatEnd = NULL") }
    #expect(try store.chatEnds().isEmpty)
    #expect(try store.readMissingChatEnds() == 1)
    #expect(try store.chatEnds()[task.id]?.said == "Paint it blue")
    #expect(try store.readMissingChatEnds() == 0)
}
