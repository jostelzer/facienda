import Foundation
import FaciendaCore

/// What came in through the bar, across every workspace: the bar's Incoming pill shows what is at work or came back, and
/// Incoming opens over the island and the board to show all of it, newest first. It belongs to the window, as
/// the bar does.
@MainActor @Observable final class FeedModel {
    @ObservationIgnored weak var workspaces: WorkspaceController?
    private(set) var arrivals: [FeedArrival] = []
    /// The Feed is open in place of the island and the board.
    private(set) var isOpen = false
    /// The place the Feed lists: everywhere, a workspace's ID, or `here` for what settled without a task.
    var place: String?
    static let here = "here"
    static let everywhere = "everywhere"
    @ObservationIgnored private var polling: Task<Void, Never>?

    /// Reads the library every couple of seconds while the window is up: requests land from the bar, and the tasks
    /// they became change state on their own.
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func load() {
        guard let library = workspaces?.library else { return }
        let fresh = (try? library.feed()) ?? []
        if fresh != arrivals { arrivals = fresh }
    }

    func toggle() { isOpen ? close() : open() }

    func open(place chosen: String? = nil) {
        load()
        place = chosen ?? place ?? defaultPlace
        isOpen = true
    }

    func close() { isOpen = false }

    /// Requests that left the bar and are still being placed or made into tasks.
    var placing = 0
    /// Something sent from the bar is at work: being placed, just made and waiting for its agent, or running.
    var working: Bool {
        let fresh = Date().addingTimeInterval(-5 * 60)
        return placing > 0 || arrivals.contains { arrival in
            guard let task = arrival.task else { return false }
            return task.state == .running || (task.state == .inbox && arrival.entry.at > fresh)
        }
    }
    /// Something sent from the bar came back and you have not looked at it yet.
    var cameBack: Bool { arrivals.contains(where: \.isNew) }

    /// Where an arrival belongs in the Feed: the workspace of the task it became, or here when it needed no task.
    func place(of arrival: FeedArrival) -> String { arrival.task == nil ? Self.here : (arrival.workspaceId ?? Self.here) }
    func arrivals(in place: String) -> [FeedArrival] { place == Self.everywhere ? arrivals : arrivals.filter { self.place(of: $0) == place } }
    /// The Feed opens on everything, newest first; each row shows where it went.
    var defaultPlace: String { Self.everywhere }

    /// Shows what an arrival became where it lives: its workspace comes forward and its task opens on the board, or in
    /// its panel when it is finished. Looking never reopens or moves a task.
    func show(_ arrival: FeedArrival) {
        guard let task = arrival.task, let workspaces else { return }
        close()
        if let home = workspaces.workspaces.first(where: { $0.id == task.workspaceId }), home.id != workspaces.current?.id {
            guard workspaces.open(home) else { return }
        }
        guard let model = workspaces.model else { return }
        UserDefaults.standard.set("board", forKey: "dashboardMode")
        model.search = ""; model.destination = .dashboard
        if task.state.isOpen { model.boardOpenRequest = task.id } else { model.showTask(task) }
    }
}
