import Foundation
import FaciendaCore

/// One cancellable lookup supplies both the results and the board, without reading the database on the UI thread.
@MainActor final class OmnibarSearch {
    struct Results: Sendable {
        let hits: [TaskHit]
        let places: [String: BarPlace]
        let boardMatches: Set<String>
        let matchesHere: Bool
        let duplicate: FaciendaTask?
    }

    private var revision = 0
    private var work: Task<Results, Error>?

    func cancel() {
        revision += 1
        work?.cancel(); work = nil
    }

    func find(_ text: String, in store: FaciendaStore, extraTaskIDs: [String] = [], debounce: Bool = true) async -> Results? {
        cancel()
        let request = revision, workspace = store.workspaceID ?? ""
        do {
            // Coalesce a burst of keys while leaving the previous rows in place.
            if debounce { try await Task.sleep(for: .milliseconds(70)) }
            try Task.checkCancellation()
            guard request == revision else { return nil }
            let work = Task.detached(priority: .userInitiated) {
                let all = try store.library.lookUpTasks(text, order: .recent(preferredWorkspaceID: workspace))
                try Task.checkCancellation()
                let hits = Array(all.prefix(8))
                let here = all.filter { $0.task.workspaceId == workspace || $0.task.workspaceId == nil }
                let duplicate = BarReading.sameTask(as: text, among: all.map(\.task))
                let places = try store.library.taskPlaces(ofTasks: hits.map(\.task.id) + extraTaskIDs + (duplicate.map { [$0.id] } ?? []))
                return Results(hits: hits, places: places, boardMatches: Set(here.filter(\.complete).map(\.task.id)), matchesHere: !here.isEmpty,
                               duplicate: duplicate)
            }
            self.work = work
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard request == revision else { return nil }
            self.work = nil
            return result
        } catch {
            if request == revision { work = nil }
            return nil
        }
    }
}
