import Foundation

/// What a resting group's band says: since when its tasks have been still.
enum RestingLine {
    /// Today it gives the time, then yesterday, the weekday through the past week, the day and month this year, and the
    /// month and year before that. A group that never had a task simply rests.
    static func text(since date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "Resting" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let when: String
        switch days {
        case ...0: when = date.formatted(style.hour().minute())
        case 1: when = "yesterday"
        case 2...6: when = date.formatted(style.weekday(.wide))
        default:
            style = calendar.isDate(date, equalTo: now, toGranularity: .year) ? style.day().month(.wide) : style.month(.wide).year()
            when = date.formatted(style)
        }
        return "Resting since " + when
    }
}
