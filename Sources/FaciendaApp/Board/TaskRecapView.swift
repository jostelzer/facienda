import SwiftUI
import FaciendaCore

/// A row's exchange, under its name: the user's last words beside a small ring, joined by a hairline to the agent's
/// answer beside the mark of the app it runs in. The answer is in ink while the task waits on the user, as it is theirs.
struct TaskRecapView: View {
    let exchange: RowExchange
    let agent: AgentProvider
    /// The task waits on the user, so what the answer says is still theirs to act on. Otherwise it reads as the rest.
    var asking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let words = exchange.said {
                line(lines: 1) { Circle().strokeBorder(Palette.muted, lineWidth: 1.2).frame(width: 7, height: 7) } text: {
                    Text(words).foregroundStyle(Palette.muted)
                }.help("You")
            }
            if let answer = exchange.answer {
                line(lines: 3) { ProviderMark(provider: agent, size: 11) } text: {
                    Text(answer).foregroundStyle(asking ? Palette.ink : Palette.muted)
                }.help(agent.name)
            } else if let working = exchange.working {
                line(lines: 1) { ProviderMark(provider: agent, size: 11) } text: { Text(working).foregroundStyle(Palette.muted) }.help(agent.name)
            }
        }
        // A hairline from the ring down to the mark, so the two lines read as one exchange.
        .background(alignment: .topLeading) {
            if exchange.said != nil, exchange.answer != nil || exchange.working != nil {
                Rectangle().fill(Palette.muted.opacity(0.55)).frame(width: 1, height: 8.5).offset(x: 5.5, y: 12.5)
            }
        }
        .font(.system(size: 11.5)).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How far the text sits from the row's edge, so a row with no exchange to show can keep the same column.
    static let symbol: CGFloat = 12, space: CGFloat = 7
    static var gutter: CGFloat { symbol + space }

    /// A symbol centred on the first line of its text, every symbol in the same column.
    private func line(lines: Int, @ViewBuilder symbol: () -> some View, text: () -> Text) -> some View {
        HStack(alignment: .top, spacing: Self.space) {
            symbol().frame(width: Self.symbol, height: 15)
            text().lineLimit(lines).multilineTextAlignment(.leading)
        }
    }
}
