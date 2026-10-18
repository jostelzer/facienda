import Foundation
import Testing
@testable import FaciendaCore
@testable import FaciendaBridge

private func fixture() throws -> String { try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")).path }

private func chat(_ id: String, _ name: String, updatedAt: Double) -> JSONValue {
    .object(["id": .string(id), "name": .string(name), "preview": .string(""), "cwd": .string("/tmp"), "updatedAt": .number(updatedAt), "status": .object(["type": .string("notLoaded")])])
}

private func conversation(_ id: String, _ texts: [(String, String)]) throws -> JSONValue {
    let items = texts.enumerated().map { index, entry -> JSONValue in
        entry.0 == "user"
            ? .object(["id": .string("\(index)"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string(entry.1)])])])
            : .object(["id": .string("\(index)"), "type": .string(entry.0 == "commentary" ? "agentMessage" : entry.0),
                       "phase": .string(entry.0 == "commentary" ? "commentary" : "final_answer"), "text": .string(entry.1)])
    }
    return .object(["thread": .object(["id": .string(id), "createdAt": .number(10), "turns": .array([
        .object(["id": .string("turn"), "status": .string("completed"), "completedAt": .number(20), "items": .array(items)])
    ])])])
}

@Test func publicMessagesKeepOnlyTheUsersWordsAndFinalReplies() throws {
    let response = try conversation("chat", [("user", "Facienda dispatch: generated prompt"), ("user", "Use the oak desk"), ("commentary", "Looking"),
                                             ("agentMessage", "Ordered the oak desk"), ("reasoning", "private")])
    let messages = PublicChatMessages.extract(response)
    #expect(messages.map(\.text) == ["Use the oak desk", "Ordered the oak desk"])
    #expect(messages.map(\.messageId) == ["turn:1", "turn:3"])
    #expect(messages.allSatisfy { $0.turnCompleted && $0.at == Date(timeIntervalSince1970: 20) })
}

@Test func indexerWalksEveryListingPageAndReadsChangedChatsOnly() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    let index = try ChatIndex(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaIndexerTests/\(UUID().uuidString)/ChatIndex.sqlite"))
    _ = try await bridge.request("fixture/setThreadList", params: .object(["pages": .object([
        "": .object(["data": .array([chat("new", "Desk order", updatedAt: 300)]), "nextCursor": .string("older")]),
        "older": .object(["data": .array([chat("old", "Studio lighting", updatedAt: 100), chat("gone", "Unavailable", updatedAt: 50)]), "nextCursor": .null])
    ])]))
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("new"), "response": try conversation("new", [("user", "Which desk fits the studio?"), ("agentMessage", "The oak desk fits.")])]))
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("old"), "response": try conversation("old", [("user", "Compare warm lamps")])]))

    let indexer = ChatIndexer(bridge: bridge, index: index)
    let first = try await indexer.step(reads: 5)
    #expect(first == ChatIndexProgress(known: 3, indexed: 2, failed: 0, listingComplete: true))
    #expect(try index.search("oak").map(\.threadId) == ["new"])
    #expect(try index.search("lamps").map(\.threadId) == ["old"])

    // Unchanged chats are not read again; the unreadable one is retried until it has failed three times.
    _ = try await indexer.step(reads: 5, relistAfter: 0)
    _ = try await indexer.step(reads: 5, relistAfter: 0)
    let reads = try await bridge.request("fixture/threadReads")["ids"].array?.compactMap(\.string) ?? []
    #expect(reads.filter { $0 == "new" }.count == 1 && reads.filter { $0 == "gone" }.count == 3)
    #expect(try index.progress() == ChatIndexProgress(known: 3, indexed: 2, failed: 1, listingComplete: true))
    await bridge.disconnect()
}

@Test func deliveryFinderReadsOnlyChatsSinceTheDeliveryAndSkipsTheRunner() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    let requested = Date(timeIntervalSince1970: 1_000)
    let item = NativeDispatch(id: UUID().uuidString, taskId: "task", state: "dispatching", requestedAt: requested, availableAt: requested.addingTimeInterval(3600))
    let marker = "Facienda dispatch: \(item.id)\nWork on the task"
    _ = try await bridge.request("fixture/setThreadList", params: .object(["pages": .object([
        "": .object(["data": .array([chat("runner", "Runner", updatedAt: 1_200), chat("worker", "Sleep nature", updatedAt: 1_100)]), "nextCursor": .string("older")]),
        "older": .object(["data": .array([chat("other", "Unrelated", updatedAt: 1_050), chat("old", "Before the delivery", updatedAt: 500)]), "nextCursor": .string("oldest")])
    ])]))
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("runner"), "response": try conversation("runner", [("user", marker)])]))
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("worker"), "response": try conversation("worker", [("user", marker)])]))
    _ = try await bridge.request("fixture/setThread", params: .object(["threadId": .string("other"), "response": try conversation("other", [("user", "Facienda dispatch: \(UUID().uuidString)\nAnother task")])]))

    let found = try await DeliveryFinder.find(item, runnerThreadId: "runner", bridge: bridge)
    #expect(found.chats.map(\.id) == ["worker"] && found.complete)

    var reply = item
    reply.threadId = "other"
    let missing = try await DeliveryFinder.find(reply, runnerThreadId: "runner", bridge: bridge)
    #expect(missing.chats.isEmpty && missing.complete)
    // Only recent turns are read, never a whole history.
    #expect(try await bridge.request("fixture/threadReads")["ids"].array?.isEmpty == true)
}
