import Foundation

public enum MemoryInferencePriority: Sendable {
    case background, interactive
}

/// Each slot owns its worker. Questions take the next free slot; running evidence reviews are not interrupted.
public actor MemoryInferencePool: MemoryInference {
    public static let parallelism = 4
    private let workers: [any MemoryInference]
    private var available: [Int]
    private struct Waiter {
        let id: UUID
        let priority: MemoryInferencePriority
        let continuation: CheckedContinuation<Int, any Error>
    }
    private var waiting: [Waiter] = []
    private var stopped = false
    var waitingCount: Int { waiting.count }

    public init(workers: [any MemoryInference]) {
        precondition(!workers.isEmpty && workers.count <= Self.parallelism)
        self.workers = workers
        available = Array(workers.indices)
    }

    public func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        try await complete(system: system, user: user, schema: schema, priority: .background)
    }

    public func complete(system: String, user: String, schema: JSONValue, priority: MemoryInferencePriority) async throws -> String {
        let id = UUID()
        let slot: Int = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                if stopped { continuation.resume(throwing: CancellationError()) }
                else if !available.isEmpty { continuation.resume(returning: available.removeFirst()) }
                else { waiting.append(Waiter(id: id, priority: priority, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        defer { release(slot) }
        try Task.checkCancellation()
        let reply = try await workers[slot].complete(system: system, user: user, schema: schema, priority: priority)
        try Task.checkCancellation()
        return reply
    }

    /// The owner shuts down active workers separately. No queued request may start during shutdown.
    public func stop() {
        stopped = true
        let pending = waiting; waiting.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ slot: Int) {
        guard !waiting.isEmpty else { available.append(slot); return }
        let index = waiting.firstIndex { $0.priority == .interactive } ?? waiting.startIndex
        waiting.remove(at: index).continuation.resume(returning: slot)
    }
}
