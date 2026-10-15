import Foundation
import Testing
import FaciendaCore
@testable import FaciendaBridge

private func fixture() throws -> String { try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")).path }

@Test func workspaceConnectionRegistersExactFolderAndReusesProjectWhenRenaming() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    let directory = FileManager.default.temporaryDirectory.appending(path: "FaciendaBridgeTests/\(UUID().uuidString)/org & notes")
    _ = try await bridge.request("fixture/registerProject", params: .object([
        "name": .string("org & notes"), "roots": .array([.object(["path": .string(directory.resolvingSymlinksInPath().path)])])
    ]))
    let project = try await bridge.connectProject(directory: directory, name: "facienda-org & notes")
    #expect(project.name == "facienda-org & notes")
    #expect(project.roots.map(\.path) == [directory.resolvingSymlinksInPath().path])
    let reopened = try await bridge.connectProject(directory: directory, name: "facienda-org & notes")
    #expect(reopened.id == project.id)
    let renamed = try await bridge.connectProject(directory: directory, name: "facienda-org")
    #expect(renamed.id == project.id && renamed.name == "facienda-org")
    #expect(renamed.roots.map(\.path) == project.roots.map(\.path))
    let inventory = try await bridge.request("project/list")
    #expect(inventory["data"].array?.count == 1)
    await bridge.disconnect()
}

@Test func groupProjectCreatesOneProjectForNewFolders() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaBridgeTests/\(UUID().uuidString)/delta_game")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let created = try await bridge.groupProject(folders: [folder.path], name: "Delta game", current: nil)
    #expect(created.owned)
    let again = try await bridge.groupProject(folders: [folder.path], name: "Delta game", current: created)
    #expect(again == created)
    #expect(try await bridge.projects().count == 1)
    await bridge.disconnect()
}

@Test func codexAccountRequiresConfirmedAuthentication() throws {
    #expect(try JSONValue.object(["account": .null, "requiresOpenaiAuth": .bool(true)]).decoded(CodexAccountStatus.self).isReady == false)
    #expect(try JSONValue.object(["account": .null, "requiresOpenaiAuth": .bool(false)]).decoded(CodexAccountStatus.self).isReady)
    #expect(throws: (any Error).self) { try JSONValue.object([:]).decoded(CodexAccountStatus.self) }
}

@Test func codexPlanUsageReadsEveryReportedWindow() throws {
    func window(_ minutes: Double, _ used: Double) -> JSONValue {
        .object(["usedPercent": .number(used), "windowDurationMins": .number(minutes), "resetsAt": .number(1_791_582_467)])
    }
    // Codex currently reports only a weekly window.
    let weekly = try #require(PlanUsage(codex: .object(["rateLimits": .object([
        "primary": window(10080, 51), "secondary": .null, "planType": .string("pro"), "rateLimitReachedType": .null
    ])])))
    #expect(weekly.agent == "Codex" && weekly.plan == "ChatGPT Pro" && !weekly.limitReached)
    #expect(weekly.windows.map(\.shortName) == ["wk"] && weekly.windows.map(\.leftPercent) == [49])
    #expect(weekly.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_791_582_467))
    // The Codex bucket wins over the legacy view, and the shorter window comes first.
    let both = try #require(PlanUsage(codex: .object([
        "rateLimits": .object(["primary": window(10080, 0)]),
        "rateLimitsByLimitId": .object(["codex": .object([
            "primary": window(10080, 30), "secondary": window(300, 104),
            "planType": .string("self_serve_business_usage_based"), "rateLimitReachedType": .string("rate_limit_reached")
        ])])
    ])))
    #expect(both.windows.map(\.name) == ["5-hour limit", "Weekly limit"] && both.windows.map(\.leftPercent) == [0, 70])
    #expect(both.plan == "ChatGPT Business" && both.limitReached)
    #expect(PlanUsage(codex: .object(["rateLimits": .object(["primary": .null, "secondary": .null])])) == nil)
    #expect(weekly.stale(at: Date(timeIntervalSince1970: 1_791_582_468)) && !weekly.stale(at: Date(timeIntervalSince1970: 0)))
}

@Test func claudePlanUsageReadsBothUsageSpellings() throws {
    let usage = try #require(PlanUsage(claude: .object([
        "five_hour": .object(["utilization": .number(38.0), "resets_at": .string("2026-10-07T14:20:00.123456+00:00")]),
        "seven_day": .object(["utilization_pct": .number(20), "reset_at": .string("2026-10-12T07:00:00Z")]),
        "seven_day_opus": .null
    ]), capabilities: ["chat", "claude_max"], tier: "default_claude_max_20x"))
    #expect(usage.agent == "Claude" && usage.plan == "Claude Max 20x" && !usage.limitReached)
    #expect(usage.windows.map(\.shortName) == ["5h", "wk"] && usage.windows.map(\.leftPercent) == [62, 80])
    let utc = Calendar(identifier: .gregorian), zone = TimeZone(identifier: "UTC")
    let fiveHourReset = try #require(DateComponents(calendar: utc, timeZone: zone, year: 2026, month: 10, day: 7, hour: 14, minute: 20).date)
    let weeklyReset = try #require(DateComponents(calendar: utc, timeZone: zone, year: 2026, month: 10, day: 12, hour: 7).date)
    #expect(abs(try #require(usage.windows[0].resetsAt).timeIntervalSince(fiveHourReset)) < 1)
    #expect(usage.windows[1].resetsAt == weeklyReset)
    #expect(PlanUsage.claudePlan(capabilities: ["claude_pro"], tier: nil) == "Claude Pro")
    #expect(PlanUsage(claude: .object(["five_hour": .null])) == nil)
    let blocked = try #require(PlanUsage(claude: .object(["five_hour": .object(["utilization": .number(100)])])))
    #expect(blocked.limitReached && blocked.windows.first?.resetsAt == nil)
}

@Test func codexSignInCompletionAndCancellation() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    #expect(try await !bridge.accountStatus().isReady)
    let cancelled = try await bridge.startSignIn()
    #expect(cancelled.url.host == "auth.openai.com")
    var messages = bridge.messages.makeAsyncIterator()
    try await bridge.cancelSignIn(cancelled.id)
    #expect(await messages.next()?.params["success"] == .bool(false))
    #expect(try await !bridge.accountStatus().isReady)
    let login = try await bridge.startSignIn()
    _ = try await bridge.request("fixture/completeLogin")
    let completed = try #require(await messages.next())
    #expect(completed.method == "account/login/completed")
    #expect(completed.params["loginId"].string == login.id)
    #expect(completed.params["success"] == .bool(true))
    #expect(try await bridge.accountStatus().isReady)
    await bridge.disconnect()
}

@Test func signInOnlyOpensAnOfficialWebAuthenticationURL() throws {
    for url in ["codex://", "file:///Applications/ChatGPT.app", "https://example.com", "http://auth.openai.com", "https://auth.openai.com@example.com"] {
        #expect(throws: BridgeError.self) {
            try CodexSignIn(response: .object(["type": .string("chatgpt"), "loginId": .string("test"), "authUrl": .string(url)]))
        }
    }
}

@Test func reportingDoesNotBroadenExecutionPermissions() throws {
    let request = ThreadStartRequest(cwd: "/tmp", developerInstructions: "", scope: .prepareOnly, mcpPath: "/tmp/facienda-mcp")
    let json = try JSONValue.encoded(request)
    #expect(json["sandbox"].string == "read-only")
    #expect(json["approvalPolicy"].string == "on-request")
    let server = json["config"]["mcp_servers"]["facienda"]
    #expect(server["default_tools_approval_mode"].string == "prompt")
    #expect(server["tools"]["facienda_task_update"]["approval_mode"].string == "approve")
    #expect(server["tools"]["facienda_propose_completion"]["approval_mode"].string == "approve")
    #expect(server["tools"]["facienda_memory_remember"] == .null)
    #expect(server["tools"]["facienda_task_create"] == .null)
}

@Test func resultsExcludeCommentaryReasoningAndIncompleteTurns() throws {
    func message(_ text: String, phase: String) -> JSONValue {
        .object(["type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }
    #expect(AgentReply(item: .object(["type": .string("reasoning"), "text": .string("private")])) == nil)
    let response: JSONValue = .object(["thread": .object(["turns": .array([
        .object(["status": .string("completed"), "items": .array([message("The answer", phase: "final_answer"), message("Progress", phase: "commentary")])]),
        .object(["status": .string("failed"), "items": .array([message("Incomplete", phase: "final_answer")])])
    ])])])
    #expect(AgentReply.latestResult(in: response)?.text == "The answer")
}

@Test func realMCPConfirmationDefaultsToOneCallAndHonorsSessionChoice() throws {
    // Captured shape from Codex 0.159; identifiers and arguments are synthetic.
    let params: JSONValue = .object([
        "threadId": .string("pilot"), "serverName": .string("facienda"), "mode": .string("form"),
        "message": .string("Allow this Facienda tool call?"),
        "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
        "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"),
                          "persist": .array([.string("session"), .string("always")]),
                          "tool_params": .object(["taskId": .string("test-task")])])
    ])
    let approval = try #require(MCPToolApproval(params: params))
    #expect(approval.threadID == "pilot")
    #expect(approval.arguments["taskId"].string == "test-task")
    #expect(approval.supportsSessionApproval)
    #expect(try approval.sessionResponse()["_meta"]["persist"].string == "session")
    for persistence: JSONValue in [.string("session"), .array([.string("session")])] {
        var variant = try #require(params.object)
        variant["_meta"] = .object(["codex_approval_kind": .string("mcp_tool_call"), "persist": persistence])
        #expect(try #require(MCPToolApproval(params: .object(variant))).supportsSessionApproval)
    }
    for persistence: JSONValue in [.null, .string("always"), .array([.string("always")]), .string("unknown")] {
        var variant = try #require(params.object)
        variant["_meta"] = .object(["codex_approval_kind": .string("mcp_tool_call"), "persist": persistence])
        let restricted = try #require(MCPToolApproval(params: .object(variant)))
        #expect(!restricted.supportsSessionApproval)
        #expect(throws: BridgeError.self) { try restricted.sessionResponse() }
    }
    #expect(approval.response(accept: true) == .object(["action": .string("accept"), "content": .object([:])]))
    #expect(approval.response(accept: false)["action"].string == "decline")
    var requiringInput = try #require(params.object)
    requiringInput["requestedSchema"] = .object(["type": .string("object"), "properties": .object(["secret": .object(["type": .string("string")])])])
    #expect(MCPToolApproval(params: .object(requiringInput)) == nil)
    requiringInput["mode"] = .string("url")
    #expect(MCPToolApproval(params: .object(requiringInput)) == nil)
}

@Test func handshakeFramingAndPagination() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    var stream = bridge.messages.makeAsyncIterator()
    let page = try await bridge.listThreads()
    #expect(page.data.first?.id == "fixture")
    #expect(page.nextCursor == "page2")
    #expect(page.data.first?.statusLabel == "notLoaded")
    let event = await stream.next()
    #expect(event?.method == "thread/status/changed")
    await bridge.disconnect()
}

@Test func cancellingOneListenerKeepsMessagesFlowingToOthers() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    // A Luna turn that timed out used to cancel its listener, which ended the shared stream for good.
    let abandoned = Task { for await _ in bridge.messages {} }
    try await Task.sleep(for: .milliseconds(50))
    abandoned.cancel(); await abandoned.value
    var stream = bridge.messages.makeAsyncIterator()
    _ = try await bridge.listThreads()
    #expect(await stream.next()?.method == "thread/status/changed")
    await bridge.disconnect()
}

@Test func timeoutErrorAndRecovery() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    await #expect(throws: BridgeError.self) { try await bridge.request("hang", timeout: .milliseconds(30)) }
    await #expect(throws: BridgeError.self) { try await bridge.request("fail") }
    #expect(try await bridge.listThreads().data.count == 1)
    await bridge.disconnect()
    await #expect(throws: BridgeError.self) { try await bridge.listThreads() }
}

@Test func processExitResolvesPendingRequests() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    await #expect(throws: BridgeError.self) { try await bridge.request("exit", timeout: .seconds(2)) }
    await bridge.disconnect()
}

@Test func ownedTurnApprovalAndUnsubscribe() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    let thread = try await bridge.startThread(.init(cwd: "/tmp", developerInstructions: "Prepare only", scope: .prepareOnly, mcpPath: "/tmp/facienda-mcp"))
    #expect(thread.id == "owned")
    var messages = bridge.messages.makeAsyncIterator()
    let turn = try await bridge.startTurn(.init(threadId: thread.id, text: "Prepare a draft"))
    #expect(turn == "turn-fixture")
    #expect(await messages.next()?.method == "turn/started")
    let approval = try #require(await messages.next())
    #expect(approval.method == "item/commandExecution/requestApproval")
    let requestID = try #require(approval.requestID)
    try await bridge.respond(id: requestID, result: .object(["decision": .string("decline")]))
    #expect(await messages.next()?.method == "turn/completed")
    try await bridge.unsubscribe(thread.id)
    await bridge.disconnect()
}

@Test func largeThreadResponsesRemainReadableAndKeepTheConnectionAlive() async throws {
    let bridge = CodexBridge()
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    do {
        let response = try await bridge.request("fixture/largeResponse", timeout: .seconds(10))
        #expect(response["text"].string?.utf8.count == 17 * 1024 * 1024)
        #expect(response["text"].string?.first == "x" && response["text"].string?.last == "x")
        #expect(try await !bridge.accountStatus().isReady)
        await bridge.disconnect()
    } catch {
        await bridge.disconnect()
        throw error
    }
}

@Test func oversizedResponseFailsOnlyItsRequestAndKeepsTheConnection() async throws {
    // A chat over the limit used to end the connection, so the chat index retried it and dropped it every tick.
    let bridge = CodexBridge(maximumLineBytes: 1024 * 1024)
    try await bridge.connect(executable: "/usr/bin/python3", arguments: [try fixture()])
    var drops = bridge.messages.makeAsyncIterator()
    await #expect(throws: BridgeError.self) { try await bridge.request("fixture/oversizedResponse", timeout: .seconds(10)) }
    #expect(await bridge.isConnected)
    #expect(try await bridge.listThreads().data.first?.id == "fixture")
    #expect(await drops.next()?.method == "thread/status/changed")
    await bridge.disconnect()
}
