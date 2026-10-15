import CryptoKit
import Foundation
import GRDB

/// Splits text into chunks of at most `limit` characters, preferring paragraph, line, sentence and word breaks.
/// A port of the recursive splitter Hindsight uses, so the same document produces the same chunks.
public enum MemoryChunker {
    public static let limit = 3_000
    static let separators = ["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""]

    public static func split(_ text: String, limit: Int = limit) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        return recurse(trimmed, separators: separators, limit: limit)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func recurse(_ text: String, separators: [String], limit: Int) -> [String] {
        guard let index = separators.firstIndex(where: { $0.isEmpty || text.contains($0) }) else { return [text] }
        let separator = separators[index], rest = Array(separators.dropFirst(index + 1))
        // The separator stays with the piece that follows it.
        var pieces: [String] = []
        if separator.isEmpty { pieces = text.map(String.init) } else {
            let parts = text.components(separatedBy: separator)
            pieces = parts.enumerated().map { $0.offset == 0 ? $0.element : separator + $0.element }.filter { !$0.isEmpty }
        }
        var chunks: [String] = [], current = ""
        for piece in pieces {
            if piece.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks += rest.isEmpty ? [piece] : recurse(piece, separators: rest, limit: limit)
            } else if current.count + piece.count > limit {
                chunks.append(current); current = piece
            } else {
                current += piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One fact as Luna extracted it, after Hindsight's post-processing.
public struct ExtractedFact: Equatable, Sendable {
    public var text: String
    public var kind: MemoryUnit.Kind
    public var memoryKind: MemoryKind? = nil
    public var occurredStart: Date?
    public var occurredEnd: Date?
    public var entities: [String]
    /// Indices of earlier facts in the same chunk that caused this one.
    public var causedBy: [Int]

    /// Parses an extraction reply. Facts without text are dropped; dates apply to events only.
    public static func parse(_ reply: String, eventDate: Date) throws -> [ExtractedFact] {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        guard let facts = json["facts"].array else { throw StoreError.invalid("Luna returned no facts.") }
        var result: [ExtractedFact] = []
        for (index, fact) in facts.enumerated() {
            func field(_ name: String) -> String? {
                guard let value = fact[name].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty, value.lowercased() != "n/a", value.lowercased() != "null" else { return nil }
                return value
            }
            guard let what = field("what"), what.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let text = [what, field("when").map { "When: \($0)" }, field("who").map { "Involving: \($0)" }, field("why")]
                .compactMap { $0 }.joined(separator: " | ")
            var start: Date?, end: Date?
            if fact["fact_kind"].string == "event" {
                start = MemoryText.parseDate(fact["occurred_start"].string) ?? inferredDate(what + " " + (field("when") ?? ""), eventDate: eventDate)
                end = MemoryText.parseDate(fact["occurred_end"].string) ?? start
            }
            var seen = Set<String>()
            let entities = (fact["entities"].array ?? []).compactMap { $0.string ?? $0["text"].string }
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .filter { !$0.isEmpty && $0.count <= 512 && seen.insert($0.lowercased()).inserted }
            let causes = (fact["causal_relations"].array ?? []).compactMap { $0["target_index"].int }.filter { $0 >= 0 && $0 < index }
            result.append(ExtractedFact(text: text, kind: fact["fact_type"].string == "assistant" ? .experience : .world,
                                        memoryKind: fact["memory_kind"].string.flatMap(MemoryKind.init(rawValue:)),
                                        occurredStart: start, occurredEnd: end, entities: entities, causedBy: Array(causes.prefix(2))))
        }
        return result
    }

    /// Hindsight's fallback for events whose dates Luna left out: relative words from the source date, at midnight.
    static func inferredDate(_ text: String, eventDate: Date) -> Date? {
        let lower = text.lowercased()
        let offsets: [(String, Int)] = [("last night", -1), ("yesterday", -1), ("today", 0), ("this morning", 0), ("this afternoon", 0),
                                        ("this evening", 0), ("tonight", 0), ("tomorrow", 1), ("last week", -7), ("this week", 0),
                                        ("next week", 7), ("last month", -30), ("this month", 0), ("next month", 30)]
        guard let days = offsets.first(where: { lower.contains($0.0) })?.1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MemoryText.utc
        return calendar.startOfDay(for: eventDate.addingTimeInterval(Double(days) * 86_400))
    }
}

extension JSONValue {
    var int: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }
}

/// Matches entity mentions to a memory's known entities, the way Hindsight does:
/// trigram and sequence similarity, number and word compatibility, shared neighbours and recency.
struct MemoryEntityResolver {
    struct Known { var id: String; var name: String; var lastSeen: Date; var trigrams: Set<String> }
    var known: [Known]
    /// Entity ID → names it has appeared with.
    var neighbours: [String: Set<String>]
    /// Lowercased name → number of distinct partners, for weighting shared neighbours.
    var degree: [String: Int]

    init(_ db: Database, spaceID: String) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, name, lastSeen FROM memoryEntities WHERE spaceId = ?", arguments: [spaceID])
        known = rows.map { Known(id: $0["id"], name: $0["name"], lastSeen: $0["lastSeen"], trigrams: Self.trigrams($0["name"])) }
        var neighbours: [String: Set<String>] = [:], degree: [String: Int] = [:]
        let pairs = try Row.fetchAll(db, sql: """
            SELECT p.a, p.b, ea.name AS an, eb.name AS bn FROM memoryEntityPairs p
            JOIN memoryEntities ea ON ea.id = p.a JOIN memoryEntities eb ON eb.id = p.b WHERE ea.spaceId = ?
            """, arguments: [spaceID])
        for pair in pairs {
            neighbours[pair["a"], default: []].insert((pair["bn"] as String).lowercased())
            neighbours[pair["b"], default: []].insert((pair["an"] as String).lowercased())
            degree[(pair["an"] as String).lowercased(), default: 0] += 1
            degree[(pair["bn"] as String).lowercased(), default: 0] += 1
        }
        self.neighbours = neighbours; self.degree = degree
    }

    /// The known entity this mention refers to, or nil for a new one.
    func resolve(_ name: String, nearby: [String], at date: Date) -> String? {
        let lower = name.lowercased()
        if let exact = known.first(where: { $0.name.lowercased() == lower }) { return exact.id }
        let grams = Self.trigrams(name)
        var best: (id: String, score: Double)?
        let candidates = known.map { ($0, Self.jaccard(grams, $0.trigrams)) }.filter { $0.1 >= 0.15 }
            .sorted { $0.1 > $1.1 }.prefix(200)
        for (candidate, similarity) in candidates where similarity >= 0.3 && Self.compatible(name, candidate.name) {
            var score: Double
            if grams == candidate.trigrams { score = 1 } else {
                score = 0.5 * Self.ratio(lower, candidate.name.lowercased())
                let shared = Set(nearby.map { $0.lowercased() }).intersection(neighbours[candidate.id] ?? [])
                if !nearby.isEmpty {
                    score += 0.3 * shared.reduce(0) { $0 + 1 / Double(max(1, degree[$1] ?? 1)).squareRoot() } / Double(nearby.count)
                }
                let gap = abs(date.timeIntervalSince(candidate.lastSeen))
                if gap < 7 * 86_400 { score += 0.2 * max(0, 1 - gap / (7 * 86_400)) }
            }
            if score > (best?.score ?? -1) { best = (candidate.id, score) }
        }
        guard let best, (best.score * 1_000_000).rounded() / 1_000_000 >= 0.6 else { return nil }
        return best.id
    }

    /// Groups new names within one batch that refer to the same thing; returns each name's canonical spelling.
    static func canonicalNames(_ mentions: [String]) -> [String: String] {
        var counts: [String: Int] = [:], spelling: [String: String] = [:]
        for name in mentions { counts[name.lowercased(), default: 0] += 1; spelling[name.lowercased()] = spelling[name.lowercased()] ?? name }
        let names = Array(counts.keys).sorted()
        guard names.count <= 250 else { return Dictionary(uniqueKeysWithValues: names.map { ($0, spelling[$0]!) }) }
        var parent = Dictionary(uniqueKeysWithValues: names.map { ($0, $0) })
        func find(_ x: String) -> String { var x = x; while parent[x]! != x { x = parent[x]! }; return x }
        let grams = Dictionary(uniqueKeysWithValues: names.map { ($0, trigrams($0)) })
        for i in names.indices { for j in names.indices where j > i {
            if jaccard(grams[names[i]]!, grams[names[j]]!) >= 0.5, compatible(names[i], names[j]) { parent[find(names[j])] = find(names[i]) }
        } }
        var clusters: [String: [String]] = [:]
        for name in names { clusters[find(name), default: []].append(name) }
        var canonical: [String: String] = [:]
        for members in clusters.values {
            let pick = members.min { a, b in
                (counts[a]!, -a.count, b) > (counts[b]!, -b.count, a)
            }!
            for member in members { canonical[member] = spelling[pick]! }
        }
        return canonical
    }

    static func trigrams(_ name: String) -> Set<String> {
        var grams = Set<String>()
        for word in name.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let padded = Array("  " + word + " ")
            guard padded.count >= 3 else { continue }
            for i in 0...(padded.count - 3) { grams.insert(String(padded[i..<(i + 3)])) }
        }
        return grams
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Different numbers never match ("Camera 1" vs "Camera 2"); every word of the shorter name must appear in the longer.
    static func compatible(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] { s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init) }
        let wa = words(a), wb = words(b)
        let na = Set(wa.filter { $0.contains(where: \.isNumber) }), nb = Set(wb.filter { $0.contains(where: \.isNumber) })
        if !na.subtracting(nb).isEmpty && !nb.subtracting(na).isEmpty { return false }
        guard wa.count > 1 || wb.count > 1 else { return true }
        let (short, long) = wa.count <= wb.count ? (wa, wb) : (wb, wa)
        return short.allSatisfy { s in long.contains { $0 == s || $0.hasPrefix(s) || s.hasPrefix($0) || ratio(s, $0) >= 0.6 } }
    }

    /// Python's `difflib.SequenceMatcher(None, a, b).ratio()`: 2·matches / total length.
    static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        func matches(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int {
            guard a0 < a1, b0 < b1 else { return 0 }
            var best = (i: a0, j: b0, size: 0)
            var lengths = [Int](repeating: 0, count: b1 - b0 + 1)
            for i in a0..<a1 {
                var next = [Int](repeating: 0, count: b1 - b0 + 1)
                for j in b0..<b1 where x[i] == y[j] {
                    next[j - b0 + 1] = lengths[j - b0] + 1
                    if next[j - b0 + 1] > best.size { best = (i - next[j - b0 + 1] + 1, j - next[j - b0 + 1] + 1, next[j - b0 + 1]) }
                }
                lengths = next
            }
            guard best.size > 0 else { return 0 }
            return best.size + matches(a0, best.i, b0, best.j) + matches(best.i + best.size, a1, best.j + best.size, b1)
        }
        return 2 * Double(matches(0, x.count, 0, y.count)) / Double(x.count + y.count)
    }
}
