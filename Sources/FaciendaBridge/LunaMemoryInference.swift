import Foundation
import FaciendaCore

/// Built-in memory's model calls in the app: the chosen background model, a fresh hidden conversation per call.
public actor LunaMemoryInference: MemoryInference {
    private let workers: [MemoryBackgroundWorker]
    private let pool: MemoryInferencePool

    public init() {
        let workers = (0..<MemoryInferencePool.parallelism).map { _ in MemoryBackgroundWorker() }
        self.workers = workers
        pool = MemoryInferencePool(workers: workers)
    }

    public func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        try await complete(system: system, user: user, schema: schema, priority: .background)
    }

    public func complete(system: String, user: String, schema: JSONValue, priority: MemoryInferencePriority) async throws -> String {
        try await pool.complete(system: system, user: user, schema: schema, priority: priority)
    }

    public func shutdown() async {
        await pool.stop()
        await withTaskGroup(of: Void.self) { group in
            for worker in workers { group.addTask { await worker.shutdown() } }
        }
    }
}

/// Separate clients keep turn notifications, cancellation and ephemeral permissions isolated between slots.
private struct MemoryBackgroundWorker: MemoryInference {
    private let luna = BackgroundModel()

    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        let request = try Self.request(system: system, user: user, schema: schema)
        try await luna.warm()
        try Task.checkCancellation()
        let thread = try await luna.open(EphemeralMemoryInference.profile)
        do {
            try Task.checkCancellation()
            let reply = try await luna.ask(thread, text: request.request.json, schema: schema, effort: MemoryInferenceRequest.reasoningEffort, timeout: .seconds(600))
            try request.validate(reply)
            await luna.close(thread)
            return reply
        } catch {
            await luna.close(thread)
            throw error
        }
    }

    func shutdown() async { await luna.shutdown() }
}
