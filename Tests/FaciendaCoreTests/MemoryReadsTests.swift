import Foundation
import Testing
@testable import FaciendaCore

/// Three invented workspaces: a small app, a household and a renovation, each with its own memory.
private func threeMemories() throws -> (store: FaciendaStore, studio: String, home: String, flat: String, task: FaciendaTask) {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "MemoryReads/\(UUID().uuidString)/test.sqlite"))
    let studio = try store.defaultWorkspace(), home = try store.createWorkspace(name: "Home"), flat = try store.createWorkspace(name: "Flat")
    let task = try store.scoped(to: studio.id).create(FaciendaTask(title: "Move the app to the new server"))
    func entry(_ space: String, _ shelf: MemoryShelf, _ subject: String, _ text: String) throws {
        _ = try store.writeMemoryEntry(MemoryEntry(spaceID: space, shelf: shelf, subject: subject, text: text, origin: .you, sources: ["Invented example"]))
    }
    try entry(home.memorySpaceId, .places, "Server", "Rented box called atlas, backups nightly at three")
    try entry(home.memorySpaceId, .people, "Accountant", "Ruth Ilse sends the quarter by mail")
    try entry(home.memorySpaceId, .rules, "Payments", "Never pay anything without asking")
    try entry(home.memorySpaceId, .places, "Domain", "Renewed each March at the registrar")
    try entry(studio.memorySpaceId, .places, "Domain", "The app uses its own domain, studio.example")
    try entry(flat.memorySpaceId, .people, "Plumber", "Herr Okafor comes on Tuesdays")
    return (store, studio.memorySpaceId, home.memorySpaceId, flat.memorySpaceId, task)
}

@Test func aMemoryReadsOnlyWhatTheUserLinkedAndNothingFurther() throws {
    let (store, studio, home, flat, task) = try threeMemories()
    let tools = ToolService(store: store), handle = try store.taskHandle(task.id)
    func found(_ text: String) throws -> [JSONValue] { try tools.call("memory_find", arguments: .object(["text": .string(text), "taskId": .string(handle)])).array ?? [] }
    #expect(try found("server").isEmpty)

    try store.setMemoryRead(reader: studio, source: home)
    // Home reads Flat, but Studio reading Home never reaches Flat.
    try store.setMemoryRead(reader: home, source: flat)
    let server = try found("server")
    #expect(server.count == 1 && server[0]["from"].string == "Home" && server[0]["readOnly"] == .bool(true))
    #expect(try found("plumber").isEmpty)
    // Rules stay home, and Studio's own entry on the same subject wins.
    #expect(try found("pay").isEmpty)
    let domains = try found("domain")
    #expect(domains.count == 1 && domains[0]["from"] == .null && domains[0]["text"].string?.contains("studio.example") == true)
    // One way only: Home does not read Studio.
    #expect(try store.linkedMemoryEntries("domain", spaceID: home).allSatisfy { $0.from == "Flat" })

    try store.removeMemoryRead(reader: studio, source: home)
    #expect(try found("server").isEmpty)
}

@Test func aLinkedEntryOpensButNeverItsWorkspacesEvidenceOrWrites() throws {
    let (store, studio, home, _, task) = try threeMemories()
    let tools = ToolService(store: store), handle = try store.taskHandle(task.id)
    let server = try #require(store.lentMemoryEntries(home).first { $0.subject == "Server" })
    let rule = try #require(store.memoryEntries(spaceID: home, states: [.live]).first { $0.shelf == .rules && $0.spaceId == home })
    func open(_ id: String) throws -> JSONValue { try tools.call("memory_open", arguments: .object(["id": .string(id), "taskId": .string(handle)])) }
    #expect(throws: StoreError.self) { try open(server.id) }

    try store.setMemoryRead(reader: studio, source: home)
    #expect(try open(server.id)["from"].string == "Home")
    #expect(throws: StoreError.self) { try open(rule.id) }
    // A proposal from a Studio task lands in Studio, never in the memory it reads.
    _ = try tools.call("memory_propose", arguments: .object(["shelf": .string("places"), "text": .string("The server moved to a new box"), "why": .string("Said today"), "taskId": .string(handle)]))
    #expect(try store.memoryEntries(spaceID: home).allSatisfy { $0.state == .live })
    #expect(try store.memoryEntries(spaceID: studio).contains { $0.state == .proposed })
}

@Test func theAgentIsToldWhichMemoriesItReads() throws {
    let (store, studio, home, _, task) = try threeMemories()
    let tools = ToolService(store: store)
    #expect(try tools.memoryInstructions(for: task).contains("reaches only this workspace"))
    #expect(try !store.memoryAgentContext(taskID: task.id, query: "server").index.contains("Also reads"))

    try store.setMemoryRead(reader: studio, source: home, understanding: true)
    #expect(try tools.memoryInstructions(for: task).contains("read-only, the memories of: Home (3 entries, with understanding)"))
    let index = try store.memoryAgentContext(taskID: task.id, query: "server")
    #expect(index.index.contains("Also reads, read-only: Home") && index.index.contains("(from Home)"))
    #expect(!index.rules.contains("Never pay"))
    #expect(try store.memoriesReading(home).map(\.id) == [studio])
}

@Test func onlyTheUserCanLinkMemories() throws {
    let (store, studio, _, _, _) = try threeMemories()
    #expect(throws: StoreError.self) { try store.setMemoryRead(reader: studio, source: studio) }
    // No agent tool links memories.
    let known = ["recall", "remember", "open", "find", "propose", "reflect"].map { "facienda_memory_" + $0 }
    #expect(ToolService.definitions.filter { $0.name.hasPrefix("facienda_memory_") }.allSatisfy { known.contains($0.name) })
}
