import Foundation
import Testing
import FaciendaCore
@testable import FaciendaBridge

@Test func threadCaptureRequiresWorkspaceLinkAndExcludesInternalContent() throws {
    let db = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaCaptureTests/\(UUID().uuidString)/test.sqlite"))
    try db.saveMemorySettings(enabled: true, workerModel: nil)
    let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"chat","createdAt":100,"turns":[{"id":"turn","status":"completed","items":[{"id":"1","type":"userMessage","content":[{"type":"text","text":"Facienda dispatch: original generated prompt"}]},{"id":"2","type":"userMessage","content":[{"type":"text","text":"Prefer the local server"}]},{"id":"3","type":"agentMessage","phase":"commentary","text":"Working on it"},{"id":"4","type":"agentMessage","phase":"final_answer","text":"Saved the preference"},{"id":"5","type":"reasoning","text":"private"}]}]}}"#.utf8))
    try ThreadMemory.capture(response, threadId: "chat", store: db)
    #expect(try db.workspaceMemoryStatus().pending == 0)
    let task = try db.create(FaciendaTask(title: "Test"))
    try db.link(ThreadLink(taskId: task.id, codexThreadId: "chat"))
    try ThreadMemory.capture(response, threadId: "chat", store: db)
    try ThreadMemory.capture(response, threadId: "chat", store: db)
    #expect(try db.workspaceMemoryStatus().pending == 0, "Public chat items without typed rollout provenance are not learned")
}

@Test func memoryInferenceIsAlwaysEphemeralLunaAndDisablesConfiguredTools() throws {
    let config: JSONValue = .object(["mcp_servers": .object(["private": .object(["enabled": .bool(true)])]), "plugins": .object(["mail": .object(["enabled": .bool(true)])])])
    let params = EphemeralMemoryInference.startParameters(cwd: "/tmp", effectiveConfig: config)
    #expect(params["ephemeral"].bool == true)
    #expect(params["config"]["model_reasoning_effort"].string == "high")
    #expect(params["model"].string == "gpt-6-luna")
    #expect(params["config"]["mcp_servers"]["private"]["enabled"].bool == false)
    #expect(params["config"]["plugins"]["mail"]["enabled"].bool == false)
    #expect(params["config"]["features"]["shell_tool"].bool == false)
    #expect(params["permissions"].string == "facienda-memory")
    #expect(params["config"]["permissions"]["facienda-memory"]["filesystem"][":root"].string == "deny")
    #expect(params["config"]["permissions"]["facienda-memory"]["network"]["enabled"].bool == false)
    #expect(throws: StoreError.self) { try MemoryInferenceRequest(.object(["messages": .array([])])) }
    #expect(EphemeralMemoryInference.serverArguments.contains("notify=[]"))
    #expect(EphemeralMemoryInference.serverArguments.contains("otel.log_user_prompt=false"))
    try EphemeralMemoryInference.validateProviderConfig(.object([:]))
    try EphemeralMemoryInference.validateProviderConfig(.object(["chatgpt_base_url": .string("https://chatgpt.com/backend-api")]))
    #expect(throws: BridgeError.self) { try EphemeralMemoryInference.validateProviderConfig(.object(["openai_base_url": .string("https://untrusted.example")])) }
}
