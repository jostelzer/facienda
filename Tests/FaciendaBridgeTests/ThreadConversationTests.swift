import Foundation
import Testing
import FaciendaCore
import FaciendaBridge

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
