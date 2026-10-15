import AppKit
import Observation
import FaciendaCore
import FaciendaBridge

struct CodexCoverPainter: CoverPainting {
    var subject: CoverSubject = .group
    /// The base style written in Settings; the painter falls back to ours when it is blank.
    static var baseStyle: String? { UserDefaults.standard.string(forKey: "coverBaseStyle") }
    func paint(executable: String, name: String, tasks: [String], style: String?, notes: [String]) async throws -> GroupCover {
        try await GroupCoverPainter.paint(executable: executable, name: name, tasks: tasks, style: style, notes: notes, baseStyle: Self.baseStyle, subject: subject)
    }
    func edit(executable: String, cover: URL, name: String, tasks: [String], instruction: String, style: String?, notes: [String]) async throws -> GroupCover {
        try await GroupCoverPainter.edit(executable: executable, cover: cover, name: name, tasks: tasks, instruction: instruction, style: style, notes: notes, baseStyle: Self.baseStyle, subject: subject)
    }
}

enum WorkspaceSheet: Identifiable {
    case manage, create, edit(Workspace)

    var id: String {
        switch self {
        case .manage: "manage"
        case .create: "create"
        case .edit(let workspace): "edit:" + workspace.id
        }
    }
}

/// The library's workspaces. Each visited workspace keeps its model, so drafts
/// and background monitoring stay intact while another workspace is on screen.
@MainActor @Observable final class WorkspaceController {
    let demo: Bool
    /// One Codex connection for every workspace, so a switch never waits for Codex to start.
    let codex: CodexConnection
    var model: AppModel?
    var workspaces: [Workspace] = []
    var memorySpaces: [MemorySpace] = []
    var startupError: String?
    var error: String?
    var sheet: WorkspaceSheet?
    /// Workspaces pinned by earlier versions, the order the user dragged them into, and every
    /// workspace by most recent visit. These are this Mac's view preferences, so they live
    /// outside the library.
    private(set) var pinned: [String]
    private(set) var order: [String]
    private(set) var recent: [String]
    /// Workspaces that need you, including ones not visited since launch.
    private var fresh: [String: Int] = [:]
    /// Paints the sidebar pictures through Codex. nil in the demo and tests, so they never reach Codex.
    @ObservationIgnored var coverPainter: (any CoverPainting)?
    /// Painted pictures by workspace ID.
    var coverImages: [String: NSImage] = [:]
    /// Workspaces whose picture is being painted right now.
    var paintingCovers: Set<String> = []
    /// What a picture looked like before its last change, so the change can be undone.
    var coverUndo: [String: CoverSnapshot] = [:]
    @ObservationIgnored private var coverStamps: [String: Date] = [:]
    /// Workspaces whose automatic painting failed since launch; they wait for the user to ask again.
    @ObservationIgnored private var coverFailures: Set<String> = []
    @ObservationIgnored private(set) var library: FaciendaStore?
    @ObservationIgnored private var models: [String: AppModel] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    /// The library file this controller opens. Tests pass their own.
    @ObservationIgnored let libraryURL: URL

    init(libraryURL: URL = LibraryHome.databaseURL, demo: Bool = false, load: Bool = true, defaults: UserDefaults = .standard) {
        self.libraryURL = libraryURL
        self.demo = demo
        self.defaults = defaults
        codex = CodexConnection(demo: demo)
        pinned = defaults.stringArray(forKey: "pinnedWorkspaces") ?? []
        order = defaults.stringArray(forKey: "workspaceOrder") ?? []
        recent = defaults.stringArray(forKey: "recentWorkspaces") ?? []
        do {
            if demo, load { install(try AppModel(demo: true)) }
            else if load, FileManager.default.fileExists(atPath: libraryURL.path) { try openLibrary() }
        } catch { startupError = error.localizedDescription }
    }

    /// Opens the library. A missing one is reported; it is never replaced by an empty one.
    func openLibrary() throws {
        let store = try LibraryHome.open(at: libraryURL)
        store.sweepGroupCovers()
        // Off the main thread: finished tasks' folders past the retention period go to the Trash (sizing them reads the
        // disk), and today's copy of the library is made outside the data folder.
        Task.detached(priority: .utility) { _ = try? store.clearFinishedArtifacts(); LibraryHome.backUp(store) }
        let available = try store.workspaces()
        guard let start = available.first(where: { $0.id == defaults.string(forKey: "currentWorkspace") }) ?? available.first else {
            throw StoreError.invalid("Create a workspace to get started.")
        }
        install(try AppModel(store: store.scoped(to: start.id), codex: codex))
    }

    var current: Workspace? {
        workspaces.first { $0.id == model?.workspaceID }
    }
    var name: String { current?.name ?? "My workspace" }

    func install(_ model: AppModel) {
        models[model.workspaceID] = model
        self.model = model
        library = model.store.library
        startupError = nil
        if !demo {
            model.coverPainter = CodexCoverPainter()
            coverPainter = CodexCoverPainter(subject: .workspace)
        }
        reload()
        guard !demo else { return }
        if let current { visited(current); defaults.set(current.id, forKey: "currentWorkspace") }
        // The phone's workspace keeps syncing while another is on screen.
        if let id = UserDefaults.standard.string(forKey: "mobileSyncWorkspace"), models[id] == nil,
           workspaces.contains(where: { $0.id == id }), let library,
           let companionModel = try? AppModel(store: library.scoped(to: id), codex: codex) {
            models[id] = companionModel
            companionModel.start()
        }
    }

    func reload() {
        guard let library else { return }
        do {
            workspaces = try library.workspaces()
            memorySpaces = try library.memorySpaces()
            fresh = try library.newCounts()
        } catch { self.error = error.localizedDescription }
        loadCovers(); paintMissingCovers()
    }

    /// Tasks that came back finished since the user last opened them.
    func newCount(for workspace: Workspace) -> Int {
        // Background models refresh lazily, so only the one on screen is fresher than the library.
        workspace.id == current?.id ? model?.newCount ?? 0 : fresh[workspace.id] ?? 0
    }

    func memoryName(for workspace: Workspace) -> String {
        memorySpaces.first { $0.id == workspace.memorySpaceId }?.name ?? "Memory"
    }

    func isPinned(_ workspace: Workspace) -> Bool { pinned.contains(workspace.id) }

    private func visited(_ workspace: Workspace) {
        recent.removeAll { $0 == workspace.id }
        recent.insert(workspace.id, at: 0)
        recent = Array(recent.prefix(50))
        defaults.set(recent, forKey: "recentWorkspaces")
    }

    /// Every workspace in the order the user dragged them into.
    var ordered: [Workspace] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return workspaces.enumerated().sorted {
            (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset)
        }.map(\.element)
    }

    /// Dropping a workspace places it just before or after the row it was dropped on.
    func move(_ source: Workspace, to target: Workspace, after: Bool) {
        var ids = ordered.map(\.id)
        guard source.id != target.id, let from = ids.firstIndex(of: source.id) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: target.id) else { return }
        ids.insert(source.id, at: after ? to + 1 : to)
        order = ids
        defaults.set(order, forKey: "workspaceOrder")
    }

    @discardableResult func open(_ workspace: Workspace) -> Bool {
        guard !demo, let library else { return false }
        do {
            // A new model has just read everything; only a kept one needs to catch up.
            let next: AppModel
            if let kept = models[workspace.id] { next = kept; next.refresh() }
            else { next = try AppModel(store: library.scoped(to: workspace.id), codex: codex) }
            install(next)
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// A new workspace shares the library's Codex connection, so it is ready at once.
    @discardableResult func create(name: String, memorySpaceID: String) -> Bool {
        guard !demo, let library else { return false }
        do {
            let workspace = try library.createWorkspace(name: name, memorySpaceID: memorySpaceID)
            reload()
            return open(workspace)
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func rename(_ workspace: Workspace, to name: String) -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.renameWorkspace(workspace.id, to: name)
            reload(); models[workspace.id]?.refresh()
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// From now on the workspace learns into and recalls from this memory. What it learned before stays where it is.
    @discardableResult func setMemory(_ workspace: Workspace, to spaceID: String) -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.setMemorySpace(workspaceID: workspace.id, spaceID: spaceID)
            reload(); models[workspace.id]?.refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func remove(_ workspace: Workspace) async -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.removeWorkspace(workspace.id)
            if let removed = models.removeValue(forKey: workspace.id) { await removed.stop() }
            let wasCurrent = model?.workspaceID == workspace.id
            reload()
            if wasCurrent {
                model = nil
                if let next = workspaces.first { _ = open(next) }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func createMemory(name: String) -> MemorySpace? {
        guard !demo, let library else { return nil }
        do {
            let space = try library.createMemorySpace(name: name)
            reload()
            return space
        } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult func renameMemory(_ space: MemorySpace, to name: String) -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.renameMemorySpace(space.id, to: name)
            reload(); model?.refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func deleteMemory(_ space: MemorySpace) -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.deleteMemorySpace(space.id)
            reload(); model?.refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    // MARK: Pictures

    private func loadCovers() {
        guard let library else { return }
        for workspace in workspaces where coverStamps[workspace.id] != workspace.coverPaintedAt {
            coverStamps[workspace.id] = workspace.coverPaintedAt
            coverImages[workspace.id] = workspace.coverPaintedAt == nil ? nil : NSImage(contentsOf: library.coverURL(workspaceId: workspace.id))
        }
    }

    /// Every workspace gets a picture once Codex is ready, one at a time so a new library does not start a crowd of runs.
    /// Renaming later never repaints on its own.
    func paintMissingCovers() {
        let enabled = UserDefaults.standard.object(forKey: "groupCovers") as? Bool ?? true
        guard coverPainter != nil, !demo, enabled, codex.connected, codex.accountReady, paintingCovers.isEmpty else { return }
        if let next = ordered.first(where: { $0.coverPaintedAt == nil && !coverFailures.contains($0.id) }) { paintCover(next, requested: false) }
    }

    /// The groups say what the workspace is about; open tasks fill in the detail.
    private func coverContents(_ workspace: Workspace, in library: FaciendaStore) -> [String] {
        let scoped = library.scoped(to: workspace.id)
        return ((try? scoped.groups()) ?? []).map(\.name) + ((try? scoped.tasks()) ?? []).filter(\.state.isOpen).map(\.displayName)
    }

    /// Repainting keeps the workspace's style and notes unless a new style is asked for.
    func paintCover(_ workspace: Workspace, newStyle: Bool = false, requested: Bool = true) {
        guard let coverPainter, let library else { return }
        let contents = coverContents(workspace, in: library), executable = codex.executable
        let style = newStyle ? nil : workspace.coverStyle, notes = workspace.coverNoteList
        changeCover(workspace, requested: requested, note: nil) {
            try await coverPainter.paint(executable: executable, name: workspace.name, tasks: contents, style: style, notes: notes)
        }
    }

    /// Carries out a wish for the workspace's picture, a change to it or a new one, and remembers the wish for later repaints.
    func adjustCover(_ workspace: Workspace, instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let coverPainter, let library, !instruction.isEmpty, workspace.coverPaintedAt != nil else { return }
        let executable = codex.executable, file = library.coverURL(workspaceId: workspace.id), style = workspace.coverStyle, notes = workspace.coverNoteList
        let contents = coverContents(workspace, in: library)
        changeCover(workspace, requested: true, note: instruction) {
            try await coverPainter.edit(executable: executable, cover: file, name: workspace.name, tasks: contents, instruction: instruction, style: style, notes: notes)
        }
    }

    private func changeCover(_ workspace: Workspace, requested: Bool, note: String?, _ produce: @escaping @Sendable () async throws -> GroupCover) {
        guard !demo, let library, !paintingCovers.contains(workspace.id) else { return }
        paintingCovers.insert(workspace.id); coverFailures.remove(workspace.id)
        Task {
            do {
                let cover = try await produce()
                if workspace.coverPaintedAt != nil { coverUndo[workspace.id] = CoverSnapshot(style: workspace.coverStyle, notes: workspace.coverNoteList) }
                try library.saveCover(workspaceId: workspace.id, image: cover.image, style: cover.style, note: note)
            } catch {
                coverFailures.insert(workspace.id)
                if requested { self.error = error.localizedDescription }
            }
            paintingCovers.remove(workspace.id)
            reload()
        }
    }

    func canUndoCover(_ workspace: Workspace) -> Bool {
        guard let library else { return false }
        return coverUndo[workspace.id] != nil && !paintingCovers.contains(workspace.id)
            && FileManager.default.fileExists(atPath: library.previousCoverURL(workspaceId: workspace.id).path)
    }

    func undoCover(_ workspace: Workspace) {
        guard let library, let snapshot = coverUndo.removeValue(forKey: workspace.id) else { return }
        do { try library.restorePreviousCover(workspaceId: workspace.id, style: snapshot.style, notes: snapshot.notes); reload() }
        catch { self.error = error.localizedDescription }
    }

    func forgetCoverNotes(_ workspace: Workspace) {
        guard let library else { return }
        do { try library.setCoverNotes(workspaceId: workspace.id, notes: []); reload() }
        catch { self.error = error.localizedDescription }
    }
}
