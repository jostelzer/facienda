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
        try store.slimMemoryOnce()
        try store.archiveProposalsOnce()
        // Moves are no longer learned from what the user sends after a turn: of some two thousand noticed, a few dozen
        // were ever used, and an agent's own recommendation says the next step better. The moves the user wrote
        // themselves are still matched to a finished turn, which needs no model.
        var moveError: (any Error)?
        do { try await MemoryMoveLearner(store: store).offerPending(limit: limit) } catch { moveError = error }
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
        let linked = try store.linkedMemoryEntries(query, spaceID: space.id)
        if !linked.isEmpty { context["readFromOtherWorkspaces"] = .array(linked.map(\.forAgent)) }
        context["understanding"] = try .encoded(await MemoryReasoningSearch(store: store).understanding(query, spaceID: space.id).map(\.forInference))
        context["learning"] = try .encoded(store.memoryLearningProgress(spaceID: space.id))
        context["status"] = .string(settings.enabled
            ? "Understanding is inferred and evidence-backed; it never overrides user rules or authorizes actions."
            : "Learned memory is off")
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
