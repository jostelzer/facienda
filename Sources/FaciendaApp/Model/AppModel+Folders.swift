import AppKit
import FaciendaCore

extension AppModel {
    /// What the board reads from disk about folders: repository roots and whether a folder still
    /// exists. Kept until the next refresh; every redraw used to read it afresh for each row, card and menu.
    struct FolderLookups {
        var roots: [String: String] = [:]
        var exists: [String: Bool] = [:]
        var automatic: [String: Bool] = [:]
    }
    func chooseFolder(for group: TaskGroup) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Link"
        panel.message = "New tasks in “\(group.name)” will work in this folder. A folder inside a repository links the whole repository."
        if panel.runModal() == .OK, let url = panel.url { linkFolder(url.path, to: group) }
    }
    func linkFolder(_ path: String, to group: TaskGroup) {
        perform(undo: "Link Folder") { try store.linkFolder(path, groupId: group.id); refresh() }
        Task { await syncCodexProject(group.id) }
    }
    func unlinkFolder(_ path: String, from group: TaskGroup) {
        perform(undo: "Unlink Folder") { try store.unlinkFolder(path, groupId: group.id); refresh() }
        Task { await syncCodexProject(group.id) }
    }
    func chooseSourceFile(for group: TaskGroup) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Link"
        panel.message = "Tasks in “\(group.name)” will be told about this file and read it when it matters."
        if panel.runModal() == .OK, let url = panel.url { linkSource(url.path, title: nil, to: group) }
    }
    func linkSource(_ address: String, title: String?, to group: TaskGroup) {
        perform(undo: "Link Source") { try store.linkSource(address, title: title, groupId: group.id); refresh() }
    }
    /// A web link or a path on the pasteboard that could become a source, with the page's name when the browser put one there.
    func pastedSource() -> (address: String, title: String?)? {
        let board = NSPasteboard.general
        if let url = board.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            let name = board.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            return (url.isFileURL ? url.path : url.absoluteString, name?.isEmpty == false ? name : nil)
        }
        guard let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.contains("\n") else { return nil }
        if text.hasPrefix("https://") || text.hasPrefix("http://"), URL(string: text)?.host != nil { return (text, nil) }
        if text.hasPrefix("/") || text.hasPrefix("~/"), FileManager.default.fileExists(atPath: (text as NSString).expandingTildeInPath) { return (text, nil) }
        return nil
    }
    /// Looks for new documents in linked Drive folders, off the main thread:
    /// listing a Drive folder can wait on Google Drive.
    func offerAutomaticSources() async {
        let store = self.store
        let offered = await Task.detached { (try? store.offerAutomaticSources()) ?? 0 }.value
        if offered > 0 { refresh() }
    }
    func acceptSource(_ source: GroupSource) { perform(undo: "Link Source") { try store.setSourceState(source.id, .linked); refresh() } }
    func dismissSource(_ source: GroupSource) { perform(undo: "Dismiss Source") { try store.setSourceState(source.id, .dismissed); refresh() } }
    func unlinkSource(_ source: GroupSource) { perform(undo: "Unlink Source") { try store.setSourceState(source.id, .dismissed); refresh() } }
    func renameSource(_ source: GroupSource, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != source.title else { return }
        perform(undo: "Rename Source") { try store.renameSource(source.id, to: title); refresh() }
    }
    /// A web source opens in the browser; anything on this Mac is only shown in Finder, so a proposed path never launches.
    func openSource(_ source: GroupSource) {
        if let url = LinkedSource.webURL(source.address) { NSWorkspace.shared.open(url); return }
        reveal(source.address)
    }
    func revealAttachment(_ attachment: TaskAttachment) { reveal(attachment.path) }
    /// Selects a path in Finder without opening it.
    func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { error = "Nothing exists at \(path) any more."; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    /// Links what the pasteboard holds, read only now that the user asked for it.
    func linkPastedSource(to group: TaskGroup) {
        guard let pasted = pastedSource() else { error = "The clipboard holds no web link or path on this Mac."; return }
        linkSource(pasted.address, title: pasted.title, to: group)
    }
    func makePrimaryFolder(_ path: String, in group: TaskGroup) { perform(undo: "Change Main Folder") { try store.makePrimaryFolder(path, groupId: group.id); refresh() } }
    /// Keeps a Codex project spanning the group's linked folders, so its tasks' chats can work in all of them.
    /// Without a connection it waits for the next task start. A group whose links are all gone keeps its project for later.
    func syncCodexProject(_ groupID: String) async {
        guard !demo, connected, let group = groups.first(where: { $0.id == groupID }),
              let folders = groupFolders[groupID], !folders.isEmpty else { return }
        do {
            let project = try await bridge.groupProject(folders: folders, name: group.name,
                                                        current: group.codexProjectId.map { ($0, group.codexProjectOwned == true) })
            if project.id != group.codexProjectId || project.owned != (group.codexProjectOwned == true) {
                try store.setCodexProject(groupId: groupID, id: project.id, owned: project.owned)
                refresh()
            }
        } catch { self.error = "Codex could not prepare a project for “\(group.name)”: " + error.localizedDescription }
    }
    func loadCodexProjectFolders() async {
        guard !demo, connected, let projects = try? await bridge.projects() else { return }
        let own = [store.libraryDirectory.standardizedFileURL.path, store.workFolder.standardizedFileURL.path]
        var seen = Set<String>()
        codexProjectFolders = projects.sorted { ($0.recencyAt ?? 0) > ($1.recencyAt ?? 0) }.flatMap { $0.roots.map(\.path) }
            .filter { root in !own.contains { root == $0 || root.hasPrefix($0 + "/") } && seen.insert(root).inserted }
    }
    /// Folders worth offering for a group: the ones its tasks already work in, then those linked to other groups, then Codex projects'.
    func folderSuggestions(for group: TaskGroup) -> [String] {
        var seen = Set(groupFolders[group.id] ?? [])
        let used = tasks.filter { groupMembers[$0.id] == group.id }.flatMap(workFolders)
        let elsewhere = groups.filter { $0.id != group.id }.flatMap { groupFolders[$0.id] ?? [] }
        return Array((used + elsewhere + codexProjectFolders).lazy.filter { seen.insert($0).inserted && self.folderExists($0) }.prefix(8))
    }
    /// Where a task works besides its own folder: the folders it took from its group, or one the user chose for it.
    func workFolders(of task: FaciendaTask) -> [String] {
        if let folders = task.folders, !folders.isEmpty { return folders }
        guard let cwd = task.cwd, !isAutomaticWorkingDirectory(cwd, taskID: task.id) else { return [] }
        return [folderRoot(cwd)]
    }
    private func isAutomaticWorkingDirectory(_ cwd: String, taskID: String) -> Bool {
        let key = taskID + "\n" + cwd
        if let known = folderLookups.automatic[key] { return known }
        let automatic = store.isAutomaticWorkingDirectory(cwd, taskID: taskID)
        folderLookups.automatic[key] = automatic
        return automatic
    }
    /// The repository a folder belongs to, or the folder itself.
    func folderRoot(_ path: String) -> String {
        if let root = folderLookups.roots[path] { return root }
        let root = LinkedFolder.root(of: path)
        folderLookups.roots[path] = root
        return root
    }
    private func folderExists(_ path: String) -> Bool {
        if let exists = folderLookups.exists[path] { return exists }
        let exists = FileManager.default.fileExists(atPath: path)
        folderLookups.exists[path] = exists
        return exists
    }
    /// A row's folder label, left out when the task works in exactly what its group links, as the card already says so.
    func folderLabel(for task: FaciendaTask) -> String? {
        let folders = workFolders(of: task)
        guard !folders.isEmpty, Set(folders) != Set(groupMembers[task.id].flatMap { groupFolders[$0] } ?? []) else { return nil }
        return folders.map(LinkedFolder.name(of:)).joined(separator: " · ")
    }
}
