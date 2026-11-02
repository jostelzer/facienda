import Foundation
import GRDB

/// Something tasks read but never work inside: a Drive folder, a Sheet or Doc, a file or a web page. A source belongs to a
/// workspace, whose every task is told about it. Folders the tasks work in are `workspaceFolders`. An agent can only propose
/// a source; the user links it, and says in a line what is inside. The table keeps its old name from when groups had sources.
public struct WorkspaceSource: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable, Sendable {
    public static let databaseTableName = "groupSources"
    public enum State: String, Codable, Sendable { case linked, proposed, dismissed }
    public var id: String
    /// The workspace it belongs to: every task in it may read it.
    public var workspaceId: String
    public var kind: SourceKind
    /// An absolute path on this Mac or a web address. One per workspace.
    public var address: String
    public var title: String
    /// The Google account of a Drive item seen through Google Drive for desktop, when the path names it.
    public var account: String?
    public var state: State
    /// The task that proposed it, when an agent did.
    public var taskId: String?
    /// Why the agent proposed it.
    public var note: String?
    /// What is inside and when to read it, in the user's words. Agents are told this with the address.
    public var about: String?
    public var position: Int
    public var createdAt: Date

    public var isWeb: Bool { LinkedSource.webURL(address) != nil }
}

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case folder, driveFolder, sheet, doc, slides, file, link

    public var label: String {
        switch self {
        case .folder: "Folder"
        case .driveFolder: "Drive folder"
        case .sheet: "Sheet"
        case .doc: "Doc"
        case .slides: "Slides"
        case .file: "File"
        case .link: "Link"
        }
    }

    /// What an address is, read from its shape alone, without touching the network.
    public static func of(_ address: String) -> SourceKind {
        if let url = LinkedSource.webURL(address), let host = url.host?.lowercased() {
            let path = url.path
            if host == "docs.google.com" {
                if path.hasPrefix("/spreadsheets") { return .sheet }
                if path.hasPrefix("/document") { return .doc }
                if path.hasPrefix("/presentation") { return .slides }
            }
            if host == "drive.google.com" {
                if path.contains("/folders/") { return .driveFolder }
                if path.hasPrefix("/file/") || path.hasPrefix("/open") { return .file }
            }
            return .link
        }
        switch URL(fileURLWithPath: address).pathExtension.lowercased() {
        case "gsheet": return .sheet
        case "gdoc": return .doc
        case "gslides": return .slides
        default: break
        }
        // An app or other package is a folder only on disk; to the user it is a file, and never one to open from a link.
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: address, isDirectory: &directory), directory.boolValue, !LinkedSource.isPackage(address) {
            return LinkedSource.isCloudDrive(address) ? .driveFolder : .folder
        }
        return .file
    }
}

/// Reading sources' addresses, without running anything.
public enum LinkedSource {
    /// The address as a web page: http or https with a host, read as a URL rather than by its first letters.
    public static func webURL(_ address: String) -> URL? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// A bundle such as an app: a folder Finder shows as one item, which opening would launch.
    public static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// Google Drive for desktop and other file providers keep their files here. A folder in it syncs to other
    /// people the moment anything is written, so it is something tasks read, never a folder they work in.
    public static func isCloudDrive(_ path: String) -> Bool {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage").standardizedFileURL.path
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return path == cloud || path.hasPrefix(cloud + "/")
    }

    /// The account a Google Drive path belongs to: `…/CloudStorage/GoogleDrive-name@example.com/…`.
    public static func account(of path: String) -> String? {
        guard isCloudDrive(path) else { return nil }
        let component = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.first { $0.hasPrefix("GoogleDrive-") }
        return component.map { String($0.dropFirst("GoogleDrive-".count)) }
    }

    /// A readable name for an address that came without one.
    public static func title(of address: String, kind: SourceKind) -> String {
        if let url = webURL(address) {
            if url.host?.hasSuffix("google.com") == true { return "Google " + kind.label }
            let path = url.path == "/" ? "" : url.path
            return (url.host ?? address) + path
        }
        let url = URL(fileURLWithPath: address)
        return ["gsheet", "gdoc", "gslides"].contains(url.pathExtension.lowercased()) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    /// What an agent's Markdown answer links to that a group could keep: Google Docs, Sheets, Slides and Drive items,
    /// and folders on this Mac that exist. Relative paths are read against the task's working folder.
    /// Files and other web pages are left out: answers cite many of them, and few belong to a group.
    public static func documents(in markdown: String, relativeTo folder: String?) -> [(address: String, title: String?)] {
        var found: [(String, String?)] = []
        var seen = Set<String>()
        func add(_ raw: String, _ title: String?) {
            var address = raw.trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'`.,;:)"))
            if let colon = address.range(of: ":\\d+$", options: .regularExpression), !address.hasPrefix("http") { address.removeSubrange(colon) }
            if address.hasPrefix("file://"), let url = URL(string: address) { address = url.path }
            if address.hasPrefix("http") {
                guard let url = URL(string: address), let host = url.host?.lowercased(),
                      host == "docs.google.com" || host == "drive.google.com" else { return }
            } else {
                if address.hasPrefix("~/") { address = FileManager.default.homeDirectoryForCurrentUser.appending(path: String(address.dropFirst(2))).path }
                else if !address.hasPrefix("/") {
                    guard let folder, !address.isEmpty, !address.contains("://"), !address.hasPrefix("#") else { return }
                    address = URL(fileURLWithPath: folder).appending(path: address).path
                }
                address = URL(fileURLWithPath: address).standardizedFileURL.path
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: address, isDirectory: &directory), directory.boolValue || isDriveStub(address) else { return }
            }
            guard seen.insert(address).inserted else { return }
            let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "`", with: "")
            found.append((address, title?.isEmpty == false && title != address ? title : nil))
        }
        // Markdown links first, so a document keeps the name the answer gave it.
        let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = linkPattern.matches(in: markdown, range: range)
        for match in matches {
            guard let text = Range(match.range(at: 1), in: markdown), let target = Range(match.range(at: 2), in: markdown) else { continue }
            add(String(markdown[target]), String(markdown[text]))
        }
        var linked = markdown
        for match in matches.reversed() { if let whole = Range(match.range, in: linked) { linked.replaceSubrange(whole, with: " ") } }
        // Bare Google addresses elsewhere in the text.
        let barePattern = try! NSRegularExpression(pattern: #"https://(?:docs|drive)\.google\.com/[^\s)\]>"']+"#)
        for match in barePattern.matches(in: linked, range: NSRange(linked.startIndex..., in: linked)) {
            if let raw = Range(match.range, in: linked) { add(String(linked[raw]), nil) }
        }
        return found.map { (address: $0.0, title: $0.1) }
    }
}

extension LinkedSource {
    /// A Google Drive for desktop link file: a Doc, Sheet or Slides that lives online.
    static func isDriveStub(_ path: String) -> Bool { ["gsheet", "gdoc", "gslides"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }

    /// The Google Docs, Sheets and Slides directly inside a Drive folder on this Mac, newest first, with when each last changed.
    public static func driveDocuments(in folder: String) -> [(path: String, modified: Date)] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return contents.filter { isDriveStub($0.path) }
            .map { ($0.standardizedFileURL.path, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
    }

    /// The web address a Google Drive for desktop link file points to. These files hold the document's ID, sometimes its address.
    public static func webAddress(ofStub path: String) -> String? {
        let kind = SourceKind.of(path)
        guard [.sheet, .doc, .slides].contains(kind), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let url = json["url"] as? String, url.hasPrefix("https://") { return url }
        guard let id = json["doc_id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let path = kind == .sheet ? "spreadsheets" : kind == .doc ? "document" : "presentation"
        return "https://docs.google.com/\(path)/d/\(id)/edit"
    }
}

extension FaciendaStore {
    static func registerGroupSources(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("group_sources") { db in
            try db.execute(sql: """
            CREATE TABLE groupSources (
              id TEXT PRIMARY KEY NOT NULL, groupId TEXT NOT NULL REFERENCES taskGroups(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, address TEXT NOT NULL, title TEXT NOT NULL, account TEXT, state TEXT NOT NULL,
              taskId TEXT, note TEXT, position INTEGER NOT NULL, createdAt DATETIME NOT NULL,
              UNIQUE (groupId, address)
            );
            """)
        }
        // Answers and task folders used to offer every file an agent touched, and linked repositories their web page.
        // Groups now get folders, online documents and what the user attached; the rest of those offers are put away.
        migrator.registerMigration("group_sources_narrowed") { db in
            try db.execute(sql: """
            UPDATE groupSources SET state = 'dismissed' WHERE state = 'proposed' AND (
              (kind = 'file' AND address NOT LIKE 'http%' AND address NOT LIKE '%/Attachments/%')
              OR (taskId IS NULL AND kind = 'link' AND note LIKE 'Where “%” is hosted%'))
            """)
        }
    }

    /// A source can belong to a workspace rather than a group, and carries a line on what is inside.
    static func registerWorkspaceSources(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("workspace_sources") { db in
            try db.execute(sql: """
            CREATE TABLE groupSourcesNew (
              id TEXT PRIMARY KEY NOT NULL, groupId TEXT REFERENCES taskGroups(id) ON DELETE CASCADE,
              workspaceId TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, address TEXT NOT NULL, title TEXT NOT NULL, account TEXT, state TEXT NOT NULL,
              taskId TEXT, note TEXT, about TEXT, position INTEGER NOT NULL, createdAt DATETIME NOT NULL,
              CHECK ((groupId IS NULL) != (workspaceId IS NULL))
            );
            INSERT INTO groupSourcesNew (id, groupId, kind, address, title, account, state, taskId, note, position, createdAt)
              SELECT id, groupId, kind, address, title, account, state, taskId, note, position, createdAt FROM groupSources;
            DROP TABLE groupSources;
            ALTER TABLE groupSourcesNew RENAME TO groupSources;
            CREATE UNIQUE INDEX group_sources_group_address ON groupSources(groupId, address) WHERE groupId IS NOT NULL;
            CREATE UNIQUE INDEX group_sources_workspace_address ON groupSources(workspaceId, address) WHERE workspaceId IS NOT NULL;
            """)
        }
    }

    /// The scoped workspace's sources, linked and proposed, in order. Dismissed ones are left out.
    public func workspaceSources(workspaceID: String? = nil) throws -> [WorkspaceSource] {
        try db.read { db in
            let workspace = try Self.workspaceID(db, workspaceID, scope: self.workspaceID)
            return try WorkspaceSource.fetchAll(db, sql: "SELECT * FROM groupSources WHERE workspaceId = ? AND state != 'dismissed' ORDER BY position", arguments: [workspace])
        }
    }
    /// The sources a task's chats are told to read: its workspace's.
    public func linkedSources(forTask taskId: String) throws -> [WorkspaceSource] {
        try db.read { db in
            guard let workspace = try String.fetchOne(db, sql: "SELECT workspaceId FROM tasks WHERE id = ?", arguments: [taskId]) else { return [] }
            return try WorkspaceSource.fetchAll(db, sql: "SELECT * FROM groupSources WHERE workspaceId = ? AND state = 'linked' ORDER BY position", arguments: [workspace])
        }
    }
    /// Links a source every task in the workspace may read. One already proposed or dismissed is linked as it is.
    /// A Drive folder linked from this Mac also offers its newest Docs, Sheets and Slides.
    @discardableResult public func linkWorkspaceSource(_ address: String, title: String? = nil, workspaceID: String? = nil) throws -> WorkspaceSource {
        let (address, account, name) = try Self.normalized(address)
        let title = title ?? name
        let source = try write { db -> WorkspaceSource in
            let workspace = try Self.workspaceID(db, workspaceID, scope: self.workspaceID)
            if var existing = try Self.source(db, workspace: workspace, address: address) {
                existing.state = .linked
                if let title, !title.isEmpty { existing.title = title }
                try existing.update(db)
                return existing
            }
            return try Self.insertSource(db, address: address, title: title, workspace: workspace, state: .linked, taskId: nil, note: nil, account: account)
        }
        if source.kind == .driveFolder, !source.isWeb { offerDriveDocuments(in: source, limit: 5) }
        return source
    }
    /// An agent's suggestion for its task's workspace. It waits for the user; one the user already linked or dismissed stays
    /// as it is. Files on this Mac reach a workspace only when the user attaches or links them.
    /// A folder on this Mac must be inside Facienda's data folder or the task's own working folder: an agent cannot point the
    /// user at arbitrary places on disk. Answers Facienda reads itself pass `anywhere`, since it found the folder there.
    @discardableResult public func proposeSource(_ address: String, title: String?, note: String?, taskId: String) throws -> WorkspaceSource {
        try proposeSource(address, title: title, note: note, taskId: taskId, anywhere: false)
    }
    private func proposeSource(_ address: String, title: String?, note: String?, taskId: String, anywhere: Bool) throws -> WorkspaceSource {
        let (address, account, name) = try Self.normalized(address)
        let title = title ?? name
        if LinkedSource.webURL(address) == nil {
            if SourceKind.of(address) == .file {
                throw StoreError.invalid("Only folders and online documents can be proposed. The user links files themselves; mention the file in your answer instead.")
            }
            if !anywhere, !isProposableFolder(address, taskId: taskId) {
                throw StoreError.invalid("Only folders inside Facienda's data folder or the task's working folder can be proposed. Mention other folders in your answer instead.")
            }
        }
        return try write { db in
            guard let workspace = try Self.sourceWorkspace(db, taskId: taskId) else { throw StoreError.notFound }
            if let existing = try Self.source(db, workspace: workspace, address: address) { return existing }
            if try Self.workspaceFolders(db, workspaceID: workspace).contains(where: { address == $0 || address.hasPrefix($0 + "/") }) {
                throw StoreError.invalid("That is inside a folder already linked to the workspace for its tasks to work in.")
            }
            return try Self.insertSource(db, address: address, title: title, workspace: workspace, state: .proposed, taskId: taskId, note: note, account: account)
        }
    }
    /// Proposes what an answer links to that the workspace could keep (Google Docs, Sheets, Slides and Drive items, and folders
    /// on this Mac), then the files the user attached to the task. Folders inside tasks' own folders or the workspace's work
    /// folders are left out. Returns the answer's new proposals; what the workspace already has, or the user dismissed, is not offered again.
    @discardableResult public func proposeSources(fromAnswer text: String, taskId: String) throws -> [WorkspaceSource] {
        let task = try self.task(taskId)
        guard let workspace = try db.read({ try Self.sourceWorkspace($0, taskId: taskId) }) else { return [] }
        let (known, worked) = try db.read { db in
            (Set(try WorkspaceSource.filter(Column("workspaceId") == workspace).fetchAll(db).map(\.address)), try Self.workspaceFolders(db, workspaceID: workspace))
        }
        let inside = { (address: String, folder: String) in address == folder || address.hasPrefix(folder + "/") }
        var proposed: [WorkspaceSource] = [], seen = known
        for found in LinkedSource.documents(in: text, relativeTo: task.cwd) where seen.insert(found.address).inserted {
            guard !worked.contains(where: { inside(found.address, $0) }), !(found.address.hasPrefix("/") && isFaciendaFolder(found.address)) else { continue }
            guard let source = try? proposeSource(found.address, title: found.title, note: "Linked in the answer to “\(task.displayName)”.", taskId: taskId, anywhere: true),
                  source.state == .proposed, source.taskId == taskId, !known.contains(source.address) else { continue }
            proposed.append(source)
            if proposed.count == 6 { break }
        }
        offerAttachments(of: taskId)
        return proposed
    }
    /// Offers the files the user attached to a task to its workspace. Returns how many were new.
    @discardableResult public func offerAttachments(of taskId: String) -> Int {
        guard let task = try? self.task(taskId), let attachments = task.attachments, !attachments.isEmpty,
              let workspace = try? db.read({ try Self.sourceWorkspace($0, taskId: taskId) }) else { return 0 }
        var offered = 0
        for file in attachments where FileManager.default.fileExists(atPath: file.path) {
            if offer(file.path, title: file.name, note: "Attached to “\(task.displayName)”.", account: nil, workspace: workspace, taskId: taskId) { offered += 1 }
        }
        return offered
    }
    /// Offers the Docs, Sheets and Slides that changed in a linked Drive folder since it was linked. Returns how many it offered.
    @discardableResult public func offerAutomaticSources() throws -> Int {
        var offered = 0
        let linked = try db.read { try WorkspaceSource.fetchAll($0, sql: "SELECT * FROM groupSources WHERE state = 'linked' AND kind = 'driveFolder'") }
        for source in linked where !source.isWeb {
            offered += offerDriveDocuments(in: source, limit: 3, changedSince: source.createdAt)
        }
        return offered
    }
    /// Proposes the newest Docs, Sheets and Slides directly inside a linked Drive folder. Returns how many were new.
    @discardableResult func offerDriveDocuments(in folder: WorkspaceSource, limit: Int, changedSince: Date? = nil) -> Int {
        var offered = 0
        for document in LinkedSource.driveDocuments(in: folder.address) where changedSince.map({ document.modified > $0 }) ?? true {
            let address = LinkedSource.webAddress(ofStub: document.path) ?? document.path
            if offer(address, title: LinkedSource.title(of: document.path, kind: SourceKind.of(document.path)), note: "In the Drive folder “\(folder.title)”.",
                     account: folder.account, workspace: folder.workspaceId) { offered += 1 }
            if offered == limit { break }
        }
        return offered
    }
    /// A proposal Facienda makes itself, not an agent. Anything the workspace already has, or the user dismissed, is left alone.
    private func offer(_ address: String, title: String, note: String, account: String?, workspace: String, taskId: String? = nil) -> Bool {
        (try? write { db -> Bool in
            guard (try? Self.workspace(db, workspace)) != nil, try Self.source(db, workspace: workspace, address: address) == nil else { return false }
            _ = try Self.insertSource(db, address: address, title: title, workspace: workspace, state: .proposed, taskId: taskId, note: note, account: account)
            return true
        }) ?? false
    }

    /// Where a task's proposals go: its workspace.
    static func sourceWorkspace(_ db: Database, taskId: String) throws -> String? {
        try FaciendaTask.fetchOne(db, key: taskId)?.workspaceId
    }
    private static func source(_ db: Database, workspace: String, address: String) throws -> WorkspaceSource? {
        try WorkspaceSource.filter(Column("workspaceId") == workspace && Column("address") == address).fetchOne(db)
    }
    /// Inside the data folder, or inside the task's working folder when that is a real project rather than the home folder or the disk.
    func isProposableFolder(_ path: String, taskId: String) -> Bool {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let inside = { (root: String) in
            let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
        if inside(workFolder.path) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        guard let cwd = (try? task(taskId))?.cwd, !cwd.isEmpty else { return false }
        let root = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return root != "/" && root != home && !home.hasPrefix(root + "/") && inside(root)
    }

    public func setSourceState(_ id: String, _ state: WorkspaceSource.State) throws {
        try write { db in
            guard var source = try WorkspaceSource.fetchOne(db, key: id) else { throw StoreError.notFound }
            source.state = state
            try source.update(db)
        }
    }

    public func renameSource(_ id: String, to title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.invalid("A source needs a name.") }
        try write { db in
            guard var source = try WorkspaceSource.fetchOne(db, key: id) else { throw StoreError.notFound }
            source.title = title
            try source.update(db)
        }
    }

    /// The user's line on what a source holds and when to read it. Blank clears it.
    public func setSourceAbout(_ id: String, _ about: String) throws {
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        try write { db in
            guard var source = try WorkspaceSource.fetchOne(db, key: id) else { throw StoreError.notFound }
            source.about = about.isEmpty ? nil : about
            try source.update(db)
        }
    }

    /// The address a source is kept under, the Google account its path names, and a name when the address alone loses it:
    /// a Drive link file becomes its document's web address, but keeps its file name.
    private static func normalized(_ address: String) throws -> (address: String, account: String?, name: String?) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalid("A source needs an address: a web link or a path on this Mac.") }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard LinkedSource.webURL(trimmed) != nil else { throw StoreError.invalid("That web address is not valid.") }
            return (trimmed, nil, nil)
        }
        let path = trimmed.hasPrefix("file://") ? URL(string: trimmed)?.path ?? trimmed : trimmed
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { throw StoreError.invalid("Give a web link or an absolute path on this Mac.") }
        let expanded = path.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.appending(path: String(path.dropFirst(2))).path : path
        let standard = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standard) else { throw StoreError.invalid("Nothing exists at \(standard) on this Mac.") }
        guard let web = LinkedSource.webAddress(ofStub: standard) else { return (standard, LinkedSource.account(of: standard), nil) }
        return (web, LinkedSource.account(of: standard), LinkedSource.title(of: standard, kind: SourceKind.of(standard)))
    }

    private static func insertSource(_ db: Database, address: String, title: String?, workspace: String, state: WorkspaceSource.State,
                                     taskId: String?, note: String?, account: String? = nil) throws -> WorkspaceSource {
        let kind = SourceKind.of(address)
        let position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM groupSources WHERE workspaceId = ?", arguments: [workspace]) ?? -1) + 1
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = WorkspaceSource(id: UUID().uuidString, workspaceId: workspace, kind: kind, address: address,
                                     title: name?.isEmpty == false ? name! : LinkedSource.title(of: address, kind: kind),
                                     account: account ?? LinkedSource.account(of: address), state: state, taskId: taskId,
                                     note: note?.isEmpty == false ? note : nil, about: nil, position: position, createdAt: Date())
        try source.insert(db)
        return source
    }
}
