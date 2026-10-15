import Foundation
import Testing
@testable import FaciendaCore

/// A scripted Luna: extraction turns each line "fact: … | entities: a, b" into a fact; consolidation creates one
/// observation per fact, or updates the first shown observation when the fact says "again".
private final class ScriptedLuna: MemoryInference, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var extractions: Int { lock.withLock { calls.filter { $0 == "extract" }.count } }
    var consolidations: Int { lock.withLock { calls.filter { $0 == "consolidate" }.count } }

    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        if system == MemoryPrompts.extraction {
            lock.withLock { calls.append("extract") }
            let content = user.components(separatedBy: "Content:\n").last ?? ""
            let facts: [JSONValue] = content.split(separator: "\n").compactMap { line in
                guard line.hasPrefix("fact: ") else { return nil }
                let parts = line.dropFirst(6).components(separatedBy: " | entities: ")
                let entities = parts.count > 1 ? parts[1].components(separatedBy: ", ") : []
                return .object(["what": .string(parts[0]), "when": .null, "where": .null, "who": .null, "why": .null,
                                "fact_kind": .string("conversation"), "occurred_start": .null, "occurred_end": .null,
                                "fact_type": .string(parts[0].hasPrefix("Assistant") ? "assistant" : "world"),
                                "memory_kind": .string(parts[0].contains("prefers") ? "preference" : parts[0].contains("passed") ? "status" : "project"),
                                "entities": .array(entities.map(JSONValue.string)), "causal_relations": .array([])])
            }
            return JSONValue.object(["facts": .array(facts)]).json
        }
        if system == MemoryPrompts.consolidation {
            lock.withLock { calls.append("consolidate") }
            let lines = user.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
            let shown = user.components(separatedBy: "### Existing observations").last ?? ""
            let existing = try? JSONDecoder().decode(JSONValue.self, from: Data(shown.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            var creates: [JSONValue] = [], updates: [JSONValue] = []
            for line in lines {
                let id = String(line.dropFirst().prefix { $0 != "]" })
                let text = line.drop { $0 != "]" }.dropFirst(2).components(separatedBy: " (").first ?? ""
                if text.contains("again"), let first = existing?.array?.first, let target = first["id"].string {
                    updates.append(.object(["text": .string((first["text"].string ?? "") + " Confirmed again."), "observation_id": .string(target),
                                            "source_fact_ids": .array([.string(id)]), "memory_kind": .string("project"), "reason": .string("same")]))
                } else {
                    creates.append(.object(["text": .string("Observed: " + text), "source_fact_ids": .array([.string(id)]), "memory_kind": .string("project"), "reason": .string("new")]))
                }
            }
            return JSONValue.object(["creates": .array(creates), "updates": .array(updates), "deletes": .array([])]).json
        }
        return JSONValue.object(["action": .string("keep"), "text": .string(""), "reason": .string("distinct")]).json
    }
}

private func nativeStore() throws -> (FaciendaStore, String) {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaNativeMemory/\(UUID().uuidString)/test.sqlite"))
    let store = library.scoped(to: try library.defaultWorkspace().id)
    return (store, try store.resolvedMemorySpace(nil).id)
}

private let models = MemoryModels(cache: FileManager.default.temporaryDirectory.appending(path: "FaciendaMemoryModels-\(getpid())"))

@Test func newLibrariesLearnInsideFacienda() throws {
    let (store, _) = try nativeStore()
    #expect(try store.memorySettings().engine == "native")
}

@Test func retainLearnsFactsEntitiesAndLinksAndOnlyRelearnsChangedChunks() async throws {
    let (store, space) = try nativeStore(), luna = ScriptedLuna()
    let engine = NativeMemoryEngine(store: store, inference: luna, models: models)
    let first = String(repeating: "Background paragraph about the studio. ", count: 90)
    let content = first + "\n\nfact: Kim records nine cameras at 40 FPS | entities: Kim, cameras\nfact: Assistant reported zero dropped frames on Kim | entities: Kim"
    try store.enqueueMemoryDocument(id: "doc", content: content, source: "Codex thread t", at: Date(), spaceID: space)
    #expect(try await engine.retainNext())
    #expect(try await !engine.retainNext())
    let units = try store.memoryUnits(spaceID: space)
    #expect(units.count == 2)
    #expect(Set(units.map(\.kind)) == [.world, .experience])
    #expect(units.allSatisfy { $0.context == "Codex thread t" && $0.vector.count == MemoryModels.dimensions })
    let names = try store.memoryEntityNames(unitIDs: units.map(\.id))
    #expect(names.values.flatMap { $0 }.filter { $0 == "Kim" }.count == 2, "both facts resolve to one Kim entity")
    let extractions = luna.extractions
    #expect(extractions >= 2, "the long source has several chunks")

    // Only the changed chunk goes back to Luna; facts of the unchanged chunk keep their identity.
    try store.enqueueMemoryDocument(id: "doc", content: first + "\n\nfact: Kim records nine cameras at 60 FPS | entities: Kim", source: "Codex thread t", at: Date(), spaceID: space)
    #expect(try await engine.retainNext())
    #expect(luna.extractions == extractions + 1)
    let after = try store.memoryUnits(spaceID: space)
    #expect(after.map(\.text) == ["Kim records nine cameras at 60 FPS"])
    #expect(try store.nativeMemoryStatus(spaceID: space).waiting == 0)
}

@Test func consolidationBuildsAndUpdatesObservationsThatRecallPrefers() async throws {
    let (store, space) = try nativeStore(), luna = ScriptedLuna()
    let engine = NativeMemoryEngine(store: store, inference: luna, models: models)
    try store.enqueueMemoryDocument(id: "a", content: "fact: User chose the Apache-2.0 license for Facienda | entities: user, Facienda, Apache-2.0", source: "Facienda task 1", at: Date(), spaceID: space)
    #expect(try await engine.retainNext())
    #expect(try await engine.consolidateNext())
    var observations = try store.memoryUnits(spaceID: space, kinds: [.observation])
    #expect(observations.count == 1 && observations[0].proofCount == 1)

    try store.enqueueMemoryDocument(id: "b", content: "fact: User chose Apache-2.0 for Facienda again | entities: user, Facienda", source: "Facienda task 2", at: Date(), spaceID: space)
    #expect(try await engine.retainNext())
    #expect(try await engine.consolidateNext())
    #expect(try await !engine.consolidateNext())
    observations = try store.memoryUnits(spaceID: space, kinds: [.observation])
    #expect(observations.count == 1)
    #expect(observations[0].proofCount == 2 && observations[0].text.hasSuffix("Confirmed again."))

    let response = try await MemoryRecall(store: store, models: models).recall("Which license did we pick?", spaceID: space)
    let results = try #require(response["results"].array)
    #expect(results.first?["type"].string == "observation")
    #expect(results.first?["source_fact_ids"].array?.count == 2)
    #expect(!results.contains { $0["type"].string == "world" }, "facts cited by a returned observation are left out")
    #expect(response["source_facts"].object?.count == 2)
}

@Test func memoryServiceUsesBuiltInRecallWithHindsightsShape() async throws {
    let (store, space) = try nativeStore()
    try store.saveMemorySettings(endpoint: try store.memorySettings().endpoint, enabled: true, workerModel: nil)
    try store.enqueueMemoryDocument(id: "a", content: "fact: Example server lost a power supply | entities: Example server, power supply", source: "Facienda task 1", at: Date(), spaceID: space)
    let service = WorkspaceMemoryService(store: store, inference: ScriptedLuna())
    try await service.synchronize()
    let context = try await service.context(query: "why is the example server throttled", spaceID: space)
    #expect(context["status"].string?.hasPrefix("Learned context") == true)
    #expect(context["learned"]["results"].array?.isEmpty == false)
    #expect(context["userConfirmed"].array != nil)
}

@Test func queryDatesFindThePeriodAsked() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15))!
    let yesterday = try #require(MemoryQueryDates.window(in: "what happened yesterday", now: now))
    #expect(calendar.component(.day, from: yesterday.start) == 11 && yesterday.duration == 86_400)
    let march = try #require(MemoryQueryDates.window(in: "plans from March 2026", now: now))
    #expect(calendar.component(.month, from: march.start) == 3)
    #expect(try #require(MemoryQueryDates.window(in: "on 2026-10-06", now: now)).duration == 86_400)
    #expect(MemoryQueryDates.window(in: "which camera is broken", now: now) == nil)
}

@Test func entityResolutionFollowsHindsightsRules() {
    #expect(!MemoryEntityResolver.compatible("Camera 1", "Camera 2"))
    #expect(MemoryEntityResolver.compatible("Example", "Example server"))
    #expect(abs(MemoryEntityResolver.ratio("abcd", "bcde") - 0.75) < 0.001)
    let canonical = MemoryEntityResolver.canonicalNames(["Orbit Stack", "orbit stack", "Orbit-Stack", "Kim"])
    #expect(canonical["orbit-stack"] == canonical["orbit stack"])
    #expect(canonical["kim"] == "Kim")
}

@Test func chunkerKeepsTextAndBreaksAtParagraphs() {
    let text = String(repeating: "a", count: 2_000) + "\n\n" + String(repeating: "b", count: 2_000)
    let chunks = MemoryChunker.split(text)
    #expect(chunks.count == 2 && chunks[0].allSatisfy { $0 == "a" } && chunks[1].allSatisfy { $0 == "b" })
    #expect(MemoryChunker.split("short") == ["short"])
    #expect(MemoryChunker.split(chunks.joined(separator: "\n\n")) == chunks, "re-chunking is stable")
}

@Test func sourcesKnowTheirTaskAndWhoSpoke() throws {
    let (store, _) = try nativeStore()
    let task = try store.create(FaciendaTask(title: "Ship the release"))
    let reply = TaskEvent(taskId: task.id, source: .user, kind: "user.reply", payload: "Use Apache")
    let report = TaskEvent(taskId: task.id, source: .mcp, kind: "codex.result", payload: "Done")
    try store.db.write { db in try reply.insert(db); try report.insert(db) }
    let decision = try store.requestDecision(Decision(taskId: task.id, question: "License?", recommendation: "Apache-2.0", options: ["Apache-2.0", "MIT"]))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "thread-abc"))
    let sources = try store.db.read { db in
        try [("task-" + task.id, "User's original request: x"), ("event-" + reply.id, "User statement: x"), ("event-" + report.id, "Assistant report: x"),
             ("decision-" + decision.id, "Question: x"), ("thread-thread-abc-turn-1-item-2", "User statement: x"), ("thread-other-turn-1-item-2", "Assistant report: x")]
            .map { try FaciendaStore.memorySource(db, documentID: $0.0, content: $0.1) }
    }
    #expect(sources.map(\.taskID) == [task.id, task.id, task.id, task.id, task.id, nil])
    #expect(sources.map(\.level) == [.user, .user, .assistant, .decision, .user, .assistant])
}

@Test func learnedFactsCarryLevelKindAndTask() async throws {
    let (store, space) = try nativeStore(), luna = ScriptedLuna()
    let task = try store.create(FaciendaTask(title: "Ship the release"))
    try store.enqueueMemoryDocument(id: "task-" + task.id, content: "User's original request:\nfact: User prefers HTML mocks for design questions | entities: user",
                                    source: "Facienda task", at: Date(), spaceID: space)
    try await NativeMemoryEngine(store: store, inference: luna, models: models).synchronize()
    let fact = try #require(try store.memoryUnits(spaceID: space, kinds: [.world]).first)
    #expect(fact.level == "user" && fact.taskId == task.id && fact.memoryKind == "preference")
    let observation = try #require(try store.memoryUnits(spaceID: space, kinds: [.observation]).first)
    #expect(observation.level == "user" && observation.taskId == task.id && observation.memoryKind == "project")
}

@Test func notesAreSearchableMemoriesThatFollowEdits() async throws {
    let (store, space) = try nativeStore()
    let engine = NativeMemoryEngine(store: store, inference: ScriptedLuna(), models: models)
    var note = MemoryFact(kind: "preference", text: "Always answer in English", source: "user")
    note.confirmedAt = Date(); note.spaceId = space
    try store.remember(note, source: .user)
    let saved = note
    try await engine.syncNotes()
    var unit = try #require(try store.memoryUnits(ids: ["note-" + saved.id]).first)
    #expect(unit.level == "note" && unit.memoryKind == "preference" && unit.consolidatedAt != nil)
    try store.correctMemory(saved.id, text: "Always answer in English or German")
    let corrected = try #require(try store.memory(spaceID: space).first { $0.text == "Always answer in English or German" })
    try await engine.syncNotes()
    #expect(try store.memoryUnits(ids: ["note-" + saved.id]).isEmpty)
    unit = try #require(try store.memoryUnits(ids: ["note-" + corrected.id]).first)
    #expect(unit.text == "Always answer in English or German")
    let recall = try await MemoryRecall(store: store, models: models).recall("which language should replies use", spaceID: space)
    #expect(recall["results"].array?.first?["level"].string == "note")
}

@Test func theTasksOwnMemoriesRankFirst() async throws {
    let (store, space) = try nativeStore(), luna = ScriptedLuna()
    let mine = try store.create(FaciendaTask(title: "Deploy the portal")), other = try store.create(FaciendaTask(title: "Fix the mapper"))
    let report = TaskEvent(taskId: other.id, source: .mcp, kind: "codex.result", payload: "")
    try await store.db.write { db in try report.insert(db) }
    try store.enqueueMemoryDocument(id: "event-" + report.id, content: "Assistant report, not independently verified:\nfact: Assistant reported the portal deploy should use port 8443 | entities: portal",
                                    source: "Facienda event", at: Date(), spaceID: space)
    try store.enqueueMemoryDocument(id: "task-" + mine.id, content: "User's original request:\nfact: The portal deploy must use port 8443 | entities: portal",
                                    source: "Facienda task", at: Date(), spaceID: space)
    let engine = NativeMemoryEngine(store: store, inference: luna, models: models)
    while try await engine.retainNext() {}
    var options = MemoryRecallOptions()
    options.taskID = mine.id; options.preferObservations = false
    let hits = try await MemoryRecall(store: store, models: models).rank("which port does the portal deploy use", spaceID: space, options: options)
    #expect(hits.first?.unit.level == "user" && hits.first?.unit.taskId == mine.id)
}

@Test func statusFadesWithinWeeksWhilePreferencesStay() {
    #expect(MemoryKind.recency(.status, age: 60) < 0.3)
    #expect(MemoryKind.recency(.project, age: 28) > 0.8)
    #expect(MemoryKind.recency(.preference, age: 400) == MemoryKind.recency(.preference, age: 1))
}

@Test func promptsGetOneLinePerMemory() throws {
    let learned = JSONValue.object(["results": .array([
        .object(["id": .string("u1"), "text": .string("Facienda will use Apache-2.0."), "type": .string("world"), "level": .string("decision"),
                 "kind": .string("decision"), "occurred_start": .null, "mentioned_at": .string("2026-10-12T14:00:00.000Z")]),
        .object(["id": .string("note-n1"), "text": .string("Duplicate of a note"), "type": .string("world"), "level": .string("note")]),
        .object(["id": .string("o1"), "text": .string("Kim records at 40 FPS."), "type": .string("observation"),
                 "source_fact_ids": .array([.string("a"), .string("b")]), "mentioned_at": .string("2026-10-09T10:00:00.000Z")]),
    ])])
    let text = MemoryPromptFormat.learned(learned, skipping: ["n1"])
    #expect(text == "- [you decided · 12 Oct 2026 · decision] Facienda will use Apache-2.0.\n- [9 Oct 2026 · 2 sources] Kim records at 40 FPS.")
    let tool = MemoryPromptFormat.toolResult(.object(["memory": .string("Work"), "status": .string("ok"), "learned": learned,
                                                       "userConfirmed": .array([.object(["id": .string("n1"), "kind": .string("fact"), "text": .string("A note")])])]))
    #expect(tool["learned"].array?.count == 2)
    #expect(tool["learned"].array?.first?["level"].string == "decision")
    #expect(tool["confirmedNotes"].array?.count == 1)
}

@Test func promptsSkipMemoriesTheLearnerWroteInAnotherScript() throws {
    #expect(WritingScript.alike("Ein Satz auf Deutsch", "an English request"))
    #expect(!WritingScript.alike("Codex-ում դեռ կա հին նախագիծը։", "why is the agent helpless"))
    #expect(WritingScript.alike("2026-10-13", "Почему"))
    let learned = JSONValue.object(["results": .array([
        .object(["id": .string("a"), "text": .string("The runner lives in the library project."), "type": .string("world")]),
        .object(["id": .string("b"), "text": .string("По отчёту ассистента, эффекты реализованы."), "type": .string("world")]),
    ])])
    #expect(MemoryPromptFormat.learned(learned, writtenLike: "explore why the agent feels helpless") == "- The runner lives in the library project.")
    #expect(MemoryPromptFormat.learned(learned).split(separator: "\n").count == 2)
}
