import Foundation
import Testing
@testable import FaciendaCore

private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
/// Saturday 17 October 2026, 22:00 in Lisbon.
private let now = ISO8601DateFormatter().date(from: "2026-10-17T21:00:00Z")!

/// One board for every test, so its tasks keep their IDs between the reading and the checks.
private let fixture = makeBoard()
private func board() -> (candidates: [BarReader.Candidate], notes: [MemoryFact]) { fixture }

private func makeBoard() -> (candidates: [BarReader.Candidate], notes: [MemoryFact]) {
    let deed = FaciendaTask(title: "Deed transfer at the notary", state: .waiting, nextAction: "Wait for the notary")
    let coast = FaciendaTask(title: "A weekend on the coast", state: .needsMe, nextAction: "Choose a place")
    let call = FaciendaTask(title: "Call home", state: .scheduled, nextAction: "Call")
    let reading = FaciendaTask(title: "Revisit the reading list", state: .scheduled, nextAction: "Choose the next book")
    let question = Decision(taskId: coast.id, question: "Book Ericeira?", recommendation: "Book Ericeira", options: ["Book Ericeira", "Book Comporta", "Neither yet"])
    return ([
        BarReader.Candidate(task: deed, group: "House move", status: "Waiting on Dr. Seibert's office"),
        BarReader.Candidate(task: coast, group: "Time away", status: "Has a question", question: question, latest: "Ericeira is quieter mid-week."),
        BarReader.Candidate(task: call, status: "Parked until Thu 19:21"),
        BarReader.Candidate(task: reading, status: "Parked · Choose the next book"),
    ], [MemoryFact(text: "Handover is on the 28th at 10", source: "Notes")])
}

private func read(_ json: String) -> BarReader.Reading? {
    let (candidates, notes) = board()
    return BarReader.read(json, candidates: candidates, notes: notes, now: now, timeZone: lisbon)
}

private func reply(kind: String, pick: Int? = nil, options: [Int] = [], message: String = "", until: String = "", then: String = "none", answer: String = "", sources: [String] = []) -> String {
    let fields: [String: JSONValue] = [
        "kind": .string(kind), "pick": pick.map { .number(Double($0)) } ?? .null, "options": .array(options.map { .number(Double($0)) }),
        "message": .string(message), "until": .string(until), "then": .string(then),
        "answer": .string(answer), "sources": .array(sources.map(JSONValue.string)),
    ]
    return JSONValue.object(fields).json
}

@Test func theReaderSeesEachTaskWithItsQuestionAndTheTimeWithItsOffset() {
    let (candidates, notes) = board()
    let prompt = BarReader.prompt(text: "ericeira, mid-week", candidates: candidates, notes: notes, now: now, timeZone: lisbon, preferredLanguages: ["en-GB"])
    #expect(prompt.contains("TODAY: Saturday 17 October 2026, 22:00 +01:00"))
    #expect(prompt.contains("TEXT: ericeira, mid-week\nWRITE IN: English"))
    #expect(prompt.contains("T1. Deed transfer at the notary · group: House move · Waiting on Dr. Seibert's office"))
    #expect(prompt.contains("T2. A weekend on the coast · group: Time away · Has a question · ASKED: \"Book Ericeira?\" OPTIONS: Book Ericeira | Book Comporta | Neither yet · LATEST: \"Ericeira is quieter mid-week.\""))
    #expect(prompt.contains("N1. Handover is on the 28th at 10"))
    // Nothing to go on is said, not left blank.
    #expect(BarReader.prompt(text: "x", candidates: [], notes: [], now: now, timeZone: lisbon).contains("TASKS:\n(none)\nNOTES:\n(none)"))
}

@Test func aReplyAndAnAnswerNeedTheirTaskAndTheirWords() {
    let (candidates, _) = board()
    let sent = read(reply(kind: "reply", pick: 1, message: " The notary called back: proxy signing is fine. "))
    #expect(sent?.kind == .reply)
    #expect(sent?.task?.id == candidates[0].task.id)
    #expect(sent?.message == "The notary called back: proxy signing is fine.")
    // Nothing to send, or a task that isn't on the list, reads as new work.
    #expect(read(reply(kind: "reply", pick: 1)) == nil)
    #expect(read(reply(kind: "reply", pick: 9, message: "Hi")) == nil)
    #expect(read(reply(kind: "done", pick: 0)) == nil)

    let answered = read(reply(kind: "decide", pick: 2, message: "Book Ericeira"))
    #expect(answered?.kind == .answer)
    #expect(answered?.message == "Book Ericeira")
    // A task that asked nothing can only be told something.
    #expect(read(reply(kind: "decide", pick: 1, message: "Yes, go ahead"))?.kind == .reply)
}

@Test func aParkedTaskComesBackAtALaterTime() {
    let parked = read(reply(kind: "park", pick: 3, until: "2026-10-23T09:00:00+01:00"))
    #expect(parked?.kind == .park)
    #expect(parked?.until == ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
    // A day alone means nine that morning, in the person's time zone.
    #expect(read(reply(kind: "park", pick: 3, until: "2026-10-23"))?.until == ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
    // A time already gone, or none, parks nothing: the task opens, where it can be parked by hand.
    #expect(read(reply(kind: "park", pick: 3, until: "2026-10-01T09:00:00+01:00"))?.kind == .open)
    #expect(read(reply(kind: "park", pick: 3, until: "friday"))?.kind == .open)
    #expect(read(reply(kind: "park", until: "2026-10-23")) == nil)
}

@Test func anAnswerStandsOnlyOnWhatItWasGiven() {
    let (candidates, notes) = board()
    let answer = read(reply(kind: "question", answer: "The 28th at 10.", sources: ["N1", "t1", "T9"]))
    #expect(answer?.kind == .question)
    #expect(answer?.answer == "The 28th at 10.")
    #expect(answer?.notes == notes)
    #expect(answer?.sources.map(\.id) == [candidates[0].task.id])
    // An answer that cites nothing it was given, or says nothing, is research for an agent.
    #expect(read(reply(kind: "question", answer: "Probably the 28th.")) == nil)
    #expect(read(reply(kind: "question", answer: "", sources: ["N1"])) == nil)
}

@Test func anUnclearTextAsksBetweenTasksAndCarriesWhatItMeant() {
    let (candidates, _) = board()
    let unclear = read(reply(kind: "unclear", options: [3, 4, 3, 7], until: "2026-10-23T09:00:00+01:00", then: "park"))
    #expect(unclear?.kind == .unclear)
    #expect(unclear?.options.map(\.id) == [candidates[2].task.id, candidates[3].task.id])
    let chosen = unclear?.choosing(candidates[3].task)
    #expect(chosen?.kind == .park)
    #expect(chosen?.task?.id == candidates[3].task.id)
    #expect(chosen?.until == ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
    // One task is no choice; a park without its time opens the one chosen; a reply needs its words.
    #expect(read(reply(kind: "unclear", options: [3], until: "2026-10-23", then: "park")) == nil)
    #expect(read(reply(kind: "unclear", options: [3, 4], then: "park"))?.then == .open)
    #expect(read(reply(kind: "unclear", options: [1, 2], then: "reply")) == nil)
    #expect(read(reply(kind: "unclear", options: [1, 2], then: "none")) == nil)
}

@Test func newWorkAndUnreadableRepliesLeaveReturnAsItWas() {
    #expect(read(reply(kind: "new"))?.kind == .new)
    #expect(read("not json") == nil)
    #expect(read(#"{"kind":"launch"}"#) == nil)
}

@Test func theReaderIsToldWhichLanguageToWriteIn() {
    #expect(BarReader.language(of: "what did the deed task find out about the signing?", preferred: ["de-DE"]) == "English")
    #expect(BarReader.language(of: "verschieb den Anruf bitte auf Freitag", preferred: ["en-US"]) == "German")
    // Too short to tell: the person's own language.
    #expect(BarReader.language(of: "ericeira", preferred: ["pt-PT", "en"]) == "Portuguese")
    #expect(BarReader.language(of: "ok", preferred: []) == "English")
}

@Test func onlyTextThatCouldBeAboutTheBoardIsRead() {
    #expect(BarReader.worthReading("buy oat milk", matchesTasks: false) == false)
    #expect(BarReader.worthReading("buy oat milk", matchesTasks: true))
    #expect(BarReader.worthReading("move it to friday", matchesTasks: false))
    #expect(BarReader.worthReading("handover date?", matchesTasks: false))
    #expect(BarReader.worthReading("lights", matchesTasks: true) == false)
    #expect(BarReader.worthReading("ericeira", matchesTasks: false, matchesQuestion: true))
    #expect(BarReader.pointsBack("move it to friday"))
    #expect(BarReader.pointsBack("done with the reading list"))
    #expect(BarReader.pointsBack("book a table for two") == false)
}

@Test func theFeedKeepsEachRequestWithItsReadingInItsWorkspace() throws {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaIntakeTests/\(UUID().uuidString)/test.sqlite"))
    let home = library.scoped(to: try library.createWorkspace(name: "Home").id)
    let work = library.scoped(to: try library.createWorkspace(name: "Work").id)
    let deed = try home.create(FaciendaTask(title: "Deed transfer", state: .waiting, nextAction: "Wait"))

    try home.recordIntake(text: "remember the notary is Dr. Seibert", reading: "Remember", decidedBy: .rule, taskId: nil)
    try home.recordIntake(text: "tell the deed task proxy signing is fine", reading: "Reply · Deed transfer", decidedBy: .model, taskId: deed.id)
    try home.recordIntake(text: "Book the dentist", reading: "New task", decidedBy: .you, taskId: nil)
    try work.recordIntake(text: "plan the retreat", reading: "New task", decidedBy: .rule, taskId: nil)
    try home.recordIntake(text: "   ", reading: "New task", decidedBy: .rule, taskId: nil)

    let feed = try home.intake()
    #expect(feed.map(\.text) == ["Book the dentist", "tell the deed task proxy signing is fine", "remember the notary is Dr. Seibert"])
    #expect(feed[0].decidedBy == .you)
    #expect(feed[1].reading == "Reply · Deed transfer")
    #expect(feed[1].decidedBy == .model)
    #expect(feed[1].taskId == deed.id)
    #expect(try work.intake().map(\.text) == ["plan the retreat"])
}

@Test func retiringTheCompanionKeepsOriginalRequestsInTheirWorkspace() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaIntakeTests/\(UUID().uuidString)/test.sqlite")
    let library = try FaciendaStore(url: url)
    let home = library.scoped(to: try library.createWorkspace(name: "Home").id)
    let work = library.scoped(to: try library.createWorkspace(name: "Work").id)
    let original = "Book the dentist\nAsk about \"Tuesday\"."
    let task = try home.create(FaciendaTask(title: original, state: .inbox, nextAction: original))
    let received = TaskEvent(taskId: task.id, source: .user, kind: "mobile.received", payload: task.id, at: now)
    try home.record(received)
    let other = try work.create(FaciendaTask(title: "Plan the retreat", state: .inbox, nextAction: "Plan"))
    try work.record(TaskEvent(taskId: other.id, source: .user, kind: "mobile.received", payload: other.id))
    // Untrusted or malformed markers must never turn into user requests.
    try home.record(TaskEvent(taskId: task.id, source: .mcp, kind: "mobile.received", payload: task.id))
    try home.record(TaskEvent(taskId: task.id, source: .user, kind: "mobile.received", payload: "invalid"))
    try home.recordIntake(text: "Keep the receipt", reading: "Remember", decidedBy: .rule, taskId: nil)
    try library.db.write { db in
        try db.execute(sql: "UPDATE tasks SET title = 'Dentist appointment', state = 'done' WHERE id = ?", arguments: [task.id])
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'unified_intake'")
    }

    let reopened = try FaciendaStore(url: url)
    let feed = try reopened.scoped(to: home.workspaceID!).intake()
    #expect(feed.count == 2)
    let entry = try #require(feed.first { $0.id == received.id })
    #expect(entry.text == original)
    #expect(entry.at == received.at)
    #expect(entry.taskId == task.id)
    #expect(entry.reading == "New task · Inbox")
    #expect(entry.decidedBy == .rule)
    #expect(try reopened.task(task.id).title == "Dentist appointment")
    #expect(try reopened.task(task.id).state == .done)
    #expect(try reopened.scoped(to: work.workspaceID!).intake().map(\.text) == ["Plan the retreat"])
    #expect(try FaciendaStore(url: url).scoped(to: home.workspaceID!).intake() == feed)
}
