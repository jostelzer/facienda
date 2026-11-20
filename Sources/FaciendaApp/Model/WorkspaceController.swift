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
    /// Workspaces put away with everything in them, latest first, for Manage Workspaces to restore.
    var archived: [Workspace] = []
    var startupError: String?
    var error: String?
    var sheet: WorkspaceSheet?
    /// Workspaces pinned by earlier versions, the order the user dragged them into, and every
    /// workspace by most recent visit. These are this Mac's view preferences, so they live
    /// outside the library.
    private(set) var pinned: [String]
    private(set) var order: [String]
    private(set) var recent: [String]
    /// Which space of the island's grid each workspace sits in, counted along the rows from the top left, so a wider or
    /// narrower island keeps the order and only wraps it. Opening one never moves anything; only dragging does.
    private(set) var slots: [String: Int]
    /// Where the planets stood before the grid, read once so the first grid keeps their order, top to bottom.
    @ObservationIgnored private var planetPlaces: [String: CGPoint] = [:]
    /// Workspaces that need you, including ones not visited since launch.
    private var fresh: [String: Int] = [:]
    /// Tasks in progress in each workspace, read with the new counts.
    private var running: [String: Int] = [:]
    /// Which workspace's memory reads which. Only the user sets these, on the island.
    private(set) var reads: [MemoryRead] = []
    /// Paints the sidebar pictures through Codex. nil in the demo and tests, so they never reach Codex.
    @ObservationIgnored var coverPainter: (any CoverPainting)?
    /// Painted pictures by workspace ID.
    var coverImages: [String: NSImage] = [:]
    /// Each picture's mean colour, measured once when it loads: the ring round the open tile, and the island's wash.
    var coverColours: [String: NSColor] = [:]
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
    /// Goals, the window's other side: the same work, by what it is for.
    let goals = GoalsModel()

    init(libraryURL: URL = LibraryHome.databaseURL, demo: Bool = false, load: Bool = true, defaults: UserDefaults = .standard) {
        self.libraryURL = libraryURL
        self.demo = demo
        self.defaults = defaults
        codex = CodexConnection(demo: demo)
        pinned = defaults.stringArray(forKey: "pinnedWorkspaces") ?? []
        order = defaults.stringArray(forKey: "workspaceOrder") ?? []
        recent = defaults.stringArray(forKey: "recentWorkspaces") ?? []
        slots = defaults.dictionary(forKey: "workspaceSlots") as? [String: Int] ?? [:]
        if slots.isEmpty {
            planetPlaces = (defaults.dictionary(forKey: "workspacePlaces") as? [String: [Double]] ?? [:])
                .compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
        do {
            if demo, load { install(try AppModel(demo: true)) }
            else if load, FileManager.default.fileExists(atPath: libraryURL.path) { try openLibrary() }
        } catch { startupError = error.localizedDescription }
        feed.workspaces = self
        goals.workspaces = self
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
            archived = try library.archivedWorkspaces()
            fresh = try library.newCounts()
            running = try library.runningCounts()
            reads = try library.memoryReads()
        } catch { self.error = error.localizedDescription }
        settleSlots(); loadCovers(); paintMissingCovers()
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

    // MARK: Memory reads

    /// How one workspace reads another's memory, if it does.
    func read(_ reader: Workspace, _ source: Workspace) -> MemoryRead? {
        reads.first { $0.readerSpaceId == reader.memorySpaceId && $0.sourceSpaceId == source.memorySpaceId }
    }

    /// The workspace that owns a memory.
    func workspace(ofSpace id: String) -> Workspace? { workspaces.first { $0.memorySpaceId == id } }

    /// Starts reading with entries only, or stops when it already reads.
    func toggleRead(_ reader: Workspace, _ source: Workspace) {
        if read(reader, source) == nil { setRead(reader, source, understanding: false) } else { stopReading(reader, source) }
    }

    func setRead(_ reader: Workspace, _ source: Workspace, understanding: Bool) {
        guard !demo, let library, reader.id != source.id else { return }
        do { try library.setMemoryRead(reader: reader.memorySpaceId, source: source.memorySpaceId, understanding: understanding); reads = try library.memoryReads() }
        catch { self.error = error.localizedDescription }
    }

    func stopReading(_ reader: Workspace, _ source: Workspace) {
        guard !demo, let library else { return }
        do { try library.removeMemoryRead(reader: reader.memorySpaceId, source: source.memorySpaceId); reads = try library.memoryReads() }
        catch { self.error = error.localizedDescription }
    }

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

    // MARK: Spaces on the island

    func slot(of workspace: Workspace) -> Int { slots[workspace.id] ?? 0 }

    /// A workspace dropped into a space. When another sits there, the two swap, so nothing else moves.
    func setSlot(_ workspace: Workspace, to slot: Int) {
        guard slot >= 0, let from = slots[workspace.id], from != slot else { return }
        if let other = slots.first(where: { $0.value == slot })?.key { slots[other] = from }
        slots[workspace.id] = slot
        saveSlots()
    }

    /// True when a space is left empty before the last workspace.
    var hasGaps: Bool { (slots.values.max() ?? -1) >= slots.count }

    /// Every workspace moves up into the first spaces, in the order they stand in, for when the island has got gappy.
    func closeGaps() {
        let standing = workspaces.enumerated().sorted { (slot(of: $0.element), $0.offset) < (slot(of: $1.element), $1.offset) }
        slots = Dictionary(uniqueKeysWithValues: standing.enumerated().map { ($1.element.id, $0) })
        saveSlots()
    }

    /// A workspace gets its space once, the first time it is seen, and keeps it: the first free one, so a new workspace never
    /// shifts the others, and an archived one leaves its space empty. The first grid keeps the order the planets stood in,
    /// top to bottom.
    private func settleSlots() {
        let ids = Set(workspaces.map(\.id))
        var changed = slots.keys.contains { !ids.contains($0) }
        slots = slots.filter { ids.contains($0.key) }
        let planets = planetPlaces
        let newcomers = ordered.enumerated().filter { slots[$0.element.id] == nil }.sorted { a, b in
            let first = planets[a.element.id].map { ($0.y, $0.x) } ?? (2, 2), second = planets[b.element.id].map { ($0.y, $0.x) } ?? (2, 2)
            return (first.0, first.1, a.offset) < (second.0, second.1, b.offset)
        }
        var taken = Set(slots.values), free = 0
        for (_, workspace) in newcomers {
            while taken.contains(free) { free += 1 }
            slots[workspace.id] = free
            taken.insert(free)
            changed = true
        }
        if !workspaces.isEmpty { planetPlaces = [:] }
        if changed { saveSlots() }
    }

    /// The demo's sample workspaces never overwrite the spaces of the real ones.
    private func saveSlots() {
        guard !demo else { return }
        defaults.set(slots, forKey: "workspaceSlots")
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

    /// Puts a workspace away with its open tasks, whose agents stop. Restore brings it all back.
    @discardableResult func archive(_ workspace: Workspace) async -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.archiveWorkspace(workspace.id)
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

    @discardableResult func restore(_ workspace: Workspace) -> Bool {
        guard !demo, let library else { return false }
        do {
            try library.restoreWorkspace(workspace.id)
            reload()
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    // MARK: Pictures

    private func loadCovers() {
        guard let library else { return }
        for workspace in workspaces where coverStamps[workspace.id] != workspace.coverPaintedAt {
            coverStamps[workspace.id] = workspace.coverPaintedAt
            let image = workspace.coverPaintedAt == nil ? nil : NSImage(contentsOf: library.coverURL(workspaceId: workspace.id))
            coverImages[workspace.id] = image
            coverColours[workspace.id] = image.flatMap(Self.meanColour)
        }
    }

    /// The mean colour of the round part of a picture, the part a planet shows. Read from a 16-point copy, so it costs
    /// next to nothing.
    static func meanColour(of image: NSImage) -> NSColor? {
        let side = 16
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var sum = (r: 0.0, g: 0.0, b: 0.0), count = 0.0
        let middle = Double(side) / 2
        for y in 0..<side {
            for x in 0..<side where hypot(Double(x) + 0.5 - middle, Double(y) + 0.5 - middle) <= middle {
                let at = (y * side + x) * 4
                sum.r += Double(pixels[at]); sum.g += Double(pixels[at + 1]); sum.b += Double(pixels[at + 2]); count += 1
            }
        }
        guard count > 0 else { return nil }
        return NSColor(srgbRed: sum.r / count / 255, green: sum.g / count / 255, blue: sum.b / count / 255, alpha: 1)
    }

    /// A picture's mean colour as the open island's tint: its hue, a little more of its colour, and always the same
    /// lightness, so a dark or muddy picture tints the island as clearly as a bright one. Worked in Oklab, where equal
    /// lightness looks equal; colour the screen cannot show is given up until it can. Other lightnesses give the shades
    /// that must stand off the wash: the open tile's ring and its name's pill.
    nonisolated static func islandTint(of mean: NSColor, lightness: Double = 0.62, boost: Double = 1.6) -> NSColor {
        guard let rgb = mean.usingColorSpace(.sRGB) else { return mean }
        let lab = Oklab(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        let chroma = hypot(lab.a, lab.b), hue = atan2(lab.b, lab.a)
        var reach = chroma * boost
        while true {
            let colour = Oklab(l: lightness, a: reach * cos(hue), b: reach * sin(hue)).rgb
            if [colour.red, colour.green, colour.blue].allSatisfy({ (-0.001...1.001).contains($0) }) || reach < 0.001 {
                return NSColor(srgbRed: min(max(colour.red, 0), 1), green: min(max(colour.green, 0), 1), blue: min(max(colour.blue, 0), 1), alpha: 1)
            }
            reach *= 0.95
        }
    }

    /// Every workspace gets a picture once Codex is ready, one at a time so a new library does not start a crowd of runs.
    /// Renaming later never repaints on its own.
    func paintMissingCovers() {
        let enabled = UserDefaults.standard.object(forKey: "groupCovers") as? Bool ?? true
        guard coverPainter != nil, !demo, enabled, codex.connected, codex.accountReady, paintingCovers.isEmpty else { return }
        if let next = ordered.first(where: { $0.coverPaintedAt == nil && !coverFailures.contains($0.id) }) { paintCover(next, requested: false) }
    }

    /// A workspace is painted from its groups, as a group is from its tasks: one coherent list. Every open task of the
    /// whole workspace on top of them pulled the picture in a dozen directions. A workspace without groups yet gives its open tasks.
    private func coverContents(_ workspace: Workspace, in library: FaciendaStore) -> [String] {
        let scoped = library.scoped(to: workspace.id)
        let groups = ((try? scoped.groups()) ?? []).map(\.name)
        return groups.isEmpty ? ((try? scoped.tasks()) ?? []).filter(\.state.isOpen).map(\.displayName) : groups
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

/// A colour in Oklab, from and back to sRGB, as Björn Ottosson defines it.
struct Oklab {
    var l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    init(red: Double, green: Double, blue: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Back in sRGB, possibly outside 0…1 when the colour is beyond what sRGB holds.
    var rgb: (red: Double, green: Double, blue: Double) {
        let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (Self.gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                Self.gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                Self.gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    private static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func gamma(_ c: Double) -> Double {
        let sign: Double = c < 0 ? -1 : 1, x = abs(c)
        return sign * (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
    }
}
