import Foundation
import Testing
@testable import FaciendaCore

private func library(_ name: String) throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "handover-\(name)-\(UUID().uuidString)/tasks.sqlite"))
}

@Test func taskUpdateKeepsTheAgentsOwnWordsForTheRow() throws {
    let store = try library("tool")
    let task = try store.create(FaciendaTask(title: "Improve the board", state: .running))
    let tools = ToolService(store: store), handle = try store.taskHandle(task.id)
    func update(_ fields: [String: String]) throws {
        var arguments: [String: JSONValue] = ["taskId": .string(handle)]
        for (key, value) in fields { arguments[key] = .string(value) }
        _ = try tools.call("task_update", arguments: .object(arguments))
    }
    // Progress on its own leaves no line: there is nothing for the user to do yet.
    try update(["brief": "Reading the board code"])
    #expect(try store.handover(taskId: task.id) == nil)

    try update(["wants": "Pick one of the five row layouts", "tail": "row layouts",
                "recommendation": "Take layout A", "recommendationWhy": "It is the only one that fits a long name, and memory “restrained design” rules out the tilted ones",
                "recommendationReply": "A, build it and pass task_update", "alternatives": "Take layout C\nAsk for a sixth\nTake layout E", "recommendationMemory": "restrained design"])
    var handover = try #require(try store.handover(taskId: task.id))
    #expect(handover.line == "Pick one of the five row layouts")
    #expect(handover.outcome == nil && handover.tail == "row layouts")
    // The line the agent wrote is the task's next step too, so the row reads in its words before any recap is built.
    #expect(try store.task(task.id).nextAction == "Pick one of the five row layouts")
    // A reply the user sends as it stands keeps what it was written with; only the row's own lines lose markdown.
    #expect(handover.recommendation == "Take layout A" && handover.reply == "A, build it and pass task_update" && handover.memory == "restrained design")
    // Two alternatives at most, so the card can show them all.
    #expect(handover.alternatives == ["Take layout C", "Ask for a sixth"])

    // A progress update in between leaves the line and its recommendation standing.
    try update(["nextAction": "Build it"])
    #expect(try store.handover(taskId: task.id) == handover)

    // A new line replaces the whole handover: a recommendation written for an older line must not outlive it.
    try update(["outcome": "Built and installed, row A"])
    handover = try #require(try store.handover(taskId: task.id))
    #expect(handover.outcome == "Built and installed, row A" && handover.wants == nil)
    #expect(handover.recommendation == nil && handover.reply == nil && handover.alternatives.isEmpty)
    // The tail stands until the subject moves again.
    #expect(handover.tail == "row layouts")

    // What it wants outranks an outcome sent with it, and agent text is cut to length.
    try update(["wants": String(repeating: "x", count: 200), "outcome": "ignored"])
    handover = try #require(try store.handover(taskId: task.id))
    #expect(handover.outcome == nil && handover.wants?.count == TaskHandover.wantsLimit)

    try store.deleteTask(task.id)
    #expect(try store.handovers().isEmpty)
}

@Test func theAgentsNextStepStandsWhenItWroteOneThisTurn() throws {
    for wrote in [false, true] {
        let store = try library("turn")
        let task = try store.create(FaciendaTask(title: "Improve the board", state: .running, nextAction: "Mock five row layouts"))
        try store.link(ThreadLink(taskId: task.id, codexThreadId: "chat"))
        let began = Date().addingTimeInterval(-60)
        try store.observe(threadId: "chat", status: "active", source: .hook, verified: true, at: began)
        // The agent's handover for the turn that is ending, or one left over from an earlier turn.
        try store.saveHandover(taskId: task.id, { $0.wants = "Pick one of the five row layouts" }, replacing: true,
                               at: began.addingTimeInterval(wrote ? 30 : -600))
        if wrote { try store.update(task.id, source: .mcp) { $0.nextAction = "Pick one of the five row layouts" } }
        try store.observe(threadId: "chat", status: "idle", source: .hook, verified: true, at: Date())
        let after = try store.task(task.id)
        #expect(after.state == .needsMe)
        // Facienda's stock line is only for a turn that ended without saying anything.
        #expect(after.nextAction == (wrote ? "Pick one of the five row layouts" : "Review the latest Codex result"))
    }
}
