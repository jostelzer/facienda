import SwiftUI
import FaciendaCore

/// Board and Plan each keep their own filters, so what one hides stays shown in the other.
/// The board rests with Done and Planned hidden; the plan view shows Planned and hides Done.
enum LegendScope {
    case board, plan

    var hiddenKey: String { self == .board ? "boardHiddenStates" : "planHiddenStates" }
    var onlyNewKey: String { self == .board ? "boardOnlyNew" : "planOnlyNew" }
    var defaultHidden: String {
        switch self {
        case .board: [TaskDot.Kind.done, .notStarted].map(\.rawValue).sorted().joined(separator: ",")
        case .plan: TaskDot.Kind.done.rawValue
        }
    }
    /// The view on screen, which task lists and the task panel adjust.
    static var current: LegendScope { UserDefaults.standard.string(forKey: "dashboardMode") == DashboardMode.plan.rawValue ? .plan : .board }
}

/// The filters of one view: New, a divider, then Planned and the task states with their counts.
struct StateLegend: View {
    @Bindable var model: AppModel
    /// The tasks the counts are taken from.
    let tasks: [FaciendaTask]
    let plannedCount: Int
    @AppStorage private var hiddenStates: String
    @AppStorage private var onlyNew: Bool

    init(model: AppModel, scope: LegendScope, tasks: [FaciendaTask], plannedCount: Int) {
        self.model = model
        self.tasks = tasks
        self.plannedCount = plannedCount
        _hiddenStates = AppStorage(wrappedValue: scope.defaultHidden, scope.hiddenKey)
        _onlyNew = AppStorage(wrappedValue: false, scope.onlyNewKey)
    }

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
    static func show(_ list: Destination, scope: LegendScope = .current) {
        let kinds = TaskDot.Kind.legend(for: list)
        guard !kinds.isEmpty else { return }
        store(Set(TaskDot.Kind.legendOrder.filter { !kinds.contains($0) }.map(\.rawValue)), scope)
        UserDefaults.standard.set(false, forKey: scope.onlyNewKey)
    }

    /// Turns on the chip of a task opened in its panel, so its row is on the board beside it.
    @MainActor static func reveal(_ task: FaciendaTask, in model: AppModel, scope: LegendScope = .current) {
        var set = hidden(UserDefaults.standard.string(forKey: scope.hiddenKey) ?? scope.defaultHidden)
        if set.remove(TaskDot.Kind(model: model, task: task).legend.rawValue) != nil { store(set, scope) }
        if !model.isUnread(task) { UserDefaults.standard.set(false, forKey: scope.onlyNewKey) }
    }

    private static func store(_ hidden: Set<String>, _ scope: LegendScope) {
        UserDefaults.standard.set(hidden.sorted().joined(separator: ","), forKey: scope.hiddenKey)
    }
}
