import Foundation
import Testing
@testable import FaciendaCore

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.standardizedFileURL
}

/// A folder that looks like a repository on the given branch.
private func repository(_ url: URL, branch: String = "main") throws -> URL {
    try FileManager.default.createDirectory(at: url.appending(path: ".git"), withIntermediateDirectories: true)
    try Data("ref: refs/heads/\(branch)\n".utf8).write(to: url.appending(path: ".git/HEAD"))
    return url
}

@Test func linkingAFolderInsideARepositoryLinksTheRepositoryOnceAndInOrder() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"), branch: "redesign")
    let notes = root.appending(path: "notes")
    try FileManager.default.createDirectory(at: app.appending(path: "Sources/Core"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let group = try store.createGroup(name: "Launch"), other = try store.createGroup(name: "Errands")

    #expect(try store.linkFolder(app.appending(path: "Sources/Core").path, groupId: group.id) == app.path)
    try store.linkFolder(app.path, groupId: group.id)
    try store.linkFolder(site.path, groupId: group.id)
    // A folder outside any repository links as it is.
    #expect(try store.linkFolder(notes.path, groupId: group.id) == notes.path)
    #expect(try store.folders(groupId: group.id) == [app.path, site.path, notes.path])
    #expect(try store.groupFolders() == [group.id: [app.path, site.path, notes.path]])

    try store.makePrimaryFolder(site.path, groupId: group.id)
    try store.unlinkFolder(notes.path, groupId: group.id)
    #expect(try store.folders(groupId: group.id) == [site.path, app.path])
    #expect(try store.folders(groupId: other.id).isEmpty)
    #expect(throws: StoreError.self) { try store.linkFolder(root.appending(path: "missing").path, groupId: group.id) }
    #expect(throws: StoreError.self) { try store.linkFolder(store.nativeProjectDirectory.appending(path: "Work/some-task").path, groupId: group.id) }

    try store.deleteGroup(group.id)
    #expect(try store.groupFolders().isEmpty)
}

@Test func startingTasksWorkInTheirGroupsLinkedFolders() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"))
    let single = try store.createGroup(name: "App"), several = try store.createGroup(name: "Launch"), none = try store.createGroup(name: "Errands")
    try store.linkFolder(app.path, groupId: single.id)
    try store.linkFolder(app.path, groupId: several.id); try store.linkFolder(site.path, groupId: several.id)
    func task(in group: TaskGroup?, _ title: String) throws -> FaciendaTask {
        let task = try store.create(FaciendaTask(title: title))
        if let group { try store.assignGroup(taskId: task.id, groupId: group.id) }
        return task
    }
    let own = { (task: FaciendaTask) in store.taskFolder(task.id).path }

    // One linked folder: the task works right in it.
    let fix = try store.prepareWorkingFolder(taskId: task(in: single, "Fix the crash").id)
    #expect(fix.cwd == app.path && fix.folders == [app.path])
    // Several: it works from its own folder across all of them.
    let ship = try store.prepareWorkingFolder(taskId: task(in: several, "Ship the launch").id)
    #expect(ship.cwd == own(ship) && ship.folders == [app.path, site.path])
    #expect(try store.linkedProjectId(task: ship) == nil)
    try store.setCodexProject(groupId: several.id, id: "project-launch", owned: true)
    #expect(try store.linkedProjectId(task: ship) == "project-launch")
    // The task keeps the folders it started with; the group's project no longer describes it once the links change.
    try store.unlinkFolder(site.path, groupId: several.id)
    #expect(try store.prepareWorkingFolder(taskId: ship.id).folders == [app.path, site.path])
    #expect(try store.linkedProjectId(task: ship) == nil)
    // No links, or no group: exactly as before.
    for group in [none, nil] {
        let plain = try store.prepareWorkingFolder(taskId: task(in: group, "Book the dentist").id)
        #expect(plain.cwd == own(plain) && plain.folders == nil)
    }
    // A folder the user chose, or a task that already has a chat, stays where it is.
    let chosen = try store.update(try task(in: single, "Draft notes").id) { $0.cwd = site.path }
    #expect(try store.prepareWorkingFolder(taskId: chosen.id).cwd == site.path)
    let chatting = try task(in: single, "Continue the chat")
    try store.link(ThreadLink(taskId: chatting.id, codexThreadId: "existing"))
    #expect(try store.prepareWorkingFolder(taskId: chatting.id).folders == nil)
    // A linked folder that has gone away stops the start with a clear reason.
    try FileManager.default.removeItem(at: app)
    #expect(throws: StoreError.self) { try store.prepareWorkingFolder(taskId: task(in: single, "Fix another crash").id) }
}

@Test func newChatsForSeveralLinkedFoldersMustUseTheirProject() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let group = try store.createGroup(name: "Launch")
    try store.linkFolder(app.path, groupId: group.id); try store.linkFolder(site.path, groupId: group.id)
    let created = try store.create(FaciendaTask(title: "Ship the launch"))
    try store.assignGroup(taskId: created.id, groupId: group.id)
    let task = try store.prepareWorkingFolder(taskId: created.id)
    _ = try store.enqueueDispatch(taskId: task.id)
    let item = try #require(try store.claimDispatch(runnerId: "runner"))
    func receipt(_ project: DispatchContext.Project?) -> DispatchContext {
        .init(contextKey: DispatchContext.key(task: task, dispatch: item), searchStatus: .complete, searchSummary: "Checked the project inventory.",
              route: .new, project: project, chats: [], uncertainties: [])
    }
    #expect(throws: StoreError.self) { try store.saveDispatchContext(receipt(nil), dispatchId: item.id, runnerId: "runner") }
    #expect(throws: StoreError.self) {
        try store.saveDispatchContext(receipt(.init(id: "workspace", path: store.nativeProjectDirectory.path, reason: "Default workspace")), dispatchId: item.id, runnerId: "runner")
    }
    try store.saveDispatchContext(receipt(.init(id: "launch", path: app.path, reason: "Roots match the group's linked folders")), dispatchId: item.id, runnerId: "runner")
    // The folders are part of the request, so a different set needs fresh discovery.
    var other = task; other.folders = [site.path]
    #expect(DispatchContext.key(task: other, dispatch: item) != DispatchContext.key(task: task, dispatch: item))
}

@Test func claudeSessionsAreOpenedToLinkedFolders() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"))
    let folder = root.appending(path: "session")
    try store.prepareClaudeFolder(folder, mcpHelper: "/Apps/facienda-mcp", folders: [app.path, site.path])
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: ".claude/settings.local.json")))
    #expect(settings["permissions"]["additionalDirectories"] == .array([.string(app.path), .string(site.path)]))
    try store.prepareClaudeFolder(folder, mcpHelper: "/Apps/facienda-mcp")
    let plain = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: ".claude/settings.local.json")))
    #expect(plain["permissions"]["additionalDirectories"] == .null)
}

@Test func aFolderInAWorktreeLinksTheWorktree() throws {
    let root = try scratch()
    let main = try repository(root.appending(path: "app"))
    let gitdir = main.appending(path: ".git/worktrees/feature")
    try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
    try Data("ref: refs/heads/feature\n".utf8).write(to: gitdir.appending(path: "HEAD"))
    let worktree = root.appending(path: "app-feature")
    try FileManager.default.createDirectory(at: worktree.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("gitdir: \(gitdir.path)\n".utf8).write(to: worktree.appending(path: ".git"))
    #expect(LinkedFolder.root(of: worktree.appending(path: "Sources").path) == worktree.path)
}

@Test func deletingATaskRemovesItWithEverythingItOwnsAndLeavesTheRest() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let stuck = try store.create(FaciendaTask(title: "hey can you please", state: .running))
    let other = try store.create(FaciendaTask(title: "Keep me", state: .running))
    let group = try store.createGroup(name: "modernGL")
    try store.assignGroup(taskId: stuck.id, groupId: group.id)

    try store.deleteTask(stuck.id)

    #expect(try store.tasks().map(\.id) == [other.id])
    #expect(try store.tasks(search: "please").isEmpty)
    #expect(throws: (any Error).self) { try store.deleteTask(stuck.id) }
}

@Test func deletingATaskDropsTheRunnersFilesForItSoALaterRequestCannotFollowThem() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let gone = try store.create(FaciendaTask(title: "find the room measurements", state: .needsMe))
    let kept = try store.create(FaciendaTask(title: "Keep me", state: .needsMe))
    let dispatch = try store.enqueueDispatch(taskId: gone.id), keptDispatch = try store.enqueueDispatch(taskId: kept.id)
    let folder = store.runnerHandoffDirectory
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = ["context-\(gone.id).json", "abc123-\(dispatch.id).json", "context-\(kept.id).json", "def456-\(keptDispatch.id).json"]
    for file in files { try Data("{}".utf8).write(to: folder.appending(path: file)) }

    try store.deleteTask(gone.id)

    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set(files.suffix(2)))
}
