import Foundation
import Testing
import FaciendaCore
import FaciendaBridge

private func conversationBridge() async throws -> CodexBridge {
    let bridge = CodexBridge(maximumLineBytes: 1024 * 1024)
    let fixture = try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [fixture.path])
    return bridge
}

@Test func taskReadsKeepTheOriginalAndRecentTextWithoutLoadingLargeToolOutput() async throws {
    let bridge = try await conversationBridge()
    let original = "Original request\n" + String(repeating: "Exact wording. ", count: 30)
    let turns = (1...60).map { index -> JSONValue in
        let content: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(index == 1 ? original : "Follow-up \(index)")]),
            .object(["type": .string("localImage"), "path": .string("/tmp/reference.png")])
        ]
        let user: JSONValue = .object(["id": .string("user-\(index)"), "type": .string("userMessage"), "content": .array(content)])
        let tool: JSONValue = .object(["id": .string("tool-\(index)"), "type": .string("mcpToolCall"),
                                      "result": .string(index == 60 ? String(repeating: "x", count: 2 * 1024 * 1024) : "Tool output")])
        let answer: JSONValue = .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                                        "phase": .string(index == 60 ? "commentary" : "final_answer"),
                                        "text": .string("Exact answer \(index)\n[Source](https://example.org)")])
        return .object(["id": .string("turn-\(index)"), "status": .string(index == 60 ? "inProgress" : "completed"),
                        "startedAt": .number(Double(index)), "completedAt": index == 60 ? .null : .number(Double(index + 1)),
                        "items": .array([user, tool, answer])])
    }
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("large"), "response": .object([
        "thread": .object(["id": .string("large"), "name": .string("Large chat"), "turns": .array(turns)])
    ])]))
    #expect(try await ThreadConversation.originalRequest("large", bridge: bridge) == original)
    let recent = try await ThreadConversation.latest("large", bridge: bridge)
    #expect(recent.title == "Large chat" && recent.threadId == "large")
    #expect(recent.turns.map(\.id) == (41...60).map { "turn-\($0)" })
    #expect(recent.turns.last?.status == "inProgress" && recent.settledStatus == nil)
    #expect(recent.turns.last?.items.count == 1)
    #expect(recent.turns.last?.items.first?["content"].array?.count == 1)
    #expect(recent.turns[18].items.last?["text"].string == "Exact answer 59\n[Source](https://example.org)")
    #expect(recent.observedStatus(for: FaciendaTask(title: "Track", state: .running)) == nil)
    let requests = try await bridge.request("fixture/threadReads")["requests"].array ?? []
    #expect(requests.count == 3)
    #expect(requests.filter { $0["method"].string == "thread/read" }.allSatisfy { $0["includeTurns"].bool == false })
    #expect(requests.filter { $0["method"].string == "thread/turns/list" }.allSatisfy { $0["itemsView"].string == "summary" })
    await bridge.disconnect()
}

@Test func originalRequestPagesPastAgentStartedTurnsAndStopsOnceFound() async throws {
    let bridge = try await conversationBridge()
    var turns = (1...45).map { index -> JSONValue in
        .object(["id": .string("turn-\(index)"), "status": .string("completed"), "items": .array([])])
    }
    turns[20] = .object(["id": .string("first-user"), "status": .string("completed"), "items": .array([
        .object(["id": .string("user"), "type": .string("userMessage"), "content": .array([
            .object(["type": .string("text"), "text": .string("Exact original request")])
        ])])
    ])])
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("agent-started"), "response": .object([
        "thread": .object(["id": .string("agent-started"), "turns": .array(turns)])
    ])]))
    #expect(try await ThreadConversation.originalRequest("agent-started", bridge: bridge) == "Exact original request")
    let requests = try await bridge.request("fixture/threadReads")["requests"].array ?? []
    #expect(requests.count == 2 && requests[1]["cursor"].string == "20")
    #expect(requests.allSatisfy { $0["sortDirection"].string == "asc" })
    await bridge.disconnect()
}

@Test func conversationPreservesPublicItemsVerbatimInEveryTurn() throws {
    let request: JSONValue = .object(["type": .string("userMessage"), "id": .string("user"), "content": .array([
        .object(["type": .string("text"), "text": .string("Original request\nWith a second line")]),
        .object(["type": .string("localImage"), "path": .string("/tmp/image.png")])
    ])])
    let answer: JSONValue = .object(["type": .string("agentMessage"), "id": .string("answer"), "phase": .string("final_answer"), "text": .string("# Documents\n\n- [Form](https://example.org/form)\n- **Originals**")])
    let progress: JSONValue = .object(["type": .string("agentMessage"), "id": .string("progress"), "phase": .string("commentary"), "text": .string("Checking the documents.")])
    let tool: JSONValue = .object(["type": .string("mcpToolCall"), "id": .string("tool"), "result": .object(["content": .array([.object(["type": .string("text"), "text": .string("Exact tool output")])])])])
    let response: JSONValue = .object(["thread": .object(["id": .string("owner"), "name": .string("Source title"), "turns": .array([
        .object(["id": .string("first"), "status": .string("completed"), "startedAt": .number(100), "completedAt": .number(110), "items": .array([request, progress, tool, answer, .object(["type": .string("reasoning"), "content": .array([.string("Private")])]), .object(["type": .string("hookPrompt")])])]),
        .object(["id": .string("second"), "status": .string("failed"), "error": .object(["message": .string("Interrupted connection")]), "items": .array([request, progress])])
    ])])])
    let conversation = try ThreadConversation.read(response, threadId: "owner")
    #expect(conversation.title == "Source title")
    #expect(conversation.turns.map(\.id) == ["first", "second"])
    #expect(conversation.turns[0].items == [request, progress, tool, answer])
    #expect(conversation.turns[0].completedAt == Date(timeIntervalSince1970: 110))
    #expect(conversation.turns[1].items == [request, progress])
    #expect(conversation.turns[1].status == "failed")
    #expect(conversation.turns[1].error["message"].string == "Interrupted connection")
    #expect(AgentReply.originalRequest(in: response) == "Original request\nWith a second line")
    #expect(throws: StoreError.self) { try ThreadConversation.read(response, threadId: "different") }
    #expect(throws: StoreError.self) { try ThreadConversation.read(.object(["thread": .object(["id": .string("owner")])]), threadId: "owner") }
    let agentStarted: JSONValue = .object(["thread": .object(["turns": .array([
        .object(["items": .array([tool, answer])]), .object(["items": .array([request])])
    ])])])
    #expect(AgentReply.originalRequest(in: agentStarted) == "Original request\nWith a second line")
    let missingOriginal: JSONValue = .object(["thread": .object(["turns": .array([.object(["items": .array([tool, answer])])])])])
    #expect(AgentReply.originalRequest(in: missingOriginal) == nil)
}
