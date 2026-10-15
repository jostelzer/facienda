import Foundation
import GRDB

/// Learns from the source outbox: retains changed sources as facts, then consolidates facts into observations.
public struct NativeMemoryEngine: Sendable {
    public let store: FaciendaStore
    public let inference: any MemoryInference
    public let models: MemoryModels

    public init(store: FaciendaStore, inference: any MemoryInference, models: MemoryModels = .shared) {
        self.store = store; self.inference = inference; self.models = models
    }

    /// Retains up to `sources` changed sources, then runs up to `batches` consolidation batches. Returns true when work remains.
    @discardableResult
    public func synchronize(sources: Int = 4, batches: Int = 4) async throws -> Bool {
        var firstError: Error?
        do { try await syncNotes() } catch { firstError = error }
        for _ in 0..<sources {
            do { guard try await retainNext() else { break } } catch { firstError = firstError ?? error }
        }
        for _ in 0..<batches {
            guard try await consolidateNext() else { break }
        }
        // Memories imported from Hindsight learn their kind a few at a time.
        do { try await classifyKinds(limit: 40) } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
        return try hasWaitingSources()
    }

    func hasWaitingSources() throws -> Bool { try store.db.read { db in try Self.nextSource(db, now: Date()) != nil } }

    // MARK: Retain

    struct Claim { var document: MemoryDocument; var attempts: Int }

    static func nextSource(_ db: Database, now: Date) throws -> MemoryDocument? {
        try MemoryDocument.fetchOne(db, sql: """
            SELECT d.* FROM memoryDocuments d LEFT JOIN memoryRetained r ON r.documentId = d.id
            WHERE d.spaceId IS NOT NULL AND d.id NOT LIKE 'curated-notes-%'
              AND (r.documentId IS NULL OR r.digest != d.digest OR r.spaceId != d.spaceId OR r.retainedAt IS NULL)
              AND (r.nextAttempt IS NULL OR r.nextAttempt <= ?) AND (r.leaseUntil IS NULL OR r.leaseUntil <= ?)
            ORDER BY d.at LIMIT 1
            """, arguments: [now, now])
    }

    func claim(now: Date = Date()) throws -> Claim? {
        try store.db.write { db in
            guard let document = try Self.nextSource(db, now: now), let space = document.spaceId else { return nil }
            let attempts = try Int.fetchOne(db, sql: "SELECT attempts FROM memoryRetained WHERE documentId = ?", arguments: [document.id]) ?? 0
            try db.execute(sql: """
                INSERT INTO memoryRetained (documentId, spaceId, digest, retainedAt, attempts, nextAttempt, leaseUntil)
                VALUES (?, ?, '', NULL, ?, ?, ?)
                ON CONFLICT(documentId) DO UPDATE SET retainedAt = NULL, leaseUntil = excluded.leaseUntil
                """, arguments: [document.id, space, attempts, now, now.addingTimeInterval(20 * 60)])
            return Claim(document: document, attempts: attempts)
        }
    }

    /// Learns one changed source. Only chunks whose text changed are sent to Luna.
    @discardableResult
    public func retainNext() async throws -> Bool {
        guard let claim = try claim() else { return false }
        let document = claim.document
        do {
            try await retain(document)
            return true
        } catch {
            recordFailure(document, attempts: claim.attempts + 1, error: error)
            throw error
        }
    }

    func recordFailure(_ document: MemoryDocument, attempts: Int, error: Error) {
        try? store.db.write { db in
            try db.execute(sql: "UPDATE memoryRetained SET attempts = ?, nextAttempt = ?, leaseUntil = NULL, error = ? WHERE documentId = ?",
                           arguments: [attempts, Date().addingTimeInterval(min(3_600, 30 * pow(2, Double(min(attempts, 7))))),
                                       error.localizedDescription, document.id])
        }
    }

    func chunkState(_ documentID: String) throws -> [(index: Int, space: String, digest: String)] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT chunkIndex, spaceId, digest FROM memoryChunks WHERE documentId = ?", arguments: [documentID])
                .map { ($0["chunkIndex"], $0["spaceId"], $0["digest"]) }
        }
    }

    struct PendingFact {
        var fact: ExtractedFact
        var chunk: Int
        var id = UUID().uuidString.lowercased()
        var mentioned: Date
        var vector: [Float] = []
    }

    func retain(_ document: MemoryDocument) async throws {
        guard let spaceID = document.spaceId else { return }
        let chunks = MemoryChunker.split(document.content)
        let digests = chunks.map(MemoryChunker.digest)
        let previous = try chunkState(document.id)
        let moved = previous.contains { $0.space != spaceID }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.index, $0.digest) })
        let changed = chunks.indices.filter { moved || old[$0] != digests[$0] }
        let removed = old.keys.filter { $0 >= chunks.count }

        var pending: [PendingFact] = []
        for index in changed {
            let input = MemoryPrompts.extractionInput(chunk: chunks[index], index: index, total: chunks.count, eventDate: document.at, context: document.source)
            let facts = try await extract(input, eventDate: document.at)
            let offset = pending.count
            for fact in facts {
                var fact = fact
                fact.causedBy = fact.causedBy.map { $0 + offset }
                pending.append(PendingFact(fact: fact, chunk: index, mentioned: document.at.addingTimeInterval(Double(pending.count) * 0.01)))
            }
        }
        // One spelling per entity across the source, before matching against what the memory already knows.
        let canonical = MemoryEntityResolver.canonicalNames(pending.flatMap(\.fact.entities))
        for i in pending.indices {
            var seen = Set<String>()
            pending[i].fact.entities = pending[i].fact.entities.map { canonical[$0.lowercased()] ?? $0 }.filter { seen.insert($0.lowercased()).inserted }
        }
        let texts = pending.map { MemoryText.embeddingText($0.fact.text, start: $0.fact.occurredStart, end: $0.fact.occurredEnd, mentioned: $0.mentioned, entities: $0.fact.entities) }
        let vectors = try await models.embed(texts)
        for i in pending.indices { pending[i].vector = vectors[i] }
        try commit(document, spaceID: spaceID, pending: pending, changed: changed, removed: removed, moved: moved, digests: digests)
    }

    func commit(_ document: MemoryDocument, spaceID: String, pending: [PendingFact], changed: [Int], removed: [Int], moved: Bool, digests: [String]) throws {
        try store.db.write { db in
            let stale = try String.fetchAll(db, sql: moved
                ? "SELECT id FROM memoryUnits WHERE documentId = ?"
                : "SELECT id FROM memoryUnits WHERE documentId = ? AND chunkIndex IN (\((changed + removed).map(String.init).joined(separator: ",")))",
                arguments: [document.id])
            try Self.forget(db, unitIDs: stale)
            try Self.insert(db, facts: pending, document: document, spaceID: spaceID)
            if moved { try db.execute(sql: "DELETE FROM memoryChunks WHERE documentId = ?", arguments: [document.id]) }
            for index in removed { try db.execute(sql: "DELETE FROM memoryChunks WHERE documentId = ? AND chunkIndex = ?", arguments: [document.id, index]) }
            for index in changed {
                try db.execute(sql: "INSERT OR REPLACE INTO memoryChunks (documentId, chunkIndex, spaceId, digest) VALUES (?, ?, ?, ?)",
                               arguments: [document.id, index, spaceID, digests[index]])
            }
            try db.execute(sql: """
                UPDATE memoryRetained SET spaceId = ?, digest = ?, retainedAt = ?, attempts = 0, leaseUntil = NULL, error = NULL WHERE documentId = ?
                """, arguments: [spaceID, document.digest, Date(), document.id])
        }
    }

    func extract(_ input: String, eventDate: Date) async throws -> [ExtractedFact] {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let reply = try await inference.complete(system: MemoryPrompts.extraction, user: input, schema: MemoryPrompts.extractionSchema)
                // The learner is told to keep the input's language; a fact in another script is a drift, not a translation to keep.
                return try ExtractedFact.parse(reply, eventDate: eventDate).filter { WritingScript.alike($0.text, input) }
            } catch { lastError = error }
        }
        throw lastError ?? StoreError.invalid("Luna could not extract facts.")
    }

    /// Removes facts whose source text changed. Observations built on them are rebuilt from their remaining facts.
    static func forget(_ db: Database, unitIDs: [String]) throws {
        guard !unitIDs.isEmpty else { return }
        let gone = Set(unitIDs)
        let observations = try MemoryUnit.fetchAll(db, sql: "SELECT * FROM memoryUnits WHERE kind = 'observation' AND spaceId = (SELECT spaceId FROM memoryUnits WHERE id = ?)", arguments: [unitIDs[0]])
        for observation in observations where !gone.isDisjoint(with: observation.sources) {
            let survivors = observation.sources.filter { !gone.contains($0) }
            for survivor in survivors {
                try db.execute(sql: "UPDATE memoryUnits SET consolidatedAt = NULL, consolidationFailedAt = NULL WHERE id = ?", arguments: [survivor])
            }
            try FaciendaStore.deleteUnits(db, ids: [observation.id])
        }
        try FaciendaStore.deleteUnits(db, ids: unitIDs)
    }

    static func insert(_ db: Database, facts: [PendingFact], document: MemoryDocument, spaceID: String) throws {
        guard !facts.isEmpty else { return }
        let source = try FaciendaStore.memorySource(db, documentID: document.documentID, content: document.content)
        var resolver = try MemoryEntityResolver(db, spaceID: spaceID)
        let now = Date()
        let existing = try MemoryUnit.fetchAll(db, sql: "SELECT * FROM memoryUnits WHERE spaceId = ? AND kind != 'observation'", arguments: [spaceID])
            .filter { unit in !facts.contains { $0.id == unit.id } }
        let existingVectors = existing.map(\.vector)
        var units: [MemoryUnit] = []
        for pending in facts {
            let fact = pending.fact
            let unit = MemoryUnit(id: pending.id, spaceId: spaceID, documentId: document.id, chunkIndex: pending.chunk, kind: fact.kind, text: fact.text,
                                  context: document.source, occurredStart: fact.occurredStart, occurredEnd: fact.occurredEnd, mentionedAt: pending.mentioned,
                                  eventDate: fact.occurredStart ?? pending.mentioned, embedding: MemoryVector.encode(pending.vector), proofCount: 1,
                                  sourceIds: nil, consolidatedAt: nil, consolidationFailedAt: nil, createdAt: now, updatedAt: now,
                                  level: source.level.rawValue, memoryKind: fact.memoryKind?.rawValue, taskId: source.taskID)
            try unit.insert(db)
            units.append(unit)
            var entityIDs: [String] = []
            for name in fact.entities {
                let nearby = fact.entities.filter { $0 != name }
                let id: String
                if let known = resolver.resolve(name, nearby: nearby, at: unit.eventDate) {
                    id = known
                    try db.execute(sql: "UPDATE memoryEntities SET mentionCount = mentionCount + 1, lastSeen = MAX(lastSeen, ?) WHERE id = ?", arguments: [unit.eventDate, id])
                } else {
                    id = UUID().uuidString.lowercased()
                    try MemoryEntity(id: id, spaceId: spaceID, name: name, mentionCount: 1, firstSeen: unit.eventDate, lastSeen: unit.eventDate).insert(db)
                    resolver.known.append(.init(id: id, name: name, lastSeen: unit.eventDate, trigrams: MemoryEntityResolver.trigrams(name)))
                }
                if !entityIDs.contains(id) { entityIDs.append(id) }
            }
            for id in entityIDs { try db.execute(sql: "INSERT OR IGNORE INTO memoryUnitEntities (unitId, entityId) VALUES (?, ?)", arguments: [unit.id, id]) }
            for a in entityIDs { for b in entityIDs where a < b {
                try db.execute(sql: """
                    INSERT INTO memoryEntityPairs (a, b, count, lastSeen) VALUES (?, ?, 1, ?)
                    ON CONFLICT(a, b) DO UPDATE SET count = count + 1, lastSeen = MAX(lastSeen, excluded.lastSeen)
                    """, arguments: [a, b, unit.eventDate])
            } }
            try FaciendaStore.indexUnit(db, unit, entities: fact.entities)
        }
        try link(db, units: units, facts: facts, existing: existing, existingVectors: existingVectors)
    }

    /// Temporal links to the nearest facts in time, semantic links to close neighbours (≥ 0.7), and causal links from extraction.
    static func link(_ db: Database, units: [MemoryUnit], facts: [PendingFact], existing: [MemoryUnit], existingVectors: [[Float]]) throws {
        func save(_ from: String, _ to: String, _ kind: MemoryLink.Kind, _ weight: Double) throws {
            try db.execute(sql: "INSERT INTO memoryLinks (fromId, toId, kind, weight) VALUES (?, ?, ?, ?) ON CONFLICT DO UPDATE SET weight = MAX(weight, excluded.weight)",
                           arguments: [from, to, kind.rawValue, weight])
        }
        for (i, unit) in units.enumerated() {
            // Temporal: the 20 nearest of the same kind on each side, plus this source's own facts within a day.
            let sameKind = existing.filter { $0.kind == unit.kind }
            let before = sameKind.filter { $0.eventDate <= unit.eventDate }.sorted { $0.eventDate > $1.eventDate }.prefix(20)
            let after = sameKind.filter { $0.eventDate > unit.eventDate }.sorted { $0.eventDate < $1.eventDate }.prefix(20)
            var temporal: [(String, Double)] = (before + after).map { ($0.id, max(0.3, 1 - abs($0.eventDate.timeIntervalSince(unit.eventDate)) / 3_600 / 24)) }
            for other in units where other.id != unit.id && other.kind == unit.kind && abs(other.eventDate.timeIntervalSince(unit.eventDate)) <= 86_400 {
                temporal.append((other.id, max(0.3, 1 - abs(other.eventDate.timeIntervalSince(unit.eventDate)) / 3_600 / 24)))
            }
            for (other, weight) in temporal.sorted(by: { $0.1 > $1.1 }).prefix(20) { try save(unit.id, other, .temporal, weight) }
            // Semantic: top 50 of the same kind at cosine ≥ 0.7.
            let vector = facts[i].vector
            var semantic: [(String, Double)] = []
            for (j, other) in existing.enumerated() where other.kind == unit.kind {
                let similarity = Double(MemoryVector.dot(vector, existingVectors[j]))
                if similarity >= 0.7 { semantic.append((other.id, similarity)) }
            }
            for (j, other) in units.enumerated() where j < i && other.kind == unit.kind {
                let similarity = Double(MemoryVector.dot(vector, facts[j].vector))
                if similarity >= 0.7 { semantic.append((other.id, similarity)) }
            }
            for (other, weight) in semantic.sorted(by: { $0.1 > $1.1 }).prefix(50) { try save(unit.id, other, .semantic, min(1, weight)) }
            for cause in facts[i].fact.causedBy where cause < units.count { try save(unit.id, units[cause].id, .causedBy, 1) }
        }
    }

    // MARK: Consolidate

    /// Consolidates up to eight unconsolidated facts of the oldest pending memory. Returns false when nothing is waiting.
    @discardableResult
    public func consolidateNext(spaceID: String? = nil) async throws -> Bool {
        let batch = try unconsolidated(spaceID: spaceID)
        guard !batch.isEmpty else { return false }
        try await consolidate(batch)
        return true
    }

    func unconsolidated(spaceID: String?) throws -> [MemoryUnit] {
        try store.db.read { db in
            try MemoryUnit.fetchAll(db, sql: """
                SELECT * FROM memoryUnits WHERE kind != 'observation' AND consolidatedAt IS NULL AND consolidationFailedAt IS NULL
                \(spaceID == nil ? "" : "AND spaceId = ?")
                AND spaceId = (SELECT spaceId FROM memoryUnits WHERE kind != 'observation' AND consolidatedAt IS NULL AND consolidationFailedAt IS NULL
                               \(spaceID == nil ? "" : "AND spaceId = ?") ORDER BY createdAt LIMIT 1)
                ORDER BY createdAt LIMIT 8
                """, arguments: spaceID.map { [$0, $0] } ?? [])
        }
    }

    /// Splits a failing batch in half until single facts are isolated; a fact that still fails is marked and skipped.
    func consolidate(_ facts: [MemoryUnit]) async throws {
        do {
            try await consolidateBatch(facts)
        } catch {
            if facts.count == 1 { try markFailed(facts[0].id); return }
            let half = facts.count / 2
            try await consolidate(Array(facts[..<half]))
            try await consolidate(Array(facts[half...]))
        }
    }

    func markFailed(_ id: String) throws {
        try store.db.write { db in try db.execute(sql: "UPDATE memoryUnits SET consolidationFailedAt = ? WHERE id = ?", arguments: [Date(), id]) }
    }

    func consolidateBatch(_ facts: [MemoryUnit]) async throws {
        let spaceID = facts[0].spaceId
        let recall = MemoryRecall(store: store, models: models)
        var shown: [String: MemoryUnit] = [:], recalledFor: [String: Set<String>] = [:]
        for fact in facts {
            let response = try await recall.recall(fact.text, spaceID: spaceID, options: .consolidation)
            let ids = (response["results"].array ?? []).compactMap { $0["id"].string }
            recalledFor[fact.id] = Set(ids)
            for unit in try store.memoryUnits(ids: ids) { shown[unit.id] = unit }
        }
        let observations = shown.values.sorted { $0.eventDate < $1.eventDate }
        let input = MemoryPrompts.consolidationInput(facts: facts.map(Self.factLine).joined(separator: "\n"),
                                                     observations: try observationsJSON(observations))
        let reply = try await inference.complete(system: MemoryPrompts.consolidation, user: input, schema: MemoryPrompts.consolidationSchema)
        let plan = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        guard plan["creates"].array != nil || plan["updates"].array != nil || plan["deletes"].array != nil else {
            throw StoreError.invalid("Luna returned no consolidation plan.")
        }
        let batchIDs = Set(facts.map(\.id))
        let unionRecalled = Set(recalledFor.values.flatMap { $0 })
        func sources(_ item: JSONValue) -> [String] {
            var seen = Set<String>()
            return (item["source_fact_ids"].array ?? []).compactMap(\.string).filter { batchIDs.contains($0) && seen.insert($0).inserted }
        }
        let factTexts = Dictionary(facts.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        func sourceText(_ ids: [String]) -> String { ids.compactMap { factTexts[$0] }.joined(separator: " ") }
        let deletes = Set((plan["deletes"].array ?? []).compactMap { $0["observation_id"].string ?? $0["id"].string }.filter(unionRecalled.contains))
        var kinds: [String: String] = [:]
        var updates: [String: (text: String, sources: [String])] = [:]
        for item in plan["updates"].array ?? [] {
            guard let id = item["observation_id"].string, let text = item["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !deletes.contains(id) else { continue }
            let from = sources(item)
            guard !from.isEmpty, from.contains(where: { recalledFor[$0]?.contains(id) == true }), WritingScript.alike(text, sourceText(from)) else { continue }
            updates[id] = (text, Array(Set((updates[id]?.sources ?? []) + from)))
            if let kind = item["memory_kind"].string.flatMap(MemoryKind.init(rawValue:)) { kinds[id] = kind.rawValue }
        }
        func normalized(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let known = Set(observations.map { normalized($0.text) } + updates.values.map { normalized($0.text) })
        var creates: [(text: String, sources: [String])] = []
        for item in plan["creates"].array ?? [] {
            guard let text = item["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !known.contains(normalized(text)) else { continue }
            let from = sources(item)
            if !from.isEmpty, WritingScript.alike(text, sourceText(from)) {
                creates.append((text, from))
                if let kind = item["memory_kind"].string.flatMap(MemoryKind.init(rawValue:)) { kinds["create:" + text] = kind.rawValue }
            }
        }

        // Near-twins (cosine ≥ 0.97) of an existing observation are merged into it when Luna agrees they state the same fact.
        let allObservations = try store.memoryUnits(spaceID: spaceID, kinds: [.observation])
        var folds: [String: (text: String, sources: [String])] = [:]
        var plannedCreates: [(text: String, sources: [String], vector: [Float])] = []
        for create in creates {
            let vector = try await models.embed([create.text])[0]
            if let twin = allObservations.filter({ !deletes.contains($0.id) }).max(by: { MemoryVector.dot(vector, $0.vector) < MemoryVector.dot(vector, $1.vector) }),
               MemoryVector.dot(vector, twin.vector) >= 0.97, let merged = try await merge(new: create.text, existing: updates[twin.id]?.text ?? twin.text) {
                let prior = folds[twin.id] ?? updates[twin.id] ?? (twin.text, [])
                folds[twin.id] = (merged, prior.sources + create.sources)
                if kinds[twin.id] == nil { kinds[twin.id] = kinds["create:" + create.text] }
            } else {
                plannedCreates.append((create.text, create.sources, vector))
            }
        }
        for (id, fold) in folds { updates[id] = (fold.text, Array(Set(fold.sources))) }
        var updateVectors: [String: [Float]] = [:]
        for (id, update) in updates {
            let current = shown[id] ?? allObservations.first { $0.id == id }
            guard let current else { continue }
            let span = Self.span(of: try store.memoryUnits(ids: Array(Set(current.sources + update.sources))))
            updateVectors[id] = try await models.embed([MemoryText.embeddingText(update.text, start: span.start, end: span.end, mentioned: span.mentioned, entities: [])])[0]
        }
        let createVectors = try await models.embed(plannedCreates.map { create in
            let span = Self.span(of: facts.filter { create.sources.contains($0.id) })
            return MemoryText.embeddingText(create.text, start: span.start, end: span.end, mentioned: span.mentioned, entities: [])
        })

        try apply(facts: facts, spaceID: spaceID, deletes: deletes, updates: updates, updateVectors: updateVectors,
                  creates: plannedCreates.map { ($0.text, $0.sources) }, createVectors: createVectors, kinds: kinds)
    }

    func apply(facts: [MemoryUnit], spaceID: String, deletes: Set<String>, updates: [String: (text: String, sources: [String])],
               updateVectors: [String: [Float]], creates plannedCreates: [(text: String, sources: [String])], createVectors: [[Float]],
               kinds: [String: String]) throws {
        /// An observation is as trustworthy as its sources, and belongs to a task only when all of them do.
        func provenance(_ db: Database, _ ids: [String]) throws -> (level: String?, task: String?) {
            let units = try MemoryUnit.fetchAll(db, keys: ids)
            let tasks = Set(units.compactMap(\.taskId))
            return (MemoryLevel.combined(units.compactMap { $0.level.flatMap(MemoryLevel.init(rawValue:)) })?.rawValue, tasks.count == 1 ? tasks.first : nil)
        }
        try store.db.write { db in
            // A fact edited since it was read makes the whole plan stale.
            for fact in facts {
                guard let current = try MemoryUnit.fetchOne(db, key: fact.id), current.updatedAt == fact.updatedAt else {
                    throw StoreError.invalid("Memory changed during consolidation; it will be retried.")
                }
            }
            let now = Date()
            try FaciendaStore.deleteUnits(db, ids: Array(deletes))
            for (id, update) in updates {
                guard var observation = try MemoryUnit.fetchOne(db, key: id), observation.kind == .observation else { continue }
                try db.execute(sql: "INSERT INTO memoryObservationHistory (id, observationId, text, sourceIds, changedAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: [UUID().uuidString, id, observation.text, observation.sourceIds, now])
                let all = Array(NSOrderedSet(array: observation.sources + update.sources)) as! [String]
                let span = Self.span(of: try MemoryUnit.fetchAll(db, keys: all))
                observation.text = update.text
                observation.sourceIds = String(data: try JSONEncoder().encode(all), encoding: .utf8)
                observation.proofCount = all.count
                observation.occurredStart = span.start; observation.occurredEnd = span.end
                observation.mentionedAt = span.mentioned; observation.eventDate = span.start ?? span.mentioned ?? observation.eventDate
                if let vector = updateVectors[id] { observation.embedding = MemoryVector.encode(vector) }
                let origin = try provenance(db, all)
                observation.level = origin.level; observation.taskId = origin.task
                observation.memoryKind = kinds[id] ?? observation.memoryKind
                observation.updatedAt = now
                try observation.update(db)
                try FaciendaStore.indexUnit(db, observation, entities: [])
            }
            for (create, vector) in zip(plannedCreates, createVectors) {
                let span = Self.span(of: facts.filter { create.sources.contains($0.id) })
                let origin = try provenance(db, create.sources)
                let observation = MemoryUnit(id: UUID().uuidString.lowercased(), spaceId: spaceID, documentId: nil, chunkIndex: nil, kind: .observation,
                                             text: create.text, context: nil, occurredStart: span.start, occurredEnd: span.end, mentionedAt: span.mentioned ?? now,
                                             eventDate: span.start ?? span.mentioned ?? now, embedding: MemoryVector.encode(vector), proofCount: create.sources.count,
                                             sourceIds: String(data: try JSONEncoder().encode(create.sources), encoding: .utf8),
                                             consolidatedAt: nil, consolidationFailedAt: nil, createdAt: now, updatedAt: now,
                                             level: origin.level, memoryKind: kinds["create:" + create.text], taskId: origin.task)
                try observation.insert(db)
                try FaciendaStore.indexUnit(db, observation, entities: [])
            }
            for fact in facts { try db.execute(sql: "UPDATE memoryUnits SET consolidatedAt = ? WHERE id = ?", arguments: [now, fact.id]) }
        }
    }

    func merge(new: String, existing: String) async throws -> String? {
        let reply = try await inference.complete(system: MemoryPrompts.mergeSystem, user: MemoryPrompts.mergeInput(new: new, existing: existing), schema: MemoryPrompts.mergeSchema)
        let decision = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        guard decision["action"].string == "merge", let text = decision["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func span(of units: [MemoryUnit]) -> (start: Date?, end: Date?, mentioned: Date?) {
        (units.compactMap(\.occurredStart).min(), units.compactMap { $0.occurredEnd ?? $0.occurredStart }.max(), units.compactMap(\.mentionedAt).max())
    }

    static func factLine(_ fact: MemoryUnit) -> String {
        let fields = [("occurred_start", fact.occurredStart), ("occurred_end", fact.occurredEnd), ("mentioned_at", fact.mentionedAt)]
            .compactMap { name, date in date.map { "\(name)=\(MemoryText.format($0, "yyyy-MM-dd"))" } }
        return "[\(fact.id)] \(fact.text)" + (fields.isEmpty ? "" : " (\(fields.joined(separator: ", ")))")
    }

    func observationsJSON(_ observations: [MemoryUnit]) throws -> String {
        let tokenizer = try? MemoryTokenizerCache.tokenizer(models)
        func tokens(_ text: String) -> Int { tokenizer.map { $0.pieces(text).count } ?? text.count / 4 }
        var total = 0
        let entries: [JSONValue] = try observations.map { observation in
            var memories: [JSONValue] = [], used = 0
            for source in try store.memoryUnits(ids: observation.sources) {
                let cost = tokens(source.text)
                guard used + cost <= 256, total + cost <= 4_096 else { continue }
                used += cost; total += cost
                var entry: [String: JSONValue] = ["text": .string(source.text)]
                if let context = source.context { entry["context"] = .string(context) }
                for (name, date) in [("occurred_start", source.occurredStart), ("occurred_end", source.occurredEnd), ("mentioned_at", source.mentionedAt)] {
                    if let date { entry[name] = .string(MemoryText.format(date, "yyyy-MM-dd")) }
                }
                memories.append(.object(entry))
            }
            var entry: [String: JSONValue] = ["id": .string(observation.id), "text": .string(observation.text), "proof_count": .number(Double(observation.proofCount))]
            for (name, date) in [("occurred_start", observation.occurredStart), ("occurred_end", observation.occurredEnd), ("mentioned_at", observation.mentionedAt)] {
                if let date { entry[name] = .string(MemoryText.format(date, "yyyy-MM-dd")) }
            }
            if !memories.isEmpty { entry["source_memories"] = .array(memories) }
            return .object(entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(data: try encoder.encode(JSONValue.array(entries)), encoding: .utf8) ?? "[]"
    }
}
