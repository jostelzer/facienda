import SwiftUI
import FaciendaBridge

/// One quiet line per plan limit, named once per agent, with the window (5h, wk) before its bar so every bar starts at
/// the same place. The names start on the gear's edge, so the footer has one left edge. Hovering names the plan and when the limit starts over.
struct UsageMeters: View {
    let usage: [PlanUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(usage, id: \.agent) { plan in
                ForEach(Array(plan.windows.enumerated()), id: \.offset) { index, window in
                    UsageMeter(agent: index == 0 ? plan.agent : "", plan: plan, window: window)
                }
            }
        }
    }

    private struct UsageMeter: View {
        let agent: String
        let plan: PlanUsage
        let window: PlanUsage.Window
        @State private var hovering = false

        /// Grey until it matters: amber under a fifth left, red once this window is what blocks the agent.
        private var warning: Color? {
            let blocking = plan.limitReached && window.leftPercent == plan.windows.map(\.leftPercent).min()
            if window.leftPercent == 0 || blocking { return Palette.accent }
            return window.leftPercent < 20 ? Palette.amber : nil
        }
        private var resets: String? {
            guard let date = window.resetsAt else { return nil }
            let time = date.formatted(date: .omitted, time: .shortened)
            if Calendar.current.isDateInToday(date) { return "today " + time }
            if Calendar.current.isDateInTomorrow(date) { return "tomorrow " + time }
            if date.timeIntervalSinceNow < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        private var detail: String { [window.name, resets.map { "resets " + $0 }].compactMap { $0 }.joined(separator: " · ") }

        var body: some View {
            HStack(spacing: 8) {
                Text(agent).frame(width: 42, alignment: .leading)
                Text(window.shortName).frame(width: 20, alignment: .leading)
                Capsule().fill(Palette.line).frame(height: 3).overlay(alignment: .leading) {
                    GeometryReader { Capsule().fill(warning ?? Palette.muted).frame(width: $0.size.width * CGFloat(window.leftPercent) / 100) }
                }
                Text("\(window.leftPercent)%").frame(width: 30, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit().lineLimit(1)
            .foregroundStyle(warning ?? Palette.muted)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // A popover rather than .help, which waits about a second before showing.
            .popover(isPresented: $hovering, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.plan ?? plan.agent).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(plan.agent) \(window.name.lowercased()), \(window.leftPercent) percent left")
            .accessibilityHint((plan.plan.map { $0 + ", " } ?? "") + detail)
        }
    }
}
