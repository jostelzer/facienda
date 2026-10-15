import AppKit
import FaciendaCore
import FaciendaBridge

struct CoverSnapshot: Equatable { var style: String?; var notes: [String] }

/// How the app paints group covers. The real painter runs Codex; tests supply their own.
protocol CoverPainting: Sendable {
    func paint(executable: String, name: String, tasks: [String], style: String?, notes: [String]) async throws -> GroupCover
    func edit(executable: String, cover: URL, name: String, tasks: [String], instruction: String, style: String?, notes: [String]) async throws -> GroupCover
}

extension AppModel {
    func loadCovers() {
        for group in groups where coverStamps[group.id] != group.coverPaintedAt {
            coverStamps[group.id] = group.coverPaintedAt
            coverImages[group.id] = group.coverPaintedAt == nil ? nil : NSImage(contentsOf: store.coverURL(groupId: group.id))
        }
    }
    /// A group gets its cover once it holds open work. Renaming or regrouping later never repaints on its own.
    func paintMissingCovers() {
        guard coverPainter != nil, !demo, connected, accountReady, coversEnabled else { return }
        for group in groups where group.coverPaintedAt == nil && !paintingCovers.contains(group.id) && !coverFailures.contains(group.id) {
            if tasks.contains(where: { groupMembers[$0.id] == group.id && $0.state.isOpen }) { paintCover(group, requested: false) }
        }
    }
    private func coverTitles(_ group: TaskGroup) -> [String] {
        tasks.filter { groupMembers[$0.id] == group.id && $0.state != .dropped }.map(\.displayName)
    }
    /// Repainting keeps the group's style and notes unless a new style is asked for.
    func paintCover(_ group: TaskGroup, newStyle: Bool = false, requested: Bool = true) {
        guard let coverPainter else { return }
        let titles = coverTitles(group)
        let executable = executable, style = newStyle ? nil : group.coverStyle, notes = group.coverNoteList
        changeCover(group, requested: requested, note: nil) {
            try await coverPainter.paint(executable: executable, name: group.name, tasks: titles, style: style, notes: notes)
        }
    }
    /// Carries out a wish for the group's picture, a change to it or a new one, and remembers the wish for later repaints.
    func adjustCover(_ group: TaskGroup, instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let coverPainter, !instruction.isEmpty, group.coverPaintedAt != nil else { return }
        let executable = executable, file = store.coverURL(groupId: group.id), style = group.coverStyle, notes = group.coverNoteList, titles = coverTitles(group)
        changeCover(group, requested: true, note: instruction) {
            try await coverPainter.edit(executable: executable, cover: file, name: group.name, tasks: titles, instruction: instruction, style: style, notes: notes)
        }
    }
    private func changeCover(_ group: TaskGroup, requested: Bool, note: String?, _ produce: @escaping @Sendable () async throws -> GroupCover) {
        guard !demo, !paintingCovers.contains(group.id) else { return }
        paintingCovers.insert(group.id); coverFailures.remove(group.id)
        Task {
            defer { paintingCovers.remove(group.id) }
            do {
                let cover = try await produce()
                if group.coverPaintedAt != nil { coverUndo[group.id] = CoverSnapshot(style: group.coverStyle, notes: group.coverNoteList) }
                try store.saveCover(groupId: group.id, image: cover.image, style: cover.style, note: note)
                refresh()
            } catch {
                coverFailures.insert(group.id)
                if requested { self.error = error.localizedDescription }
            }
        }
    }
    func canUndoCover(_ group: TaskGroup) -> Bool {
        coverUndo[group.id] != nil && !paintingCovers.contains(group.id) && FileManager.default.fileExists(atPath: store.previousCoverURL(groupId: group.id).path)
    }
    func undoCover(_ group: TaskGroup) {
        guard let snapshot = coverUndo.removeValue(forKey: group.id) else { return }
        perform { try store.restorePreviousCover(groupId: group.id, style: snapshot.style, notes: snapshot.notes); refresh() }
    }
    func forgetCoverNotes(_ group: TaskGroup) { perform { try store.setCoverNotes(groupId: group.id, notes: []); refresh() } }
}
