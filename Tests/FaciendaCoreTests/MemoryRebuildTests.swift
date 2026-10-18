import Foundation
import Testing
import GRDB
@testable import FaciendaCore

private func rebuiltMemory() throws -> (FaciendaStore, String, FaciendaTask) {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "MemoryRebuild/\(UUID().uuidString)/test.sqlite"))
    let task = try store.create(FaciendaTask(title: "Prepare the studio"))
    return (store, try store.memorySpace(forTask: task.id).id, task)
}

@Test func repeatedMovesAreOfferedButNeverAcceptThemselves() async throws {
    let (store, space, task) = try rebuiltMemory()
    let learner = MemoryMoveLearner(store: store)
    let situations = [("build", "Please show me the changes."), ("quote", "Compare this with the other quote."), ("explanation", "Draw the experiment for me.")]
    for (situation, text) in situations {
        let context = try #require(MemorySituation.core.first { $0.0 == situation }).2
        for index in 0..<3 {
            try store.captureUtterance(id: situation + "-\(index)", text: text, source: "Invented studio, renovation and research examples", kind: .userReply,
                                       taskID: task.id, spaceID: space, at: Date().addingTimeInterval(Double(index)), priorResult: context)
        }
    }
    try await learner.learnPending()
    try await learner.learnPending()
    let moves = try store.memoryMoves(spaceID: space)
    #expect(moves.count == 3 && moves.allSatisfy { $0.stage == .offered && $0.seen == 3 })
    try store.record(TaskEvent(taskId: task.id, source: .mcp, kind: "codex.result", payload: MemorySituation.core[0].2))
    let result = try #require(store.latestResults().first { $0.taskId == task.id }).eventId
    try await learner.offer(taskID: task.id, eventID: result, result: MemorySituation.core[0].2)
    try await learner.offer(taskID: task.id, eventID: result, result: MemorySituation.core[0].2)
    let offered = try #require(store.suggestedMoves(taskID: task.id).first)
    #expect(offered.text == situations[0].1 && offered.offered == 1 && offered.used == 0)
    #expect(throws: (any Error).self) { try store.recordMoveUse(offered.id, taskID: task.id) }
    try store.acceptMove(offered.id, spaceID: space)
    try store.recordMoveUse(offered.id, taskID: task.id)
    #expect(try store.suggestedMoves(taskID: task.id).first?.used == 1)
    let other = try store.createWorkspace(name: "Another lab")
    let otherTask = try store.scoped(to: other.id).create(FaciendaTask(title: "Study a seed"))
    try store.record(TaskEvent(taskId: otherTask.id, source: .mcp, kind: "codex.result", payload: MemorySituation.core[0].2))
    try await learner.offerLatest(taskID: otherTask.id)
    #expect(try store.suggestedMoves(taskID: otherTask.id).isEmpty)
}

@Test func suggestionsFollowTheLatestResultAndFinishedTasksLeaveRoomForOpenOnes() async throws {
    let (store, space, task) = try rebuiltMemory()
    try store.saveMemorySettings(enabled: true, workerModel: nil)
    try store.writeMemoryMove(spaceID: space, situationID: "build", text: "Show me the changes", isYourStep: false)
    try store.writeMemoryMove(spaceID: space, situationID: "question", text: "Take the first option", isYourStep: false)
    let learner = MemoryMoveLearner(store: store)
    try await learner.learnPending()
    try store.record(TaskEvent(taskId: task.id, source: .mcp, kind: "codex.result", payload: MemorySituation.core[0].2))
    // Finished tasks with newer results used to take every place in the sweep, so open ones never got theirs.
    for index in 0..<3 {
        let finished = try store.create(FaciendaTask(title: "Finished errand \(index)", state: .done))
        try store.record(TaskEvent(taskId: finished.id, source: .mcp, kind: "codex.result", payload: MemorySituation.core[0].2))
    }
    try await learner.offerPending(limit: 2)
    #expect(try store.suggestedMoves(taskID: task.id).map(\.text) == ["Show me the changes"])
    // A newer result hides the moves read from the one before until it has been read itself.
    let question = try #require(MemorySituation.core.first { $0.0 == "question" }).2
    try store.record(TaskEvent(taskId: task.id, source: .mcp, kind: "codex.result", payload: question))
    #expect(try store.suggestedMoves(taskID: task.id).isEmpty)
    try await learner.offerLatest(taskID: task.id)
    #expect(try store.suggestedMoves(taskID: task.id).map(\.text) == ["Take the first option"])
}

@Test func keeperQuotesSourcesKeepsHistoryAndProposesContradictions() throws {
    let (store, space, task) = try rebuiltMemory()
    let keeper = MemoryKeeper(store: store, inference: EmptyKeeper())
    func utterance(_ id: String, _ text: String, at: TimeInterval) throws -> MemoryUtterance {
        try store.captureUtterance(id: id, text: text, source: "Invented renovation reply", kind: .userReply, taskID: task.id, spaceID: space, at: Date(timeIntervalSince1970: at))
        return try store.db.read { try MemoryUtterance.fetchOne($0, key: id)! }
    }
    let first = try utterance("one", "Always use oak for the shelves.", at: 100)
    func choice(_ text: String, action: String, existing: String = "") -> MemoryKeeper.Choice {
        .init(shelf: .choices, subject: "Shelf material", quote: text, existingId: existing, action: action, reason: "Different material", fields: [])
    }
    try keeper.apply([choice(first.text, action: "keep"), choice("Invented by the worker", action: "keep")], utterance: first, candidates: [])
    let entry = try #require(store.memoryEntries(spaceID: space).first)
    #expect(entry.text == first.text && entry.state == .live)
    let second = try utterance("two", "Use birch instead of oak now.", at: 200)
    try keeper.apply([choice(second.text, action: "update", existing: entry.id)], utterance: second, candidates: [entry])
    let updated = try store.memoryEntry(entry.id, spaceID: space)
    #expect(updated.text == second.text && updated.revision == 2)
    #expect(try store.memoryEntryHistory(entry.id, spaceID: space).first?.snapshot.text == first.text)
    let third = try utterance("three", "Use walnut for the shelves.", at: 300)
    try keeper.apply([choice(third.text, action: "conflict", existing: entry.id)], utterance: third, candidates: [updated])
    let proposal = try #require(store.memoryEntries(spaceID: space).first { $0.state == .proposed })
    #expect(try store.memoryEntry(entry.id, spaceID: space).text == second.text)
    let undo = try UndoStep.recording { try store.acceptMemoryEntry(proposal.id, spaceID: space) }
    #expect(try store.memoryEntry(entry.id, spaceID: space).text == third.text)
    _ = try store.replay(undo)
    #expect(try store.memoryEntry(entry.id, spaceID: space).text == second.text)
}

/// The schema is decoded the first time the keeper reads a pending source, a few seconds after launch, and a typo in it
/// stops the app there; the other keeper tests apply choices directly and never reach it.
@Test func keeperSchemaDecodesAndNamesEveryChoiceField() throws {
    let entry = MemoryKeeper.schema["properties"]["entries"]["items"]
    #expect(MemoryKeeper.schema["required"] == .array([.string("entries")]))
    #expect(Set(entry["required"].array?.compactMap(\.string) ?? []) == ["shelf", "subject", "quote", "existingId", "action", "reason", "fields"])
    #expect(entry["properties"]["fields"]["items"]["required"] == .array([.string("name"), .string("value")]))
}

private struct EmptyKeeper: MemoryInference {
    func complete(system: String, user: String, schema: JSONValue) async throws -> String { #"{"entries":[]}"# }
}

private actor MigrationWorker: MemoryInference {
    var sawSecret = false
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        sawSecret = sawSecret || user.contains("invented-secret")
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        let sources = input["OLD_SOURCES"].array ?? []
        return JSONValue.object(["proposals": .array([.object(["shelf": .string("choices"), "subject": .string("Shelf material"), "text": .string("Use oak for shelves."),
                                                             "sources": .array(sources.compactMap { $0["id"].string }.map(JSONValue.string))])])]).json
    }
}

private struct InterruptedMigrationWorker: MemoryInference {
    let store: FaciendaStore
    let space: String
    var editNote: String? = nil
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        #expect(throws: (any Error).self) {
            try store.enqueueMemoryDocument(id: "late-legacy", content: "An old client report", source: "Invented fixture", at: Date(), spaceID: space)
        }
        if let editNote {
            try store.correctMemory(editNote, text: "Use birch now.")
            return #"{"proposals":[]}"#
        }
        throw StoreError.invalid("Invented worker outage")
    }
}

@Test func migrationLeaseReleasesAfterFailureAndPreservesUserEdits() async throws {
    for edited in [false, true] {
        let (store, space, _) = try rebuiltMemory()
        var note = MemoryFact(text: "Use oak.", source: "Invented user"); note.spaceId = space
        try store.remember(note, source: .user)
        let worker = InterruptedMigrationWorker(store: store, space: space, editNote: edited ? note.id : nil)
        await #expect(throws: (any Error).self) { try await MemoryMigration(store: store, inference: worker).run(spaceID: space) }
        #expect(try !store.memoryWasMigrated(space))
        #expect(try store.memory(spaceID: space).first?.text == (edited ? "Use birch now." : "Use oak."))
        #expect(try await store.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memoryMigrationLeases") } == 0)
        try store.enqueueMemoryDocument(id: "resumed-legacy", content: "Old capture resumes after failure", source: "Invented fixture", at: Date(), spaceID: space)
    }
}

@Test func migrationRedactsArchivesAndUndoesOnlyItsWorkspace() async throws {
    let (store, space, _) = try rebuiltMemory(), worker = MigrationWorker()
    var note = MemoryFact(text: "Use oak for shelves.", source: "Invented user decision")
    note.spaceId = space; note.confirmedAt = Date(); try store.remember(note, source: .user)
    let noteID = note.id
    try await store.db.write { try $0.execute(sql: "UPDATE memoryFacts SET source = 'password is invented-secret' WHERE id = ?", arguments: [noteID]) }
    try store.enqueueMemoryDocument(id: "legacy-source", content: "Use oak for shelves.", source: "Invented legacy source", at: Date(), spaceID: space)
    let other = try store.createWorkspace(name: "Research room")
    var untouched = MemoryFact(text: "Keep samples cool.", source: "Invented user")
    untouched.spaceId = other.memorySpaceId; untouched.confirmedAt = Date(); try store.remember(untouched, source: .user)
    let receipt = try await MemoryMigration(store: store, inference: worker).run(spaceID: space)
    #expect(receipt.proposed == 1 && receipt.archived == 2 && receipt.redacted.notes == 1)
    #expect(await worker.sawSecret == false)
    #expect(try store.memory(spaceID: space).isEmpty)
    #expect(try store.memory(spaceID: other.memorySpaceId).count == 1)
    #expect(try store.memoryEntries(spaceID: space, states: [.live]).isEmpty)
    #expect(try store.archivedMemorySource("archive:note:" + note.id, spaceID: space)["text"].string == note.text)
    #expect(try await MemoryMigration(store: store, inference: worker).run(spaceID: space).alreadyMigrated)
    #expect(throws: (any Error).self) {
        try store.enqueueMemoryDocument(id: "old-writer", content: "Agent narration must not return", source: "Old client", at: Date(), spaceID: space)
    }
    try store.enqueueMemoryDocument(id: "new-writer", content: "Use birch for the next shelf.", source: "Invented user", at: Date(), spaceID: space, sourceKind: .userReply)
    #expect(try await store.db.read { try MemoryUtterance.fetchOne($0, key: "new-writer")?.text } == "Use birch for the next shelf.")
    var late = MemoryFact(text: "Old client note", source: "Invented fixture"); late.spaceId = space
    #expect(throws: (any Error).self) { try store.remember(late, source: .user) }
    var otherLate = MemoryFact(text: "Another research note", source: "Invented fixture"); otherLate.spaceId = other.memorySpaceId
    try store.remember(otherLate, source: .user)
    #expect(try store.memory(spaceID: other.memorySpaceId).count == 2)
    try store.undoMemoryMigration(spaceID: space)
    #expect(try store.memory(spaceID: space).first?.source == "[redacted]")
    #expect(try store.memoryEntries(spaceID: space).isEmpty)
}

@Test func memoryIndexIsBoundedAndHookIsExactScopedAndReadOnly() throws {
    let (store, space, task) = try rebuiltMemory()
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "fixture-thread"))
    for index in 0..<120 {
        _ = try store.writeMemoryEntry(.init(spaceID: space, shelf: .people, subject: "Researcher \(index)", text: "Studies fictional seeds \(index)", origin: .you, sources: ["Invented fixture"]))
    }
    let place = try store.writeMemoryEntry(.init(spaceID: space, shelf: .places, subject: "Studio", text: "Read the brief here", origin: .you, sources: ["Invented fixture"], fields: ["path": "/tmp/fictional-studio"]))
    let context = try store.memoryAgentContext(taskID: task.id, query: "Researcher")
    #expect(context.index.count <= 1500 && context.index.split(separator: "\n").count <= 15)
    let input = JSONValue.object(["path": .string("/tmp/fictional-studio")])
    let change = try store.db.read { try Int.fetchOne($0, sql: "PRAGMA data_version") }
    let start = Date()
    #expect(try store.memoryHookContext(threadID: "fixture-thread", input: input)?.contains(place.text) == true)
    #expect(Date().timeIntervalSince(start) < 0.05)
    #expect(try store.memoryHookContext(threadID: "fixture-thread", input: .object(["path": .string("/tmp/fictional-studio-other")])) == nil)
    #expect(try store.memoryHookContext(threadID: "unknown-thread", input: input) == nil)
    #expect(try store.db.read { try Int.fetchOne($0, sql: "PRAGMA data_version") } == change)
    let other = try store.createWorkspace(name: "Elsewhere")
    #expect(throws: (any Error).self) { try store.memoryEntry(place.id, spaceID: other.memorySpaceId) }
}

@Test func earnedSectionsWaitForAcceptanceAndForgetSupportsUndo() throws {
    let (store, space, _) = try rebuiltMemory()
    for index in 0..<3 {
        _ = try store.writeMemoryEntry(.init(spaceID: space, shelf: .places, subject: "Room \(index)", text: "Instrument \(index)", origin: .you, sources: ["Invented lab"], fields: ["floor": "2", "instrument": "\(index)"]))
    }
    try store.proposeMemoryCollections(spaceID: space)
    let section = try #require(store.memorySections(spaceID: space).first)
    #expect(section.state == .proposed && section.entryIds.count == 3)
    #expect(try store.memoryEntries(spaceID: space).allSatisfy { $0.sectionId == nil })
    try store.acceptMemorySection(section.id, spaceID: space, name: "Instrument rooms")
    #expect(try store.memoryEntries(spaceID: space).allSatisfy { $0.sectionId == section.id })
    let entry = try #require(store.memoryEntries(spaceID: space).first)
    let undo = try UndoStep.recording { try store.forgetMemoryEntry(entry.id, spaceID: space) }
    #expect(try store.memoryEntries(spaceID: space).count == 2)
    _ = try store.replay(undo)
    #expect(try store.memoryEntries(spaceID: space).count == 3)
}

@Test func routinesCannotAutomaticallyMessagePayOrPublish() throws {
    let (store, space, task) = try rebuiltMemory()
    let routine = MemoryRoutine(id: "fixture-routine", spaceId: space, name: "Review", state: .proposed,
                                steps: [.init(text: "Send the invoice")], seen: 3, createdAt: Date())
    try store.db.write { try routine.insert($0) }
    #expect(throws: (any Error).self) { try store.saveMemoryRoutine(routine.id, spaceID: space, name: "Review", steps: [.init(text: "Send the invoice", mode: .automatic)]) }
    #expect(throws: (any Error).self) { try store.startMemoryRoutine(routine.id, taskID: task.id) }
    try store.saveMemoryRoutine(routine.id, spaceID: space, name: "Review", steps: [.init(text: "Check the figures", mode: .automatic, action: .reminder), .init(text: "Publish the report", mode: .oneClick)])
    try store.startMemoryRoutine(routine.id, taskID: task.id)
    #expect(try store.advanceMemoryRoutine(taskID: task.id, expectedStep: 0, userConfirmed: false) == "Check the figures")
    #expect(throws: (any Error).self) { try store.advanceMemoryRoutine(taskID: task.id, expectedStep: 1, userConfirmed: false) }
    #expect(try store.dispatches().isEmpty)
}

@Test func aMovedTaskDoesNotMoveItsPreviouslyCapturedMemory() throws {
    let (store, space, task) = try rebuiltMemory()
    try store.enqueueMemoryDocument(id: "original", content: "Use oak for shelves.", source: "Invented user", at: Date(), spaceID: space, sourceKind: .userReply, taskID: task.id)
    let target = try store.createWorkspace(name: "Research")
    // Re-reading a chat after a move must keep the source in its original memory.
    try store.enqueueMemoryDocument(id: "original", content: "Use oak for shelves.", source: "Invented user", at: Date(), spaceID: target.memorySpaceId, sourceKind: .userReply, taskID: task.id)
    #expect(try store.db.read { try MemoryDocument.fetchOne($0, sql: "SELECT * FROM memoryDocuments WHERE id = 'original'")?.spaceId } == space)
    #expect(try store.db.read { try MemoryUtterance.fetchOne($0, key: "original")?.spaceId } == space)
    #expect(throws: (any Error).self) { try store.openMemoryReference("utterance:original", spaceID: target.memorySpaceId) }
}

@Test func structuredMemoryFieldsRedactCredentialValues() throws {
    let (store, space, _) = try rebuiltMemory()
    let entry = try store.writeMemoryEntry(.init(spaceID: space, shelf: .places, subject: "Fictional lab", text: "Read the notebook", origin: .you,
                                               sources: ["Invented fixture"], fields: ["password": "invented-secret", "path": "/tmp/fictional-lab"]))
    #expect(entry.fields["password"] == "[redacted]")
    #expect(entry.fields["path"] == "/tmp/fictional-lab")
    try store.editMemoryEntry(entry.id, spaceID: space, text: entry.text, fields: ["token": "another-invented-secret"])
    #expect(try store.memoryEntry(entry.id, spaceID: space).fields["token"] == "[redacted]")
}

@Test func localMovesArePreparedWithoutAnAIWorker() async throws {
    let (store, space, task) = try rebuiltMemory()
    try store.saveMemorySettings(enabled: true, workerModel: nil)
    try store.setMemoryAIWorker(false)
    try store.writeMemoryMove(spaceID: space, situationID: "build", text: "Show me the changes", isYourStep: false)
    try store.record(TaskEvent(taskId: task.id, source: .mcp, kind: "codex.result", payload: MemorySituation.core[0].2))
    try await WorkspaceMemoryService(store: store, inference: nil).synchronize()
    #expect(try store.suggestedMoves(taskID: task.id).first?.text == "Show me the changes")
}

@Test func preToolHookOnlyAddsItsAuditReceipt() throws {
    let (store, space, task) = try rebuiltMemory()
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "fixture-tool-thread"))
    _ = try store.writeMemoryEntry(.init(spaceID: space, shelf: .rules, subject: "Publishing", text: "Ask before publishing", origin: .you, sources: ["Invented fixture"], fields: ["trigger": "git push"]))
    let before = try store.task(task.id), entries = try store.memoryEntries(spaceID: space)
    let event = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"session_id":"fixture-tool-thread","hook_event_name":"PreToolUse","tool_input":{"command":"git push origin main"}}"#.utf8))
    let start = Date(), result = try event.apply(to: store)
    #expect(Date().timeIntervalSince(start) < 0.05)
    #expect(result?["hookSpecificOutput"]["additionalContext"].string?.contains("Ask before publishing") == true)
    #expect(try store.task(task.id).revision == before.revision)
    #expect(try store.task(task.id).state == before.state)
    #expect(try store.memoryEntries(spaceID: space) == entries)
    #expect(try store.memoryDeliveries(spaceID: space).count == 1)
    #expect(try store.dispatches().isEmpty)
}
