import Foundation
import Testing
@testable import FaciendaCore

private func sidebarStore() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "ClaudeSidebarTests/\(UUID().uuidString)/test.sqlite"))
}

@Test func runnerFilesTaskSessionsIntoOneSidebarGroupUntilTurnedOff() throws {
    let store = try sidebarStore()
    #expect(try store.groupsClaudeSessions())
    let step = try #require(try store.claudeSidebarStep(threadId: "local_worker"))
    #expect(step.contains("mcp__ccd_sidebar__move_sessions") && step.contains("[\"local_worker\"]"))
    #expect(step.contains("named exactly \"\(FaciendaStore.claudeSidebarGroupName)\""))

    try store.setGroupsClaudeSessions(false)
    #expect(try !store.groupsClaudeSessions())
    #expect(try store.claudeSidebarStep(threadId: "local_worker") == nil)
    // The choice belongs to the library, so the helper reads the same answer.
    #expect(try !FaciendaStore(url: store.url).groupsClaudeSessions())
}

@Test func runnerMayFileSessionsWithoutAskingAndAnOlderRunnerFolderLearnsIt() throws {
    let store = try sidebarStore()
    let helper = "/Apps/facienda-mcp"
    let rules = store.claudeRunnerRules(helper: helper)
    for tool in ["list_groups", "create_group", "move_sessions"] { #expect(rules.contains("mcp__ccd_sidebar__" + tool)) }
    // Task sessions never get them: filing is the runner's job.
    #expect(store.claudeTaskRules(helper: helper).allSatisfy { !$0.hasPrefix("mcp__ccd_sidebar__") })

    let runnerBase = store.workFolder.appending(path: "claude")
    let folder = runnerBase.appending(path: "runner-old")
    try FileManager.default.createDirectory(at: folder.appending(path: ".claude"), withIntermediateDirectories: true)
    let older = rules.filter { !$0.hasPrefix("mcp__ccd_sidebar__") }
    let settings: JSONValue = .object(["enabledMcpjsonServers": .array([.string("facienda")]), "autoCompactWindow": .number(Double(FaciendaStore.claudeRunnerContext)),
                                       "permissions": .object(["allow": .array(older.map(JSONValue.string))])])
    try Data(settings.json.utf8).write(to: folder.appending(path: ".claude/settings.local.json"))
    try Data(store.url.path.utf8).write(to: folder.appending(path: FaciendaStore.claudeRunnerMarker))
    store.narrowClaudeFolders(helper: helper, runnerBase: runnerBase)
    let updated = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: ".claude/settings.local.json")))
    #expect(updated["permissions"]["allow"].array == rules.map(JSONValue.string))
}
