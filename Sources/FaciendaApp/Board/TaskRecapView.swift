import SwiftUI
import FaciendaCore

/// A new row's recap, under its name: the user's last words beside a small ring, joined by a hairline to the agent's answer
/// beside the mark of the app it runs in. What the agent asks of the user ends its answer, in ink.
struct TaskRecapView: View {
    let recap: TaskRecap
    let agent: AgentProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let words = recap.said {
                line(lines: 1) { Circle().strokeBorder(Palette.muted, lineWidth: 1.2).frame(width: 7, height: 7) } text: {
                    Text(words).foregroundStyle(Palette.muted)
                }.help("You")
            }
            line(lines: 3) { ProviderMark(provider: agent, size: 11) } text: { answer }.help(agent.name)
        }
        // A hairline from the ring down to the mark, so the two lines read as one exchange.
        .background(alignment: .topLeading) {
            if recap.said != nil { Rectangle().fill(Palette.muted.opacity(0.55)).frame(width: 1, height: 8.5).offset(x: 5.5, y: 12.5) }
        }
        .font(.system(size: 11.5)).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A symbol centred on the first line of its text, every symbol in the same column.
    private func line(lines: Int, @ViewBuilder symbol: () -> some View, text: () -> Text) -> some View {
        HStack(alignment: .top, spacing: 7) {
            symbol().frame(width: 12, height: 15)
            text().lineLimit(lines).multilineTextAlignment(.leading)
        }
    }

    /// The answer in grey; what it needs from the user in ink.
    private var answer: Text {
        let said = Text(recap.answer).foregroundStyle(Palette.muted)
        guard let ask = recap.ask else { return said }
        return Text("\(said) \(Text(ask).foregroundStyle(Palette.ink))")
    }

    /// When the agent last answered, for the name's line.
    static func time(of recap: TaskRecap) -> String? { (recap.answeredAt ?? recap.saidAt).map(stamp) }

    /// Today's times plainly; earlier ones with their weekday.
    static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
