import Foundation
import GRDB
import Darwin

/// What the bundled helper accepts on its command line. Sessions run it through narrow permission rules, so a command a
/// rule allows must not be able to switch to another mode, another library or an arbitrary file.
public enum HelperPolicy {
    /// Set to 1 by the test suites and smoke scripts: libraries in the system temp folder may then be made and opened.
    public static let testEnvironment = "FACIENDA_TEST_LIBRARY"

    public enum Mode: Equatable, Sendable { case server, initialize, tools, claude, runner, call }

    static let modes: [String: Mode] = ["--init": .initialize, "--tools": .tools, "--claude": .claude, "--runner": .runner, "--call": .call]

    /// The one mode a command line asks for. `--call` and `--tools` take nothing but their library and arguments, so a
    /// rule that allows them allows nothing else.
    public static func mode(_ args: [String]) throws -> Mode {
        let flags = Array(args.dropFirst())
        let present = flags.compactMap { modes[$0] }
        guard present.count <= 1 else { throw StoreError.invalid("Use one of --call, --runner, --claude, --tools or --init at a time.") }
        guard let mode = present.first else { return .server }
        switch mode {
        case .call:
            let values = try pairs(flags, allowed: ["--database", "--library-folder", "--call", "--arguments", "--arguments-file"], switches: [])
            guard (values["--arguments"] == nil) != (values["--arguments-file"] == nil), values["--database"] == nil || values["--library-folder"] == nil else {
                throw StoreError.invalid("--call takes exactly one of --arguments JSON or --arguments-file FILE, and nothing else besides the library.")
            }
        case .tools: _ = try pairs(flags, allowed: ["--database", "--library-folder"], switches: ["--tools"])
        default: break
        }
        return mode
    }

    /// The runner and maintenance commands the helper has. None answers an approval, queues a start or reply, or
    /// reprints a delivery by its ID: those are the user's, in the app, or go through a task's handle.
    public static let runnerCommands: Set<String> = [
        "tick", "wait", "instructions", "context", "prepare", "begin", "ack", "defer", "unreported", "missed-report", "name", "confirm-name",
        "bind", "bind-dispatcher", "prepare-setup", "status", "approvals",
        "memory-sync", "memory-configure", "memory-import", "memory-recall", "memory-recall-batch", "memory-learn", "memory-classify", "memory-status"
    ]

    /// Flags followed by a value, each at most once, and the given switches. Anything else is refused.
    static func pairs(_ flags: [String], allowed: Set<String>, switches: Set<String>) throws -> [String: String] {
        var values: [String: String] = [:], index = 0
        while index < flags.count {
            let flag = flags[index]
            if switches.contains(flag) { index += 1; continue }
            guard allowed.contains(flag), values[flag] == nil, flags.indices.contains(index + 1) else {
                throw StoreError.invalid("Unexpected \(flag) in this helper command. It takes only " + (allowed.sorted() + switches.sorted()).joined(separator: ", ") + ".")
            }
            values[flag] = flags[index + 1]; index += 2
        }
        return values
    }

    /// The app's own library, as the pointer the app keeps names it.
    public static var appLibrary: URL {
        LibraryHome.libraryFolder(in: LibraryHome.savedDataFolder ?? LibraryHome.defaultDataFolder).appending(path: LibraryHome.databaseName)
    }

    /// Folders whose libraries the test suites and smoke scripts may make and open.
    static var temporaryFolders: [URL] { [URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/private/tmp")] }

    /// The library a helper may serve: the app's own; an experiment library (`.facienda/facienda.sqlite`, opened with
    /// `--library-folder`) that already holds Facienda's schema; or, with the test environment set, one in the system
    /// temp folder. Only that last kind may be made (`creating`).
    public static func database(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                                app: URL = appLibrary, creating: Bool = false) throws -> URL {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let requested = value("--database").map { URL(fileURLWithPath: $0) }
            ?? value("--library-folder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).appending(path: LibraryHome.databaseName) }
            ?? app
        let file = canonical(requested)
        let testing = environment[testEnvironment] == "1" && temporaryFolders.contains { inside(canonical($0), file) }
        if creating {
            guard testing else { throw StoreError.invalid("--init makes test libraries only: set \(testEnvironment)=1 and choose a path in the system temp folder.") }
            return requested
        }
        if file.pathComponents == canonical(app).pathComponents || testing { return requested }
        let parts = file.pathComponents
        if parts.suffix(2) == [LibraryHome.libraryFolderName, LibraryHome.databaseName], isLibrary(file) { return requested }
        throw StoreError.invalid("Facienda's helper serves only Facienda's own library (\(app.path)); \(requested.path) is not one it may open.")
    }

    /// Whether a file is a Facienda library: a regular SQLite file this account owns, holding Facienda's first migration.
    public static func isLibrary(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8) else { return false }
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else { return false }
        return (try? queue.read { db in
            try db.tableExists("tasks") && db.tableExists("grdb_migrations")
                && Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = 'v1')") == true
        }) ?? false
    }

    /// Opens an existing library once it is known to be one, so Facienda never migrates another SQLite file.
    public static func open(_ url: URL) throws -> FaciendaStore {
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.libraryMissing(url.path) }
        guard isLibrary(url) else { throw StoreError.invalid("\(url.path) is not a Facienda library, so Facienda left it unchanged.") }
        return try FaciendaStore(existing: url)
    }

    /// Where helper commands may read files a session names: the data folder (task folders, the library's handoffs),
    /// the system temp folder and the folders chosen for open tasks.
    public static func readableFolders(_ store: FaciendaStore) -> [URL] {
        let chosen = ((try? store.library.tasks()) ?? []).filter { $0.state.isOpen }.compactMap(\.cwd).filter { $0.hasPrefix("/") && $0 != "/" }
        return [store.workFolder] + temporaryFolders + chosen.map { URL(fileURLWithPath: $0) }
    }

    /// Reads a file a session named: a regular file, symlinks resolved, inside one of `folders`, at most `limit` bytes.
    public static func read(_ path: String, from folders: [URL], limit: Int) throws -> Data {
        let file = canonical(URL(fileURLWithPath: path))
        guard folders.map(canonical).contains(where: { inside($0, file) }) else {
            throw StoreError.invalid("Facienda reads \(path) only from the task's folder, Facienda's data folder or the system temp folder. Write the file there.")
        }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreError.invalid("Facienda could not read \(path).") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StoreError.invalid("\(path) is not a regular file.") }
        let large = StoreError.invalid("\(path) is larger than the \(limit / 1024) KB Facienda accepts here.")
        guard info.st_size <= limit else { throw large }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw large }
        return data
    }

    /// A folder a session named, inside one of `folders`, symlinks resolved.
    public static func folder(_ path: String, from folders: [URL]) throws -> URL {
        let folder = canonical(URL(fileURLWithPath: path))
        var isDirectory: ObjCBool = false
        guard folders.map(canonical).contains(where: { inside($0, folder) }),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StoreError.invalid("Facienda reads \(path) only as a folder in its data folder or the system temp folder.")
        }
        return folder
    }

    /// The path with every symlink resolved, including those above a part that does not exist yet.
    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL, rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent()
        }
        var resolved = existing
        if let real = realpath(existing.path, nil) { resolved = URL(fileURLWithPath: String(cString: real)); free(real) }
        // Not standardized again: that would turn a resolved /private/var back into /var for existing paths only.
        for part in rest { resolved.append(path: part) }
        return resolved
    }

    static func inside(_ folder: URL, _ path: URL) -> Bool { path.pathComponents.starts(with: folder.pathComponents) }
}
