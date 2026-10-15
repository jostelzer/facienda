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
