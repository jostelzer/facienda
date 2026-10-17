import Foundation
import Testing
@testable import FaciendaCore

private func claudeStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "ClaudeRunnerTests/\(UUID().uuidString)/test.sqlite"))
}

private func claudeTask(_ store: FaciendaStore, title: String = "Draft the venue email", model: String = "claude-sonnet-5-5") throws -> FaciendaTask {
    var task = FaciendaTask(title: title, state: .needsMe)
    task.workerModel = model; task.workerReasoningEffort = "medium"; task.workerProvider = .claude
    return try store.create(task)
}

@discardableResult private func bindClaude(_ store: FaciendaStore, session: String = "local_runner", canStart: Bool = false) throws -> ClaudeRunnerState {
    let setup = try store.prepareClaudeSetup()
    return try store.bindClaudeRunner(sessionId: session, challenge: setup.challenge, canStartSessions: canStart)
}

@Test func modelChoiceDecidesTheAgentAppAndKeepsValidSettings() {
    #expect(TaskModelChoice.standard.provider == .codex)
    #expect(TaskModelChoice.claudeStandard.provider == .claude)
    let ultra = TaskModelChoice(model: "gpt-6.1-sol", effort: "ultra", fast: true)
    let opus = ultra.choosing("claude-opus-5-5")
    #expect(opus.provider == .claude && opus.effort == "high" && opus.fast)
    #expect(opus.serviceTier == "fast")
    let sonnet = opus.choosing("claude-sonnet-5-5")
    #expect(!sonnet.fast && sonnet.serviceTier == nil)
    #expect(ultra.serviceTier == "priority")
    #expect(TaskModelChoice.provider(ofModel: "claude-future-9") == .claude)
    #expect(TaskModelChoice.efforts(for: .claude) == ["low", "medium", "high", "xhigh", "max"])
}

@Test func switchingBackToAModelBringsBackItsReasoningAndFast() {
    let opus = TaskModelChoice(model: "claude-opus-5-5", effort: "xhigh", fast: true)
    let sol = TaskModelChoice(model: "gpt-6.1-sol", effort: "ultra", fast: false)
    let remembered = ["claude-opus-5-5": opus, "gpt-6.1-sol": sol]
    #expect(sol.choosing("claude-opus-5-5", remembered: remembered) == opus)
    #expect(opus.choosing("gpt-6.1-sol", remembered: remembered) == sol)
    // A model never chosen before carries the current settings over, as plain switching does.
    #expect(sol.choosing("gpt-6-luna", remembered: remembered) == sol.choosing("gpt-6-luna"))
    // A remembered setting the model no longer offers is dropped.
    let stale = ["claude-sonnet-5-5": TaskModelChoice(model: "claude-sonnet-5-5", effort: "ultra", fast: true)]
    #expect(sol.choosing("claude-sonnet-5-5", remembered: stale) == TaskModelChoice(model: "claude-sonnet-5-5", effort: "high", fast: false))
}

@Test func claudeStartsNeverReachTheCodexRunnerAndOpenInTheComposer() throws {
    let store = try claudeStore()
    try store.bindRunner(threadId: "codex-runner", automationId: nil)
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    #expect(item.agent == .claude)
    #expect(try store.claimDispatch(runnerId: "codex-runner") == nil)
    let handed = try store.handOffToClaudeComposer(item.id)
    #expect(handed.awaitsClaudeSend)
    #expect(try store.handOffToClaudeComposer(item.id).id == item.id)
    let url = try store.claudeComposerURL(dispatchId: item.id, helper: "/Applications/Facienda.app/Contents/Helpers/facienda-mcp")
    #expect(url.scheme == "claude" && url.host == "code" && url.path == "/new")
    let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(query["q"]?.hasPrefix("Facienda dispatch: \(item.id)\n") == true)
    #expect(query["q"]?.contains("--claude attach --dispatch-id \(item.id)") == true)
    // Each task session opens in the task's own folder, new to Claude, prepared with Facienda's tools.
    let taskFolder = store.taskFolder(task.id)
    #expect(query["folder"] == taskFolder.path)
    #expect(FileManager.default.fileExists(atPath: taskFolder.appending(path: ".mcp.json").path))
    let chosen = try store.update(task.id) { $0.cwd = "/Users/me/projects/site" }
    #expect(store.claudeSessionFolder(for: chosen) == "/Users/me/projects/site")
    // A Codex task still goes to the Codex runner.
    let codex = try store.create(FaciendaTask(title: "Codex work", state: .needsMe))
    let codexItem = try store.enqueueDispatch(taskId: codex.id)
    #expect(codexItem.agent == .codex)
    #expect(try store.claimDispatch(runnerId: "codex-runner")?.id == codexItem.id)
}

@Test func aSessionLinksItselfOnceAndOthersAreToldToStop() throws {
    let store = try claudeStore()
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    #expect(throws: StoreError.self) { try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_a", cliSessionId: nil, cwd: nil) }
    try store.handOffToClaudeComposer(item.id)
    #expect(throws: StoreError.self) { try store.attachClaudeSession(dispatchId: item.id, sessionId: "", cliSessionId: nil, cwd: nil) }
    let session = try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_a", cliSessionId: "6c1f0d39-1b8c-4c4b-9d3e-0f5a2a7b8c90", cwd: "/tmp/work")
    // No runner is awake, so the session keeps the Claude app's own settings and starts at once.
    #expect(session.configureState == "skipped")
    #expect(try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_a", cliSessionId: nil, cwd: nil).threadId == "local_a")
    #expect(throws: StoreError.self) { try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_b", cliSessionId: nil, cwd: nil) }
    let link = try #require(try store.links(taskId: task.id).first)
    #expect(link.provider == .claude && link.threadId == "local_a")
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "started")
    #expect(try store.claudeDelivery(item.id, sessionId: "local_a").id == item.id)
    #expect(throws: StoreError.self) { try store.claudeDelivery(item.id, sessionId: "local_b") }
    // Cancelled requests are refused too.
    let other = try claudeTask(store, title: "Second")
    let second = try store.enqueueDispatch(taskId: other.id)
    try store.handOffToClaudeComposer(second.id)
    try store.cancelDispatch(second.id)
    #expect(throws: StoreError.self) { try store.attachClaudeSession(dispatchId: second.id, sessionId: "local_c", cliSessionId: nil, cwd: nil) }
}

@Test func aSessionNamesItsOwnTaskWhenNoRunnerDid() throws {
    let store = try claudeStore()
    let task = try claudeTask(store, title: "hey can you please draft the email to the venue about friday")
    let item = try store.enqueueDispatch(taskId: task.id)
    try store.handOffToClaudeComposer(item.id)
    // Sent by hand with no runner awake: nothing named the task, so the session's instructions start with naming it.
    #expect(try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_a", cliSessionId: nil, cwd: nil).configureState == "skipped")
    let step = try #require(try store.claudeNamingStep(dispatchId: item.id, sessionId: "local_a", base: "facienda-mcp"))
    #expect(step.contains("facienda-mcp --claude name --task-id \(task.id) --title-file") && step.contains("session_id = local_a"))
    // Only the session carrying the task may name it.
    let other = try claudeTask(store, title: "Second")
    let second = try store.enqueueDispatch(taskId: other.id)
    try store.handOffToClaudeComposer(second.id)
    try store.attachClaudeSession(dispatchId: second.id, sessionId: "local_b", cliSessionId: nil, cwd: nil)
    #expect(throws: StoreError.self) { try store.nameTask(task.id, runnerID: "local_b", expectedTitle: task.title, displayTitle: "Wrong", context: "test") }
    #expect(throws: StoreError.self) { try store.nameTask(task.id, runnerID: "local_stranger", expectedTitle: task.title, displayTitle: "Wrong", context: "test") }
    let named = try store.nameTask(task.id, runnerID: "local_a", expectedTitle: task.title, displayTitle: "Draft venue email", context: "test")
    #expect(named.displayName == "Draft venue email" && named.displayTitleSource == "session" && named.title == task.title)
    #expect(try store.claudeNamingStep(dispatchId: item.id, sessionId: "local_a", base: "facienda-mcp") == nil)
    // A name the user gave is kept, and nothing asks the session to name it.
    _ = try store.update(other.id) { $0.displayTitle = "My own name" }
    #expect(try store.claudeNamingStep(dispatchId: second.id, sessionId: "local_b", base: "facienda-mcp") == nil)
    #expect(try store.nameTask(other.id, runnerID: "local_b", expectedTitle: other.title, displayTitle: "Agent name", context: "test").displayName == "My own name")
    // Only a start carries the naming step, never a reply.
    let third = try claudeTask(store, title: "Third")
    let reply = try store.enqueueDispatch(taskId: third.id, message: "Shorter please")
    #expect(try reply.kind == "reply" && store.task(third.id).displayTitle == nil)
    #expect(try store.claudeNamingStep(dispatchId: reply.id, sessionId: "local_c", base: "facienda-mcp") == nil)
}

@Test func anAwakeRunnerAppliesTheModelBeforeTheSessionStarts() throws {
    let store = try claudeStore()
    try bindClaude(store)
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    // The runner cannot start sessions, so new sessions are left to the composer.
    #expect(try store.hasClaudeWork(runnerId: "local_runner") == false)
    #expect(try store.claimClaudeWork(runnerId: "local_runner") == nil)
    try store.handOffToClaudeComposer(item.id)
    #expect(throws: StoreError.self) { try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_runner", cliSessionId: nil, cwd: nil) }
    let session = try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_worker", cliSessionId: nil, cwd: nil)
    #expect(session.configureState == "pending" && session.model == "claude-sonnet-5-5" && session.effort == "medium")
    #expect(try store.settledClaudeSession("local_worker") == nil)
    #expect(try store.hasClaudeWork(runnerId: "local_runner"))
    guard case .configure(let claimed) = try #require(try store.claimClaudeWork(runnerId: "local_runner")) else { Issue.record("Expected a configure job"); return }
    #expect(claimed.threadId == "local_worker" && claimed.configureState == "configuring")
    #expect(try store.claimClaudeWork(runnerId: "local_runner") == nil)
    try store.nameTask(task.id, runnerID: "local_runner", expectedTitle: task.title, displayTitle: "Venue email", context: "test")
    try store.finishClaudeConfigure(threadId: "local_worker", runnerId: "local_runner", applied: true, note: "Sonnet 5.5, medium")
    #expect(try store.settledClaudeSession("local_worker")?.configureState == "done")
    #expect(try store.task(task.id).displayName == "Venue email")
    #expect(throws: StoreError.self) { try store.finishClaudeConfigure(threadId: "local_worker", runnerId: "intruder", applied: true, note: nil) }
}

@Test func unfinishedConfigurationLetsTheSessionGoAhead() throws {
    let store = try claudeStore()
    try bindClaude(store)
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    try store.handOffToClaudeComposer(item.id)
    let start = Date()
    try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_worker", cliSessionId: nil, cwd: nil, now: start)
    // Nobody picked it up within five minutes.
    #expect(try store.settledClaudeSession("local_worker", now: start.addingTimeInterval(301))?.configureState == "failed")
    let second = try claudeTask(store, title: "Second")
    let next = try store.enqueueDispatch(taskId: second.id)
    try store.handOffToClaudeComposer(next.id)
    try store.attachClaudeSession(dispatchId: next.id, sessionId: "local_second", cliSessionId: nil, cwd: nil, now: start)
    _ = try store.claimClaudeWork(runnerId: "local_runner", now: start)
    // Claimed, then abandoned for ten minutes.
    #expect(try store.settledClaudeSession("local_second", now: start.addingTimeInterval(601))?.configureState == "failed")
}

@Test func repliesReachTheOwningClaudeSessionThroughTheRunner() throws {
    let store = try claudeStore()
    try store.bindRunner(threadId: "codex-runner", automationId: nil)
    try bindClaude(store)
    let task = try claudeTask(store)
    let start = try store.enqueueDispatch(taskId: task.id)
    try store.handOffToClaudeComposer(start.id)
    try store.attachClaudeSession(dispatchId: start.id, sessionId: "local_worker", cliSessionId: nil, cwd: nil)
    _ = try store.claimClaudeWork(runnerId: "local_runner")
    try store.finishClaudeConfigure(threadId: "local_worker", runnerId: "local_runner", applied: true, note: nil)
    let reply = try store.enqueueDispatch(taskId: task.id, message: "Use the shorter version")
    #expect(reply.threadId == "local_worker" && reply.agent == .claude)
    #expect(try store.claimDispatch(runnerId: "codex-runner") == nil)
    #expect(throws: StoreError.self) { try store.claimClaudeWork(runnerId: "local_worker") }
    guard case .deliver(let claimed) = try #require(try store.claimClaudeWork(runnerId: "local_runner")) else { Issue.record("Expected a delivery"); return }
    #expect(claimed.id == reply.id)
    #expect(throws: StoreError.self) { try store.handOffToClaudeComposer(reply.id) }
    _ = try store.beginClaudeDelivery(reply.id, runnerId: "local_runner")
    try store.acknowledgeDispatch(reply.id, runnerId: "local_runner", threadId: "local_worker")
    #expect(try store.dispatches().first { $0.id == reply.id }?.state == "started")
    #expect(try store.claudeDelivery(reply.id, sessionId: "local_worker").message == "Use the shorter version")
    #expect(try store.links(taskId: task.id).count == 1)
}

@Test func unfinishedRunnerJobsAreLeasedSoTheyCannotLoop() throws {
    let store = try claudeStore()
    try bindClaude(store)
    let task = try claudeTask(store)
    let start = try store.enqueueDispatch(taskId: task.id)
    try store.handOffToClaudeComposer(start.id)
    try store.attachClaudeSession(dispatchId: start.id, sessionId: "local_worker", cliSessionId: nil, cwd: nil)
    _ = try store.claimClaudeWork(runnerId: "local_runner")
    try store.finishClaudeConfigure(threadId: "local_worker", runnerId: "local_runner", applied: false, note: "refused")
    let now = Date()
    let reply = try store.enqueueDispatch(taskId: task.id, message: "Again")
    #expect(try store.claimClaudeWork(runnerId: "local_runner", now: now) != nil)
    // The runner woke but did not finish: the same job comes back once, then rests.
    #expect(try store.claimClaudeWork(runnerId: "local_runner", now: now) != nil)
    #expect(try store.hasClaudeWork(runnerId: "local_runner", now: now) == false)
    #expect(try store.claimClaudeWork(runnerId: "local_runner", now: now) == nil)
    #expect(try store.hasClaudeWork(runnerId: "local_runner", now: now.addingTimeInterval(121)))
    try store.deferDispatch(reply.id, runnerId: "local_runner", reason: "Session busy")
    #expect(try store.dispatches().first { $0.id == reply.id }?.state == "claimed")
}

@Test func aRunnerThatCanStartSessionsCreatesThemItself() throws {
    let store = try claudeStore()
    try bindClaude(store, canStart: true)
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    guard case .create(let claimed) = try #require(try store.claimClaudeWork(runnerId: "local_runner")) else { Issue.record("Expected a create job"); return }
    #expect(claimed.id == item.id)
    _ = try store.beginClaudeDelivery(item.id, runnerId: "local_runner")
    let session = try store.attachClaudeSession(dispatchId: item.id, sessionId: "local_new", cliSessionId: nil, cwd: nil)
    #expect(session.configureState == "pending")
    #expect(try store.links(taskId: task.id).first?.provider == .claude)
}

@Test func eachRunnerChecksThroughItsOwnApp() throws {
    let store = try claudeStore()
    try store.bindRunner(threadId: "codex-runner", automationId: nil)
    try bindClaude(store)
    let codex = try store.create(FaciendaTask(title: "Codex supplier", state: .needsMe))
    try store.link(ThreadLink(taskId: codex.id, codexThreadId: "codex-owner"))
    let claude = try store.create(FaciendaTask(title: "Claude supplier", state: .needsMe))
    try store.link(ThreadLink(taskId: claude.id, codexThreadId: "local_owner", provider: .claude))
    let due = Date().addingTimeInterval(600)
    _ = try store.planCheck(taskId: codex.id, threadId: "codex-owner", expectedRevision: 0, nextCheck: due, purpose: "Quote", reason: "Promised", waitingOn: "Supplier")
    _ = try store.planCheck(taskId: claude.id, threadId: "local_owner", expectedRevision: 0, nextCheck: due, purpose: "Quote", reason: "Promised", waitingOn: "Supplier")
    try store.enqueueDueChecks(runnerId: "codex-runner", now: due)
    #expect(try store.dispatches().map(\.taskId) == [codex.id])
    try store.enqueueDueChecks(runnerId: "local_runner", now: due)
    let checks = try store.dispatches()
    #expect(checks.count == 2)
    #expect(checks.first { $0.taskId == claude.id }?.agent == .claude)
    #expect(try store.claimDispatch(runnerId: "codex-runner")?.taskId == codex.id)
    guard case .deliver(let check) = try #require(try store.claimClaudeWork(runnerId: "local_runner", now: due)) else { Issue.record("Expected a check"); return }
    #expect(check.taskId == claude.id && check.kind == "check")
    _ = try store.beginClaudeDelivery(check.id, runnerId: "local_runner", now: due)
    #expect(throws: StoreError.self) { try store.enqueueDueChecks(runnerId: "stranger", now: due) }
}

@Test func setupBindsOnceAndRepairMovesTheRunner() throws {
    let store = try claudeStore()
    let setup = try store.prepareClaudeSetup()
    #expect(try store.prepareClaudeSetup().challenge == setup.challenge)
    #expect(throws: StoreError.self) { try store.bindClaudeRunner(sessionId: "local_a", challenge: "wrong", canStartSessions: false) }
    let bound = try store.bindClaudeRunner(sessionId: "local_a", challenge: setup.challenge, canStartSessions: false)
    #expect(bound.isBound && bound.isAwake())
    #expect(try store.bindClaudeRunner(sessionId: "local_a", challenge: setup.challenge, canStartSessions: false).sessionId == "local_a")
    #expect(throws: StoreError.self) { try store.bindClaudeRunner(sessionId: "local_b", challenge: setup.challenge, canStartSessions: false) }
    let repair = try store.prepareClaudeSetup(repair: true)
    #expect(repair.challenge != setup.challenge && repair.sessionId == "local_a")
    let moved = try store.bindClaudeRunner(sessionId: "local_b", challenge: repair.challenge, canStartSessions: false)
    #expect(moved.sessionId == "local_b")
    #expect(throws: StoreError.self) { try store.claudeRunnerHeartbeat("local_a") }
    try store.setClaudeRunnerCapabilities("local_b", canStartSessions: true)
    #expect(try store.claudeRunner()?.canStartSessions == true)
    #expect(try store.claudeRunner()?.isAwake(at: Date().addingTimeInterval(ClaudeRunnerState.awakeWindow + 1)) == false)
}

@Test func runnerWaitReturnsWhenWorkArrives() async throws {
    let store = try claudeStore()
    try bindClaude(store)
    let task = try claudeTask(store)
    let start = try store.enqueueDispatch(taskId: task.id)
    try store.handOffToClaudeComposer(start.id)
    let waiting = Task.detached { try store.waitForClaudeWork(runnerId: "local_runner", seconds: 5) }
    try await Task.sleep(for: .milliseconds(150))
    let producer = try FaciendaStore(url: store.url)
    try producer.attachClaudeSession(dispatchId: start.id, sessionId: "local_worker", cliSessionId: nil, cwd: nil)
    #expect(try await waiting.value)
}

@Test func claudeFoldersGetFaciendaToolsWithoutTouchingForeignFiles() throws {
    let store = try claudeStore()
    let folder = FileManager.default.temporaryDirectory.appending(path: "claude-folder-\(UUID().uuidString)")
    try store.prepareClaudeFolder(folder, mcpHelper: "/Apps/facienda-mcp")
    let server = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: ".mcp.json")))
    #expect(server["mcpServers"]["facienda"]["command"].string == "/Apps/facienda-mcp")
    #expect(server["mcpServers"]["facienda"]["args"].array?.last?.string == store.url.path)
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: ".claude/settings.local.json")))
    #expect(settings["enabledMcpjsonServers"].array == [.string("facienda")])
    // Only Facienda's tools and exactly the helper commands a task session's instructions name, pinned to this library.
    let base = "/Apps/facienda-mcp --database \(store.url.path)"
    #expect(settings["permissions"]["allow"].array == ["mcp__facienda", "Bash(\(base) --call *)", "Bash(\(base) --tools)", "Bash(\(base) --claude attach --dispatch-id *)",
                                                        "Bash(\(base) --claude await --dispatch-id *)", "Bash(\(base) --claude prompt --dispatch-id *)",
                                                        "Bash(\(base) --claude name --task-id *)"].map(JSONValue.string))
    #expect(!(settings["permissions"]["allow"].array ?? []).contains { $0.string?.hasSuffix("facienda-mcp *)") == true || $0.string?.contains("--runner") == true })
    // The prompts name the helper exactly as the rule does.
    #expect(store.claudeHelperBase(helper: "/Apps/facienda-mcp").hasPrefix("/Apps/facienda-mcp --database "))
    #expect(store.claudeHelperBase(helper: "/My Apps/facienda-mcp").hasPrefix("'/My Apps/facienda-mcp' --database "))
    // A file someone else wrote stays exactly as it was.
    try Data("{\"permissions\":{}}".utf8).write(to: folder.appending(path: ".claude/settings.local.json"))
    try store.prepareClaudeFolder(folder, mcpHelper: "/Apps/new-path/facienda-mcp")
    #expect(try String(contentsOf: folder.appending(path: ".claude/settings.local.json"), encoding: .utf8) == "{\"permissions\":{}}")
    // Facienda's own file follows the app when it moves.
    let moved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: ".mcp.json")))
    #expect(moved["mcpServers"]["facienda"]["command"].string == "/Apps/new-path/facienda-mcp")
}

@Test func everySetupOpensTheRunnerInAFolderClaudeHasNotSeen() throws {
    let store = try claudeStore()
    try store.prepareClaudeSetup()
    // The runner opens in the folder the user chose, never among the library's task folders.
    let runners = FileManager.default.temporaryDirectory.appending(path: "claude-runners-\(UUID().uuidString)")
    let first = try store.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners)
    let firstFolder = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value)
    #expect(firstFolder.hasPrefix(runners.appending(path: "runner-").path))
    #expect(!firstFolder.contains(store.nativeProjectDirectory.lastPathComponent))
    #expect(FaciendaStore.defaultClaudeRunnerFolder == (LibraryHome.savedDataFolder ?? LibraryHome.defaultDataFolder).appending(path: "claude"))
    // Only the runner's folder lets it apply settings and relay messages without stopping for approval.
    let runnerSettings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: firstFolder + "/.claude/settings.local.json")))
    #expect(runnerSettings["permissions"]["allow"].array?.contains(.string("mcp__ccd_session_mgmt__set_session_model")) == true)
    #expect(runnerSettings["permissions"]["allow"].array?.contains(.string("SendMessage")) == true)
    // Reopening the same setup keeps its folder; a repair gets a new one.
    #expect(try store.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners) == first)
    try store.prepareClaudeSetup(repair: true)
    let repaired = try store.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners)
    #expect(URLComponents(url: repaired, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value != firstFolder)
}

@Test func claudeTranscriptsBecomeTheSameConversation() throws {
    let lines: [String] = [
        #"{"type":"custom-title","customTitle":"Venue email","sessionId":"s"}"#,
        #"{"type":"user","uuid":"u1","timestamp":"2026-10-06T21:32:19.303Z","origin":{"kind":"human"},"message":{"role":"user","content":"Facienda dispatch: 11111111-2222-3333-4444-555555555555\nFacienda task: Venue email"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-06T21:32:25.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Linking the task first."},{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#,
        #"{"type":"user","uuid":"r1","timestamp":"2026-10-06T21:32:26.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"secret tool output"}]}}"#,
        #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-06T21:33:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Here is the draft."}],"stop_reason":"end_turn"}}"#,
        #"{"type":"user","uuid":"n1","timestamp":"2026-10-06T21:34:00.000Z","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
        #"{"type":"user","uuid":"s1","isSidechain":true,"timestamp":"2026-10-06T21:34:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"subagent prompt"}}"#,
        #"{"type":"user","uuid":"x1","timestamp":"2026-10-06T21:35:00.000Z","origin":{"kind":"peer"},"message":{"role":"user","content":"<cross-session-message from=\"Facienda runner\">Facienda dispatch: 66666666-7777-8888-9999-000000000000\nThe user replied in Facienda.</cross-session-message>"}}"#,
        #"{"type":"assistant","uuid":"a3","timestamp":"2026-10-06T21:35:10.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Working on the shorter version."},{"type":"tool_use","id":"t2","name":"Read","input":{}}],"stop_reason":"tool_use"}}"#,
        "not json"
    ]
    let conversation = ClaudeTranscript.conversation(from: Data(lines.joined(separator: "\n").utf8), threadId: "local_x")
    #expect(conversation.title == "Venue email")
    #expect(conversation.turns.count == 2)
    let first = conversation.turns[0]
    #expect(first.status == "completed")
    #expect(first.items.count == 3)
    #expect(first.items[1]["phase"].string == "commentary")
    #expect(first.items[2]["text"].string == "Here is the draft." && first.items[2]["phase"] == .null)
    #expect(!conversation.turns.flatMap(\.items).contains { $0.json.contains("secret") || $0.json.contains("private") || $0.json.contains("subagent") })
    let second = conversation.turns[1]
    #expect(second.status == "inProgress")
    #expect(conversation.containsDelivery("66666666-7777-8888-9999-000000000000"))
    let reply = NativeDispatch(id: "66666666-7777-8888-9999-000000000000", taskId: "t", state: "started", requestedAt: Date(), kind: "reply", message: "Make it shorter")
    #expect(second.messages(originalRequest: "Venue email", dispatches: [reply]).first?.text == "Make it shorter")
    #expect(first.messages(originalRequest: "Write the venue email", dispatches: []).first?.role == .automation)
}

@Test func transcriptsAreFoundByProjectFolderOrBySearching() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "claude-projects-\(UUID().uuidString)")
    let id = UUID().uuidString.lowercased()
    #expect(ClaudeTranscript.projectFolderName("/Users/me/projects/facienda") == "-Users-me-projects-facienda")
    #expect(ClaudeTranscript.projectFolderName("/tmp/a.b_c") == "-tmp-a-b-c")
    let folder = root.appending(path: "-tmp-work")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appending(path: id + ".jsonl"))
    #expect(ClaudeTranscript.locate(cliSessionId: id, cwd: "/tmp/work", in: root)?.lastPathComponent == id + ".jsonl")
    #expect(ClaudeTranscript.locate(cliSessionId: id, cwd: "/elsewhere", in: root) != nil)
    #expect(ClaudeTranscript.locate(cliSessionId: "../../etc/passwd", cwd: nil, in: root) == nil)
}

@Test func helperCallsAcceptPlainToolNamesAndExplainArguments() async throws {
    let store = try claudeStore()
    let task = try store.create(FaciendaTask(title: "Report a result", state: .running))
    let service = ToolService(store: store)
    #expect(ToolService.canonicalName("save_result") == "facienda_save_result")
    #expect(ToolService.canonicalName("facienda_save_result") == "facienda_save_result")
    do {
        _ = try service.call("save_result", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "result": .string("Done")]))
        Issue.record("Expected the wrong argument to be refused")
    } catch let StoreError.invalid(message) {
        #expect(message.contains("Unsupported argument result") && message.contains("taskId, text (required)"))
    }
    do {
        _ = try service.call("no_such_tool", arguments: .object([:]))
        Issue.record("Expected an unknown tool to be refused")
    } catch let StoreError.invalid(message) {
        #expect(message.contains("facienda_save_result"))
    }
    _ = try await service.callWithMemory("save_result", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "text": .string("Done")]))
    #expect(try store.latestEvent(taskId: task.id, kind: "codex.result")?.payload == "Done")
}

@Test func anAwakeRunnerStartsSessionsThroughTheAppsImportWithoutASend() throws {
    let store = try claudeStore()
    try bindClaude(store)
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    let transcripts = FileManager.default.temporaryDirectory.appending(path: "claude-transcripts-\(UUID().uuidString)")
    let imported = try store.importClaudeSession(dispatchId: item.id, helper: "/Apps/facienda-mcp", permissionMode: "auto", cliVersion: "2.1.289", transcripts: transcripts)
    #expect(imported.url.absoluteString == "claude://resume?session=" + imported.cliSessionId)
    #expect(imported.threadId == "local_" + imported.cliSessionId)
    #expect(imported.cwd == store.taskFolder(task.id).path)
    // The opening message is written the way the app writes its own, with the delivery marker first.
    let file = transcripts.appending(path: ClaudeTranscript.projectFolderName(imported.cwd)).appending(path: imported.cliSessionId + ".jsonl")
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    #expect(lines.count == 2)
    let opening = try #require(lines[0])
    #expect(opening["sessionId"] as? String == imported.cliSessionId && opening["cwd"] as? String == imported.cwd && opening["permissionMode"] as? String == "auto")
    #expect(((opening["message"] as? [String: Any])?["content"] as? String)?.hasPrefix("Facienda dispatch: \(item.id)\n") == true)
    #expect(lines[1]?["customTitle"] as? String == task.displayName)
    #expect(FileManager.default.fileExists(atPath: imported.cwd + "/.mcp.json"))
    // Linked at once, but held from the runner until the app has adopted it.
    #expect(try store.links(taskId: task.id).first?.threadId == imported.threadId)
    #expect(try store.claudeSession(imported.threadId)?.configureState == "importing")
    #expect(try store.claimClaudeWork(runnerId: "local_runner") == nil)
    #expect(throws: StoreError.self) { try store.importClaudeSession(dispatchId: item.id, helper: "/Apps/facienda-mcp", permissionMode: "auto", cliVersion: "2.1.289", transcripts: transcripts) }
    try store.confirmClaudeImport(dispatchId: item.id)
    guard case .configure(let session) = try #require(try store.claimClaudeWork(runnerId: "local_runner")) else { Issue.record("Expected a configure job"); return }
    #expect(session.threadId == imported.threadId && session.model == "claude-sonnet-5-5")
    try store.finishClaudeConfigure(threadId: imported.threadId, runnerId: "local_runner", applied: true, note: nil)
    guard case .deliver(let start) = try #require(try store.claimClaudeWork(runnerId: "local_runner")) else { Issue.record("Expected the start delivery"); return }
    #expect(start.id == item.id && start.threadId == imported.threadId && start.kind == "start")
    _ = try store.beginClaudeDelivery(item.id, runnerId: "local_runner")
    #expect(try store.claudeDelivery(item.id, sessionId: imported.threadId).id == item.id)
    try store.acknowledgeDispatch(item.id, runnerId: "local_runner", threadId: imported.threadId)
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "started")
    #expect(try store.links(taskId: task.id).count == 1)
}

@Test func anImportTheAppIgnoresIsRevertedForTheComposer() throws {
    let store = try claudeStore()
    try bindClaude(store)
    let task = try claudeTask(store)
    let item = try store.enqueueDispatch(taskId: task.id)
    let transcripts = FileManager.default.temporaryDirectory.appending(path: "claude-transcripts-\(UUID().uuidString)")
    let imported = try store.importClaudeSession(dispatchId: item.id, helper: "/Apps/facienda-mcp", permissionMode: "default", cliVersion: "2.1.289", transcripts: transcripts)
    let file = transcripts.appending(path: ClaudeTranscript.projectFolderName(imported.cwd)).appending(path: imported.cliSessionId + ".jsonl")
    try store.revertClaudeImport(dispatchId: item.id, transcripts: transcripts)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try store.links(taskId: task.id).isEmpty)
    #expect(try store.claudeSession(imported.threadId) == nil)
    let reverted = try #require(try store.dispatches().first { $0.id == item.id })
    #expect(reverted.state == "queued" && reverted.threadId == nil && reverted.availableAt == nil)
    // The composer hand-off still works afterwards, and a sleeping runner never imports.
    #expect(try store.handOffToClaudeComposer(item.id).awaitsClaudeSend)
    let asleep = try claudeStore()
    let setup = try asleep.prepareClaudeSetup()
    try asleep.bindClaudeRunner(sessionId: "local_r", challenge: setup.challenge, canStartSessions: false, now: Date().addingTimeInterval(-3600))
    let other = try claudeTask(asleep)
    let queued = try asleep.enqueueDispatch(taskId: other.id)
    #expect(throws: StoreError.self) { try asleep.importClaudeSession(dispatchId: queued.id, helper: "/Apps/facienda-mcp", permissionMode: "auto", cliVersion: "2.1.289", transcripts: transcripts) }
}

@Test func theAppsSessionRegistryIsSearchedByCliSessionId() throws {
    let registry = FileManager.default.temporaryDirectory.appending(path: "claude-registry-\(UUID().uuidString)")
    let organisation = registry.appending(path: "account/org")
    try FileManager.default.createDirectory(at: organisation, withIntermediateDirectories: true)
    #expect(!ClaudeDesktop.sessionExists(cliSessionId: "ABC", registry: registry))
    try Data("{}".utf8).write(to: organisation.appending(path: "local_abc.json"))
    #expect(ClaudeDesktop.sessionExists(cliSessionId: "ABC", registry: registry))
    let settings = registry.appending(path: "settings.json")
    #expect(ClaudeDesktop.defaultPermissionMode(settings: settings) == "default")
    try Data("{\"permissions\":{\"defaultMode\":\"auto\"}}".utf8).write(to: settings)
    #expect(ClaudeDesktop.defaultPermissionMode(settings: settings) == "auto")
}

@Test func aNewRunnerClearsAwayOnlyItsLibrarysEarlierRunnerFolders() throws {
    let store = try claudeStore()
    let runners = FileManager.default.temporaryDirectory.appending(path: "claude-runners-\(UUID().uuidString)")
    try store.prepareClaudeSetup()
    let old = URL(fileURLWithPath: try #require(URLComponents(url: try store.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value))
    // One earlier runner folder where a session left a file of its own, and another library's.
    try store.prepareClaudeSetup(repair: true)
    let kept = URL(fileURLWithPath: try #require(URLComponents(url: try store.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value))
    try Data("notes".utf8).write(to: kept.appending(path: "notes.md"))
    let other = try claudeStore()
    try other.prepareClaudeSetup()
    let foreign = URL(fileURLWithPath: try #require(URLComponents(url: try other.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value))
    try store.prepareClaudeSetup(repair: true)
    let current = URL(fileURLWithPath: try #require(URLComponents(url: try store.claudeSetupURL(helper: "/Apps/facienda-mcp", runnerFolder: runners), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value))
    store.removeRetiredClaudeRunnerFolders(keeping: current)
    let exists = { (folder: URL) in FileManager.default.fileExists(atPath: folder.path) }
    #expect(exists(current) && exists(kept) && exists(foreign))
    #expect(!exists(old))
}

@Test func claudeHookShowsAPermissionPromptUntilTheSessionMovesOn() throws {
    let store = try claudeStore(), task = try claudeTask(store)
    _ = try store.update(task.id) { $0.state = .running }
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "local_work", provider: .claude))
    try store.write { db in
        try ClaudeSession(threadId: "local_work", taskId: task.id, cliSessionId: "9F3C2A10-0000-4000-8000-00000000AB12", cwd: nil, linkedAt: Date(),
                          model: nil, effort: nil, fast: false, configureState: "done", configureClaimedAt: nil, configuredAt: nil, configureNote: nil).insert(db)
    }
    let status = { try store.threadLink(threadId: "local_work")?.lastKnownStatus }
    // Claude names the session by its CLI ID, in lower case.
    func send(_ event: String, session: String = "9f3c2a10-0000-4000-8000-00000000ab12", type: String? = nil) throws {
        let json = #"{"session_id":"\#(session)","hook_event_name":"\#(event)""# + (type.map { #","notification_type":"\#($0)""# } ?? "") + "}"
        try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(json.utf8)).apply(to: store)
    }
    // Moving on says nothing while no prompt is open: turns are read from the transcript.
    try send("Stop")
    #expect(try status() == "unknown")
    try send("PermissionRequest")
    #expect(try status() == "waitingOnApproval")
    // Within the grace the task stays running; the board already shows the prompt.
    #expect(try store.task(task.id).state == .running)
    try send("PostToolUse")
    #expect(try status() == "active")
    try send("Notification", type: "idle_prompt")
    #expect(try status() == "active")
    try send("Notification", type: "permission_prompt")
    #expect(try status() == "waitingOnApproval")
    // Denied, and the turn ended: the task comes back for review.
    try send("Stop")
    #expect(try status() == "idle")
    #expect(try store.task(task.id).state == .needsMe)
    // Sessions Facienda did not start are left alone.
    try send("PermissionRequest", session: "00000000-0000-4000-8000-000000000000")
    #expect(try status() == "idle")
    // A prompt sent in Claude runs a turn at once, before the transcript is next read.
    try send("UserPromptSubmit")
    #expect(try status() == "active")
    #expect(try store.task(task.id).state == .running)
    // Its end is still read from the transcript: another hook may keep the turn going.
    try send("Stop")
    #expect(try status() == "active")
}

@Test func anAgentAskingMidTurnLeavesItsTaskRunningUntilTheTurnStops() throws {
    let store = try claudeStore(), task = try claudeTask(store)
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "local_work", provider: .claude))
    try store.observe(threadId: "local_work", status: "active", source: .app, verified: true)
    #expect(try store.task(task.id).state == .running)
    let service = ToolService(store: store)
    _ = try service.call("facienda_save_result", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "text": .string("The venue email is drafted.")]))
    _ = try service.call("facienda_request_decision", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "question": .string("May I send the venue email?"), "recommendation": .string("Send"), "options": .array([.string("Send"), .string("Not yet")]), "kind": .string("permission")]))
    // The agent is still writing its reply, so the board keeps showing it at work.
    #expect(try store.task(task.id).state == .running)
    try store.observe(threadId: "local_work", status: "idle", source: .app, verified: true)
    let back = try store.task(task.id)
    #expect(back.state == .needsMe && back.nextAction == "May I send the venue email?")
    // Asked with no turn running, the task comes back at once.
    _ = try store.update(task.id) { $0.state = .running }
    _ = try service.call("facienda_propose_completion", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "evidence": .string("Sent.")]))
    #expect(try store.task(task.id).state == .needsMe)
}

@Test func agentsCanAskForPermissionRatherThanAnAnswer() throws {
    let store = try claudeStore(), task = try claudeTask(store)
    let service = ToolService(store: store)
    _ = try service.call("facienda_request_decision", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "question": .string("May I send the venue email?"), "recommendation": .string("Send"), "options": .array([.string("Send"), .string("Not yet")]), "kind": .string("permission")]))
    _ = try service.call("facienda_request_decision", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "question": .string("Which date?"), "recommendation": .string("Fri"), "options": .array([.string("Fri")])]))
    #expect(try store.decisions(taskId: task.id).map(\.kind) == ["permission", "decision"])
    #expect(throws: StoreError.self) {
        _ = try service.call("facienda_request_decision", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "question": .string("?"), "recommendation": .string("a"), "options": .array([.string("a")]), "kind": .string("vote")]))
    }
}
