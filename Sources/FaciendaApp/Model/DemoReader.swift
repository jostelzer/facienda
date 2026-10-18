import Foundation
import FaciendaCore

/// The demo's stand-in for the reading model, which the demo never calls. Phrasings about the demo's own tasks get the
/// reading the model gives them, written as the model's reply and read by the same parser; anything else is new work.
/// It exists so the bar's readings can be tried on sample data.
enum DemoReader {
    static func read(_ text: String, candidates: [BarReader.Candidate], notes: [MemoryFact], places: [BarPlace] = [], here: String? = nil,
                     now: Date = Date()) -> BarReader.Reading? {
        let lower = text.lowercased()
        func task(_ name: String) -> Int? { candidates.firstIndex { $0.task.title.lowercased().contains(name) }.map { $0 + 1 } }
        func says(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        var reply: [String: JSONValue] = ["kind": .string("new")]
        if says("oak", "go with"), let office = task("quieter home office") {
            reply = ["kind": .string("decide"), "pick": .number(Double(office)), "message": .string("Go with the oak desk")]
        } else if says("one more option", "keep looking"), let office = task("quieter home office") {
            reply = ["kind": .string("decide"), "pick": .number(Double(office)), "message": .string("Explore one more option")]
        } else if says("reading list"), says("done", "finished", "erledigt"), let list = task("reading list") {
            reply = ["kind": .string("done"), "pick": .number(Double(list))]
        } else if says("move it", "park it", "verschieb"), let call = task("call home"), let list = task("reading list") {
            reply = ["kind": .string("unclear"), "options": .array([.number(Double(call)), .number(Double(list))]), "then": .string("park"),
                     "until": .string(stamp(next(.friday, from: now)))]
        } else if says("release"), says("park", "monday"), let release = task("autumn release") {
            reply = ["kind": .string("park"), "pick": .number(Double(release)), "until": .string(stamp(next(.monday, from: now)))]
        } else if says("lighting", "supplier"), !lower.hasSuffix("?"), let lighting = task("lighting proposal") {
            let message = text.split(separator: ":", maxSplits: 1).last.map(String.init) ?? text
            reply = ["kind": .string("reply"), "pick": .number(Double(lighting)), "message": .string(message.trimmingCharacters(in: .whitespaces))]
        } else if lower.hasSuffix("?"), says("quiet", "coast", "ericeira", "comporta"), let coast = task("weekend on the coast") {
            reply = ["kind": .string("question"), "answer": .string("Ericeira is quieter mid-week, and both places have parking. Comporta is a longer ride from the station."),
                     "sources": .array([.string("T\(coast)")])]
        } else if lower.hasSuffix("?"), says("desk"), let office = task("quieter home office") {
            reply = ["kind": .string("question"), "answer": .string("The oak desk: it fits the room, has cable management and leaves space by the window. Nothing is ordered yet."),
                     "sources": .array([.string("T\(office)")])]
        }
        if reply["kind"] == .string("new") { reply.merge(place(text, places: places, here: here)) { kept, _ in kept } }
        for (key, empty) in [("pick", JSONValue.null), ("options", .array([])), ("message", .string("")), ("until", .string("")),
                             ("then", .string("none")), ("answer", .string("")), ("sources", .array([])),
                             ("place", .null), ("sure", .bool(true)), ("alt", .null)] where reply[key] == nil {
            reply[key] = empty
        }
        return BarReader.read(JSONValue.object(reply).json, candidates: candidates, notes: notes, places: places, here: here, now: now)
    }

    /// The place whose workspace, group and work share the most words with the text; sure when one clearly leads, and
    /// here without a group, unsure, when none shares any.
    private static func place(_ text: String, places: [BarPlace], here: String?) -> [String: JSONValue] {
        guard places.count > 1 else { return [:] }
        let words = Set(TaskLookup.terms(text))
        let scores = places.enumerated().map { index, place in
            (index + 1, words.intersection(TaskLookup.terms(([place.workspaceName, place.groupName ?? ""] + place.examples).joined(separator: " "))).count)
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 > 0 else {
            let home = places.firstIndex { $0.workspaceID == here && $0.groupID == nil }.map { Double($0 + 1) }
            return ["place": home.map(JSONValue.number) ?? .null, "sure": .bool(false)]
        }
        // A tie is not sure, and offers the other place.
        let tie = scores.dropFirst().first.flatMap { $0.1 == best.1 ? $0 : nil }
        return ["place": .number(Double(best.0)), "sure": .bool(tie == nil), "alt": tie.map { .number(Double($0.0)) } ?? .null]
    }

    private enum Weekday: Int { case monday = 2, friday = 6 }

    /// The coming weekday at 09:00, never today.
    private static func next(_ day: Weekday, from now: Date) -> Date {
        let calendar = Calendar.current
        let morning = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: day.rawValue), matchingPolicy: .nextTime) ?? now
        return calendar.isDate(morning, inSameDayAs: now) ? calendar.date(byAdding: .day, value: 7, to: morning) ?? morning : morning
    }

    private static func stamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter(); format.timeZone = .current
        return format.string(from: date)
    }
}
