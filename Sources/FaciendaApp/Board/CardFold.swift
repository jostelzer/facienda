import SwiftUI
import FaciendaCore

/// What a card's title row needs about its fold: whether it is folded, and what to count while it is.
struct CardFoldState {
    let folded: Bool
    let tasks: [FaciendaTask]
    let planned: Int
}

extension GroupBoard {
    /// A ring around a card's button where a click does nothing. A click anywhere else on a card folds it,
    /// so a near miss on the + or the sources must not.
    struct GraceZone: View {
        static let width: CGFloat = 6
        var body: some View {
            Color.clear.padding(-Self.width).contentShape(Rectangle()).onTapGesture {}.accessibilityHidden(true)
        }
    }

    /// The Plan view's fold arrow, in the card's margin beside its name: under the pointer while the card is open,
    /// and always while it is folded, so a short card says why it is short. The whole title row takes the click.
    struct FoldArrow: View {
        let hover: BoardHover
        let key: String
        let folded: Bool
        var body: some View {
            let shown = folded || hover.card == key
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 16, height: 16)
                .opacity(shown ? 1 : 0)
                .animation(Motion.fade, value: shown)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// What a folded card holds, where its sources were: the blue dot with how many came back, then each state's glyph
    /// and count in the legend's order. The dot rings and the running arc turns, as on the rows, so a folded card
    /// still shows from across the board that work came back or is under way.
    struct FoldTally: View {
        let model: AppModel
        let tasks: [FaciendaTask]
        let planned: Int

        /// How many of each legend state the card holds, its planned lines counted as Planned.
        private var counts: [TaskDot.Kind: Int] {
            var counts = Dictionary(grouping: tasks) { TaskDot.Kind(model: model, task: $0).legend }.mapValues(\.count)
            counts[.notStarted] = planned
            return counts
        }

        var body: some View {
            let counts = counts
            let unread = tasks.filter(model.isUnread).count
            let shown = TaskDot.Kind.legendOrder.filter { counts[$0, default: 0] > 0 }
            let summary = ((unread > 0 ? ["\(unread) new"] : []) + shown.map { "\(counts[$0, default: 0]) \($0.label.lowercased())" }).joined(separator: ", ")
            HStack(spacing: 6) {
                if unread > 0 {
                    HStack(spacing: 3) {
                        UnreadDot(size: 7)
                        Text("\(unread)")
                    }
                }
                ForEach(shown, id: \.self) { kind in
                    HStack(spacing: 2) {
                        TaskDot(kind: kind)
                        Text("\(counts[kind, default: 0])")
                    }
                }
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
            .fixedSize()
            .help(summary.isEmpty ? "Nothing here right now" : summary.prefix(1).uppercased() + summary.dropFirst())
            .accessibilityElement(children: .ignore).accessibilityLabel(summary.isEmpty ? "Nothing here right now" : summary)
        }
    }
}
