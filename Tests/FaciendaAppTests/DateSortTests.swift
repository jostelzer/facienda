import Foundation
import Testing
import FaciendaCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

/// Captions go by calendar day, so ten minutes can already be "Yesterday", and a week is the six days before yesterday.
@Test func dayBandsFollowTheCalendar() {
    let now = at(14, 0, 10)
    #expect(DayBand.of(at(14, 0, 1), now: now, calendar: calendar) == .today)
    #expect(DayBand.of(at(13, 23, 50), now: now, calendar: calendar) == .yesterday)
    #expect(DayBand.of(at(12, 9), now: now, calendar: calendar) == .week)
    #expect(DayBand.of(at(8, 9), now: now, calendar: calendar) == .week)
    #expect(DayBand.of(at(7, 23, 59), now: now, calendar: calendar) == .earlier)
    // A clock a little ahead of the chat's own never sends a row into the future.
    #expect(DayBand.of(at(14, 9), now: now, calendar: calendar) == .today)
}

/// Newest first, and two rows that moved at the same moment keep a fixed order, so a redraw never shuffles them.
@Test func dateOrderPutsTheNewestFirst() {
    func task(_ id: String) -> FaciendaTask { FaciendaTask(id: id, title: id) }
    let tasks = ["b", "a", "c", "d"].map(task)
    let moved: [String: Date] = ["a": at(13, 9), "b": at(14, 8), "c": at(13, 9), "d": at(1, 9)]
    #expect(DateOrder.sorted(tasks, movedAt: { moved[$0.id]! }).map(\.id) == ["b", "a", "c", "d"])
    #expect(DateOrder.sorted(tasks.reversed(), movedAt: { moved[$0.id]! }).map(\.id) == ["b", "a", "c", "d"])
}

/// Each workspace keeps its own cards by date, Unsorted's empty key included, and a board with none leaves nothing behind.
@Test func dateSortedCardsAreKeptPerWorkspace() throws {
    let name = "FaciendaDateSortedCards-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(name).plist"))
    }

    DateSortedCards.save(["group-a", ""], for: "library#home", in: defaults)
    DateSortedCards.save(["group-b"], for: "library#work", in: defaults)
    #expect(DateSortedCards.load("library#home", from: defaults) == ["group-a", ""])
    #expect(DateSortedCards.load("library#work", from: defaults) == ["group-b"])
    #expect(DateSortedCards.load("library#other", from: defaults).isEmpty)
    // Folded cards live beside them, under a key of their own.
    FoldedCards.save(["group-c"], for: "library#home", in: defaults)
    #expect(DateSortedCards.load("library#home", from: defaults) == ["group-a", ""])

    DateSortedCards.save([], for: "library#home", in: defaults)
    #expect(defaults.object(forKey: DateSortedCards.key("library#home")) == nil)
    #expect(DateSortedCards.load("library#work", from: defaults) == ["group-b"])
}
