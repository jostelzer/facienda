import Foundation
import Testing
import GRDB
@testable import FaciendaCore

private func understandingLibrary() throws -> (FaciendaStore, String, FaciendaTask) {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "UnderstandingTests/\(UUID().uuidString)/test.sqlite"))
    let task = try store.create(FaciendaTask(title: "Invented greenhouse measurements"))
    try store.saveMemorySettings(enabled: true, workerModel: nil)
    return (store, try store.memorySpace(forTask: task.id).id, task)
}

private func source(_ store: FaciendaStore, _ space: String, _ id: String, _ text: String, at: TimeInterval = 100) throws {
    try store.captureUtterance(id: id, text: text, source: "Invented user conversation", kind: .userReply, taskID: nil, spaceID: space, at: Date(timeIntervalSince1970: at))
}

private actor UnderstandingWorker: MemoryInference {
    var calls = 0
    var inputs: [String] = []
    var rejectFirst = false
    var fail = false
    init(rejectFirst: Bool = false, fail: Bool = false) { self.rejectFirst = rejectFirst; self.fail = fail }
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        calls += 1; inputs.append(user)
        if fail { throw StoreError.invalid("Invented transient outage") }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        if value["INTERPRETATIONS"].array != nil {
            let reject = rejectFirst; rejectFirst = false
            return JSONValue.object(["verdicts": .array((value["INTERPRETATIONS"].array ?? []).indices.map {
                .object(["index": .number(Double($0)), "supported": .bool(!reject), "reason": .string(reject ? "Limit the claim to greenhouse measurements." : "Supported by the supplied user statements.")])
            })]).json
        }
        let sources = value["EVIDENCE"].array ?? []
        let existing = value["EXISTING"].array?.first
        let sourcesByDate = sources.sorted { ($0["at"].string ?? "") < ($1["at"].string ?? "") }
        let changed = sourcesByDate.last?["text"].string?.contains("instead") == true
        return JSONValue.object(["understanding": .array([.object([
            "existingId": existing?["id"] ?? .string(""), "kind": .string("process"), "subject": .string("Calibration before measurement"),
            "summary": .string(changed ? "Use the revised calibration reference before each batch." : "Establish the sensor baseline before interpreting a measurement batch."),
            "explanation": .string("The user relates unreliable readings to a missing baseline check."), "appliesWhen": .string("Greenhouse measurements"),
            "exceptions": .array([]), "questions": .array([]), "connections": .array([]), "confidence": .string("strong"),
            "steps": .array([.object(["action": .string("Calibrate against the reference"), "why": .string("Separate sensor drift from the thing being measured"), "check": .string("The reference reading agrees")])]),
            "citations": .array(sources.map { .object(["evidenceId": $0["id"], "quote": $0["text"]]) })
        ])])]).json
    }
}

@Test func understandingLearnsAcrossSourcesChecksEvidenceAndRevises() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "The greenhouse sensor drifted. Check its reference before the next batch.")
    try source(store, space, "two", "Calibrating first made our second batch interpretable.", at: 200)
    // Upgrades revisit user sources even when the previous quote keeper marked them complete.
    try await store.db.write { try $0.execute(sql: "UPDATE memoryUtterances SET keptAt = ? WHERE id = 'one'", arguments: [Date()]) }
    let worker = UnderstandingWorker(rejectFirst: true)
    let engine = MemoryReasoner(store: store, inference: worker)
    let progress = try await engine.learn(spaceID: space)
    #expect(progress.processed == 2 && progress.pending == 0)
    #expect(await worker.calls == 4) // draft, independent rejection, corrected draft, review
    let first = try #require(store.memoryUnderstanding(spaceID: space).first)
    #expect(first.kind == .process && first.steps.count == 1 && first.citations.count == 2)
    #expect(first.confidence == "supported")
    #expect(first.summary != "Calibrating first made our second batch interpretable.")
    try source(store, space, "three", "Use the new reference instead of the old reference for calibration.", at: 300)
    try await engine.learn(spaceID: space)
    let updated = try #require(store.memoryUnderstanding(spaceID: space).first)
    #expect(updated.id == first.id && updated.revision == 2 && updated.summary.contains("revised"))
    #expect(try store.memoryUnderstandingHistory(first.id, spaceID: space).first?.snapshot.summary == first.summary)
    #expect(try store.memoryEntries(spaceID: space, states: [.live]).isEmpty) // inferred understanding never becomes a rule
}

@Test func understandingRejectsFabricatedQuotesAndCrossWorkspaceEvidence() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "Check the reference before measurement.")
    try store.prepareMemoryEvidence(spaceID: space)
    let evidence = try await store.db.read { try MemoryEvidence.fetchAll($0) }
    let draft = MemoryReasoner.Draft(existingId: "", kind: .process, subject: "Calibration", summary: "Check the reference first.", explanation: "", appliesWhen: "Measuring", exceptions: [], steps: [], questions: [],
                                    citations: [.init(evidenceId: evidence[0].id, quote: "A sentence the user never said")], connections: [], confidence: "supported")
    #expect(throws: (any Error).self) { try MemoryReasoner.validate([draft], evidence: evidence, existing: []) }
    #expect(throws: (any Error).self) { try MemoryReflector.validatedCitations([.init(evidenceId: "other-workspace", quote: evidence[0].text)], evidence: evidence) }
    let other = try store.createWorkspace(name: "Invented separate workshop")
    #expect(try store.memoryEvidence(evidence.map(\.id), spaceID: other.memorySpaceId).isEmpty)
    #expect(throws: (any Error).self) { try store.openMemoryReference("evidence:" + evidence[0].id, spaceID: other.memorySpaceId) }
}

@Test func understandingFailureBacksOffWithoutLosingSourcesAndRetries() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "Check the reference before measurement.")
    let failed = try await MemoryReasoner(store: store, inference: UnderstandingWorker(fail: true)).learn(spaceID: space)
    #expect(failed.pending == 1 && failed.retrying == 1 && failed.error != nil)
    #expect(try await store.db.read { try String.fetchOne($0, sql: "SELECT leaseOwner FROM memoryReasoningState WHERE spaceId = ?", arguments: [space]) } == nil)
    try store.retryMemoryLearning(spaceID: space)
    let retried = try await MemoryReasoner(store: store, inference: UnderstandingWorker()).learn(spaceID: space)
    #expect(retried.pending == 0 && retried.processed == 1)
}

@Test func reviewedUnderstandingWinsOverLaterInferenceAndDismissalPersists() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "Check the reference before measurement.")
    let engine = MemoryReasoner(store: store, inference: UnderstandingWorker())
    try await engine.learn(spaceID: space)
    let item = try #require(store.memoryUnderstanding(spaceID: space).first)
    let undo = try UndoStep.recording { try store.reviewMemoryUnderstanding(item.id, spaceID: space, summary: "Only calibrate this instrument after it warms up.") }
    try source(store, space, "two", "Check the reference before every greenhouse batch.", at: 200)
    try await engine.learn(spaceID: space)
    #expect(try store.memoryUnderstanding(spaceID: space).first?.summary == "Only calibrate this instrument after it warms up.")
    #expect(try store.memoryUnderstanding(spaceID: space).first?.state == .reviewed)
    _ = try store.replay(undo)
    try store.reviewMemoryUnderstanding(item.id, spaceID: space, dismiss: true)
    try source(store, space, "three", "Check the reference again today.", at: 300)
    try await engine.learn(spaceID: space)
    #expect(try store.memoryUnderstanding(spaceID: space).isEmpty)
}

@Test func evidencePreparationRedactsAndDoesNotPromoteAgentProposals() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "Use a reference. password is invented-secret")
    _ = try store.proposeMemoryEntry(spaceID: space, shelf: .rules, subject: "Unaccepted instruction", text: "Publish automatically", source: "An agent", reason: "Untrusted proposal")
    let worker = UnderstandingWorker()
    try await MemoryReasoner(store: store, inference: worker).learn(spaceID: space)
    #expect(await worker.inputs.allSatisfy { !$0.contains("invented-secret") && !$0.contains("Publish automatically") })
    let count = try await store.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memoryEvidence WHERE spaceId = ?", arguments: [space]) }
    #expect(count == 1)
}

private actor ReflectionWorker: MemoryInference {
    var calls = 0
    var priorities: [MemoryInferencePriority] = []
    func complete(system: String, user: String, schema: JSONValue, priority: MemoryInferencePriority) async throws -> String {
        priorities.append(priority)
        return try await complete(system: system, user: user, schema: schema)
    }
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        calls += 1
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        if input["ANSWER_TO_CHECK"].object != nil {
            return #"{"supported":true,"reason":"The answer is grounded in the supplied evidence."}"#
        }
        let evidence = input["USER_EVIDENCE"].array ?? []
        return JSONValue.object([
            "action": .string(calls == 1 ? "search" : "answer"), "queries": .array([.string("calibration reference changes")]), "evidenceIds": .array([]),
            "answer": .string(calls == 1 ? "" : "The process separates instrument drift from measurement changes by checking the reference first."),
            "nextMove": .string(calls == 1 ? "" : "Prepare a reference check before the next batch."), "uncertainties": .array([]),
            "citations": .array(calls == 1 ? [] : evidence.map { .object(["evidenceId": $0["id"], "quote": $0["text"]]) })
        ]).json
    }
}

@Test func reflectionSearchesThenAnswersWithScopedEvidence() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "Check the reference before measurement.")
    try store.prepareMemoryEvidence(spaceID: space)
    let worker = ReflectionWorker()
    let reflection = try await MemoryReflector(store: store, inference: worker).reflect("How should we prepare the next greenhouse batch?", spaceID: space)
    #expect(reflection.calls == 3 && !reflection.citations.isEmpty && reflection.answer.contains("drift"))
    #expect(await worker.priorities == [.interactive, .interactive, .interactive])
    #expect(reflection.evidence.allSatisfy { $0.spaceId == space })
    let other = try store.createWorkspace(name: "Invented other room")
    let empty = try await MemoryReflector(store: store, inference: worker).reflect("What is the greenhouse process?", spaceID: other.memorySpaceId)
    #expect(empty.calls == 0 && empty.citations.isEmpty && empty.nextMove.isEmpty)
}

private actor ParallelUnderstandingWorker: MemoryInference {
    var initialBatches: [[String]] = []
    var completions: [String] = []
    var rewrittenWithFreshContext = 0
    var initial: [Int: CheckedContinuation<Void, Never>] = [:]
    let parties: Int
    let failBatch: Int?
    init(parties: Int = 4, failBatch: Int? = nil) { self.parties = parties; self.failBatch = failBatch }

    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        if let drafts = value["INTERPRETATIONS"].array {
            return JSONValue.object(["verdicts": .array(drafts.indices.map {
                .object(["index": .number(Double($0)), "supported": .bool(true), "reason": .string("Invented fixture evidence supports this revision.")])
            })]).json
        }
        let sources = value["EVIDENCE"].array ?? []
        let existing = value["EXISTING"].array ?? []
        let ids = value["NEW_EVIDENCE_IDS"].array?.compactMap(\.string) ?? []
        let first = try #require(sources.first)
        // The first wave must overlap before any call returns. Later batches intentionally finish first.
        if existing.isEmpty && initialBatches.count < parties {
            let index = initialBatches.count
            initialBatches.append(ids)
            if initialBatches.count < parties { await withCheckedContinuation { initial[index] = $0 } }
            else {
                for i in (0..<(parties - 1)).reversed() { initial.removeValue(forKey: i)?.resume() }
            }
            if index == 0 { try await Task.sleep(for: .milliseconds(50)) }
            if index == failBatch { throw StoreError.invalid("Invented failure in one parallel batch") }
        } else if !existing.isEmpty { rewrittenWithFreshContext += 1 }
        let latest = try #require(sources.max { ($0["at"].string ?? "") < ($1["at"].string ?? "") })
        completions.append(first["id"].string ?? "")
        // These inputs all describe successive revisions of one subject, so stale drafts must be regenerated.
        let citations = [first, latest].map { JSONValue.object(["evidenceId": $0["id"], "quote": $0["text"]]) }
        return JSONValue.object(["understanding": .array([.object([
            "existingId": existing.first?["id"] ?? .string(""), "kind": .string("process"), "subject": .string("Invented reference procedure"),
            "summary": latest["text"], "explanation": .string("Each dated instruction revises the reference."), "appliesWhen": .string("Fixture measurements"),
            "exceptions": .array([]), "steps": .array([]), "questions": .array([]), "connections": .array([]), "confidence": .string("tentative"), "citations": .array(citations)
        ])])]).json
    }
}

@Test(.timeLimit(.minutes(1))) func parallelUnderstandingUsesDisjointBatchesAndReconcilesInDateOrder() async throws {
    let (store, space, _) = try understandingLibrary()
    for i in 0..<48 { try source(store, space, "parallel-\(i)", "For measurement use reference revision \(i).", at: Double(i + 100)) }
    let worker = ParallelUnderstandingWorker()
    let result = try await MemoryReasoner(store: store, inference: worker).learn(spaceID: space)
    #expect(result.processed == 48 && result.pending == 0 && result.retrying == 0)
    let batches = await worker.initialBatches
    #expect(batches.count == 4 && batches.allSatisfy { $0.count == 12 })
    #expect(Set(batches.flatMap { $0 }).count == 48)
    #expect(await worker.completions.first != batches[0][0])
    #expect(await worker.rewrittenWithFreshContext == 3)
    let models = try store.memoryUnderstanding(spaceID: space)
    #expect(models.count == 1 && models[0].revision == 4)
    #expect(models[0].summary == "For measurement use reference revision 47.")
    let history = try store.memoryUnderstandingHistory(models[0].id, spaceID: space)
    #expect(Set(history.map { $0.snapshot.summary }) == Set([11, 23, 35].map { "For measurement use reference revision \($0)." }))
    #expect(try await store.db.read { try String.fetchOne($0, sql: "SELECT leaseOwner FROM memoryReasoningState WHERE spaceId = ?", arguments: [space]) } == nil)
}

@Test(.timeLimit(.minutes(1))) func parallelUnderstandingFailureDoesNotDiscardSuccessfulBatches() async throws {
    let (store, space, _) = try understandingLibrary()
    for i in 0..<24 { try source(store, space, "partial-\(i)", "Reference instruction \(i).", at: Double(i + 100)) }
    let worker = ParallelUnderstandingWorker(parties: 2, failBatch: 0)
    let result = try await MemoryReasoner(store: store, inference: worker).learn(spaceID: space)
    #expect(result.processed == 12 && result.pending == 12 && result.retrying == 12)
    #expect(try store.memoryUnderstanding(spaceID: space).count == 1)
}

private actor CancelledUnderstandingWorker: MemoryInference {
    var calls = 0
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        calls += 1
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}

@Test func parallelUnderstandingCancellationLeavesSourcesPendingAndReleasesLease() async throws {
    let (store, space, _) = try understandingLibrary()
    for i in 0..<48 { try source(store, space, "cancel-\(i)", "Check invented reference \(i).") }
    let worker = CancelledUnderstandingWorker()
    let task = Task { try await MemoryReasoner(store: store, inference: worker).learn(spaceID: space) }
    defer { task.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await worker.calls < 4 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await worker.calls == 4)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let progress = try store.memoryLearningProgress(spaceID: space)
    #expect(progress.processed == 0 && progress.pending == 48 && progress.retrying == 0)
    #expect(try store.claimMemoryReasoning(spaceID: space, owner: "after-cancellation"))
}

@Test(.timeLimit(.minutes(1))) func parallelWorkspacesKeepUnderstandingAndEvidenceSeparate() async throws {
    let (store, space, _) = try understandingLibrary()
    let other = try store.createWorkspace(name: "Invented pottery group").memorySpaceId
    try source(store, space, "greenhouse", "The greenhouse uses a dry reference.")
    try source(store, other, "pottery", "The pottery group uses a fired test tile.")
    let worker = ParallelUnderstandingWorker(parties: 2)
    let pool = MemoryInferencePool(workers: [worker, worker, worker, worker])
    try await WorkspaceMemoryService(store: store, inference: pool).consolidate()
    #expect(await worker.initialBatches.count == 2)
    for (id, text) in [(space, "The greenhouse uses a dry reference."), (other, "The pottery group uses a fired test tile.")] {
        let model = try #require(store.memoryUnderstanding(spaceID: id).first)
        #expect(model.spaceId == id && model.summary == text)
        let sources = try store.memoryEvidence(model.citations.map(\.evidenceId), spaceID: id)
        #expect(sources.count == 1 && sources.allSatisfy { $0.spaceId == id && $0.text == text })
        #expect(try store.memoryLearningProgress(spaceID: id).pending == 0)
    }
}

private actor IndependentBatchWorker: MemoryInference {
    var evidence: [String] = []
    var active = 0
    var peak = 0
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        if input["EMPTY_RESULT"].bool == true {
            return #"{"verdicts":[{"index":0,"supported":true,"reason":"Only incidental requests, no durable pattern."}]}"#
        }
        evidence += input["NEW_EVIDENCE_IDS"].array?.compactMap(\.string) ?? []
        try await Task.sleep(for: .milliseconds(20))
        return #"{"understanding":[]}"#
    }
}

private actor EmptyUnderstandingWorker: MemoryInference {
    let recover: Bool
    private let worker = UnderstandingWorker()
    var drafts = 0
    var emptyReviews = 0
    init(recover: Bool) { self.recover = recover }
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        if input["EMPTY_RESULT"].bool == true {
            emptyReviews += 1
            return #"{"verdicts":[{"index":0,"supported":false,"reason":"The reference-check procedure has clear conditions and a reason."}]}"#
        }
        if input["INTERPRETATIONS"].array == nil {
            drafts += 1
            if drafts == 1 || !recover { return #"{"understanding":[]}"# }
        }
        return try await worker.complete(system: system, user: user, schema: schema)
    }
}

@Test func understandingReviewsEmptyResultsInsteadOfSilentlyDiscardingUsefulEvidence() async throws {
    for recover in [true, false] {
        let (store, space, _) = try understandingLibrary()
        try source(store, space, "useful", "Check the dry reference before each greenhouse batch. Stop if it has drifted, to avoid mistaking instrument error for plant changes.")
        let worker = EmptyUnderstandingWorker(recover: recover)
        let progress = try await MemoryReasoner(store: store, inference: worker).learn(spaceID: space)
        #expect(await worker.drafts == (recover ? 2 : 4))
        #expect(await worker.emptyReviews == (recover ? 1 : 4))
        #expect(progress.processed == (recover ? 1 : 0))
        #expect(progress.retrying == (recover ? 0 : 1))
        #expect(progress.understanding == (recover ? 1 : 0))
    }
}

@Test func parallelUnderstandingBoundsLongQueuesAndProcessesEverySourceOnce() async throws {
    let (store, space, _) = try understandingLibrary()
    for i in 0..<84 { try source(store, space, "wave-\(i)", "An invented incidental request numbered \(i).") }
    let worker = IndependentBatchWorker()
    let result = try await MemoryReasoner(store: store, inference: worker).learn(spaceID: space, batches: 7, parallelism: 50)
    #expect(result.processed == 84 && result.pending == 0 && result.understanding == 0)
    #expect(await worker.peak == 4)
    let seen = await worker.evidence
    #expect(seen.count == 84 && Set(seen).count == 84)
}

@Test func understandingSchemasAreClosedAndAllFieldsRequired() {
    func check(_ value: JSONValue) {
        if value["type"].string == "object" {
            #expect(value["additionalProperties"].bool == false)
            #expect(Set(value["required"].array?.compactMap(\.string) ?? []) == Set(value["properties"].object?.keys.map { $0 } ?? []))
        }
        for child in value.object?.values ?? [:].values { check(child) }
        for child in value.array ?? [] { check(child) }
    }
    check(MemoryReasoner.schema); check(MemoryReasoner.reviewSchema); check(MemoryReflector.schema); check(MemoryReflector.assessmentSchema)
}

private actor UnsupportedReflectionWorker: MemoryInference {
    let cite: Bool
    init(cite: Bool) { self.cite = cite }
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))
        if input["ANSWER_TO_CHECK"].object != nil {
            return #"{"supported":false,"reason":"The user never reported the outcome."}"#
        }
        let source = input["USER_EVIDENCE"].array!.first!
        return JSONValue.object([
            "action": .string("answer"), "queries": .array([]), "evidenceIds": .array([]),
            "answer": .string("The latest batch succeeded and doubled the yield."), "nextMove": .string(""),
            "uncertainties": .array([.string("The exact yield is unknown.")]),
            "citations": .array(cite ? [.object(["evidenceId": source["id"], "quote": source["text"]])] : [])
        ]).json
    }
}

@Test func reflectionDoesNotTreatRealQuotesOrUncertaintyAsProofOfInventedOutcome() async throws {
    let (store, space, _) = try understandingLibrary()
    try source(store, space, "one", "Check the reference before measurement.")
    try store.prepareMemoryEvidence(spaceID: space)
    for cite in [true, false] {
        let answer = try await MemoryReflector(store: store, inference: UnsupportedReflectionWorker(cite: cite))
            .reflect("Did the batch succeed?", spaceID: space, rounds: 2)
        #expect(!answer.answer.contains("doubled"))
        #expect(answer.citations.isEmpty && answer.nextMove.isEmpty && !answer.uncertainties.isEmpty)
        #expect(answer.calls == (cite ? 4 : 1))
    }
}

@Test func understandingLeasePreventsConcurrentWritersAndExpires() throws {
    let (store, space, _) = try understandingLibrary()
    try store.prepareMemoryEvidence(spaceID: space)
    let now = Date()
    #expect(try store.claimMemoryReasoning(spaceID: space, owner: "first", now: now))
    #expect(try !store.claimMemoryReasoning(spaceID: space, owner: "second", now: now))
    #expect(try store.claimMemoryReasoning(spaceID: space, owner: "second", now: now.addingTimeInterval(1801)))
    #expect(throws: (any Error).self) { try store.renewMemoryReasoning(spaceID: space, owner: "first") }
    try store.releaseMemoryReasoning(spaceID: space, owner: "first")
    #expect(try !store.claimMemoryReasoning(spaceID: space, owner: "third", now: now.addingTimeInterval(1802)))
}
