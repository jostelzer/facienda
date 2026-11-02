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

    // MARK: The workspace's places

    /// A folder for the workspace's tasks to work in. With only one, every group works in it unless it says otherwise.
    /// `group` also has that group work in it, for a folder linked from the group's own menu.
    func chooseFolder(for group: TaskGroup? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Link"
        panel.message = group.map { "Tasks in “\($0.name)” will work in this folder. A folder inside a repository links the whole repository." }
            ?? "Tasks in “\(workspace?.name ?? "this workspace")” can work in this folder. A folder inside a repository links the whole repository."
        if panel.runModal() == .OK, let url = panel.url { linkFolder(url.path, for: group) }
    }
    func linkFolder(_ path: String, for group: TaskGroup? = nil) {
        perform(undo: "Link Folder") {
            let linked = try store.linkFolder(path)
            // A Drive folder is linked to read instead, so it is never a place to work.
            if let group, try store.workspaceFolders().contains(linked) { try store.setWorkPlace(.folders([linked]), groupId: group.id) }
            refresh()
        }
        Task { await syncCodexProjects() }
    }
    func unlinkFolder(_ path: String) {
        perform(undo: "Unlink Folder") { try store.unlinkFolder(path); refresh() }
        Task { await syncCodexProjects() }
    }
    func makePrimaryFolder(_ path: String) { perform(undo: "Change Main Folder") { try store.makePrimaryFolder(path); refresh() } }
    /// Where a group's tasks work: where the workspace does, each in its own folder, or in folders of the workspace it chose.
    func setWorkPlace(_ place: GroupWorkPlace, for group: TaskGroup) {
        perform(undo: "Change Work Folder") { try store.setWorkPlace(place, groupId: group.id); refresh() }
        Task { await syncCodexProject(group.id) }
    }
    /// Adds or removes one of the workspace's folders from what the group works in. Nothing left means where the workspace works.
    func toggleWorkFolder(_ path: String, for group: TaskGroup) {
        var chosen = group.ownFolders == true ? [] : groupFolders[group.id] ?? []
        if chosen.contains(path) { chosen.removeAll { $0 == path } } else { chosen.append(path) }
        setWorkPlace(chosen.isEmpty ? .workspace : .folders(chosen), for: group)
    }
    /// The group works somewhere other than the workspace's usual place, so its card says where.
    func worksElsewhere(_ group: TaskGroup) -> Bool { (groupFolders[group.id] ?? []) != defaultFolders }
    /// Where the workspace's tasks work when their group says nothing: its one folder, or each task's own.
    var defaultFolders: [String] { workspaceFolders.count == 1 ? workspaceFolders : [] }

    func chooseWorkspaceSourceFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Link"
        panel.message = "Every task in “\(workspace?.name ?? "this workspace")” will be told about this folder and read it when it matters."
        if panel.runModal() == .OK, let url = panel.url { linkWorkspaceSource(url.path, title: nil) }
    }
    func chooseWorkspaceSourceFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Link"
        panel.message = "Every task in “\(workspace?.name ?? "this workspace")” will be told about this file and read it when it matters."
        if panel.runModal() == .OK, let url = panel.url { linkWorkspaceSource(url.path, title: nil) }
    }
    func linkWorkspaceSource(_ address: String, title: String?) {
        perform(undo: "Link Source") { try store.linkWorkspaceSource(address, title: title); refresh() }
    }
    /// Links what the pasteboard holds, read only now that the user asked for it.
    func linkPastedWorkspaceSource() {
        guard let pasted = pastedSource() else { error = "The clipboard holds no web link or path on this Mac."; return }
        linkWorkspaceSource(pasted.address, title: pasted.title)
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
    /// The user's line on what a source holds, which agents are told with its address.
    func setSourceAbout(_ source: WorkspaceSource, _ about: String) {
        perform { try store.setSourceAbout(source.id, about); refresh() }
    }

    func acceptSource(_ source: WorkspaceSource) { perform(undo: "Link Source") { try store.setSourceState(source.id, .linked); refresh() } }
    func dismissSource(_ source: WorkspaceSource) { perform(undo: "Dismiss Source") { try store.setSourceState(source.id, .dismissed); refresh() } }
    func unlinkSource(_ source: WorkspaceSource) { perform(undo: "Unlink Source") { try store.setSourceState(source.id, .dismissed); refresh() } }
    func renameSource(_ source: WorkspaceSource, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != source.title else { return }
        perform(undo: "Rename Source") { try store.renameSource(source.id, to: title); refresh() }
    }
    /// A web source opens in the browser; anything on this Mac is only shown in Finder, so a proposed path never launches.
    func openSource(_ source: WorkspaceSource) {
        if let url = LinkedSource.webURL(source.address) { NSWorkspace.shared.open(url); return }
        reveal(source.address)
    }
    func revealAttachment(_ attachment: TaskAttachment) { reveal(attachment.path) }
    /// Selects a path in Finder without opening it.
    func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { error = "Nothing exists at \(path) any more."; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Codex projects

    /// Keeps a Codex project spanning the folders a group works in, so its tasks' chats can work in all of them.
    /// Without a connection it waits for the next task start. A group that no longer works in any keeps its project for later.
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
    /// After the workspace's folders change, every group that works in them gets its project.
    func syncCodexProjects() async {
        for group in groups where groupFolders[group.id] != nil { await syncCodexProject(group.id) }
    }
    /// A task without a group works in the workspace's folder; Codex needs a project there too. One that matches is reused.
    func syncWorkspaceProject(_ folders: [String]) async {
        guard !demo, connected, !folders.isEmpty else { return }
        do { _ = try await bridge.groupProject(folders: folders, name: workspace?.name ?? LinkedFolder.name(of: folders[0]), current: nil) }
        catch { self.error = "Codex could not prepare a project for this workspace’s folder: " + error.localizedDescription }
    }
    func loadCodexProjectFolders() async {
        guard !demo, connected, let projects = try? await bridge.projects() else { return }
        let own = [store.libraryDirectory.standardizedFileURL.path, store.workFolder.standardizedFileURL.path]
        var seen = Set<String>()
        codexProjectFolders = projects.sorted { ($0.recencyAt ?? 0) > ($1.recencyAt ?? 0) }.flatMap { $0.roots.map(\.path) }
            .filter { root in !own.contains { root == $0 || root.hasPrefix($0 + "/") } && seen.insert(root).inserted }
    }

    // MARK: Reading folders

    /// Folders worth offering for the workspace: the ones its tasks already work in, then Codex projects'.
    func folderSuggestions() -> [String] {
        var seen = Set(workspaceFolders)
        let used = tasks.flatMap(workFolders)
        return Array((used + codexProjectFolders).lazy.filter { seen.insert($0).inserted && self.folderExists($0) }.prefix(8))
    }
    /// Where a task works besides its own folder: the folders it took from its group or workspace, or one the user chose for it.
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
    func folderExists(_ path: String) -> Bool {
        if let exists = folderLookups.exists[path] { return exists }
        let exists = FileManager.default.fileExists(atPath: path)
        folderLookups.exists[path] = exists
        return exists
    }
    /// A row's folder label, left out when the task works where its group or workspace does, which goes without saying.
    func folderLabel(for task: FaciendaTask) -> String? {
        let folders = workFolders(of: task)
        let usual = groupMembers[task.id].map { groupFolders[$0] ?? [] } ?? defaultFolders
        guard !folders.isEmpty, Set(folders) != Set(usual) else { return nil }
        return folders.map(LinkedFolder.name(of:)).joined(separator: " · ")
    }
}
