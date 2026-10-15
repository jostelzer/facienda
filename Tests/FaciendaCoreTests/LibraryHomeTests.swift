import Foundation
import Testing
@testable import FaciendaCore

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.standardizedFileURL.resolvingSymlinksInPath()
}

@Test func aDeletedLibraryIsReportedAndNeverReplaced() throws {
    let root = try scratch(), url = root.appending(path: "facienda/.facienda/facienda.sqlite")
    #expect(throws: StoreError.self) { try LibraryHome.open(at: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

    let store = try LibraryHome.setUp(workspaceName: "Home", dataFolder: root.appending(path: "facienda"), pointer: nil)
    #expect(store.url.path == url.path)
    _ = try store.create(FaciendaTask(title: "Keep me"))
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    do { _ = try FaciendaStore(existing: url); Issue.record("A missing library opened") }
    catch StoreError.libraryMissing(let path) { #expect(path == url.path) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func setUpKeepsAnExistingLibraryAndRemembersTheFolder() throws {
    let root = try scratch(), data = root.appending(path: "facienda"), pointer = root.appending(path: "support/data-folder.json")
    let first = try LibraryHome.setUp(workspaceName: "Workspace 1", dataFolder: data, pointer: pointer)
    let task = try first.create(FaciendaTask(title: "Still here"))
    #expect(try first.defaultWorkspace().name == "Workspace 1")
    #expect(try first.artifactRetentionDays() == 30)
    #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: pointer))["folder"] == data.path)
    let again = try LibraryHome.setUp(workspaceName: "Other", dataFolder: data, pointer: nil)
    #expect(try again.task(task.id).title == "Still here")
    #expect(try again.defaultWorkspace().name == "Workspace 1")
    #expect(throws: StoreError.self) { try LibraryHome.setUp(workspaceName: "Home", dataFolder: FileManager.default.homeDirectoryForCurrentUser, pointer: nil) }
}

@Test func tasksWorkInTheDataFolderBesideTheHiddenLibrary() throws {
    let root = try scratch()
    let store = try LibraryHome.setUp(workspaceName: "Home", dataFolder: root.appending(path: "facienda"), pointer: nil)
    // One Codex project for the runner and the tasks: the data folder, which holds the library.
    #expect(store.workFolder.path == root.appending(path: "facienda").path)
    #expect(store.nativeProjectDirectory.path == store.workFolder.path)
    #expect(store.libraryDirectory.lastPathComponent == ".facienda")
    let task = try store.create(FaciendaTask(title: "Draft a letter"))
    let prepared = try store.prepareWorkingFolder(taskId: task.id)
    #expect(prepared.cwd == root.appending(path: "facienda/\(task.id)").path)
    #expect(store.isAutomaticWorkingDirectory(prepared.cwd!, taskID: task.id))
    #expect(throws: StoreError.self) { try store.linkFolder(store.libraryDirectory.path, groupId: store.createGroup(name: "G").id) }
}

@Test func clearingArtifactsKeepsTheTaskAndOnlyTouchesFaciendasFolders() throws {
    let root = try scratch()
    let store = try LibraryHome.setUp(workspaceName: "Home", dataFolder: root.appending(path: "facienda"), pointer: nil)
    let open = try store.prepareWorkingFolder(taskId: store.create(FaciendaTask(title: "Open")).id)
    var done = try store.prepareWorkingFolder(taskId: store.create(FaciendaTask(title: "Done")).id)
    try Data(count: 64_000).write(to: URL(fileURLWithPath: done.cwd!).appending(path: "render.bin"))
    try Data(count: 8_000).write(to: URL(fileURLWithPath: open.cwd!).appending(path: "draft.txt"))
    done = try store.update(done.id) { $0.state = .done }
    let mine = store.workFolder.appending(path: "My notes")
    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)

    // The library's own folder and the user's folders are never listed.
    let found = try store.artifacts()
    #expect(found.map(\.taskId) == [done.id, open.id])
    #expect(found[0].bytes >= 64_000)
    #expect(!found.contains { $0.folder == mine.path || $0.folder == store.libraryDirectory.path })
    #expect(throws: StoreError.self) {
        try store.clearArtifacts(TaskArtifacts(folder: mine.path, taskId: nil, title: "", state: nil, finishedAt: nil, bytes: 0), toTrash: false)
    }
    #expect(throws: StoreError.self) {
        try store.clearArtifacts(TaskArtifacts(folder: store.libraryDirectory.path, taskId: nil, title: "", state: nil, finishedAt: nil, bytes: 0), toTrash: false)
    }

    // Retention clears only finished work, and only once it is old enough.
    try store.setArtifactRetentionDays(nil)
    #expect(try store.clearFinishedArtifacts(toTrash: false) == 0)
    try store.setArtifactRetentionDays(7)
    #expect(try store.clearFinishedArtifacts(now: Date(), toTrash: false) == 0)
    #expect(try store.clearFinishedArtifacts(now: Date().addingTimeInterval(8 * 86_400), toTrash: false) > 0)
    #expect(!FileManager.default.fileExists(atPath: done.cwd!))
    #expect(FileManager.default.fileExists(atPath: open.cwd!))
    #expect(FileManager.default.fileExists(atPath: mine.path))
    #expect(FileManager.default.fileExists(atPath: store.url.path))
    #expect(try store.task(done.id).title == "Done")

    // Started again, the task gets an empty folder rather than an error.
    _ = try store.update(done.id) { $0.state = .inbox }
    let restarted = try store.prepareWorkingFolder(taskId: done.id)
    #expect(FileManager.default.fileExists(atPath: restarted.cwd!))
}

@Test func theLibraryIsCopiedOnceADayOutsideTheDataFolder() throws {
    let root = try scratch(), backups = root.appending(path: "Backups")
    let store = try LibraryHome.setUp(workspaceName: "Home", dataFolder: root.appending(path: "facienda"), pointer: nil)
    _ = try store.create(FaciendaTask(title: "Worth keeping"))
    let day: TimeInterval = 86_400, start = Date()
    let first = try #require(try store.backUpDaily(to: backups, keep: 3, now: start))
    #expect(try store.backUpDaily(to: backups, keep: 3, now: start) == nil)
    #expect(try FaciendaStore(existing: first).tasks().map(\.title) == ["Worth keeping"])
    for offset in 1...4 { try store.backUpDaily(to: backups, keep: 3, now: start.addingTimeInterval(Double(offset) * day)) }
    let kept = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasSuffix(".sqlite") }
    #expect(kept.count == 3)
    #expect(!kept.contains(first.lastPathComponent))
}

private func mode(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func theDataFolderTaskFoldersAndLibraryAreThisAccountsAlone() throws {
    let root = try scratch(), data = root.appending(path: "facienda")
    let store = try LibraryHome.setUp(workspaceName: "Home", dataFolder: data, pointer: nil)
    #expect(try mode(data) == 0o700)
    #expect(try mode(store.libraryDirectory) == 0o700)
    let prepared = try store.prepareWorkingFolder(taskId: store.create(FaciendaTask(title: "Draft")).id)
    #expect(try mode(URL(fileURLWithPath: prepared.cwd!)) == 0o700)
    // A library made when folders were readable by others is tightened when it opens again.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.libraryDirectory.path)
    _ = try LibraryHome.open(at: store.url)
    #expect(try mode(data) == 0o700)
    #expect(try mode(store.libraryDirectory) == 0o700)
    // An existing folder chosen at setup is tightened too.
    let chosen = root.appending(path: "chosen")
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    _ = try LibraryHome.setUp(workspaceName: "Home", dataFolder: chosen, pointer: nil)
    #expect(try mode(chosen) == 0o700)
}

@Test func aSyncedOrSharedDataFolderIsRefused() throws {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(LibraryHome.sharingProblem(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/facienda"), home: home)?.contains("iCloud Drive") == true)
    #expect(LibraryHome.sharingProblem(home.appending(path: "Library/CloudStorage/Dropbox/facienda"), home: home) != nil)
    #expect(LibraryHome.sharingProblem(URL(fileURLWithPath: "/Users/Shared/facienda"), home: home) != nil)
    #expect(LibraryHome.sharingProblem(URL(fileURLWithPath: "/tmp/facienda"), home: home) != nil)
    #expect(LibraryHome.sharingProblem(URL(fileURLWithPath: "/private/var/tmp/facienda"), home: home) != nil)
    #expect(LibraryHome.sharingProblem(home.appending(path: "facienda"), home: home) == nil)
    #expect(LibraryHome.sharingProblem(home.appending(path: "Library/CloudStorageNotes"), home: home) == nil)
    #expect(LibraryHome.sharingProblem(try scratch().appending(path: "facienda")) == nil)
    // Refused before anything is made there.
    let shared = URL(fileURLWithPath: "/tmp/facienda-refused-\(UUID().uuidString)")
    #expect(throws: StoreError.self) { try LibraryHome.setUp(workspaceName: "Home", dataFolder: shared, pointer: nil) }
    #expect(!FileManager.default.fileExists(atPath: shared.path))
}

@Test func deletedTextIsOverwrittenAndBackupsAreStillMade() throws {
    let root = try scratch()
    let store = try LibraryHome.setUp(workspaceName: "Home", dataFolder: root.appending(path: "facienda"), pointer: nil)
    #expect(try store.db.read { try Int.fetchOne($0, sql: "PRAGMA secure_delete") } == 1)
    #expect(try store.db.write { try Int.fetchOne($0, sql: "PRAGMA secure_delete") } == 1)
    let reopened = try LibraryHome.open(at: store.url)
    #expect(try reopened.db.read { try Int.fetchOne($0, sql: "PRAGMA secure_delete") } == 1)
    _ = try store.create(FaciendaTask(title: "Kept"))
    let backup = try #require(try store.backUpDaily(to: root.appending(path: "Backups")))
    #expect(try FaciendaStore(existing: backup).tasks().map(\.title) == ["Kept"])
}
