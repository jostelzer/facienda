import Foundation

/// Typed capture, evidence-backed understanding and local discovery. Model work stays in the configured background worker.
public struct WorkspaceMemoryService: Sendable {
    public let store: FaciendaStore
    private let inference: (any MemoryInference)?
    public init(store: FaciendaStore, inference: (any MemoryInference)? = HelperMemoryInference.bundled()) {
        self.store = store; self.inference = inference
    }

    public func synchronize(limit: Int = 8) async throws {
        guard try store.memorySettings().enabled else { return }
        try store.captureWorkspaceMemory()
        var moveError: (any Error)?
        do {
            try await MemoryMoveLearner(store: store).learnPending(limit: max(24, limit))
            try await MemoryMoveLearner(store: store).offerPending(limit: limit)
        } catch { moveError = error }
        // Local situation matching must not hold up reading and understanding the conversations.
        try await forEachSpace(try store.memorySpaces()) { space in
            try store.prepareMemoryEvidence(spaceID: space.id)
            if try store.memorySettings().useAIWorker, let inference {
                try await MemoryReasoner(store: store, inference: inference).learn(spaceID: space.id, batches: 4)
            }
            try store.proposeMemoryCollections(spaceID: space.id)
        }
        if let moveError { throw moveError }
    }

    public func context(query: String, spaceID: String? = nil, taskID: String? = nil) async throws -> JSONValue {
        let settings = try store.memorySettings()
        let space = try store.resolvedMemorySpace(spaceID)
        let notes = try store.memory(spaceID: space.id).filter { $0.confirmedAt != nil }
        var context: [String: JSONValue] = ["memory": .string(space.name), "userConfirmed": try .encoded(notes), "bankId": .string(space.bankId)]
        context["entries"] = try .encoded(store.findMemoryEntries(query, spaceID: space.id))
        context["understanding"] = try .encoded(await MemoryReasoningSearch(store: store).understanding(query, spaceID: space.id).map(\.forInference))
        context["learning"] = try .encoded(store.memoryLearningProgress(spaceID: space.id))
        if try store.memoryWasMigrated(space.id) {
            context["status"] = .string("Understanding is inferred and evidence-backed; it never overrides user rules or authorizes actions. Entry proposals wait for acceptance.")
            return .object(context)
        }
        guard settings.enabled else { context["status"] = .string("Learned memory is off"); return .object(context) }
        do {
            let question = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Workspace preferences, decisions, procedures and useful lessons" : query
            var options = MemoryRecallOptions()
            options.taskID = taskID
            context["learned"] = try await MemoryRecall(store: store).recall(question, spaceID: space.id, options: options)
            context["status"] = .string("Learned context from the \(space.name) memory; inferred observations are not user-confirmed facts")
        } catch {
            context["status"] = .string("Learned memory unavailable; use confirmed notes and current task evidence")
            context["error"] = .string(error.localizedDescription)
        }
        return .object(context)
    }

    public func consolidate(spaceID: String? = nil) async throws {
        guard try store.memorySettings().enabled, try store.memorySettings().useAIWorker, let inference else { return }
        let spaces = try spaceID.map { [try store.memorySpace($0)] } ?? store.memorySpaces()
        try await forEachSpace(spaces) { space in
            try await MemoryReasoner(store: store, inference: inference).learn(spaceID: space.id, batches: 10)
        }
    }

    private func forEachSpace(_ spaces: [MemorySpace], operation: @escaping @Sendable (MemorySpace) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var remaining = spaces.makeIterator()
            for _ in 0..<MemoryInferencePool.parallelism {
                if let space = remaining.next() { group.addTask { try await operation(space) } }
            }
            while try await group.next() != nil {
                if let space = remaining.next() { group.addTask { try await operation(space) } }
            }
        }
    }
}
