import SwiftUI
import FaciendaCore

/// The shared filters: New, a divider, then Planned and the task states with their counts.
/// Both views read the same settings, so a filter set in one holds in the other.
struct StateLegend: View {
    @Bindable var model: AppModel
    /// The tasks the counts are taken from.
    let tasks: [FaciendaTask]
    let plannedCount: Int
    @AppStorage("dashboardHiddenStates") private var hiddenStates = GroupBoard.defaultHiddenStates
    @AppStorage("dashboardOnlyNew") private var onlyNew = false

    var body: some View {
        let counts = Dictionary(grouping: tasks) { TaskDot.Kind(model: model, task: $0).legend }.mapValues(\.count)
        let unread = tasks.filter(model.isUnread).count
        let hidden = StateLegend.hidden(hiddenStates)
        // Chips keep their one line and move to the next row when the board is narrow, as beside a task's panel.
        return WrapLayout(spacing: 6) {
            // New cuts across the states, so it sits apart and narrows instead of hiding.
            Button { onlyNew.toggle() } label: {
                HStack(spacing: 5) {
                    Text("New").font(.system(size: 11, weight: .semibold)).foregroundStyle(onlyNew ? Palette.green : Palette.ink)
                    if unread > 0 { Text("\(unread)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted) }
                }.padding(.horizontal, 10).padding(.vertical, 3)
                    .background(onlyNew ? Palette.green.opacity(0.14) : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(onlyNew ? Palette.green.opacity(0.5) : Palette.line, lineWidth: 1))
                    .contentShape(Capsule())
            }.buttonStyle(.plain)
                .help(onlyNew ? "Show all tasks" : "Show only new tasks")
                .accessibilityLabel("Only new").accessibilityValue(onlyNew ? "on" : "off")
            Rectangle().fill(Palette.line).frame(width: 1, height: 14).frame(width: 9, height: 20)
            ForEach(TaskDot.Kind.legendOrder, id: \.self) { kind in
                stateChip(kind, count: kind == .notStarted ? plannedCount : counts[kind] ?? 0, hidden: hidden)
            }
        }
    }

    private func stateChip(_ kind: TaskDot.Kind, count: Int, hidden: Set<String>) -> some View {
        let on = !hidden.contains(kind.rawValue)
        return Button { toggle(kind) } label: {
            HStack(spacing: 5) {
                TaskDot(kind: kind, animated: false)
                Text(kind.label).font(.system(size: 11, weight: .medium))
                if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted) }
            }.padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 3)
                .background(on ? Palette.card : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                .opacity(on ? 1 : 0.45).contentShape(Capsule())
        }.buttonStyle(.plain)
            .help(on ? "Hide \(kind.label.lowercased()) tasks" : "Show \(kind.label.lowercased()) tasks")
            .accessibilityLabel(kind.label).accessibilityValue(on ? "shown" : "hidden")
    }

    private func toggle(_ kind: TaskDot.Kind) {
        var set = StateLegend.hidden(hiddenStates)
        if !set.insert(kind.rawValue).inserted { set.remove(kind.rawValue) }
        hiddenStates = set.sorted().joined(separator: ",")
    }

    static func hidden(_ stored: String) -> Set<String> { Set(stored.split(separator: ",").map(String.init)) }

    /// Only the chips a task list stands for, such as Done for Go to Done.
    static func show(_ list: Destination) {
        let kinds = TaskDot.Kind.legend(for: list)
        guard !kinds.isEmpty else { return }
        store(Set(TaskDot.Kind.legendOrder.filter { !kinds.contains($0) }.map(\.rawValue)))
        UserDefaults.standard.set(false, forKey: "dashboardOnlyNew")
    }

    /// Turns on the chip of a task opened in its panel, so its row is on the board beside it.
    @MainActor static func reveal(_ task: FaciendaTask, in model: AppModel) {
        var set = hidden(UserDefaults.standard.string(forKey: "dashboardHiddenStates") ?? GroupBoard.defaultHiddenStates)
        if set.remove(TaskDot.Kind(model: model, task: task).legend.rawValue) != nil { store(set) }
        if !model.isUnread(task) { UserDefaults.standard.set(false, forKey: "dashboardOnlyNew") }
    }

    private static func store(_ hidden: Set<String>) {
        UserDefaults.standard.set(hidden.sorted().joined(separator: ","), forKey: "dashboardHiddenStates")
    }
}
