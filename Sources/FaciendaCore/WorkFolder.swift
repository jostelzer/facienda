import Foundation
import GRDB

/// What one task left in its own folder.
public struct TaskArtifacts: Identifiable, Equatable, Sendable {
    public var id: String { folder }
    public let folder: String
    /// nil for a folder no task owns any more.
    public let taskId: String?
    public let title: String
    public let state: TaskState?
    /// When a closed task last changed, which is when it was closed, or for a leftover folder when it last changed. nil while open.
    public let finishedAt: Date?
    public let bytes: Int64
}

/// The data folder (`~/facienda` unless the user chose another) holds what tasks produce, one folder per task, and
/// the library itself in its hidden `.facienda` folder. It is the one Codex project: the runner writes the library from
/// there, and task chats start there. Facienda only ever clears the task folders it made, and keeps daily copies of
/// the library outside it, so deleting the data folder loses at most a day.
extension FaciendaStore {
    static func registerWorkFolder(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("artifact_retention") { db in
            try db.execute(sql: "ALTER TABLE libraryState ADD COLUMN artifactRetentionDays INTEGER")
        }
    }

    /// The library's own folder: the database and the small files that belong to it.
    public var libraryDirectory: URL { url.deletingLastPathComponent() }

    /// The folder holding the library's folder: task folders sit beside it.
    public var workFolder: URL { libraryDirectory.deletingLastPathComponent() }

    /// Whether a path belongs to Facienda rather than the user: the data folder itself, anything in a task's own
    /// folder, or the library. Other folders the user keeps inside the data folder are theirs.
    public func isFaciendaFolder(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let work = workFolder.standardizedFileURL.path, library = libraryDirectory.standardizedFileURL.path
        if path == work || path == library || path.hasPrefix(library + "/") { return true }
        guard path.hasPrefix(work + "/"), let first = path.dropFirst(work.count + 1).split(separator: "/").first else { return false }
        return UUID(uuidString: String(first)) != nil
    }

    /// The folder Facienda makes for a task that works nowhere in particular.
    public func taskFolder(_ taskID: String) -> URL {
        workFolder.appending(path: taskID, directoryHint: .isDirectory)
    }

    public func isAutomaticWorkingDirectory(_ directory: String, taskID: String) -> Bool {
        // Existing directories may gain a trailing slash when reconstructed from
        // a saved path. Compare filesystem paths, not URL directory hints.
        URL(fileURLWithPath: directory).standardizedFileURL.path == taskFolder(taskID).standardizedFileURL.path
    }

    // MARK: Artifacts

    /// Told to every task chat. A task once copied a 30 GB project into its folder twice and filled the disk.
    public static let artifactRules = "Keep files you make in the working folder, and keep them lean: never copy a whole project, repository or large asset folder there. Work in the original folder, or use git worktree for a separate checkout. Before finishing, delete large intermediate output you no longer need, such as builds, frame renders and downloads."

    /// Days after a task is done before its folder is cleared. nil keeps folders until the user clears them.
    public func artifactRetentionDays() throws -> Int? {
        try db.read { try Int.fetchOne($0, sql: "SELECT artifactRetentionDays FROM libraryState WHERE id = 1") }
    }

    public func setArtifactRetentionDays(_ days: Int?) throws {
        guard days.map({ $0 >= 1 }) ?? true else { throw StoreError.invalid("Keep finished work for at least a day.") }
        try write { try $0.execute(sql: "UPDATE libraryState SET artifactRetentionDays = ? WHERE id = 1", arguments: [days]) }
    }

    /// Every folder in the work folder that belongs to a task, or did, largest first. Folders the user put there
    /// themselves are left out: Facienda only ever clears what it made.
    public func artifacts() throws -> [TaskArtifacts] {
        let root = workFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let tasks = Dictionary(try library.tasks().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return names.compactMap { name -> TaskArtifacts? in
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            guard UUID(uuidString: name) != nil, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let task = tasks[name]
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            return TaskArtifacts(folder: folder.path, taskId: task?.id, title: task?.displayName ?? "Removed task", state: task?.state,
                                 finishedAt: task.map { $0.state.isOpen ? nil : $0.updatedAt } ?? modified,
                                 bytes: DiskUsage.size(of: folder))
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Moves a task's own folder to the Trash. The task, its results and its chats stay; the folder comes back
    /// empty if the task is started again. A folder the user chose for the task is never touched.
    /// Tests pass `toTrash: false` to delete straight away.
    public func clearArtifacts(_ artifacts: TaskArtifacts, toTrash: Bool = true) throws {
        let folder = URL(fileURLWithPath: artifacts.folder, isDirectory: true).standardizedFileURL
        guard folder.deletingLastPathComponent().path == workFolder.standardizedFileURL.path,
              UUID(uuidString: folder.lastPathComponent) != nil else { throw StoreError.invalid("Facienda only clears the folders it made for tasks.") }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if toTrash { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        else { try FileManager.default.removeItem(at: folder) }
    }

    /// Clears the folders of tasks done for longer than the retention period, and of tasks that no longer exist.
    /// Open tasks keep everything. Returns how much was cleared.
    @discardableResult public func clearFinishedArtifacts(now: Date = Date(), toTrash: Bool = true) throws -> Int64 {
        guard let days = try artifactRetentionDays() else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var cleared: Int64 = 0
        for item in try artifacts() where item.state.map({ !$0.isOpen }) ?? true {
            guard let finished = item.finishedAt, finished < cutoff else { continue }
            try clearArtifacts(item, toTrash: toTrash)
            cleared += item.bytes
        }
        return cleared
    }
}

/// Sizes on disk, counted the way Finder does: the blocks a file holds.
public enum DiskUsage {
    public static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return Int64((try? url.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = walker?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Free space for new work on the volume holding `url`.
    public static func available(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? nil
    }

    /// Below this, Facienda holds new task starts so a task cannot fill the disk.
    public static let lowSpaceThreshold: Int64 = 5 * 1_073_741_824
}
