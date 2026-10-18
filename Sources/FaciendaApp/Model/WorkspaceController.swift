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
    var startupError: String?
    var error: String?
    var sheet: WorkspaceSheet?
    /// Workspaces pinned by earlier versions, the order the user dragged them into, and every
    /// workspace by most recent visit. These are this Mac's view preferences, so they live
    /// outside the library.
    private(set) var pinned: [String]
    private(set) var order: [String]
    private(set) var recent: [String]
    /// Where each workspace sits on the sidebar's island, as fractions of its width and height. Opening one never
    /// moves anything; only dragging does.
    private(set) var places: [String: CGPoint]
    /// Workspaces that need you, including ones not visited since launch.
    private var fresh: [String: Int] = [:]
    /// Tasks in progress in each workspace, read with the new counts.
    private var running: [String: Int] = [:]
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
    /// Group covers from any workspace, for the bar and History, kept until their file changes.
    @ObservationIgnored private var groupCovers: [String: (stamp: Date?, image: NSImage?)] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    /// The library file this controller opens. Tests pass their own.
    @ObservationIgnored let libraryURL: URL
    /// What came in through the bar, across every workspace.
    let feed = FeedModel()

    init(libraryURL: URL = LibraryHome.databaseURL, demo: Bool = false, load: Bool = true, defaults: UserDefaults = .standard) {
        self.libraryURL = libraryURL
        self.demo = demo
        self.defaults = defaults
        codex = CodexConnection(demo: demo)
        pinned = defaults.stringArray(forKey: "pinnedWorkspaces") ?? []
        order = defaults.stringArray(forKey: "workspaceOrder") ?? []
        recent = defaults.stringArray(forKey: "recentWorkspaces") ?? []
        places = (defaults.dictionary(forKey: "workspacePlaces") as? [String: [Double]] ?? [:])
            .compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        do {
            if demo, load { install(try AppModel(demo: true)) }
            else if load, FileManager.default.fileExists(atPath: libraryURL.path) { try openLibrary() }
        } catch { startupError = error.localizedDescription }
        feed.workspaces = self
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
    }

    func reload() {
        guard let library else { return }
        do {
            workspaces = try library.workspaces()
            fresh = try library.newCounts()
            running = try library.runningCounts()
        } catch { self.error = error.localizedDescription }
        settlePlaces(); loadCovers(); paintMissingCovers()
    }

    /// Tasks that came back finished since the user last opened them.
    func newCount(for workspace: Workspace) -> Int {
        // Background models refresh lazily, so only the one on screen is fresher than the library.
        workspace.id == current?.id ? model?.newCount ?? 0 : fresh[workspace.id] ?? 0
    }

    /// Tasks in progress: running, or handed to an agent that has not picked them up yet.
    func runningCount(for workspace: Workspace) -> Int {
        workspace.id == current?.id ? model?.count(.processing) ?? 0 : running[workspace.id] ?? 0
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

    // MARK: Places on the island

    func place(of workspace: Workspace) -> CGPoint { places[workspace.id] ?? CGPoint(x: 0.5, y: 0.5) }

    /// Kept on the island. The island itself keeps every planet whole inside it, and makes room for the open one.
    func setPlace(_ workspace: Workspace, to point: CGPoint) {
        places[workspace.id] = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        savePlaces()
    }

    /// Puts every workspace back into the zigzag, in the order of the list, for when the island has got crowded.
    func arrangePlaces() {
        places = [:]
        settlePlaces()
    }

    /// The first workspaces fall into a gentle zigzag down the island, in the order of the list.
    private static let slots = [CGPoint(x: 0.32, y: 0.13), CGPoint(x: 0.7, y: 0.29), CGPoint(x: 0.31, y: 0.45),
                                CGPoint(x: 0.69, y: 0.61), CGPoint(x: 0.33, y: 0.77), CGPoint(x: 0.7, y: 0.91)]

    /// A workspace gets its place once, the first time it is seen, and keeps it; a new one never shifts the others.
    private func settlePlaces() {
        let ids = Set(workspaces.map(\.id))
        var changed = places.keys.contains { !ids.contains($0) }
        places = places.filter { ids.contains($0.key) }
        for workspace in ordered where places[workspace.id] == nil {
            places[workspace.id] = freeSpot()
            changed = true
        }
        if changed { savePlaces() }
    }

    /// The next free slot of the zigzag, or else the point farthest from every workspace already there.
    /// Distances count height more, since the island is taller than it is wide.
    private func freeSpot() -> CGPoint {
        let gap = { (a: CGPoint, b: CGPoint) in hypot(a.x - b.x, (a.y - b.y) * 1.7) }
        if let slot = Self.slots.first(where: { slot in places.values.allSatisfy { gap(slot, $0) > 0.2 } }) { return slot }
        var best = CGPoint(x: 0.5, y: 0.5), widest = -1.0
        for column in 0...8 {
            for row in 0...12 {
                let point = CGPoint(x: 0.12 + 0.76 * Double(column) / 8, y: 0.08 + 0.84 * Double(row) / 12)
                let nearest = places.values.map { gap(point, $0) }.min() ?? 1
                if nearest > widest { best = point; widest = nearest }
            }
        }
        return best
    }

    /// The demo's sample workspaces never overwrite the places of the real ones.
    private func savePlaces() {
        guard !demo else { return }
        defaults.set(places.mapValues { [$0.x, $0.y] }, forKey: "workspacePlaces")
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

    /// A group's cover from any workspace, or nil when it has none painted.
    func groupCover(_ groupID: String) -> NSImage? {
        guard let library else { return nil }
        let url = library.coverURL(groupId: groupID)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let kept = groupCovers[groupID], kept.stamp == stamp { return kept.image }
        let image = stamp == nil ? nil : NSImage(contentsOf: url)
        groupCovers[groupID] = (stamp, image)
        return image
    }

    /// A workspace's model without bringing it on screen, for work the bar sends there. It is kept and runs as a visited
    /// workspace's does, so the task starts and is watched while you stay where you are.
    func model(for workspaceID: String) -> AppModel? {
        if let kept = models[workspaceID] { return kept }
        guard !demo, let library, workspaces.contains(where: { $0.id == workspaceID }),
              let made = try? AppModel(store: library.scoped(to: workspaceID), codex: codex) else { return nil }
        models[workspaceID] = made
        made.start()
        return made
    }

    /// A new workspace shares the library's Codex connection, so it is ready at once, and starts with an empty memory of its own.
    @discardableResult func create(name: String) -> Bool {
        guard !demo, let library else { return false }
        do {
            let workspace = try library.createWorkspace(name: name)
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
