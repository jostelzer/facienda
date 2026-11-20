import Foundation
import Testing
import GRDB
@testable import FaciendaCore

private func slimLibrary() throws -> (FaciendaStore, String, FaciendaTask) {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "MemorySlimTests/\(UUID().uuidString)/test.sqlite"))
    let task = try store.create(FaciendaTask(title: "Invented orchard survey"))
    try store.saveMemorySettings(enabled: true, workerModel: nil)
    return (store, try store.memorySpace(forTask: task.id).id, task)
}

private func understanding(_ space: String, _ subject: String, confidence: String = "tentative", cites: Int = 1, state: MemoryUnderstanding.State = .inferred,
                           at: TimeInterval = 100, connections: [MemoryUnderstanding.Connection] = []) -> MemoryUnderstanding {
    MemoryUnderstanding(id: "u-" + subject, spaceId: space, kind: .thing, subject: subject, subjectKey: MemoryEntry.key(subject), summary: "Invented summary of " + subject,
                        explanation: "", appliesWhen: "", exceptions: [], steps: [], questions: [],
                        citations: (0..<cites).map { .init(evidenceId: "e\($0)", quote: "invented") }, connections: connections, confidence: confidence, state: state,
                        revision: 1, sourceRevision: 0, model: "invented", updatedAt: Date(timeIntervalSince1970: at), embedding: Data())
}

@Test func aWorkspaceKeepsItsBestSupportedSubjectsAndWhatTheUserReviewed() throws {
    let (store, space, _) = try slimLibrary()
    try store.db.write { db in
        for index in 0..<30 { try understanding(space, "Passing remark \(index)", at: TimeInterval(index)).insert(db) }
        try understanding(space, "Pruning calendar", confidence: "strong", cites: 4, at: 1).insert(db)
        try understanding(space, "Reviewed long ago", state: .reviewed, at: 0).insert(db)
        try understanding(space, "Put away", state: .dismissed, at: 0).insert(db)
        try understanding(space, "Grafting", confidence: "supported", cites: 2, at: 2, connections: [.init(targetId: "u-Passing remark 0", relation: "explains")]).insert(db)
        try MemoryUnderstandingVersion(id: "v", understandingId: "u-Passing remark 0", snapshot: understanding(space, "Passing remark 0"), at: Date()).insert(db)
    }
    let dropped = try store.trimMemoryUnderstanding(spaceID: space)
    let kept = try store.memoryUnderstanding(spaceID: space)
    #expect(kept.count == MemoryUnderstanding.kept && dropped.count == 13)
    #expect(Set(["Pruning calendar", "Reviewed long ago", "Grafting", "Passing remark 29"]).isSubset(of: Set(kept.map(\.subject))))
    // Among equally weak ones the oldest go, and with them their history and the links that pointed at them.
    #expect(!kept.contains { $0.subject == "Passing remark 0" })
    #expect(kept.first { $0.subject == "Grafting" }?.connections.isEmpty == true)
    #expect(try store.memoryUnderstanding(spaceID: space, includeDismissed: true).contains { $0.subject == "Put away" })
    #expect(try store.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memoryUnderstandingHistory") } == 0)
    #expect(try store.trimMemoryUnderstanding(spaceID: space).isEmpty)
}

@Test func anInterpretationKeepsOnlyItsLastVersions() throws {
    let (store, space, _) = try slimLibrary()
    try store.db.write { try understanding(space, "Irrigation").insert($0) }
    for round in 0..<6 { try store.reviewMemoryUnderstanding("u-Irrigation", spaceID: space, summary: "Invented correction \(round)") }
    #expect(try store.memoryUnderstandingHistory("u-Irrigation", spaceID: space).count == MemoryUnderstanding.keptVersions)
}

@Test func theOneTimeCleanupArchivesWhatItRemovesAndRunsOnce() throws {
    let (store, space, task) = try slimLibrary()
    let summary = "This session is being continued from a previous conversation that ran out of context. Invented summary."
    try store.db.write { db in
        for index in 0..<25 { try understanding(space, "Passing remark \(index)", at: TimeInterval(index)).insert(db) }
        for index in 0..<5 { try MemoryUnderstandingVersion(id: "v\(index)", understandingId: "u-Passing remark 24", snapshot: understanding(space, "Passing remark 24"), at: Date(timeIntervalSince1970: TimeInterval(index))).insert(db) }
        for (id, text) in [("summary", summary), ("wrapped", "<system-reminder>Invented notice</system-reminder>\nPlant the quinces first"), ("plain", "Order the stakes")] {
            try db.execute(sql: "INSERT INTO memoryUtterances (id, spaceId, taskId, text, source, sourceKind, at) VALUES (?, ?, ?, ?, 'Invented chat', 'claudeUser', ?)", arguments: [id, space, task.id, text, Date()])
        }
        for (id, stage) in [("seen-once", "noticed"), ("offered", "offered"), ("mine", "accepted")] {
            try db.execute(sql: "INSERT INTO memoryMoves (id, spaceId, situationId, text, stage, seen, embedding, createdAt, updatedAt) VALUES (?, ?, 's', 'Invented move', ?, 1, x'', ?, ?)", arguments: [id, space, stage, Date(), Date()])
        }
        try db.execute(sql: "UPDATE memoryUtterances SET moveId = 'seen-once' WHERE id = 'plain'")
    }
    try store.slimMemoryOnce()
    #expect(try store.memoryUnderstanding(spaceID: space).count == MemoryUnderstanding.kept)
    #expect(try store.memoryUnderstandingHistory("u-Passing remark 24", spaceID: space).count == MemoryUnderstanding.keptVersions)
    let utterances = try store.db.read { try Row.fetchAll($0, sql: "SELECT id, text, moveId FROM memoryUtterances ORDER BY id") }
    #expect(utterances.map { $0["text"] as String } == ["Order the stakes", "Plant the quinces first"] && utterances[0]["moveId"] as String? == nil)
    #expect(try store.db.read { try String.fetchAll($0, sql: "SELECT id FROM memoryMoves") } == ["mine"])
    // Everything that went is in the file beside the library.
    let archive = try DatabaseQueue(path: store.memoryArchiveURL.path)
    #expect(try archive.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memoryUnderstanding") } == 25)
    #expect(try archive.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memoryMoves") } == 3)
    #expect(try archive.read { try String.fetchOne($0, sql: "SELECT text FROM memoryUtterances WHERE id = 'summary'") } == summary)
    // A second run leaves later memory alone.
    try store.db.write { db in for index in 0..<3 { try understanding(space, "Later subject \(index)", at: 500).insert(db) } }
    try store.slimMemoryOnce()
    #expect(try store.memoryUnderstanding(spaceID: space).count == MemoryUnderstanding.kept + 3)
}

@Test func aClaudeSessionSummaryAndItsRemindersAreNotThePersonsWords() {
    func line(_ id: String, _ text: String, summary: Bool = false) -> String {
        JSONValue.object(["type": .string("user"), "uuid": .string(id), "timestamp": .string("2026-11-02T10:00:00.000Z"), "isCompactSummary": .bool(summary),
                          "message": .object(["role": .string("user"), "content": .string(text)])]).json
    }
    let lines = [line("a", "This session is being continued from a previous conversation that ran out of context. Invented."),
                 line("b", "Invented text an app marked as its summary", summary: true),
                 line("c", "<system-reminder>Invented notice</system-reminder>\nPrune the pears in March"),
                 line("d", "Keep the old apple varieties")]
    #expect(MemoryUserMessages.claude(Data(lines.joined(separator: "\n").utf8)).map(\.text) == ["Prune the pears in March", "Keep the old apple varieties"])
}

@Test func memoryFindAnswersWithWhatAnAgentCanUseAndTheLookupIsListed() async throws {
    let (store, space, task) = try slimLibrary()
    try store.writeMemoryEntry(MemoryEntry(spaceID: space, shelf: .places, subject: "Tool shed", text: "Invented: ladders hang on the north wall", origin: .you, sources: ["invented"]))
    let handle = try store.taskHandle(task.id)
    let found = try await ToolService(store: store).callWithMemory("memory_find", arguments: .object(["text": .string("shed"), "taskId": .string(handle)])).array ?? []
    #expect(found.count == 1 && found[0]["subject"].string == "Tool shed" && found[0]["shelf"].string == "places")
    #expect(Set(found[0].object?.keys.map { $0 } ?? []) == ["id", "subject", "text", "shelf"])
    let listed = try store.memoryDeliveries(spaceID: space)
    #expect(listed.first?.kind == "Looked up" && listed.first?.text == "shed")
}

@Test func theIndexNamesWhatMemoryKnowsAbout() throws {
    let (store, space, task) = try slimLibrary()
    try store.db.write { db in for subject in ["Pruning calendar", "Grafting"] { try understanding(space, subject).insert(db) } }
    let index = try store.memoryAgentContext(taskID: task.id, query: "grafting").index
    #expect(index.contains("Knows about: Grafting · Pruning calendar") && !index.contains("Usual next move"))
}

@Test func openProposalsArePutAwayOnceAndTheUsersEntriesStay() throws {
    let (store, space, _) = try slimLibrary()
    let kept = try store.writeMemoryEntry(MemoryEntry(spaceID: space, shelf: .choices, subject: "Ladders", text: "Borrow the tall ladder", origin: .you, sources: [], reason: ""))
    let proposed = try store.proposeMemoryEntry(spaceID: space, shelf: .choices, subject: "Pears", text: "Pick pears early", source: "Invented", reason: "Invented")
    try store.archiveProposalsOnce()
    #expect(try store.memoryEntries(spaceID: space).map(\.id) == [kept.id])
    #expect(try store.memoryEntry(proposed.id, spaceID: space).state == .archived)
    // Later proposals are left alone: the step runs once.
    let later = try store.proposeMemoryEntry(spaceID: space, shelf: .choices, subject: "Plums", text: "Plums after rain", source: "Invented", reason: "Invented")
    try store.archiveProposalsOnce()
    #expect(try store.memoryEntry(later.id, spaceID: space).state == .proposed)
}
