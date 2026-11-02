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
    let group = try store.createGroup(name: "Launch")

    #expect(try store.linkFolder(app.appending(path: "Sources/Core").path) == app.path)
    try store.linkFolder(app.path)
    try store.linkFolder(site.path)
    // A folder outside any repository links as it is.
    #expect(try store.linkFolder(notes.path) == notes.path)
    #expect(try store.workspaceFolders() == [app.path, site.path, notes.path])
    // With several, a group works only in what it chose.
    #expect(try store.groupFolders().isEmpty)
    try store.setWorkPlace(.folders([notes.path, site.path]), groupId: group.id)
    #expect(try store.groupFolders() == [group.id: [notes.path, site.path]])

    try store.makePrimaryFolder(site.path)
    try store.unlinkFolder(notes.path)
    #expect(try store.workspaceFolders() == [site.path, app.path])
    #expect(try store.workPlace(groupId: group.id) == .folders([site.path]))
    #expect(throws: StoreError.self) { try store.linkFolder(root.appending(path: "missing").path) }
    #expect(throws: StoreError.self) { try store.linkFolder(store.nativeProjectDirectory.appending(path: "Work/some-task").path) }
    // Another workspace has folders of its own; a group moved there leaves its choice behind.
    let work = try store.createWorkspace(name: "Work")
    #expect(try store.workspaceFolders(workspaceID: work.id).isEmpty)
    try store.moveGroup(group.id, toWorkspace: work.id)
    #expect(try store.workPlace(groupId: group.id) == .workspace)

    try store.deleteGroup(group.id)
    #expect(try store.workspaceFolders() == [site.path, app.path])
}

@Test func startingTasksWorkWhereTheirGroupOrWorkspaceDoes() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"))
    let single = try store.createGroup(name: "App"), several = try store.createGroup(name: "Launch")
    let apart = try store.createGroup(name: "Errands"), plain = try store.createGroup(name: "Notes")
    func task(in group: TaskGroup?, _ title: String) throws -> FaciendaTask {
        let task = try store.create(FaciendaTask(title: title))
        if let group { try store.assignGroup(taskId: task.id, groupId: group.id) }
        return task
    }
    func start(in group: TaskGroup?, _ title: String) throws -> FaciendaTask { try store.prepareWorkingFolder(taskId: task(in: group, title).id) }
    let own = { (task: FaciendaTask) in store.taskFolder(task.id).path }

    // No folders: every task gets its own, exactly as before.
    let first = try start(in: plain, "Book the dentist")
    #expect(first.cwd == own(first) && first.folders == nil)
    // One workspace folder: every task works right in it, in a group or not, unless its group keeps to its own folders.
    try store.linkFolder(app.path)
    try store.setWorkPlace(.own, groupId: apart.id)
    for group in [plain, nil] {
        let started = try start(in: group, "Fix the crash")
        #expect(started.cwd == app.path && started.folders == [app.path])
    }
    let kept = try start(in: apart, "Buy stamps")
    #expect(kept.cwd == own(kept) && kept.folders == nil)
    // Several: none is the default. A group works in what it chose, across several from each task's own folder.
    try store.linkFolder(site.path)
    try store.setWorkPlace(.folders([app.path]), groupId: single.id)
    try store.setWorkPlace(.folders([app.path, site.path]), groupId: several.id)
    #expect(throws: StoreError.self) { try store.setWorkPlace(.folders([root.path]), groupId: single.id) }
    let fix = try start(in: single, "Fix another crash")
    #expect(fix.cwd == app.path && fix.folders == [app.path])
    let ship = try start(in: several, "Ship the launch")
    #expect(ship.cwd == own(ship) && ship.folders == [app.path, site.path])
    for group in [plain, nil] {
        let started = try start(in: group, "Water the plants")
        #expect(started.cwd == own(started) && started.folders == nil)
    }
    #expect(try store.linkedProjectId(task: ship) == nil)
    try store.setCodexProject(groupId: several.id, id: "project-launch", owned: true)
    #expect(try store.linkedProjectId(task: ship) == "project-launch")
    // Unlinking a folder takes it out of the groups that chose it. The task keeps the folders it started with,
    // and the group's project no longer describes it.
    try store.unlinkFolder(site.path)
    #expect(try store.folders(groupId: several.id) == [app.path])
    #expect(try store.prepareWorkingFolder(taskId: ship.id).folders == [app.path, site.path])
    #expect(try store.linkedProjectId(task: ship) == nil)
    // A folder the user chose, or a task that already has a chat, stays where it is.
    let chosen = try store.update(try task(in: single, "Draft notes").id) { $0.cwd = site.path }
    #expect(try store.prepareWorkingFolder(taskId: chosen.id).cwd == site.path)
    let chatting = try task(in: single, "Continue the chat")
    try store.link(ThreadLink(taskId: chatting.id, codexThreadId: "existing"))
    #expect(try store.prepareWorkingFolder(taskId: chatting.id).folders == nil)
    // A linked folder that has gone away stops the start with a clear reason.
    try FileManager.default.removeItem(at: app)
    #expect(throws: StoreError.self) { try start(in: single, "Fix a third crash") }
}

@Test func groupLinksMoveToTheirWorkspace() throws {
    let root = try scratch(), url = root.appending(path: "library/tasks.sqlite")
    var store = try FaciendaStore(url: url)
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"))
    let home = try store.defaultWorkspace(), work = try store.createWorkspace(name: "Work")
    let coding = try store.createGroup(name: "Coding"), releasing = try store.createGroup(name: "Releasing"), errands = try store.createGroup(name: "Errands")
    let launch = try store.scoped(to: work.id).createGroup(name: "Launch"), notes = try store.scoped(to: work.id).createGroup(name: "Notes")
    let sheet = "https://docs.google.com/spreadsheets/d/budget/edit", folder = "https://drive.google.com/drive/folders/quotes"
    // The library as groups kept their links before.
    try store.db.write { db in
        try db.execute(sql: "DROP TABLE workspaceFolders; ALTER TABLE taskGroups DROP COLUMN ownFolders; DELETE FROM grdb_migrations WHERE identifier = 'workspace_places'")
        for (group, path, position) in [(coding.id, app.path, 0), (launch.id, app.path, 0), (launch.id, site.path, 1)] {
            try db.execute(sql: "INSERT INTO groupFolders (groupId, path, position) VALUES (?, ?, ?)", arguments: [group, path, position])
        }
        for (group, address, state) in [(releasing.id, sheet, "linked"), (errands.id, sheet, "proposed"), (releasing.id, app.path, "linked"), (errands.id, folder, "dismissed")] {
            try db.execute(sql: "INSERT INTO groupSources (id, groupId, kind, address, title, state, position, createdAt) VALUES (?, ?, 'link', ?, 'x', ?, 0, ?)",
                           arguments: [UUID().uuidString, group, address, state, Date()])
        }
    }
    store = try FaciendaStore(url: url)

    // One folder in a workspace is its default, so every group there works in it.
    #expect(try store.workspaceFolders(workspaceID: home.id) == [app.path])
    for group in [coding, releasing, errands] { #expect(try store.workPlace(groupId: group.id) == .workspace && store.folders(groupId: group.id) == [app.path]) }
    // Several: the group that linked them keeps them as its choice; the others work in their own folders.
    #expect(try store.workspaceFolders(workspaceID: work.id) == [app.path, site.path])
    #expect(try store.workPlace(groupId: launch.id) == .folders([app.path, site.path]))
    #expect(try store.folders(groupId: notes.id).isEmpty)
    // Sources join the workspace once each: a link wins over a proposal; one the workspace works in is put away.
    let sources = try store.db.read { try WorkspaceSource.fetchAll($0, sql: "SELECT * FROM groupSources ORDER BY address") }
    #expect(sources.allSatisfy { $0.workspaceId == home.id })
    #expect(sources.map(\.address) == [app.path, folder, sheet].sorted())
    #expect(Dictionary(uniqueKeysWithValues: sources.map { ($0.address, $0.state) }) == [sheet: .linked, folder: .dismissed, app.path: .dismissed])
}

@Test func newChatsForSeveralFoldersMustUseTheirProject() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = try repository(root.appending(path: "app")), site = try repository(root.appending(path: "site"))
    try store.bindRunner(threadId: "runner", automationId: nil)
    let group = try store.createGroup(name: "Launch")
    try store.linkFolder(app.path); try store.linkFolder(site.path)
    try store.setWorkPlace(.folders([app.path, site.path]), groupId: group.id)
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
