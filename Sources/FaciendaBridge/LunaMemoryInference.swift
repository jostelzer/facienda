import Foundation
import FaciendaCore

/// Built-in memory's model calls in the app: the chosen background model, a fresh hidden conversation per call.
public actor LunaMemoryInference: MemoryInference {
    private let luna = BackgroundModel()
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        // One Luna turn at a time; later calls wait their turn instead of failing.
        if running { await withCheckedContinuation { waiting.append($0) } }
        running = true
        defer { if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() } }
        let request = try Self.request(system: system, user: user, schema: schema)
        try await luna.warm()
        let thread = try await luna.open(EphemeralMemoryInference.profile)
        defer { Task { await luna.close(thread) } }
        let reply = try await luna.ask(thread, text: request.request.json, schema: schema, effort: MemoryInferenceRequest.reasoningEffort, timeout: .seconds(600))
        try request.validate(reply)
        return reply
    }

    public func shutdown() async { await luna.shutdown() }
}
