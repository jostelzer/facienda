import Foundation
import Testing

/// The age under a row's glyph is one short whole unit, and never runs ahead of the clock.
@Test func messageAgeIsOneShortWholeUnit() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ago = { (seconds: TimeInterval) in AppModel.age(since: now.addingTimeInterval(-seconds), now: now) }
    #expect(ago(-30) == "now" && ago(59) == "now")
    #expect(ago(60) == "1 min" && ago(47 * 60 + 59) == "47 min")
    #expect(ago(3600) == "1 h" && ago(23 * 3600 + 3599) == "23 h")
    #expect(ago(86400) == "1 d" && ago(13 * 86400) == "13 d")
    #expect(ago(14 * 86400) == "2 w" && ago(60 * 86400) == "8 w")
}
