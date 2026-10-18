import SwiftUI
import FaciendaCore

/// The workspace's pages: every card side by side, one group's plan, or what the workspace remembers. What came in is
/// the window's, opened from the bar, since it spans every workspace.
enum DashboardMode: String { case board, plan, memory }

/// The page row across the top, and under it the open page with whatever stands beside it, such as a task's panel.
struct DashboardModes<Beside: View>: View {
    @Bindable var model: AppModel
    @AppStorage("dashboardMode") private var mode = DashboardMode.board.rawValue
    /// The group the Plan view shows, remembered per workspace.
    @State private var planGroup: String?
    private var planGroupKey: String { "planGroup:" + model.storageKey }
    private let beside: Beside

    init(model: AppModel, @ViewBuilder beside: () -> Beside) {
        _model = Bindable(model); self.beside = beside()
    }

    var body: some View {
        VStack(spacing: 0) {
            pageRow
            // Beside the page rather than over it, so the page narrows and a task's row stays in view.
            HStack(spacing: 0) {
                ZStack {
                    if mode == DashboardMode.plan.rawValue {
                        PlanBoard(model: model, groupID: $planGroup).transition(.opacity)
                    } else if mode == DashboardMode.memory.rawValue {
                        MemoryPage(model: model).transition(.opacity)
                    } else {
                        GroupBoard(model: model).transition(.opacity)
                    }
                }
                beside
            }.animation(Motion.move, value: model.selection)
        }
        .onAppear {
            planGroup = UserDefaults.standard.string(forKey: planGroupKey)
            // The Feed was a page here once; it lives in the bar now.
            if DashboardMode(rawValue: mode) == nil { mode = DashboardMode.board.rawValue }
        }
        .onChange(of: planGroup) { _, id in UserDefaults.standard.set(id, forKey: planGroupKey) }
        // New groups are made on the board, so asking for one brings the board back.
        .onChange(of: model.newGroupRequested) { _, requested in if requested { mode = DashboardMode.board.rawValue } }
    }

    /// The pages on the left and the open page's filters right of them, on one row, as wide as the cards. The board's +
    /// ends the row, in line with the cards' own +. Where the filters' names no longer fit they keep their glyphs and
    /// counts, and where even those do not fit they wrap beneath the pages.
    private var pageRow: some View {
        ViewThatFits(in: .horizontal) {
            line(compact: false)
            line(compact: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) { DashboardModeSwitch(); Spacer(minLength: 0); newGroup }
                legend(compact: false)
            }
        }
        .padding(.horizontal, IslandFrame.inset).padding(.vertical, IslandFrame.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(compact: Bool) -> some View {
        HStack(spacing: 18) {
            DashboardModeSwitch()
            legend(compact: compact)
            Spacer(minLength: 0)
            newGroup
        }
    }

    /// The group the Plan view shows: the one chosen, else the first.
    private var shownPlanGroup: TaskGroup? { model.groups.first { $0.id == planGroup } ?? model.groups.first }

    /// Explains each glyph and doubles as the filter. Board and Plan each keep their own.
    @ViewBuilder private func legend(compact: Bool) -> some View {
        if mode == DashboardMode.board.rawValue {
            StateLegend(model: model, scope: .board, tasks: model.boardTasks(in: nil) + model.groups.flatMap { model.boardTasks(in: $0.id) },
                        plannedCount: model.groups.reduce(0) { $0 + model.plannedLines(in: $1.id).count }, compact: compact)
        } else if mode == DashboardMode.plan.rawValue, let group = shownPlanGroup {
            let counted = model.planLegend(for: group)
            StateLegend(model: model, scope: .plan, tasks: counted.tasks, plannedCount: counted.planned, compact: compact)
        }
    }

    /// As the island's + adds a workspace, the board's adds a group.
    @ViewBuilder private var newGroup: some View {
        if mode == DashboardMode.board.rawValue {
            PlusButton(help: "New group (⇧⌘G)", label: "New group") { model.newGroupRequested = true }
                // Where the new group's sheet grows out of and, if let go, folds back into.
                .anchorPreference(key: GroupCardKey.self, value: .bounds) { [AppModel.newGroupSheet: $0] }
                .padding(.trailing, GroupBoard.plusInset)
        }
    }
}

/// Board, Plan or Memory, at the start of the page row. The highlight slides from one to the other.
struct DashboardModeSwitch: View {
    @AppStorage("dashboardMode") private var mode = DashboardMode.board.rawValue
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            option(.board, title: "Board", symbol: "square.grid.2x2", help: "Every group side by side")
            option(.plan, title: "Plan", symbol: "list.bullet.indent", help: "Write out what one group should get done")
            option(.memory, title: "Memory", symbol: "book.closed", help: "What this workspace remembers: its rules, sources, notes and what it learned")
        }
        .padding(2)
        .background(Palette.sidebar, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        .fixedSize()
    }

    private func option(_ value: DashboardMode, title: String, symbol: String, help: String) -> some View {
        let on = mode == value.rawValue
        return Button {
            withAnimation(Motion.move) { mode = value.rawValue }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? Palette.ink : Palette.muted)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background {
                if on {
                    Capsule().fill(Palette.card).overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
        .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
    }
}
