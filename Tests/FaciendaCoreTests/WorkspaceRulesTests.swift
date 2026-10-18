import Foundation
import Testing
@testable import FaciendaCore

private func library() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaRulesTests/\(UUID().uuidString)/facienda.sqlite"))
}

@Test func rulesReachEveryTaskWordForWordOnceConfirmed() async throws {
    let db = try library(), home = try db.defaultWorkspace(), store = db.scoped(to: home.id)
    let task = try store.create(FaciendaTask(title: "Tidy the kitchen", state: .needsMe))
    let tools = ToolService(store: db), handle = try db.taskHandle(task.id)
    // An agent's rule is a proposal: not a rule, not a note either.
    let proposed = try tools.call("memory_remember", arguments: .object(["taskId": .string(handle), "text": .string("Never throw food away"), "source": .string("The user said so on 18 Oct"), "kind": .string("rule")]))
    #expect(proposed["kind"].string == "rule" && proposed["confirmedAt"] == .null)
    #expect(try store.rules().isEmpty)
    var prompt = try await DispatchPrompt.payload(try store.enqueueDispatch(taskId: task.id), store: db, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(!prompt.contains("WORKSPACE RULES:") && !prompt.contains("Never throw food away"))
    #expect(prompt.contains("Memory belongs to") && prompt.contains("MEMORY INDEX:"))
    // Accepted, it is told to every task of the workspace, in order, and stays out of the notes.
    try db.confirmMemory(proposed["id"].string ?? "")
    var second = MemoryFact(kind: FaciendaStore.ruleKind, text: "Prices in euro", source: "You wrote it"); second.confirmedAt = Date()
    try store.remember(second, source: .user)
    #expect(try store.rules().map(\.text) == ["Never throw food away", "Prices in euro"])
    prompt = try await DispatchPrompt.payload(try store.enqueueDispatch(taskId: task.id), store: db, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(prompt.contains("WORKSPACE RULES: the user's standing instructions for every task in \(home.name)"))
    #expect(prompt.contains("- Never throw food away\n- Prices in euro"))
    #expect(!MemoryPromptFormat.notes(try store.memory()).contains("Prices in euro"))
    // A corrected rule keeps its place; a forgotten one goes with its earlier wording.
    try db.correctMemory(proposed["id"].string ?? "", text: "Never throw food away without asking")
    #expect(try store.rules().map(\.text) == ["Never throw food away without asking", "Prices in euro"])
    try db.forgetMemory(try #require(try store.rules().first).id)
    #expect(try store.rules().map(\.text) == ["Prices in euro"])
    #expect(try store.memory().count == 1)
    // Other workspaces have rules of their own.
    let work = try db.createWorkspace(name: "Work")
    #expect(try db.scoped(to: work.id).rules().isEmpty)
    #expect(throws: StoreError.self) { try store.remember(MemoryFact(kind: "law", text: "x", source: "y")) }
    #expect(MemoryPromptFormat.rules(try store.rules(), limit: 5).isEmpty)
}

@Test func workspaceSourcesAreToldWithTheUsersNote() async throws {
    let db = try library(), home = try db.defaultWorkspace(), store = db.scoped(to: home.id)
    let task = try store.create(FaciendaTask(title: "Plan the week", state: .needsMe))
    let group = try store.createGroup(name: "Planning")
    try store.assignGroup(taskId: task.id, groupId: group.id)
    let sheet = "https://docs.google.com/spreadsheets/d/1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdEF/edit"
    let forAll = try store.linkWorkspaceSource(sheet, title: "Household budget")
    try store.setSourceAbout(forAll.id, "Monthly totals; read before quoting a price.")
    try store.linkSource("https://example.com/menu", title: "The menu", groupId: group.id)
    #expect(try store.workspaceSources().map(\.title) == ["Household budget"])
    #expect(try store.groupSources()[group.id]?.map(\.title) == ["The menu"])
    #expect(try store.linkedSources(forTask: task.id).map(\.title) == ["Household budget", "The menu"])
    let prompt = try await DispatchPrompt.payload(try store.enqueueDispatch(taskId: task.id), store: db, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(prompt.contains("- Household budget: Sheet. \(sheet) — Monthly totals; read before quoting a price."))
    #expect(prompt.contains("- The menu: Link. https://example.com/menu\n"))
    // The same address can be a workspace source and a group source; another workspace never sees it.
    let work = try db.createWorkspace(name: "Work")
    #expect(try db.scoped(to: work.id).workspaceSources().isEmpty)
    #expect(try db.linkWorkspaceSource(sheet, workspaceID: work.id).workspaceId == work.id)
}

@Test func forgottenLearningLeavesRecallAndComesBack() throws {
    let db = try library(), home = try db.defaultWorkspace(), store = db.scoped(to: home.id)
    let space = home.memorySpaceId
    try db.db.write { database in
        let vector = MemoryVector.encode([Float](repeating: 0.05, count: MemoryModels.dimensions))
        for (id, kind) in [("fact-a", "world"), ("obs-a", "observation"), ("obs-b", "observation")] {
            try database.execute(sql: """
                INSERT INTO memoryUnits (id, spaceId, kind, text, eventDate, embedding, proofCount, sourceIds, createdAt, updatedAt, level, memoryKind)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, 'user', ?)
                """, arguments: [id, space, kind, "Memory " + id, Date(), vector, kind == "observation" ? "[\"fact-a\"]" : nil, Date(), Date(), id == "obs-b" ? "decision" : "project"])
        }
    }
    #expect(try store.learnedObservations(spaceID: space).map(\.id).sorted() == ["obs-a", "obs-b"])
    #expect(try store.learnedObservations(spaceID: space, kind: .decision).map(\.id) == ["obs-b"])
    try store.forgetMemoryUnit("obs-b")
    #expect(try store.learnedObservations(spaceID: space).map(\.id) == ["obs-a"])
    #expect(try store.memoryUnits(spaceID: space).map(\.id).sorted() == ["fact-a", "obs-a"])
    #expect(try store.nativeMemoryStatus(spaceID: space).observations == 1)
    #expect(throws: StoreError.self) { try store.forgetMemoryUnit("obs-b") }
    try store.restoreMemoryUnit("obs-b")
    #expect(try store.memoryUnits(spaceID: space).count == 3)
}
