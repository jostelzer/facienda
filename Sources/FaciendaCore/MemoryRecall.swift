import Foundation
import GRDB

/// How much to recall and how to rank it.
public struct MemoryRecallOptions: Sendable {
    /// Candidates per arm ("low" in Hindsight).
    public var budget = 100
    public var maxTokens = 1_600
    public var preferObservations = true
    public var sourceFactTokens = 800
    public var sourceTokensPerObservation = 256
    public var kinds: [MemoryUnit.Kind] = MemoryUnit.Kind.allCases
    /// False interleaves the arms without the cross-encoder, as consolidation does.
    public var rerank = true
    public var rerankCandidates = 150
    public var includeSourceFacts = true
    /// Results this similar to a better-ranked one are left out.
    public var duplicateSimilarity: Float = 0.95
    /// The task asking, so its own memories, group and folders rank higher.
    public var taskID: String?
    /// Facienda-specific ranking signals, switchable for evaluation. In blind judging on real requests the task boost won
    /// clearly; ranking by who said it lost (agents' outcome reports are often what a task needs), and fading by kind did
    /// not help on two weeks of history. Levels and kinds therefore label memories; kind fading waits for longer history.
    public var kindRecency = false, trustBoost = false, taskBoost = true, excludeNotes = false
    public var now = Date()
    public init() {}

    /// What consolidation shows Luna for one new fact: observations only, unreranked, 512 tokens.
    public static var consolidation: MemoryRecallOptions {
        var options = MemoryRecallOptions()
        options.kinds = [.observation]; options.rerank = false; options.maxTokens = 512
        options.sourceFactTokens = 4_096
        return options
    }
}

/// A memory loaded for searching: every unit's vector, entities and links, rebuilt when the memory changes.
final class MemoryIndex: @unchecked Sendable {
    let revision: String
    let units: [MemoryUnit]
    let position: [String: Int]
    let vectors: [[Float]]
    let entities: [[String]]
    let entityNames: [String: String]
    let unitsByEntity: [String: [Int]]
    /// Observations citing each fact.
    let citedBy: [String: [Int]]
    /// Unit index → (neighbour index, weight, kind) in both directions.
    let links: [[(Int, Double, MemoryLink.Kind)]]
    let lowercased: [String]

    init(store: FaciendaStore, spaceID: String, revision: String) throws {
        self.revision = revision
        units = try store.memoryUnits(spaceID: spaceID)
        position = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($0.element.id, $0.offset) })
        vectors = units.map(\.vector)
        lowercased = units.map { ($0.text + " " + ($0.context ?? "")).lowercased() }
        let (memberships, names, links) = try store.db.read { db -> ([Row], [Row], [Row]) in
            (try Row.fetchAll(db, sql: "SELECT ue.unitId, ue.entityId FROM memoryUnitEntities ue JOIN memoryUnits u ON u.id = ue.unitId WHERE u.spaceId = ?", arguments: [spaceID]),
             try Row.fetchAll(db, sql: "SELECT id, name FROM memoryEntities WHERE spaceId = ?", arguments: [spaceID]),
             try Row.fetchAll(db, sql: "SELECT l.fromId, l.toId, l.kind, l.weight FROM memoryLinks l JOIN memoryUnits u ON u.id = l.fromId WHERE u.spaceId = ?", arguments: [spaceID]))
        }
        entityNames = Dictionary(uniqueKeysWithValues: names.map { ($0["id"] as String, $0["name"] as String) })
        var entities = [[String]](repeating: [], count: units.count), byEntity: [String: [Int]] = [:]
        for row in memberships {
            guard let i = position[row["unitId"]] else { continue }
            entities[i].append(row["entityId"]); byEntity[row["entityId"], default: []].append(i)
        }
        var cited: [String: [Int]] = [:]
        for (i, unit) in units.enumerated() where unit.kind == .observation {
            var inherited = Set(entities[i])
            for source in unit.sources {
                cited[source, default: []].append(i)
                if let s = position[source] { inherited.formUnion(entities[s]) }
            }
            entities[i] = Array(inherited)
        }
        self.entities = entities; unitsByEntity = byEntity; citedBy = cited
        var adjacency = [[(Int, Double, MemoryLink.Kind)]](repeating: [], count: units.count)
        for row in links {
            guard let a = position[row["fromId"]], let b = position[row["toId"]], let kind = MemoryLink.Kind(rawValue: row["kind"]) else { continue }
            adjacency[a].append((b, row["weight"], kind)); adjacency[b].append((a, row["weight"], kind))
        }
        self.links = adjacency
    }

    func names(_ i: Int) -> [String] { entities[i].compactMap { entityNames[$0] }.sorted() }
}

/// Keeps one loaded index per memory in each process.
actor MemoryIndexCache {
    static let shared = MemoryIndexCache()
    private var indexes: [String: MemoryIndex] = [:]

    func index(store: FaciendaStore, spaceID: String) throws -> MemoryIndex {
        let key = store.url.path + "#" + spaceID
        let revision = try store.memoryRevision(spaceID: spaceID) + "-" + (try store.memoryLinkRevision(spaceID: spaceID))
        if let index = indexes[key], index.revision == revision { return index }
        let index = try MemoryIndex(store: store, spaceID: spaceID, revision: revision)
        indexes[key] = index
        return index
    }
}

extension FaciendaStore {
    func memoryLinkRevision(spaceID: String) throws -> String {
        try db.read { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryEntities WHERE spaceId = ?", arguments: [spaceID]) ?? 0
            let m = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryUnitEntities ue JOIN memoryUnits u ON u.id = ue.unitId WHERE u.spaceId = ?", arguments: [spaceID]) ?? 0
            return "\(n)-\(m)"
        }
    }
}

/// Finds what a memory knows about a query: four retrieval arms, reciprocal rank fusion, cross-encoder reranking with
/// recency, date and evidence boosts, then observations over the facts they cite, within a token budget.
public struct MemoryRecall: Sendable {
    public let store: FaciendaStore
    public let models: MemoryModels
    public init(store: FaciendaStore, models: MemoryModels = .shared) { self.store = store; self.models = models }

    public struct Hit: Sendable {
        public var unit: MemoryUnit
        public var score: Double
        public var semantic: Double?
        public var keyword: Double?
        public var reranker: Double?
    }

    public func recall(_ query: String, spaceID: String, options: MemoryRecallOptions = MemoryRecallOptions()) async throws -> JSONValue {
        let index = try await MemoryIndexCache.shared.index(store: store, spaceID: spaceID)
        let hits = try await rank(query, index: index, options: options)
        return try respond(hits, index: index, options: options)
    }

    /// The ranked units, before budgets are applied.
    public func rank(_ query: String, spaceID: String, options: MemoryRecallOptions = MemoryRecallOptions()) async throws -> [Hit] {
        let index = try await MemoryIndexCache.shared.index(store: store, spaceID: spaceID)
        return try await rank(query, index: index, options: options)
    }

    func rank(_ query: String, index: MemoryIndex, options: MemoryRecallOptions) async throws -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines), started = Date()
        guard !index.units.isEmpty, !query.isEmpty else { return [] }
        let allowed = Set(options.kinds)
        let eligible = index.units.indices.filter { allowed.contains(index.units[$0].kind) && !(options.excludeNotes && index.units[$0].id.hasPrefix("note-")) }
        let q = try await models.embed([query])[0]
        let context = MemoryRecallContext.load(store, taskID: options.taskID)
        let similarity = eligible.reduce(into: [Int: Double]()) { $0[$1] = Double(MemoryVector.dot(q, index.vectors[$1])) }

        // 1. Semantic: cosine ≥ 0.3, best `budget` per kind.
        var semantic: [Int] = []
        for kind in options.kinds {
            semantic += eligible.filter { index.units[$0].kind == kind && similarity[$0]! >= 0.3 }
                .sorted { similarity[$0]! > similarity[$1]! }.prefix(options.budget)
        }
        semantic.sort { similarity[$0]! > similarity[$1]! }

        // 2. Keywords: FTS5 BM25 over text, context, entities and dates, with the rarest 16 query terms OR-ed.
        let keywordScores = try keywords(query, index: index, eligible: Set(eligible), limit: options.budget * options.kinds.count)
        let keyword = keywordScores.keys.sorted { keywordScores[$0]! > keywordScores[$1]! }

        // 3. Graph: shared entities, semantic and causal links from the top 20 semantic seeds.
        let graphScores = graph(seeds: Array(semantic.prefix(20)), index: index, allowed: allowed)
        let graph = graphScores.keys.sorted { graphScores[$0]! > graphScores[$1]! }.prefix(options.budget)

        // 4. Time: only when the query names a period.
        var temporalScores: [Int: Double] = [:]
        if let window = MemoryQueryDates.window(in: query, now: options.now) {
            temporalScores = temporal(window, similarity: similarity, index: index, eligible: eligible, budget: options.budget)
        }
        let temporal = temporalScores.keys.sorted { temporalScores[$0]! > temporalScores[$1]! }

        let arms = [semantic, keyword, Array(graph), temporal].filter { !$0.isEmpty }
        var hits: [Hit]
        if options.rerank {
            var fused: [Int: Double] = [:]
            for arm in arms { for (rank, i) in arm.enumerated() { fused[i, default: 0] += 1 / Double(60 + rank + 1) } }
            let pool = fused.keys.sorted { fused[$0]! > fused[$1]! }.prefix(options.rerankCandidates)
            let documents = pool.map { rerankText(index.units[$0]) }
            let reranking = Date()
            let logits = try await models.rerank(query, documents)
            if ProcessInfo.processInfo.environment["FACIENDA_MEMORY_TRACE"] != nil {
                FileHandle.standardError.write(Data("rerank \(documents.count): \(Int(Date().timeIntervalSince(reranking) * 1000)) ms, before: \(Int(reranking.timeIntervalSince(started) * 1000)) ms\n".utf8))
            }
            hits = zip(pool, logits).map { i, logit in
                let unit = index.units[i]
                let normalized = logit.isNaN ? 0 : 1 / (1 + exp(-Double(logit)))
                let recency = options.kindRecency ? Self.recency(unit, now: options.now) : Self.recency(unit.with(kind: nil), now: options.now)
                let time = temporalScores[i] ?? 0.5
                let proof = min(1, max(0, 0.5 + log(Double(max(1, unit.proofCount))) / 10))
                let trust = options.trustBoost ? unit.level.flatMap(MemoryLevel.init(rawValue:))?.trust ?? 0.5 : 0.5
                let combined = normalized * (1 + 0.2 * (recency - 0.5)) * (1 + 0.2 * (time - 0.5)) * (1 + 0.1 * (proof - 0.5))
                    * (1 + 0.1 * (trust - 0.5)) * (options.taskBoost ? context.boost(unit.taskId) : 1)
                return Hit(unit: unit, score: combined, semantic: similarity[i], keyword: keywordScores[i], reranker: normalized)
            }
            hits.sort { $0.score > $1.score }
        } else {
            // Round-robin across arms so each arm's best result is shown.
            var seen = Set<Int>(), order: [Int] = []
            for rank in 0..<(arms.map(\.count).max() ?? 0) {
                for arm in arms where rank < arm.count && seen.insert(arm[rank]).inserted { order.append(arm[rank]) }
            }
            hits = order.enumerated().map { Hit(unit: index.units[$1], score: 1 - Double($0) / Double(max(1, order.count)), semantic: similarity[$1], keyword: keywordScores[$1]) }
        }
        if options.preferObservations {
            let top = hits.prefix(options.budget * 2).filter { $0.unit.kind == .observation }
            let cited = Set(top.flatMap(\.unit.sources))
            hits.removeAll { $0.unit.kind != .observation && cited.contains($0.unit.id) }
        }
        // Near-duplicates (cosine ≥ 0.95 to a better-ranked result) only take space from different memories.
        var kept: [Hit] = [], keptVectors: [[Float]] = []
        for hit in hits where kept.count < options.budget * 2 {
            guard let i = index.position[hit.unit.id] else { continue }
            if keptVectors.contains(where: { MemoryVector.dot($0, index.vectors[i]) >= options.duplicateSimilarity }) { continue }
            kept.append(hit); keptVectors.append(index.vectors[i])
        }
        return kept
    }

    static func recency(_ unit: MemoryUnit, now: Date) -> Double {
        guard let anchor = unit.occurredStart ?? unit.mentionedAt ?? unit.occurredEnd else { return 0.5 }
        return MemoryKind.recency(unit.memoryKind.flatMap(MemoryKind.init(rawValue:)), age: max(0, now.timeIntervalSince(anchor) / 86_400))
    }

    func rerankText(_ unit: MemoryUnit) -> String {
        var text = unit.context.map { "\($0): \(unit.text)" } ?? unit.text
        if let start = unit.occurredStart {
            text = "[Date: \(MemoryText.format(start, "MMMM dd, yyyy")) (\(MemoryText.format(start, "yyyy-MM-dd")))] " + text
        }
        return text
    }

    static let stopwords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was", "were", "be", "been",
        "it", "this", "that", "these", "those", "at", "by", "from", "as", "do", "did", "does", "what", "which", "who", "whom", "how", "when", "where",
        "why", "we", "i", "you", "he", "she", "they", "our", "my", "your", "their", "me", "us", "about", "any", "can", "could", "would", "should", "have", "has", "had"]

    func keywords(_ query: String, index: MemoryIndex, eligible: Set<Int>, limit: Int) throws -> [Int: Double] {
        let tokens = query.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        var terms: [String] = []
        for term in String(tokens).split(separator: " ").map(String.init) where !Self.stopwords.contains(term) && !terms.contains(term) { terms.append(term) }
        guard !terms.isEmpty else { return [:] }
        if terms.count > 16 {
            let frequency = Dictionary(uniqueKeysWithValues: terms.map { term in (term, index.lowercased.lazy.filter { $0.contains(term) }.count) })
            terms = Array(terms.sorted { frequency[$0]! < frequency[$1]! }.prefix(16))
        }
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " OR ")
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT unitId, bm25(memoryUnitSearch) AS rank FROM memoryUnitSearch WHERE memoryUnitSearch MATCH ? ORDER BY rank LIMIT ?",
                             arguments: [match, limit * 3])
        }
        var scores: [Int: Double] = [:]
        for row in rows {
            guard let i = index.position[row["unitId"]], eligible.contains(i) else { continue }
            scores[i] = -(row["rank"] as Double)
            if scores.count >= limit { break }
        }
        return scores
    }

    func graph(seeds: [Int], index: MemoryIndex, allowed: Set<MemoryUnit.Kind>) -> [Int: Double] {
        let seedSet = Set(seeds)
        var shared: [Int: Set<String>] = [:], semantic: [Int: Double] = [:], causal: [Int: Double] = [:]
        for seed in seeds {
            for entity in index.entities[seed] {
                for other in (index.unitsByEntity[entity] ?? []).suffix(200) where !seedSet.contains(other) { shared[other, default: []].insert(entity) }
                // Observations reach facts through their sources' entities.
                for other in (index.unitsByEntity[entity] ?? []).suffix(200) {
                    for observation in index.citedBy[index.units[other].id] ?? [] where !seedSet.contains(observation) {
                        shared[observation, default: []].insert(entity)
                    }
                }
            }
            for (other, weight, kind) in index.links[seed] where !seedSet.contains(other) {
                switch kind {
                case .semantic: semantic[other] = max(semantic[other] ?? 0, weight)
                case .causedBy: causal[other] = max(causal[other] ?? 0, weight)
                case .temporal: break
                }
            }
        }
        var activation: [Int: Double] = [:]
        for i in Set(shared.keys).union(semantic.keys).union(causal.keys) where allowed.contains(index.units[i].kind) {
            activation[i] = tanh(0.5 * Double(shared[i]?.count ?? 0)) + (semantic[i] ?? 0) + (causal[i] ?? 0)
        }
        return activation
    }

    func temporal(_ window: DateInterval, similarity: [Int: Double], index: MemoryIndex, eligible: [Int], budget: Int) -> [Int: Double] {
        let mid = window.start.addingTimeInterval(window.duration / 2), half = max(window.duration / 2, 3_600)
        func best(_ unit: MemoryUnit) -> Date? {
            if let s = unit.occurredStart, let e = unit.occurredEnd { return s.addingTimeInterval(e.timeIntervalSince(s) / 2) }
            return unit.occurredStart ?? unit.occurredEnd ?? unit.mentionedAt
        }
        func proximity(_ unit: MemoryUnit) -> Double {
            guard let date = best(unit) else { return 0.3 }
            return 1 - min(abs(date.timeIntervalSince(mid)) / half, 1)
        }
        func overlaps(_ unit: MemoryUnit) -> Bool {
            let start = unit.occurredStart ?? unit.mentionedAt, end = unit.occurredEnd ?? start
            if let start, let end, start <= window.end, end >= window.start { return true }
            if let mentioned = unit.mentionedAt, window.contains(mentioned) { return true }
            return false
        }
        var scores: [Int: Double] = [:]
        var entries: [Int] = []
        for kind in MemoryUnit.Kind.allCases {
            entries += eligible.filter { index.units[$0].kind == kind && (similarity[$0] ?? 0) >= 0.1 && overlaps(index.units[$0]) }
                .sorted { similarity[$0]! > similarity[$1]! }.prefix(60)
        }
        for i in entries { scores[i] = proximity(index.units[i]) }
        // Spread along temporal and causal links, decaying each hop.
        var frontier = entries.sorted { scores[$0]! > scores[$1]! }.prefix(10).map { $0 }
        let eligibleSet = Set(eligible)
        for _ in 0..<5 where !frontier.isEmpty && scores.count < budget {
            var next: [Int] = []
            for parent in frontier {
                let neighbours = index.links[parent].filter { $0.2 != .semantic && $0.1 >= 0.1 }.sorted { $0.1 > $1.1 }.prefix(10)
                for (other, weight, kind) in neighbours where eligibleSet.contains(other) && (similarity[other] ?? 0) >= 0.1 {
                    let boost = kind == .causedBy ? 2.0 : 1.0
                    let score = max(proximity(index.units[other]), scores[parent]! * weight * boost * 0.7)
                    if score > (scores[other] ?? 0) {
                        scores[other] = score
                        if score > 0.2 { next.append(other) }
                    }
                }
            }
            frontier = Array(next.prefix(20))
        }
        return scores
    }

    // MARK: Response, in Hindsight's shape

    func respond(_ hits: [Hit], index: MemoryIndex, options: MemoryRecallOptions) throws -> JSONValue {
        let tokenizer = try? MemoryTokenizerCache.tokenizer(models)
        func tokens(_ text: String) -> Int { tokenizer.map { $0.pieces(text).count } ?? text.count / 4 }
        var used = 0, results: [JSONValue] = [], chosen: [Hit] = []
        for hit in hits {
            let cost = tokens(hit.unit.text)
            if used + cost > options.maxTokens, !chosen.isEmpty { continue }
            used += cost; chosen.append(hit)
            results.append(unitJSON(hit.unit, index: index, scores: hit))
        }
        var sourceFacts: [String: JSONValue] = [:], truncated = false, sourceUsed = 0
        if options.includeSourceFacts {
            for hit in chosen where hit.unit.kind == .observation {
                var perObservation = 0
                for id in hit.unit.sources where sourceFacts[id] == nil {
                    guard let i = index.position[id] else { continue }
                    let cost = tokens(index.units[i].text)
                    if perObservation + cost > options.sourceTokensPerObservation || sourceUsed + cost > options.sourceFactTokens { truncated = true; continue }
                    perObservation += cost; sourceUsed += cost
                    sourceFacts[id] = unitJSON(index.units[i], index: index, scores: nil)
                }
            }
        }
        var entities: [String: JSONValue] = [:]
        for hit in chosen {
            guard let i = index.position[hit.unit.id] else { continue }
            for id in index.entities[i] {
                guard let name = index.entityNames[id], entities[name] == nil, entities.count < 40 else { continue }
                entities[name] = .object(["entity_id": .string(id), "canonical_name": .string(name), "observations": .array([])])
            }
        }
        return .object([
            "results": .array(results), "source_facts": .object(sourceFacts), "source_facts_truncated": .bool(truncated),
            "entities": .object(entities), "trace": .null,
        ])
    }

    func unitJSON(_ unit: MemoryUnit, index: MemoryIndex, scores: Hit?) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(unit.id), "text": .string(unit.text), "type": .string(unit.kind.rawValue),
            "entities": .array((index.position[unit.id].map(index.names) ?? []).map(JSONValue.string)),
            "context": unit.context.map(JSONValue.string) ?? .null,
            "occurred_start": MemoryText.isoString(unit.occurredStart), "occurred_end": MemoryText.isoString(unit.occurredEnd),
            "mentioned_at": MemoryText.isoString(unit.mentionedAt),
            "document_id": unit.documentId.map(JSONValue.string) ?? .null,
            "metadata": unit.context.map { .object(["source": .string($0)]) } ?? .object([:]),
            "chunk_id": unit.documentId.map { .string("\($0)_\(unit.chunkIndex ?? 0)") } ?? .null,
            "tags": .array([]),
        ]
        if unit.kind == .observation { object["source_fact_ids"] = .array(unit.sources.map(JSONValue.string)) }
        if let level = unit.level { object["level"] = .string(level) }
        if let kind = unit.memoryKind { object["kind"] = .string(kind) }
        if let task = unit.taskId { object["task_id"] = .string(task) }
        if let scores {
            object["scores"] = .object([
                "final": .number(scores.score), "reranker": scores.reranker.map(JSONValue.number) ?? .null,
                "semantic": scores.semantic.map(JSONValue.number) ?? .null, "keyword": scores.keyword.map(JSONValue.number) ?? .null,
            ])
        }
        return .object(object)
    }
}

enum MemoryTokenizerCache {
    nonisolated(unsafe) private static var cached: MemoryTokenizer?
    private static let lock = NSLock()

    static func tokenizer(_ models: MemoryModels) throws -> MemoryTokenizer {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let folder = MemoryModels.resourceFolder() else { throw StoreError.invalid("Facienda's memory models are missing from this installation.") }
        let tokenizer = try MemoryTokenizer(vocabulary: folder.appendingPathComponent("vocab.txt"))
        cached = tokenizer
        return tokenizer
    }
}

/// Finds the period a query asks about ("yesterday", "last week", "in March 2026", "2026-10-06"). It only adds a
/// ranking arm and a proximity boost; it never filters.
public enum MemoryQueryDates {
    public static func window(in query: String, now: Date) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let lower = query.lowercased()
        let today = calendar.startOfDay(for: now)
        func days(_ start: Int, _ length: Int) -> DateInterval {
            let s = calendar.date(byAdding: .day, value: start, to: today)!
            return DateInterval(start: s, end: calendar.date(byAdding: .day, value: length, to: s)!)
        }
        func period(_ component: Calendar.Component, offset: Int) -> DateInterval? {
            guard let shifted = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: component == .day ? .day : component, for: shifted)
        }
        if lower.contains("yesterday") || lower.contains("last night") { return days(-1, 1) }
        if lower.contains("today") || lower.contains("this morning") || lower.contains("tonight") { return days(0, 1) }
        if lower.contains("last weekend") {
            let weekday = calendar.component(.weekday, from: today)
            let back = (weekday + 6) % 7 + 1 // days since last Sunday, at least 1
            return days(-back - 1, 2)
        }
        for (phrase, component, offset) in [("last week", Calendar.Component.weekOfYear, -1), ("this week", .weekOfYear, 0),
                                            ("last month", .month, -1), ("this month", .month, 0), ("last year", .year, -1), ("this year", .year, 0)]
        where lower.contains(phrase) { return period(component, offset: offset) }
        if let match = lower.firstMatch(of: /(\d+|a couple of|a few|few|two|three|four|five|six) (day|week|month|year)s? ago/) {
            let words = ["a couple of": 2, "a few": 3, "few": 3, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
            let n = Int(match.1) ?? words[String(match.1)] ?? 2
            let component: Calendar.Component = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year][String(match.2)]!
            guard let center = calendar.date(byAdding: component, value: -n, to: now) else { return nil }
            return calendar.dateInterval(of: component == .weekOfYear ? .weekOfYear : component, for: center)
        }
        if let match = query.firstMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
           let date = calendar.date(from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))) {
            return calendar.dateInterval(of: .day, for: date)
        }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        if let match = lower.firstMatch(of: /(january|february|march|april|june|july|august|september|october|november|december|may) (\d{1,2})(?:st|nd|rd|th)?(?:,? (\d{4}))?/),
           let month = months.firstIndex(of: String(match.1)) {
            let year = match.3.flatMap { Int($0) } ?? calendar.component(.year, from: now)
            if let date = calendar.date(from: DateComponents(year: year, month: month + 1, day: Int(match.2))) { return calendar.dateInterval(of: .day, for: date) }
        }
        if let match = lower.firstMatch(of: /(january|february|march|april|june|july|august|september|october|november|december) (\d{4})/),
           let month = months.firstIndex(of: String(match.1)),
           let date = calendar.date(from: DateComponents(year: Int(match.2), month: month + 1, day: 1)) {
            return calendar.dateInterval(of: .month, for: date)
        }
        if let match = lower.firstMatch(of: /(?:in|during|since) (\d{4})\b/), let year = Int(match.1),
           abs(year - calendar.component(.year, from: now)) < 120,
           let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) {
            return calendar.dateInterval(of: .year, for: date)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let match = lower.firstMatch(of: /(?:last|on) (sunday|monday|tuesday|wednesday|thursday|friday|saturday)/),
           let target = weekdays.firstIndex(of: String(match.1)) {
            let current = calendar.component(.weekday, from: today) - 1
            let back = (current - target + 7) % 7 == 0 ? 7 : (current - target + 7) % 7
            return days(-back, 1)
        }
        return nil
    }
}
