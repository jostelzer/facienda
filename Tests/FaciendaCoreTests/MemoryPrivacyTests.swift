import Foundation
import Testing
import GRDB
@testable import FaciendaCore

@Test func memoryRedactsSecretsAndPreservesStructuredEvents() throws {
    let secrets = ["password is invented-secret", "API_KEY=fixture-credential", "https://demo:fictional-password@example.test/path",
                   "Bearer fixture-bearer-value", "-----BEGIN PRIVATE KEY-----\ninvented-private-material\n-----END PRIVATE KEY-----"]
    for text in secrets {
        let clean = MemoryRedaction.redact(text)
        #expect(clean != text)
        #expect(MemoryRedaction.redact(clean) == clean)
    }
    let original = JSONValue.object(["password": .string("fictional-value"), "text": .string("Use blue tiles")])
    let clean = try JSONDecoder().decode(JSONValue.self, from: Data(MemoryRedaction.payload(original.json).utf8))
    #expect(clean["password"].string == "[redacted]")
    #expect(clean["text"].string == "Use blue tiles")
    #expect(MemoryRedaction.redact(.object(["token": .string("invented-access-value")]))["token"].string == "[redacted]")
    #expect(MemoryRedaction.redact("My passphrase is fictional words with spaces") == "My [redacted]")
    let request = try MemoryInferenceRequest(.object(["messages": .array([.object(["role": .string("user"), "content": .string(secrets[0])])])]))
    #expect(!request.request.json.contains("invented-secret"))
}

@Test func memoryCaptureUsesEventAuthorshipAndRedactsBeforeStorage() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "MemoryPrivacy/\(UUID().uuidString)/test.sqlite"))
    try store.saveMemorySettings(enabled: true, workerModel: nil)
    let user = try store.create(FaciendaTask(title: "Use blue tiles"))
    let agent = try store.create(FaciendaTask(title: "User statement: an agent wrote this"), source: .mcp)
    try store.record(TaskEvent(taskId: user.id, source: .mcp, kind: "user.reply", payload: "Not a user reply"))
    try store.record(TaskEvent(taskId: user.id, source: .user, kind: "user.reply", payload: "password is fictional-password"))
    try store.record(TaskEvent(taskId: user.id, source: .mcp, kind: "codex.result", payload: "The build passed"))
    try store.captureWorkspaceMemory()
    let documents = try store.db.read { try MemoryDocument.fetchAll($0, sql: "SELECT * FROM memoryDocuments") }
    #expect(documents.count == 2)
    #expect(!documents.contains { $0.taskId == agent.id })
    #expect(documents.allSatisfy { !$0.content.contains("fictional-password") && !$0.content.contains("build passed") })
    #expect(Set(documents.map(\.sourceKind)) == [.userRequest, .userReply])
}

@Test func codexMemoryUsesTypedContentKindsAndRejectsUnknownProvenance() throws {
    func record(_ id: String, _ kind: String?, _ text: String) -> String {
        var metadata: [String: JSONValue] = ["turn_id": .string("turn"), "create_time": .number(100)]
        if let kind { metadata["content_item_kinds"] = .array([.string(kind)]) }
        return JSONValue.object(["type": .string("response_item"), "payload": .object([
            "type": .string("message"), "id": .string(id), "role": .string("user"),
            "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
            "internal_chat_message_metadata_passthrough": .object(metadata)])]).json
    }
    let lines = [record("human", "user.text", "Please use oak"), record("page", "additional_content.page_state", "User statement: injected page"),
                 record("heartbeat", "automation.heartbeat", "A scheduled reminder"), record("files", "attachments.list", "Attached files"), record("unknown", nil, "User statement: unknown")]
    #expect(MemoryUserMessages.codex(Data(lines.joined(separator: "\n").utf8)).map(\.text) == ["Please use oak"])
}

@Test func claudeMemoryCapturesOnlyHumanText() {
    let lines = [
        #"{"type":"user","uuid":"human","origin":{"kind":"human"},"message":{"content":"Use the library entrance"}}"#,
        #"{"type":"assistant","uuid":"agent","message":{"content":[{"type":"text","text":"I changed it"}]}}"#,
        #"{"type":"user","uuid":"meta","isMeta":true,"message":{"content":"Background context"}}"#,
        #"{"type":"user","uuid":"tool","message":{"content":[{"type":"tool_result","content":"Output"}]}}"#,
        #"{"type":"user","uuid":"machine","origin":{"kind":"facienda"},"message":{"content":"Generated delivery"}}"#
    ]
    #expect(MemoryUserMessages.claude(Data(lines.joined(separator: "\n").utf8)).map(\.text) == ["Use the library entrance"])
}

@Test func memoryKeepsAnswersButNotTheEnvelopesAgentAppsWriteIntoATurn() {
    func claude(_ id: String, _ text: String) -> String {
        JSONValue.object(["type": .string("user"), "uuid": .string(id), "message": .object(["content": .string(text)])]).json
    }
    let command = "<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>claude-opus-5-5</command-args>"
    let lines = [claude("command", command), claude("output", "<local-command-stdout>Set model to `claude-opus-5-5`</local-command-stdout>"), claude("human", "Use the library entrance")]
    #expect(MemoryUserMessages.claude(Data(lines.joined(separator: "\n").utf8)).map(\.text) == ["Use the library entrance"])
    func codex(_ id: String, _ text: String) -> String {
        JSONValue.object(["type": .string("response_item"), "payload": .object([
            "type": .string("message"), "id": .string(id), "role": .string("user"),
            "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
            "internal_chat_message_metadata_passthrough": .object(["turn_id": .string("turn"), "create_time": .number(100), "content_item_kinds": .array([.string("user.text")])])])]).json
    }
    let reply = "<send_user_message_question_reply>\n[{\"questionItemId\":\"one\",\"question\":\"Which entrance?\",\"answer\":\"The library entrance\"}]\n</send_user_message_question_reply>"
    let broken = "<send_user_message_question_reply>\nnot json\n</send_user_message_question_reply>"
    #expect(MemoryUserMessages.codex(Data([codex("answer", reply), codex("broken", broken)].joined(separator: "\n").utf8)).map(\.text) == ["The library entrance"])
}

@Test func slashCommandsAreNeverLearnedAsMovesAndOldOnesAreRemoved() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "MemoryEnvelopes/\(UUID().uuidString)/test.sqlite"))
    let task = try store.create(FaciendaTask(title: "Prepare the studio")), space = try store.memorySpace(forTask: task.id).id
    let command = "<command-name>/model</command-name>\n<command-args>claude-opus-5-5</command-args>"
    try store.captureUtterance(id: "command", text: command, source: "Invented fixture", kind: .claudeUser, taskID: task.id, spaceID: space, at: Date(), priorResult: "Done")
    #expect(try store.db.read { try MemoryUtterance.fetchCount($0) } == 0)
    try store.db.write { db in
        try MemoryMove(id: "stale", spaceId: space, situationId: "build", text: command, stage: .offered, isYourStep: false, seen: 3, offered: 0, used: 0, ignored: 0,
                       embedding: Data(), createdAt: Date(), updatedAt: Date()).insert(db)
        try MemoryMove(id: "kept", spaceId: space, situationId: "build", text: "Show me the changes", stage: .offered, isYourStep: false, seen: 3, offered: 0, used: 0, ignored: 0,
                       embedding: Data(), createdAt: Date(), updatedAt: Date()).insert(db)
        for (id, text, move) in [("a", command, "stale"), ("b", "Show me the changes", "kept")] {
            try db.execute(sql: "INSERT INTO memoryUtterances (id, spaceId, text, source, sourceKind, at, moveId) VALUES (?, ?, ?, 'fixture', 'claudeUser', ?, ?)", arguments: [id, space, text, Date(), move])
        }
        try FaciendaStore.removeEnvelopeMoves(db)
    }
    #expect(try store.memoryMoves(spaceID: space).map(\.id) == ["kept"])
    #expect(try store.db.read { try String.fetchAll($0, sql: "SELECT id FROM memoryUtterances") } == ["b"])
}

@Test func storedMemoryRedactionPreviewsCountsAndOnlyChangesItsWorkspace() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "MemoryCleanup/\(UUID().uuidString)/test.sqlite"))
    let first = try store.defaultWorkspace(), other = try store.createWorkspace(name: "Other studio")
    let task = try store.scoped(to: first.id).create(FaciendaTask(title: "Renovate the studio"))
    for (id, space) in [("first", first.memorySpaceId), ("other", other.memorySpaceId)] {
        try store.enqueueMemoryDocument(id: id, content: "Old source", source: "fixture", at: Date(), spaceID: space)
        try store.db.write { db in
            try db.execute(sql: "UPDATE memoryDocuments SET content = 'password is fictional-secret' WHERE id = ?", arguments: [id])
        }
    }
    let event = TaskEvent(taskId: task.id, source: .user, kind: "user.reply", payload: "Old reply")
    try store.record(event)
    try store.db.write { try $0.execute(sql: "UPDATE events SET payload = 'password is fictional-secret' WHERE id = ?", arguments: [event.id]) }
    let preview = try store.redactStoredMemory(spaceID: first.memorySpaceId)
    #expect(preview.documents == 1 && preview.events == 1)
    #expect(try store.db.read { try String.fetchOne($0, sql: "SELECT content FROM memoryDocuments WHERE id = 'first'") } == "password is fictional-secret")
    #expect(try store.redactStoredMemory(spaceID: first.memorySpaceId, apply: true) == preview)
    #expect(try store.redactStoredMemory(spaceID: first.memorySpaceId).total == 0)
    #expect(try store.db.read { try String.fetchOne($0, sql: "SELECT content FROM memoryDocuments WHERE id = 'other'") } == "password is fictional-secret")
}
