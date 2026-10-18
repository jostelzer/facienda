import SwiftUI
import FaciendaCore

/// History: what came in through the bar, across every workspace, in place of the island and the board. Nothing stands
/// above it but a slim row of workspace chips and a close button; below, one list, newest first, using the whole room.
/// Each row leads with the group's cover and the workspace's planet, as the bar draws found tasks, then the request in
/// its own words, where it went and what it became, with the task's live glyph. Esc or the ✕ brings the board back.
struct FeedView: View {
    @Bindable var feed: FeedModel
    let workspaces: WorkspaceController
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { list }
                    .padding(.bottom, 16)
            }
        }
        .background(Palette.paper)
        .onExitCommand { feed.close() }
    }

    // MARK: Filters

    /// All, then each workspace something went to, then Here for what needed no task, each with its count; the ✕ at the end
    /// closes History.
    private var filters: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(id: FeedModel.everywhere, name: "All", image: nil, symbol: "square.stack.3d.up")
                    ForEach(workspaces.ordered.filter { !feed.arrivals(in: $0.id).isEmpty }) { workspace in
                        chip(id: workspace.id, name: workspace.name, image: workspaces.coverImages[workspace.id], symbol: nil)
                    }
                    if !feed.arrivals(in: FeedModel.here).isEmpty { chip(id: FeedModel.here, name: "Here", image: nil, symbol: "tray") }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 8)
            Button { feed.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26).background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain).help("Back to the board (esc)").accessibilityLabel("Close History")
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
    }

    private func chip(id: String, name: String, image: NSImage?, symbol: String?) -> some View {
        let chosen = (feed.place ?? feed.defaultPlace) == id, count = feed.arrivals(in: id).count
        return Button { withAnimation(Motion.fade) { feed.place = id } } label: {
            HStack(spacing: 6) {
                ZStack {
                    Palette.line
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.ink) }
                    else { Text(name.prefix(1).uppercased()).font(.system(size: 10, design: .serif)).foregroundStyle(Palette.muted) }
                }
                .frame(width: 18, height: 18).clipShape(Circle())
                Text(name).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(.system(size: 12)).monospacedDigit().opacity(0.7)
            }
            .foregroundStyle(chosen ? Palette.ink : Palette.muted)
            .padding(.leading, 4).padding(.trailing, 10).frame(height: 26)
            .background(chosen ? Palette.card : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(chosen ? Palette.line : .clear, lineWidth: 1))
            .shadow(color: .black.opacity(chosen ? 0.08 : 0), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(count)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: List

    /// The chosen place's requests, newest first, across the whole room.
    @ViewBuilder private var list: some View {
        let shown = feed.arrivals(in: feed.place ?? feed.defaultPlace)
        if shown.isEmpty {
            Text(feed.arrivals.isEmpty ? "Nothing has come in yet. What you type in the bar shows here, with what it became."
                                       : "Nothing came in for this workspace yet.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 18).padding(.vertical, 20)
        } else {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, arrival in
                if index > 0 { Divider().overlay(Palette.line) }
                row(arrival)
            }
        }
    }

    /// Where a request went, as the bar names a found task's place.
    private func place(of arrival: FeedArrival) -> BarPlace? {
        guard let id = arrival.workspaceId, let workspace = workspaces.workspaces.first(where: { $0.id == id }) else { return nil }
        return BarPlace(workspaceID: id, workspaceName: workspace.name, groupID: arrival.groupId, groupName: arrival.groupName)
    }

    private func row(_ arrival: FeedArrival) -> some View {
        let entry = arrival.entry, spot = place(of: arrival)
        let elsewhere = arrival.workspaceId != nil && arrival.workspaceId != workspaces.current?.id
        let target = arrival.task.map(\.displayName)
        // The reading names its task when it acted on one; a new task only says "New task", so its name follows.
        let landed = target.flatMap { entry.reading.contains($0) || $0 == entry.text ? nil : $0 }
        return HStack(alignment: .center, spacing: 14) {
            PlaceThumb(place: spot, workspaces: workspaces, elsewhere: elsewhere, size: CGSize(width: 96, height: 60))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).font(.system(size: 14, weight: arrival.isNew ? .semibold : .regular))
                    .fullTextOnHover(entry.text, lines: 2)
                HStack(spacing: 0) {
                    if let spot {
                        Text(spot.label).foregroundStyle(elsewhere ? Palette.blue : Palette.muted)
                        Text(" · ").foregroundStyle(Palette.muted)
                    }
                    Text(entry.reading).foregroundStyle(Palette.ink.opacity(0.8))
                    if let landed { Text(" · " + landed).foregroundStyle(Palette.muted) }
                    Text(" · " + Self.decided(entry.decidedBy)).foregroundStyle(Palette.muted)
                }
                .font(.system(size: 11.5)).lineLimit(1)
            }
            Spacer(minLength: 12)
            FeedGlyph(arrival: arrival, workspaces: workspaces)
            Text(Self.when(entry.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background {
            if arrival.isNew { Palette.blue.opacity(0.08) }
            else if hovered == arrival.id && arrival.task != nil { Palette.selected.opacity(0.5) }
        }
        .overlay(alignment: .leading) {
            if arrival.isNew { Circle().fill(Palette.blue).frame(width: 6, height: 6).padding(.leading, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { feed.show(arrival) }
        .onHover { inside in if inside { hovered = arrival.id } else if hovered == arrival.id { hovered = nil } }
        .help(arrival.task == nil ? entry.reading : "Show it on the board")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(arrival.task == nil ? [] : .isButton)
        .accessibilityAction { feed.show(arrival) }
    }

    /// Who settled what a request meant, as the row says it.
    static func decided(_ decider: IntakeEntry.Decider) -> String {
        switch decider {
        case .rule: "as typed"
        case .model: "read by the model"
        case .you: "your choice"
        }
    }

    /// The time today, the weekday this week, the date before that.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The glyph of what a request became: the board's own for its task, live, or a quiet sign for a request that needed no
/// task, a note remembered or a question answered.
struct FeedGlyph: View {
    let arrival: FeedArrival
    let workspaces: WorkspaceController

    var body: some View {
        Group {
            if arrival.task != nil {
                if let kind = Self.kind(of: arrival, workspaces: workspaces) {
                    TaskDot(kind: kind)
                } else {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted).frame(width: 16, height: 16)
                }
            } else {
                Image(systemName: arrival.entry.reading.hasPrefix("Remember") ? "book.closed" : "text.bubble")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 16, height: 16)
            }
        }
        .accessibilityHidden(true)
    }

    /// The board's glyph for what an arrival became. The open workspace knows the task's chats and waits; elsewhere its
    /// state says enough. Nothing for a note that needed no task, or a task that was dropped.
    @MainActor static func kind(of arrival: FeedArrival, workspaces: WorkspaceController) -> TaskDot.Kind? {
        guard let task = arrival.task else { return nil }
        if let model = workspaces.model, model.workspaceID == task.workspaceId, let live = model.tasksByID[task.id] {
            return TaskDot.Kind(model: model, task: live)
        }
        return TaskDot.Kind(state: task.state)
    }
}

/// The way into what came in: a pill named History at the bar's end, with the latest request that finished or came
/// back for you in the last day, in blue while you have not looked at it. A click opens what came in, or closes it again.
struct FeedTrail: View {
    @Bindable var feed: FeedModel
    let workspaces: WorkspaceController

    var body: some View {
        let done = feed.latestDone
        Button { withAnimation(Motion.fade) { feed.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                Text("History").font(.system(size: 12, weight: .semibold))
                if let done, let task = done.task {
                    Rectangle().fill(Palette.line).frame(width: 1, height: 14).padding(.horizontal, 2)
                    FeedGlyph(arrival: done, workspaces: workspaces).scaleEffect(0.85)
                    // As wide as the name, up to a point, so the bar keeps its room for typing.
                    Text(task.displayName.count > 34 ? task.displayName.prefix(33) + "…" : task.displayName)
                        .font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(done.isNew ? Palette.blue : Palette.muted)
                    if done.isNew { Circle().fill(Palette.blue).frame(width: 6, height: 6) }
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 28)
            .background(feed.isOpen ? Palette.blue.opacity(0.1) : Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(feed.isOpen ? Palette.blue.opacity(0.5) : Palette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(feed.isOpen ? "Back to the board (esc)" : "History (⇧⌘K): what you asked in the bar and what became of it")
        .accessibilityLabel("History")
        .accessibilityValue(done?.task.map { "Latest finished: \($0.displayName)" } ?? "")
    }
}
