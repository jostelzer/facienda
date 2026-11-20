import Foundation
import Testing
@testable import FaciendaCore

private func library() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaRulesTests/\(UUID().uuidString)/facienda.sqlite"))
}

@Test func rulesReachEveryTaskWordForWordOnceConfirmed() async throws {
    let db = try library(), home = try db.defaultWorkspace(), store = db.scoped(to: home.id)
    let task = try store.create(FaciendaTask(title: "Tidy the kitchen", state: .needsMe))
    // An unconfirmed rule is not a rule, and not a note either.
    let proposed = MemoryFact(kind: FaciendaStore.ruleKind, text: "Never throw food away", source: "The user said so on 18 Oct")
    try store.remember(proposed)
    #expect(try store.rules().isEmpty)
    var prompt = try await DispatchPrompt.payload(try store.enqueueDispatch(taskId: task.id), store: db, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(!prompt.contains("WORKSPACE RULES:") && !prompt.contains("Never throw food away"))
    #expect(prompt.contains("MEMORY INDEX:"))
    // Accepted, it is told to every task of the workspace, in order, and stays out of the notes.
    try db.confirmMemory(proposed.id)
    var second = MemoryFact(kind: FaciendaStore.ruleKind, text: "Prices in euro", source: "You wrote it"); second.confirmedAt = Date()
    try store.remember(second, source: .user)
    #expect(try store.rules().map(\.text) == ["Never throw food away", "Prices in euro"])
    prompt = try await DispatchPrompt.payload(try store.enqueueDispatch(taskId: task.id), store: db, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(prompt.contains("WORKSPACE RULES: the user's standing instructions for every task in \(home.name)"))
    #expect(prompt.contains("- Never throw food away\n- Prices in euro"))
    // A corrected rule keeps its place; a forgotten one goes with its earlier wording.
    try db.correctMemory(proposed.id, text: "Never throw food away without asking")
    #expect(try store.rules().map(\.text) == ["Never throw food away without asking", "Prices in euro"])
    try db.forgetMemory(try #require(try store.rules().first).id)
    #expect(try store.rules().map(\.text) == ["Prices in euro"])
    #expect(try store.memory().count == 1)
    // Other workspaces have rules of their own.
    let work = try db.createWorkspace(name: "Work")
    #expect(try db.scoped(to: work.id).rules().isEmpty)
    #expect(throws: StoreError.self) { try store.remember(MemoryFact(kind: "law", text: "x", source: "y")) }
}

@Test func workspaceSourcesAreToldWithTheUsersNote() async throws {
    let db = try library(), home = try db.defaultWorkspace(), store = db.scoped(to: home.id)
    let task = try store.create(FaciendaTask(title: "Plan the week", state: .needsMe))
    let group = try store.createGroup(name: "Planning")
    try store.assignGroup(taskId: task.id, groupId: group.id)
    let sheet = "https://docs.google.com/spreadsheets/d/1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdEF/edit"
    let forAll = try store.linkWorkspaceSource(sheet, title: "Household budget")
    try store.setSourceAbout(forAll.id, "Monthly totals; read before quoting a price.")
    try store.linkWorkspaceSource("https://example.com/menu", title: "The menu")
    #expect(try store.workspaceSources().map(\.title) == ["Household budget", "The menu"])
    #expect(try store.linkedSources(forTask: task.id).map(\.title) == ["Household budget", "The menu"])
    let prompt = try await DispatchPrompt.payload(try store.enqueueDispatch(taskId: task.id), store: db, base: "facienda-mcp")["workerPrompt"].string ?? ""
    #expect(prompt.contains("- Household budget: Sheet. \(sheet) — Monthly totals; read before quoting a price."))
    #expect(prompt.contains("- The menu: Link. https://example.com/menu\n"))
    // Another workspace never sees it, and can link the same address itself.
    let work = try db.createWorkspace(name: "Work")
    #expect(try db.scoped(to: work.id).workspaceSources().isEmpty)
    #expect(try db.linkWorkspaceSource(sheet, workspaceID: work.id).workspaceId == work.id)
}
