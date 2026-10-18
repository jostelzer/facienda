import Foundation
import Testing
@testable import FaciendaCore

private actor InferenceTraffic {
    var started: [String] = []
    var peak = 0
    var overlappingSlot = false
    private var active: Set<Int> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var released = false

    func call(_ user: String, slot: Int) async throws -> String {
        if !active.insert(slot).inserted { overlappingSlot = true }
        peak = max(peak, active.count)
        started.append(user)
        defer { active.remove(slot) }
        if !released { await withCheckedContinuation { gates[user] = $0 } }
        try Task.checkCancellation()
        if user == "failure" { throw StoreError.invalid("Invented worker failure") }
        return user
    }

    func release(_ user: String) { gates.removeValue(forKey: user)?.resume() }
    func releaseAll() {
        released = true
        let pending = gates; gates.removeAll()
        for continuation in pending.values { continuation.resume() }
    }
}

private struct TrafficWorker: MemoryInference {
    let traffic: InferenceTraffic
    let slot: Int
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        try await traffic.call(user, slot: slot)
    }
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(await predicate())
}

@Test func memoryPoolCapsCallsAndGivesQuestionsTheNextSlot() async throws {
    let traffic = InferenceTraffic()
    let pool = MemoryInferencePool(workers: (0..<4).map { TrafficWorker(traffic: traffic, slot: $0) })
    defer { Task { await traffic.releaseAll(); await pool.stop() } }
    let active = (0..<4).map { index in Task { try await pool.complete(system: "", user: "active-\(index)", schema: .null) } }
    try await eventually { await traffic.started.count == 4 }
    let background = (0..<6).map { index in Task { try await pool.complete(system: "", user: "background-\(index)", schema: .null) } }
    try await eventually { await pool.waitingCount == 6 }
    let question = Task { try await pool.complete(system: "", user: "question", schema: .null, priority: .interactive) }
    try await eventually { await pool.waitingCount == 7 }
    await traffic.release("active-0")
    try await eventually { await traffic.started.count == 5 }
    #expect(await traffic.started.last == "question")
    #expect(await traffic.peak == 4)
    await traffic.releaseAll()
    for task in active + background { _ = try await task.value }
    #expect(try await question.value == "question")
    #expect(await !traffic.overlappingSlot)
    #expect(await pool.waitingCount == 0)
}

@Test func memoryPoolCancellationFailureAndShutdownReleaseWaitersAndSlots() async throws {
    let traffic = InferenceTraffic()
    let pool = MemoryInferencePool(workers: [TrafficWorker(traffic: traffic, slot: 0)])
    defer { Task { await traffic.releaseAll(); await pool.stop() } }
    let active = Task { try await pool.complete(system: "", user: "active", schema: .null) }
    try await eventually { await traffic.started.count == 1 }
    let cancelled = Task { try await pool.complete(system: "", user: "cancelled", schema: .null, priority: .interactive) }
    try await eventually { await pool.waitingCount == 1 }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await pool.waitingCount == 0)
    let next = Task { try await pool.complete(system: "", user: "next", schema: .null) }
    try await eventually { await pool.waitingCount == 1 }
    active.cancel()
    await traffic.release("active")
    await #expect(throws: CancellationError.self) { try await active.value }
    try await eventually { await traffic.started.count == 2 }
    #expect(await traffic.started == ["active", "next"])
    let stopped = Task { try await pool.complete(system: "", user: "stopped", schema: .null) }
    try await eventually { await pool.waitingCount == 1 }
    await pool.stop()
    await #expect(throws: CancellationError.self) { try await stopped.value }
    await traffic.releaseAll()
    #expect(try await next.value == "next")
    await #expect(throws: CancellationError.self) { try await pool.complete(system: "", user: "after-stop", schema: .null) }

    let recovering = MemoryInferencePool(workers: [TrafficWorker(traffic: traffic, slot: 0)])
    await #expect(throws: (any Error).self) { try await recovering.complete(system: "", user: "failure", schema: .null) }
    #expect(try await recovering.complete(system: "", user: "recovered", schema: .null) == "recovered")
}
