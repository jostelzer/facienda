import Foundation
import GRDB
import Testing
@testable import FaciendaCore

/// A library in a data folder of its own: `data/.facienda/facienda.sqlite`, task folders beside it.
private func library() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "AgentBoundaryTests/\(UUID().uuidString)/data/.facienda/facienda.sqlite"))
}

private let helper = "/Apps/facienda-mcp"

@Test func handlesOpenOnlyTheirOwnTask() throws {
    let store = try library()
    let mine = try store.create(FaciendaTask(title: "Mine")), theirs = try store.create(FaciendaTask(title: "Theirs"))
    let handle = try store.taskHandle(mine.id), other = try store.taskHandle(theirs.id)
    #expect(try store.taskHandle(mine.id) == handle)
    #expect(handle.hasPrefix(mine.id + ".") && handle.count == mine.id.count + 33 && handle != other)
    #expect(try store.taskID(forHandle: handle) == mine.id)
    // A bare ID, another task's secret, a made-up secret and nothing at all open nothing, and say what to pass instead.
    let secret = String(handle.split(separator: ".").last!), forged = theirs.id + "." + secret
    for (attempt, hint) in [(mine.id, "not a bare task ID"), (forged, "not a valid Facienda task handle"), (mine.id + "." + String(repeating: "0", count: 32), "not a valid"),
                            ("", "Pass taskId"), (handle.uppercased(), "not a bare task ID")] {
        do { _ = try store.taskID(forHandle: attempt); Issue.record("\(attempt) opened a task") }
        catch let StoreError.invalid(message) { #expect(message.contains(hint) && message.contains("latest Facienda instructions")) }
    }
    let tools = ToolService(store: store)
    _ = try tools.call("task_update", arguments: .object(["taskId": .string(handle), "brief": .string("Drafted")]))
    #expect(try store.task(mine.id).brief == "Drafted" && store.task(theirs.id).brief.isEmpty)
    for name in ["task_update", "save_result", "get_blockers", "get_check_plan", "propose_completion", "memory_recall", "chat_search", "task_search"] {
        var arguments: [String: JSONValue] = ["taskId": .string(theirs.id)]
        for key in ToolService.definitions.first(where: { $0.name == "facienda_" + name })!.schema["required"].array!.compactMap(\.string) where key != "taskId" { arguments[key] = .string("x") }
        #expect(throws: StoreError.self, "\(name) took a bare ID") { try tools.call(name, arguments: .object(arguments)) }
        arguments["taskId"] = .string(forged)
        #expect(throws: StoreError.self, "\(name) took a forged handle") { try tools.call(name, arguments: .object(arguments)) }
    }
    // A blocker of another task cannot be removed through this task's handle.
    let blocker = try store.setExternalBlocker(taskId: theirs.id, kind: "condition", title: "Reply", sourceReference: "Mail", criterion: "A reply", freshnessSeconds: nil)
    #expect(throws: StoreError.self) {
        try tools.call("remove_blocker", arguments: .object(["taskId": .string(handle), "blockerId": .string(blocker.id), "expectedRevision": .string("1"), "userInstruction": .string("Remove it")]))
    }
    #expect(try store.blockers(taskId: theirs.id).count == 1)
}

@Test func taskSearchStaysInsideTheHandlesMemoryAndNeverPassesOnHandles() throws {
    let store = try library()
    let work = try store.createWorkspace(name: "Work")
    let home = try store.scoped(to: try store.defaultWorkspace().id).create(FaciendaTask(title: "Trip"))
    let job = try store.scoped(to: work.id).create(FaciendaTask(title: "Hire"))
    let sibling = try store.scoped(to: work.id).create(FaciendaTask(title: "Onboard"))
    // An agent wrote a sibling's handle into its brief; search gives the bare ID only.
    let leaked = try store.taskHandle(sibling.id)
    _ = try store.update(sibling.id) { $0.brief = "Use \(leaked) for this" }
    let tools = ToolService(store: store)
    #expect(throws: StoreError.self) { try tools.call("task_search", arguments: .object(["query": .string("")])) }
    let found = try tools.call("task_search", arguments: .object(["query": .string(""), "taskId": .string(try store.taskHandle(job.id))]))
    #expect(Set(found.array?.compactMap { $0["id"].string } ?? []) == [job.id, sibling.id])
    #expect(!found.json.contains(leaked) && found.json.contains("Use \(sibling.id) for this"))
    #expect(!found.json.contains(home.id))
    // A task made from this one joins its workspace and comes with its own handle.
    let created = try tools.call("task_create", arguments: .object(["title": .string("Follow-up"), "nextAction": .string("Draft"), "fromTaskId": .string(try store.taskHandle(job.id))]))
    #expect(created["workspaceId"].string == work.id)
    #expect(try store.taskID(forHandle: created["handle"].string ?? "") == created["id"].string)
    #expect(throws: StoreError.self) { try tools.call("task_create", arguments: .object(["title": .string("X"), "nextAction": .string("Y"), "fromTaskId": .string(job.id)])) }
}

@Test func currentTaskGivesDataOnlyWithTheThreadsOwnHandle() throws {
    let store = try library()
    let mine = try store.create(FaciendaTask(title: "Mine", brief: "Private brief")), theirs = try store.create(FaciendaTask(title: "Theirs", brief: "Their brief"))
    try store.link(ThreadLink(taskId: mine.id, codexThreadId: "my-chat"))
    try store.link(ThreadLink(taskId: theirs.id, codexThreadId: "their-chat"))
    let tools = ToolService(store: store), handle = try store.taskHandle(mine.id)
    func current(_ thread: String, _ taskId: String? = nil) throws -> JSONValue {
        var arguments: [String: JSONValue] = ["threadId": .string(thread)]
        if let taskId { arguments["taskId"] = .string(taskId) }
        return try tools.call("current_task", arguments: .object(arguments))
    }
    // With its own handle, the chat reads its task.
    let full = try current("my-chat", handle)
    #expect(full["id"].string == mine.id && full["brief"].string == "Private brief")
    // A thread ID alone says only whether it is linked: no ID, title or brief.
    for thread in ["their-chat", "my-chat", "nobody"] {
        let bare = try current(thread)
        #expect(bare["linked"].bool == (thread != "nobody"))
        #expect(!bare.json.contains(mine.id) && !bare.json.contains(theirs.id) && !bare.json.contains("brief") && !bare.json.contains("Theirs"))
    }
    // Another thread, a bare ID or a forged handle open nothing.
    #expect(throws: StoreError.self) { try current("their-chat", handle) }
    #expect(throws: StoreError.self) { try current("nobody", handle) }
    #expect(throws: StoreError.self) { try current("their-chat", theirs.id) }
    #expect(throws: StoreError.self) { try current("their-chat", theirs.id + "." + String(handle.split(separator: ".").last!)) }
}

@Test func promptsAndHooksGiveTheHandle() async throws {
    let store = try library(), task = try store.create(FaciendaTask(title: "Book the ferry", state: .needsMe))
    let handle = try store.taskHandle(task.id)
    let item = try store.enqueueDispatch(taskId: task.id)
    let prompt = try await DispatchPrompt.payload(item, store: store, base: "facienda-mcp --database DB")["workerPrompt"].string ?? ""
    #expect(prompt.contains("TASK HANDLE: \(handle)") && prompt.contains("facienda_memory_find(text, taskId: \(handle))") && prompt.contains("fromTaskId \(handle)"))
    #expect(!prompt.contains("--runner rules"))
    #expect(!prompt.replacingOccurrences(of: handle, with: "HANDLE").contains("taskId \(task.id)"))
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "chat", role: "work", linkedBy: "user"))
    let event = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"session_id":"chat","hook_event_name":"UserPromptSubmit"}"#.utf8))
    let context = try event.apply(to: store)?["hookSpecificOutput"]["additionalContext"].string ?? ""
    #expect(context.contains("Facienda task handle: \(handle)") && !context.contains("Facienda task ID"))
    // Its instructions come back only through the handle.
    let tools = ToolService(store: store, helper: helper)
    #expect(throws: StoreError.self) { try tools.call("task_instructions", arguments: .object(["taskId": .string(task.id)])) }
}

@Test func agentsAskTheUserInsteadOfArmingAStart() throws {
    let store = try library()
    let prerequisite = try store.create(FaciendaTask(title: "Get the quote")), task = try store.create(FaciendaTask(title: "Order"))
    try store.addTaskDependencies(taskId: task.id, prerequisiteIDs: [prerequisite.id])
    let tools = ToolService(store: store), handle = try store.taskHandle(task.id)
    let asked = try tools.call("set_readiness", arguments: .object(["taskId": .string(handle), "armed": .string("true"), "userInstruction": .string("The user said: start as soon as the quote is in")]))
    // Nothing is armed or queued: the user gets a permission question quoting the agent.
    #expect(try store.readiness(task.id).armed == false)
    #expect(try store.dispatches().filter { $0.taskId == task.id }.isEmpty)
    let decision = try #require(try store.decisions(taskId: task.id).first)
    #expect(asked["decision"]["id"].string == decision.id)
    #expect(decision.kind == "permission" && decision.question == FaciendaStore.readinessQuestion && decision.context.contains("“The user said: start as soon as the quote is in”"))
    #expect(try store.events(taskId: task.id).filter { $0.kind.hasPrefix("readiness.") }.allSatisfy { $0.source == .mcp && !$0.verified })
    // Asking again does not ask twice, and agents may not ask the question themselves or arm through the store.
    _ = try tools.call("set_readiness", arguments: .object(["taskId": .string(handle), "armed": .string("true"), "userInstruction": .string("Start it")]))
    #expect(try store.decisions(taskId: task.id).count == 1)
    #expect(throws: StoreError.self) {
        try tools.call("request_decision", arguments: .object(["taskId": .string(handle), "question": .string(FaciendaStore.readinessQuestion), "recommendation": .string("Start when ready"), "options": .array([.string("Start when ready")]), "kind": .string("permission")]))
    }
    #expect(throws: StoreError.self) { try store.setReadiness(taskId: task.id, armed: true, userInstruction: "Agent", source: .mcp) }
    #expect(try store.dispatches().filter { $0.taskId == task.id }.isEmpty)
    // The user's answer arms it, once, with the start held for the prerequisite.
    try store.answerDecision(decision.id, answer: FaciendaStore.readinessApproval)
    try store.write { try store.reconcileBlockers($0, now: Date()) }
    try store.write { try store.reconcileBlockers($0, now: Date()) }
    let ready = try store.readiness(task.id)
    #expect(ready.armed && ready.userInstruction.hasPrefix("Approved in Facienda"))
    #expect(try store.dispatches().filter { $0.taskId == task.id }.map(\.state) == ["held"])
    #expect(try store.events(taskId: task.id).filter { $0.kind == "readiness.approved" }.count == 1)
    // Pausing stays the agent's to do.
    _ = try tools.call("set_readiness", arguments: .object(["taskId": .string(handle), "armed": .string("false"), "userInstruction": .string("Hold off")]))
    #expect(try store.readiness(task.id).armed == false)
}

@Test func noToolQueuesWorkOrSpeaksForTheUser() throws {
    let store = try library(), task = try store.create(FaciendaTask(title: "Plan", state: .needsMe))
    let tools = ToolService(store: store), handle = try store.taskHandle(task.id)
    let calls: [(String, [String: JSONValue])] = [
        ("task_update", ["brief": .string("x"), "proposedState": .string("needsMe")]), ("save_result", ["text": .string("Done")]),
        ("request_decision", ["question": .string("Q?"), "recommendation": .string("A"), "options": .array([.string("A")])]),
        ("schedule_followup", ["nextAction": .string("Look"), "returnAt": .string("2099-01-01T00:00:00Z")]),
        ("propose_completion", ["evidence": .string("Sent")]), ("memory_remember", ["text": .string("Fact"), "source": .string("User 2026")]),
        ("set_blocker", ["kind": .string("condition"), "title": .string("Reply"), "sourceReference": .string("Mail"), "criterion": .string("A reply")]),
        ("set_readiness", ["armed": .string("true"), "userInstruction": .string("Go")])
    ]
    let before = try store.events(taskId: task.id).filter { $0.source == .user }.count
    for (name, arguments) in calls { _ = try tools.call(name, arguments: .object(arguments.merging(["taskId": .string(handle)]) { $1 })) }
    #expect(try store.dispatches().isEmpty)
    #expect(try store.events(taskId: task.id).filter { $0.source == .user }.count == before)
}

@Test func theHelperTakesOneModeAndCallTakesNothingElse() throws {
    #expect(try HelperPolicy.mode(["h"]) == .server)
    #expect(try HelperPolicy.mode(["h", "--database", "/db", "--call", "save_result", "--arguments-file", "/tmp/a.json"]) == .call)
    #expect(try HelperPolicy.mode(["h", "--database", "/db", "--tools"]) == .tools)
    #expect(try HelperPolicy.mode(["h", "--database", "/db", "--claude", "prompt", "--dispatch-id", "D"]) == .claude)
    for refused in [["h", "--database", "/db", "--call", "x", "--arguments", "{}", "--runner", "enqueue"],
                    ["h", "--database", "/db", "--call", "x", "--arguments-file", "f", "--claude", "bind"],
                    ["h", "--call", "x", "--arguments", "{}", "--init"],
                    ["h", "--call", "x", "--arguments", "{}", "--database", "/other", "--database", "/db"],
                    ["h", "--database", "/db", "--call", "x", "--arguments", "{}", "--library-folder", "/tmp/x"],
                    ["h", "--database", "/db", "--call", "x", "--arguments", "{}", "--arguments-file", "f"],
                    ["h", "--database", "/db", "--call", "x"],
                    ["h", "--database", "/db", "--tools", "--session-id", "s"],
                    ["h", "--claude", "prompt", "--dispatch-id", "D", "--runner", "rules"],
                    ["h", "--runner", "tick", "--runner", "enqueue"]] {
        #expect(throws: StoreError.self, "\(refused)") { try HelperPolicy.mode(refused) }
    }
    // The commands that answered approvals, queued replies or reprinted any delivery are gone.
    for removed in ["answer-approval", "enqueue", "retry-undelivered", "rules"] { #expect(!HelperPolicy.runnerCommands.contains(removed)) }
    #expect(HelperPolicy.runnerCommands.isSuperset(of: ["tick", "wait", "prepare", "begin", "ack", "defer", "context", "approvals"]))
}

@Test func theHelperServesOnlyFaciendasLibraries() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AgentBoundaryTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let app = URL(fileURLWithPath: "/Users/someone/facienda/.facienda/facienda.sqlite"), test = root.appending(path: "smoke.sqlite")
    let testing = [HelperPolicy.testEnvironment: "1"]
    #expect(try HelperPolicy.database(["h"], environment: [:], app: app) == app)
    #expect(try HelperPolicy.database(["h", "--database", app.path], environment: [:], app: app) == app)
    #expect(throws: StoreError.self) { try HelperPolicy.database(["h", "--database", "/etc/facienda.sqlite"], environment: testing, app: app) }
    // Temp libraries only for tests, and only tests make libraries.
    #expect(throws: StoreError.self) { try HelperPolicy.database(["h", "--database", test.path], environment: [:], app: app) }
    #expect(try HelperPolicy.database(["h", "--database", test.path], environment: testing, app: app) == test)
    #expect(throws: StoreError.self) { try HelperPolicy.database(["h", "--database", test.path], environment: [:], app: app, creating: true) }
    #expect(throws: StoreError.self) { try HelperPolicy.database(["h", "--database", app.path], environment: testing, app: app, creating: true) }
    #expect(throws: StoreError.self) { try HelperPolicy.database(["h", "--library-folder", root.path], environment: [:], app: app) }
    // An experiment library is served once it is one; a look-alike SQLite file is neither served nor migrated.
    let experiment = try FaciendaStore(url: root.appending(path: "experiment/.facienda/facienda.sqlite"))
    #expect(try HelperPolicy.database(["h", "--library-folder", root.appending(path: "experiment/.facienda").path], environment: [:], app: app).path == experiment.url.path)
    let fake = root.appending(path: "fake/.facienda/facienda.sqlite")
    try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseQueue(path: fake.path).write { try $0.execute(sql: "CREATE TABLE notes (text TEXT)") }
    #expect(!HelperPolicy.isLibrary(fake) && HelperPolicy.isLibrary(experiment.url))
    #expect(throws: StoreError.self) { try HelperPolicy.database(["h", "--database", fake.path], environment: [:], app: app) }
    #expect(throws: StoreError.self) { try HelperPolicy.open(fake) }
    #expect(try DatabaseQueue(path: fake.path).read { try $0.tableExists("grdb_migrations") } == false)
    #expect(throws: StoreError.self) { try HelperPolicy.open(root.appending(path: "missing.sqlite")) }
}

@Test func fileFlagsReadOnlyRegularFilesInFaciendasFolders() throws {
    let store = try library()
    let folders = HelperPolicy.readableFolders(store)
    let task = store.taskFolder("T")
    try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
    let arguments = task.appending(path: "arguments.json")
    try Data("{\"text\":\"Done\"}".utf8).write(to: arguments)
    #expect(try HelperPolicy.read(arguments.path, from: folders, limit: 1024) == Data("{\"text\":\"Done\"}".utf8))
    // Outside Facienda's folders, through a symlink, a folder, or too large: refused.
    #expect(throws: StoreError.self) { try HelperPolicy.read("/etc/hosts", from: folders, limit: 1 << 20) }
    let link = task.appending(path: "hosts.json")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
    #expect(throws: StoreError.self) { try HelperPolicy.read(link.path, from: folders, limit: 1 << 20) }
    #expect(throws: StoreError.self) { try HelperPolicy.read(task.path, from: folders, limit: 1 << 20) }
    #expect(throws: StoreError.self) { try HelperPolicy.read(arguments.path, from: folders, limit: 4) }
    #expect(throws: StoreError.self) { try HelperPolicy.read(arguments.path, from: [URL(fileURLWithPath: "/Applications")], limit: 1024) }
    #expect(try HelperPolicy.folder(task.path, from: folders) == HelperPolicy.canonical(task))
    #expect(throws: StoreError.self) { try HelperPolicy.folder("/etc", from: folders) }
    // A folder chosen for an open task is readable too.
    _ = try store.create(FaciendaTask(title: "In a project", cwd: "/Applications"))
    #expect(HelperPolicy.readableFolders(store).contains(URL(fileURLWithPath: "/Applications")))
}

@Test func claudeFoldersArePrivateAndRunnerFoldersAllowOnlyRelaying() throws {
    let store = try library()
    let folder = store.taskFolder("T")
    try store.prepareClaudeFolder(folder, mcpHelper: helper)
    for path in [folder.path, folder.appending(path: ".claude").path] {
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o700)
    }
    for path in [folder.appending(path: ".mcp.json").path, folder.appending(path: ".claude/settings.local.json").path] {
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
    }
    let runner = store.claudeRunnerRules(helper: helper)
    #expect(runner.allSatisfy { !$0.contains("--call") && !$0.contains("--runner") && !$0.hasSuffix("--claude *)") && $0 != "mcp__facienda" })
    #expect(runner.contains("Bash(\(store.claudeHelperBase(helper: helper)) --claude next)"))
    // A folder an earlier build prepared with a rule for every helper command gets today's rules, keeping its linked folders.
    let old = store.workFolder.appending(path: try store.create(FaciendaTask(title: "Old")).id)
    try FileManager.default.createDirectory(at: old.appending(path: ".claude"), withIntermediateDirectories: true)
    let legacy: JSONValue = .object(["enabledMcpjsonServers": .array([.string("facienda")]), "permissions": .object([
        "allow": .array([.string("mcp__facienda"), .string("Bash(\(helper) *)")]), "additionalDirectories": .array([.string("/Users/me/site")])])])
    try Data(legacy.json.utf8).write(to: old.appending(path: ".claude/settings.local.json"))
    store.narrowClaudeFolders(helper: helper, runnerBase: store.workFolder.appending(path: "claude"))
    let narrowed = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: old.appending(path: ".claude/settings.local.json")))
    #expect(narrowed["permissions"]["allow"].array == store.claudeTaskRules(helper: helper).map(JSONValue.string))
    #expect(narrowed["permissions"]["additionalDirectories"].array == [.string("/Users/me/site")])
    #expect(narrowed["autoCompactWindow"] == .null)
    // The runner already running gets its bound from the folder it works in.
    let runnerFolder = store.workFolder.appending(path: "claude/runner-old")
    try FileManager.default.createDirectory(at: runnerFolder.appending(path: ".claude"), withIntermediateDirectories: true)
    let unbounded: JSONValue = .object(["enabledMcpjsonServers": .array([.string("facienda")]),
                                        "permissions": .object(["allow": .array(runner.map(JSONValue.string))])])
    try Data(unbounded.json.utf8).write(to: runnerFolder.appending(path: ".claude/settings.local.json"))
    try Data(store.url.path.utf8).write(to: runnerFolder.appending(path: FaciendaStore.claudeRunnerMarker))
    store.narrowClaudeFolders(helper: helper, runnerBase: store.workFolder.appending(path: "claude"))
    let bounded = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: runnerFolder.appending(path: ".claude/settings.local.json")))
    #expect(bounded["autoCompactWindow"].number == Double(FaciendaStore.claudeRunnerContext))
    #expect(bounded["permissions"]["allow"].array == runner.map(JSONValue.string))
}
