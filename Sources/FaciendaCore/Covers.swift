import Foundation
import GRDB

/// The pictures on group cards and in the workspace sidebar, with the standing wishes every repaint honours.
extension FaciendaStore {
    /// Covers are plain image files in the library folder, so they travel with it.
    var coversDirectory: URL { url.deletingLastPathComponent().appending(path: "Covers") }

    /// Removes the covers of groups that are gone, kept by deletes that could have been undone.
    /// Run when the app opens the library: undo never reaches back past that.
    public func sweepGroupCovers() {
        guard let groups = try? db.read({ try String.fetchAll($0, sql: "SELECT id FROM taskGroups") }),
              let files = try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path) else { return }
        let kept = Set(groups)
        for file in files where file.hasSuffix(".jpg") && !file.hasPrefix("workspace-") {
            let id = String(file.dropLast(4)).replacingOccurrences(of: ".previous", with: "")
            if !kept.contains(id) { try? FileManager.default.removeItem(at: coversDirectory.appending(path: file)) }
        }
    }

    /// A group's cover on the dashboard.
    public func coverURL(groupId: String) -> URL {
        coversDirectory.appending(path: groupId + ".jpg")
    }

    /// The cover a new one replaced, kept so a change can be undone.
    public func previousCoverURL(groupId: String) -> URL {
        coversDirectory.appending(path: groupId + ".previous.jpg")
    }

    /// Replaces the cover, keeping the old picture for undo. A note is a wish the new cover already honours; it is remembered for later repaints.
    public func saveCover(groupId: String, image: Data, style: String, note: String? = nil) throws {
        guard let group = try db.read({ try TaskGroup.fetchOne($0, key: groupId) }) else { throw StoreError.notFound }
        try Self.replaceCover(coverURL(groupId: groupId), previous: previousCoverURL(groupId: groupId), with: image)
        try write { db in
            try db.execute(sql: "UPDATE taskGroups SET coverStyle = ?, coverPaintedAt = ?, coverNotes = ? WHERE id = ?",
                arguments: [style, Date(), Self.notes(group.coverNoteList, adding: note), groupId])
        }
    }

    /// Swaps the cover back to the picture it replaced, restoring the style and notes that went with it.
    public func restorePreviousCover(groupId: String, style: String?, notes: [String]) throws {
        try Self.swapBackCover(coverURL(groupId: groupId), previous: previousCoverURL(groupId: groupId))
        try write { db in
            guard try TaskGroup.fetchOne(db, key: groupId) != nil else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE taskGroups SET coverStyle = ?, coverPaintedAt = ?, coverNotes = ? WHERE id = ?",
                arguments: [style, Date(), Self.notes(notes, adding: nil), groupId])
        }
    }

    public func setCoverNotes(groupId: String, notes: [String]) throws {
        try write { db in
            guard try TaskGroup.fetchOne(db, key: groupId) != nil else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE taskGroups SET coverNotes = ? WHERE id = ?", arguments: [Self.notes(notes, adding: nil), groupId])
        }
    }

    /// A workspace's sidebar picture sits with the group covers, so it travels with the library.
    public func coverURL(workspaceId: String) -> URL {
        coversDirectory.appending(path: "workspace-" + workspaceId + ".jpg")
    }

    /// The picture a new one replaced, kept so a change can be undone.
    public func previousCoverURL(workspaceId: String) -> URL {
        coversDirectory.appending(path: "workspace-" + workspaceId + ".previous.jpg")
    }

    /// Replaces the picture, keeping the old one for undo. A note is a wish the new picture already honours; it is remembered for later repaints.
    public func saveCover(workspaceId: String, image: Data, style: String, note: String? = nil) throws {
        let notes = try workspace(workspaceId).coverNoteList
        try Self.replaceCover(coverURL(workspaceId: workspaceId), previous: previousCoverURL(workspaceId: workspaceId), with: image)
        try write { db in
            try db.execute(sql: "UPDATE workspaces SET coverStyle = ?, coverPaintedAt = ?, coverNotes = ? WHERE id = ?",
                arguments: [style, Date(), Self.notes(notes, adding: note), workspaceId])
        }
    }

    /// Swaps the picture back to the one it replaced, restoring the style and notes that went with it.
    public func restorePreviousCover(workspaceId: String, style: String?, notes: [String]) throws {
        try Self.swapBackCover(coverURL(workspaceId: workspaceId), previous: previousCoverURL(workspaceId: workspaceId))
        try write { db in
            _ = try Self.workspace(db, workspaceId)
            try db.execute(sql: "UPDATE workspaces SET coverStyle = ?, coverPaintedAt = ?, coverNotes = ? WHERE id = ?",
                arguments: [style, Date(), Self.notes(notes, adding: nil), workspaceId])
        }
    }

    public func setCoverNotes(workspaceId: String, notes: [String]) throws {
        try write { db in
            _ = try Self.workspace(db, workspaceId)
            try db.execute(sql: "UPDATE workspaces SET coverNotes = ? WHERE id = ?", arguments: [Self.notes(notes, adding: nil), workspaceId])
        }
    }

    /// Writes a new picture, moving the one it replaces aside so it can come back.
    static func replaceCover(_ file: URL, previous: URL, with image: Data) throws {
        let files = FileManager.default
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: file.path) { try? files.removeItem(at: previous); try files.moveItem(at: file, to: previous) }
        try image.write(to: file, options: .atomic)
    }

    /// Trades a picture for the one it replaced, so undoing twice brings the newer one back.
    static func swapBackCover(_ file: URL, previous: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: previous.path) else { throw StoreError.notFound }
        let parked = previous.appendingPathExtension("swap")
        try? files.removeItem(at: parked)
        try files.moveItem(at: previous, to: parked)
        if files.fileExists(atPath: file.path) { try files.moveItem(at: file, to: previous) }
        try files.moveItem(at: parked, to: file)
    }

    /// Standing wishes as stored: one per line, nil when there are none.
    static func notes(_ notes: [String], adding note: String?) -> String? {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") ?? ""
        let all = notes + (note.isEmpty ? [] : [note])
        return all.isEmpty ? nil : all.joined(separator: "\n")
    }
}
