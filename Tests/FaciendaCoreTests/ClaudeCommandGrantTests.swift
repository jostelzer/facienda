import Foundation
import Testing
@testable import FaciendaCore

private func grantStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "ClaudeCommandGrantTests/\(UUID().uuidString)/test.sqlite"))
}

/// A Claude task whose session Claude Code knows by `cli`.
private func claudeTask(_ store: FaciendaStore, title: String, session: String, cli: String) throws -> FaciendaTask {
    var task = FaciendaTask(title: title, state: .needsMe)
    task.workerModel = "claude-sonnet-5-5"; task.workerProvider = .claude
    task = try store.create(task)
    let item = try store.enqueueDispatch(taskId: task.id)
    try store.handOffToClaudeComposer(item.id)
    try store.attachClaudeSession(dispatchId: item.id, sessionId: session, cliSessionId: cli, cwd: "/tmp/work")
    return task
}

private func hook(_ session: String, _ command: String) throws -> ClaudeHookEvent {
    let event: JSONValue = .object(["session_id": .string(session), "hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"),
                                    "tool_input": .object(["command": .string(command), "description": .string("Restart the gateway")])])
    return try JSONDecoder().decode(ClaudeHookEvent.self, from: Data(event.json.utf8))
}

private let restart = "ssh orchard@greenhouse 'systemctl restart sprinkler-gateway'"

@Test func anAllowedCommandPassesOnceForItsOwnSessionOnly() throws {
    let store = try grantStore()
    let task = try claudeTask(store, title: "Fix the sprinkler alarm", session: "local_a", cli: "11111111-1111-4111-8111-111111111111")
    _ = try claudeTask(store, title: "Plan the harvest", session: "local_b", cli: "22222222-2222-4222-8222-222222222222")
    let decision = try store.requestCommandPermission(taskId: task.id, question: "May I restart the sprinkler gateway?", context: "The fix is deployed.", command: restart)
    #expect(decision.kind == "permission")
    #expect(decision.options == [FaciendaStore.allowOnce, FaciendaStore.dontAllow])
    #expect(try store.commandGrant(decisionId: decision.id)?.command == restart)

    // Asked is not allowed.
    #expect(try !store.useClaudeCommandGrant(cliSessionId: "11111111-1111-4111-8111-111111111111", command: restart))
    #expect(try hook("11111111-1111-4111-8111-111111111111", restart).preToolUse(in: store)?["hookSpecificOutput"]["permissionDecision"].string == nil)

    try store.answerDecision(decision.id, answer: FaciendaStore.allowOnce)
    // Another task's session, or the command changed by one character, gets nothing.
    #expect(try !store.useClaudeCommandGrant(cliSessionId: "22222222-2222-4222-8222-222222222222", command: restart))
    #expect(try !store.useClaudeCommandGrant(cliSessionId: "11111111-1111-4111-8111-111111111111", command: restart + " "))
    let allowed = try hook("11111111-1111-4111-8111-111111111111", restart).preToolUse(in: store)
    #expect(allowed?["hookSpecificOutput"]["permissionDecision"].string == "allow")
    #expect(allowed?["hookSpecificOutput"]["hookEventName"].string == "PreToolUse")
    // Once only.
    #expect(try hook("11111111-1111-4111-8111-111111111111", restart).preToolUse(in: store)?["hookSpecificOutput"]["permissionDecision"].string == nil)
}

@Test func onlyAllowOnceWithinTheHourAllows() throws {
    let store = try grantStore()
    let task = try claudeTask(store, title: "Fix the sprinkler alarm", session: "local_a", cli: "33333333-3333-4333-8333-333333333333")
    let refused = try store.requestCommandPermission(taskId: task.id, question: "May I restart the gateway?", context: "", command: restart)
    try store.answerDecision(refused.id, answer: FaciendaStore.dontAllow)
    #expect(try !store.useClaudeCommandGrant(cliSessionId: "33333333-3333-4333-8333-333333333333", command: restart))

    let late = try store.requestCommandPermission(taskId: task.id, question: "May I restart the gateway now?", context: "", command: restart)
    try store.answerDecision(late.id, answer: FaciendaStore.allowOnce)
    #expect(try !store.useClaudeCommandGrant(cliSessionId: "33333333-3333-4333-8333-333333333333", command: restart, now: Date().addingTimeInterval(2 * 3600)))
    #expect(try store.useClaudeCommandGrant(cliSessionId: "33333333-3333-4333-8333-333333333333", command: restart))
}

@Test func commandPermissionsAreForClaudeTasksAndKeepTheirCommand() throws {
    let store = try grantStore()
    let codex = try store.create(FaciendaTask(title: "Codex work", state: .needsMe))
    #expect(throws: StoreError.self) { try store.requestCommandPermission(taskId: codex.id, question: "May I?", context: "", command: restart) }
    let task = try claudeTask(store, title: "Fix the sprinkler alarm", session: "local_a", cli: "44444444-4444-4444-8444-444444444444")
    #expect(throws: StoreError.self) { try store.requestCommandPermission(taskId: task.id, question: "May I?", context: "", command: "  ") }
    let first = try store.requestCommandPermission(taskId: task.id, question: "May I restart it?", context: "", command: restart)
    // The same words again return the waiting question, but never for another command.
    #expect(try store.requestCommandPermission(taskId: task.id, question: "May I restart it?", context: "", command: restart).id == first.id)
    #expect(throws: StoreError.self) { try store.requestCommandPermission(taskId: task.id, question: "May I restart it?", context: "", command: "rm -rf ~/greenhouse") }
}
