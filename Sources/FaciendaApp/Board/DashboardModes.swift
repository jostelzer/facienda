import SwiftUI

/// The dashboard's two views of the same groups: every card side by side, or one group's plan.
enum DashboardMode: String { case board, plan }

struct DashboardModes: View {
    @Bindable var model: AppModel
    @AppStorage("dashboardMode") private var mode = DashboardMode.board.rawValue
    /// The group the Plan view shows, remembered per workspace.
    @State private var planGroup: String?
    private var planGroupKey: String { "planGroup:" + model.storageKey }

    var body: some View {
        ZStack {
            if mode == DashboardMode.plan.rawValue {
                PlanBoard(model: model, groupID: $planGroup).transition(.opacity)
            } else {
                GroupBoard(model: model).transition(.opacity)
            }
        }
        .onAppear { planGroup = UserDefaults.standard.string(forKey: planGroupKey) }
        .onChange(of: planGroup) { _, id in UserDefaults.standard.set(id, forKey: planGroupKey) }
        // New groups are made on the board, so asking for one brings the board back.
        .onChange(of: model.newGroupRequested) { _, requested in if requested { mode = DashboardMode.board.rawValue } }
    }
}

/// Board or Plan, in the top bar beside the logo. The highlight slides from one to the other.
struct DashboardModeSwitch: View {
    @AppStorage("dashboardMode") private var mode = DashboardMode.board.rawValue
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            option(.board, title: "Board", symbol: "square.grid.2x2", help: "Every group side by side")
            option(.plan, title: "Plan", symbol: "list.bullet.indent", help: "Write out what one group should get done")
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
