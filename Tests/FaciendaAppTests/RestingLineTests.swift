import Foundation
import Testing

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}
private let locale = Locale(identifier: "en_GB")
/// Sunday 18 October 2026, 15:00 UTC.
private let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15))!
private func line(_ date: Date?) -> String { RestingLine.text(since: date, now: now, calendar: calendar, locale: locale) }
private func day(_ month: Int, _ day: Int, year: Int = 2026, hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 20))!
}

@Test func aGroupThatNeverHadATaskSimplyRests() {
    #expect(line(nil) == "Resting")
}

@Test func earlierTodayGivesTheTime() {
    #expect(line(day(10, 18)) == "Resting since 09:20")
}

@Test func thenYesterdayThenTheWeekday() {
    // Just before midnight is still yesterday, however few hours ago.
    #expect(line(day(10, 17, hour: 23)) == "Resting since yesterday")
    #expect(line(day(10, 13)) == "Resting since Tuesday")
    #expect(line(day(10, 12)) == "Resting since Monday")
}

@Test func aWeekOrMoreGivesTheDateAndAnotherYearItsMonth() {
    #expect(line(day(10, 11)) == "Resting since 11 October")
    #expect(line(day(1, 3)) == "Resting since 3 January")
    #expect(line(day(12, 30, year: 2025)) == "Resting since December 2025")
}
