import Foundation
import Darwin

/// Where Facienda keeps its data: one folder the user chooses (`~/facienda` by default). Each task gets a folder there
/// for what it makes, and the library itself lives in its hidden `.facienda` folder. A small pointer in Application Support
/// tells the app, the helpers and the hooks which folder that is, and daily copies of the library are kept beside it.
public enum LibraryHome {
    public static let databaseName = "facienda.sqlite"
    public static let libraryFolderName = ".facienda"
    /// Facienda's Application Support folder: the pointer, the library's daily copies, the chat index and the speech model.
    public static let supportDirectory = URL.applicationSupportDirectory.appending(path: "Facienda", directoryHint: .isDirectory)
    public static let pointerURL = supportDirectory.appending(path: "data-folder.json")
    public static let backupDirectory = supportDirectory.appending(path: "Backups", directoryHint: .isDirectory)
    public static var defaultDataFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "facienda", directoryHint: .isDirectory)
    }

    /// The library folder. `--library-folder DIR` at launch names another one, so a separate library
    /// (for example a local experiment) can run beside the usual one without touching it.
    public static var directory: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--library-folder"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        return libraryFolder(in: savedDataFolder ?? defaultDataFolder)
    }
    public static var databaseURL: URL { directory.appending(path: databaseName) }
    public static var exists: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    /// The data folder setup chose, if any.
    public static var savedDataFolder: URL? {
        guard let data = try? Data(contentsOf: pointerURL),
              let saved = try? JSONDecoder().decode([String: String].self, from: data)["folder"], saved.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: saved, isDirectory: true)
    }

    public static func libraryFolder(in dataFolder: URL) -> URL {
        dataFolder.appending(path: libraryFolderName, directoryHint: .isDirectory)
    }

    /// Today's copy of the library, made only for the real library: a test or experiment library is never copied
    /// into the user's backups.
    public static func backUp(_ store: FaciendaStore) {
        guard store.url.standardizedFileURL.path == databaseURL.standardizedFileURL.path else { return }
        _ = try? store.library.backUpDaily()
    }

    /// Opens the library that is there. It never makes one, so a deleted library is reported instead of quietly starting over.
    public static func open(at url: URL = databaseURL) throws -> FaciendaStore {
        let store = try FaciendaStore(existing: url)
        // A library made before folders were private is tightened when it opens.
        let library = url.deletingLastPathComponent()
        makePrivate(library); makePrivate(library.deletingLastPathComponent())
        return store
    }

    /// Why a data folder would leave this Mac or this account: iCloud Drive, a cloud storage provider, or a shared folder.
    public static func sharingProblem(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = home.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if inside(home + "/Library/Mobile Documents") { return "iCloud Drive would copy Facienda’s library to the cloud. Choose a folder outside iCloud Drive." }
        if inside(home + "/Library/CloudStorage") { return "A cloud storage app syncs this folder, so Facienda’s library would leave this Mac. Choose a folder it does not sync." }
        if ["/Users/Shared", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"].contains(where: inside) {
            return "Other accounts on this Mac can reach this folder. Choose a folder in your own home folder."
        }
        // Desktop and Documents in iCloud: the nearest folder that exists tells.
        var existing = URL(fileURLWithPath: path, isDirectory: true)
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 { existing.deleteLastPathComponent() }
        if (try? existing.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return "iCloud syncs this folder, so Facienda’s library would leave this Mac. Choose a folder iCloud does not sync."
        }
        return nil
    }

    /// Makes one of Facienda's folders this account's alone. Folders owned by someone else, and the home folder, are left as they are.
    static func makePrivate(_ folder: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        guard folder.standardizedFileURL.resolvingSymlinksInPath().path != home else { return }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 != 0 else { return }
        chmod(folder.path, 0o700)
    }

    /// First run: makes the library in the data folder with its first workspace, and remembers the folder.
    /// A library that is already there is opened and keeps its tasks. Tests pass `pointer: nil`.
    public static func setUp(workspaceName: String, dataFolder: URL, pointer: URL? = pointerURL) throws -> FaciendaStore {
        guard dataFolder.isFileURL, dataFolder.path.hasPrefix("/") else { throw StoreError.invalid("Choose a folder on this Mac.") }
        let folder = dataFolder.standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.pathComponents.count > 1, folder.path != home.path else {
            throw StoreError.invalid("Choose a folder of its own for Facienda, not your home folder.")
        }
        if let problem = sharingProblem(folder) { throw StoreError.invalid(problem) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw StoreError.invalid("Choose a folder, rather than a file.") }
        makePrivate(folder)
        let url = libraryFolder(in: folder).appending(path: databaseName)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        let store = isNew ? try FaciendaStore(url: url) : try FaciendaStore(existing: url)
        makePrivate(libraryFolder(in: folder))
        if isNew {
            try store.renameWorkspace(store.defaultWorkspace().id, to: workspaceName)
            // Finished tasks' files go to the Trash after a month unless the user chooses otherwise in Settings.
            try store.setArtifactRetentionDays(30)
            let settings = try store.memorySettings()
            try store.saveMemorySettings(endpoint: settings.endpoint, enabled: true, workerModel: "gpt-6-luna", workerReasoningEffort: "high")
        }
        if let pointer {
            try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(["folder": folder.path]).write(to: pointer, options: .atomic)
        }
        return store
    }
}

extension FaciendaStore {
    /// Copies the library once a day to `directory`, outside the data folder, and keeps the newest `keep` copies.
    /// Returns the copy it made, or nil when today's is already there.
    @discardableResult public func backUpDaily(to directory: URL = LibraryHome.backupDirectory, keep: Int = 7, now: Date = Date()) throws -> URL? {
        let day = now.formatted(.iso8601.year().month().day())
        let file = directory.appending(path: "facienda-\(day).sqlite")
        guard !FileManager.default.fileExists(atPath: file.path) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Written under another name and renamed, so a half-written copy never looks like a backup.
        let partial = directory.appending(path: ".facienda-\(day)-\(UUID().uuidString).partial")
        try db.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [partial.path]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        do { try FileManager.default.moveItem(at: partial, to: file) }
        catch { try? FileManager.default.removeItem(at: partial); if !FileManager.default.fileExists(atPath: file.path) { throw error } }
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("facienda-") && $0.hasSuffix(".sqlite") }.sorted(by: >)
        for old in copies.dropFirst(keep) { try? FileManager.default.removeItem(at: directory.appending(path: old)) }
        return file
    }
}
