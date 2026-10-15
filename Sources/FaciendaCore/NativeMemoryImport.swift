import Foundation
import GRDB

public struct MemoryImportSummary: Codable, Equatable, Sendable {
    public var facts: Int
    public var observations: Int
    public var entities: Int
    public var links: Int
    public var retainedSources: Int
}

extension FaciendaStore {
    /// Replaces a memory's built-in contents with a Hindsight bank exported by `scripts/export_hindsight_memory.py`:
    /// facts, observations, entities, links, chunk hashes and the original embeddings. Sources Hindsight had already
    /// retained count as learned, so nothing is extracted twice.
    public func importHindsightMemory(spaceID: String, from folder: URL) throws -> MemoryImportSummary {
        let summary = try importHindsightRows(spaceID: spaceID, from: folder)
        // Facts Hindsight drew from the notes document stay: observations rest on them, and near-duplicates of the notes
        // themselves are filtered at recall.
        try attributeMemoryUnits(spaceID: spaceID)
        return summary
    }

    func importHindsightRows(spaceID: String, from folder: URL) throws -> MemoryImportSummary {
        func rows(_ name: String) throws -> [JSONValue] {
            let text = try String(contentsOf: folder.appendingPathComponent(name + ".jsonl"), encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }
        let units = try rows("units"), entities = try rows("entities"), memberships = try rows("unit_entities")
        let pairs = try rows("cooccurrences"), links = try rows("links"), chunks = try rows("chunks")
        let now = Date()
        return try db.write { db in
            _ = try Self.memorySpace(db, spaceID)
            try Self.clearNativeMemory(db, spaceID: spaceID)
            // Hindsight knows sources by `externalId ?? id`; native memory uses the local ID.
            let documents = try MemoryDocument.fetchAll(db, sql: "SELECT * FROM memoryDocuments WHERE spaceId = ?", arguments: [spaceID])
            let local = Dictionary(documents.map { ($0.documentID, $0.id) }, uniquingKeysWith: { a, _ in a })

            var names: [String: String] = [:]
            for entity in entities {
                guard let id = entity["id"].string, let name = entity["canonical_name"].string else { continue }
                let record = MemoryEntity(id: id, spaceId: spaceID, name: name, mentionCount: entity["mention_count"].int ?? 1,
                                          firstSeen: MemoryText.parseDate(entity["first_seen"].string) ?? now,
                                          lastSeen: MemoryText.parseDate(entity["last_seen"].string) ?? now)
                // Hindsight's names are unique case-insensitively within a bank, as here.
                try record.insert(db, onConflict: .ignore)
                names[id] = name
            }
            var unitEntities: [String: [String]] = [:]
            for row in memberships {
                guard let unit = row["unit_id"].string, let entity = row["entity_id"].string, names[entity] != nil else { continue }
                unitEntities[unit, default: []].append(entity)
            }
            var summary = MemoryImportSummary(facts: 0, observations: 0, entities: names.count, links: 0, retainedSources: 0)
            var imported = Set<String>()
            for row in units {
                guard let id = row["id"].string, let text = row["text"].string, let kind = MemoryUnit.Kind(rawValue: row["fact_type"].string ?? ""),
                      let vector = Self.parseVector(row["embedding"].string), vector.count == MemoryModels.dimensions else { continue }
                let document = row["document_id"].string
                let chunkIndex = row["chunk_id"].string.flatMap { $0.split(separator: "_").last.flatMap { Int($0) } }
                let mentioned = MemoryText.parseDate(row["mentioned_at"].string)
                let start = MemoryText.parseDate(row["occurred_start"].string)
                let sources = (row["source_memory_ids"].array ?? []).compactMap(\.string)
                let unit = MemoryUnit(id: id, spaceId: spaceID, documentId: document.map { local[$0] ?? $0 }, chunkIndex: chunkIndex, kind: kind, text: text,
                                      context: row["context"].string, occurredStart: start, occurredEnd: MemoryText.parseDate(row["occurred_end"].string),
                                      mentionedAt: mentioned, eventDate: MemoryText.parseDate(row["event_date"].string) ?? start ?? mentioned ?? now,
                                      embedding: MemoryVector.encode(vector), proofCount: row["proof_count"].int ?? 1,
                                      sourceIds: kind == .observation ? String(data: try JSONEncoder().encode(sources), encoding: .utf8) : nil,
                                      consolidatedAt: MemoryText.parseDate(row["consolidated_at"].string),
                                      consolidationFailedAt: MemoryText.parseDate(row["consolidation_failed_at"].string),
                                      createdAt: MemoryText.parseDate(row["created_at"].string) ?? now, updatedAt: MemoryText.parseDate(row["updated_at"].string) ?? now)
                try unit.insert(db)
                imported.insert(id)
                for entity in unitEntities[id] ?? [] {
                    try db.execute(sql: "INSERT OR IGNORE INTO memoryUnitEntities (unitId, entityId) VALUES (?, ?)", arguments: [id, entity])
                }
                try Self.indexUnit(db, unit, entities: (unitEntities[id] ?? []).compactMap { names[$0] })
                if kind == .observation { summary.observations += 1 } else { summary.facts += 1 }
            }
            for pair in pairs {
                guard let a = pair["entity_id_1"].string, let b = pair["entity_id_2"].string, names[a] != nil, names[b] != nil else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO memoryEntityPairs (a, b, count, lastSeen) VALUES (?, ?, ?, ?)",
                               arguments: [a, b, pair["cooccurrence_count"].int ?? 1, MemoryText.parseDate(pair["last_cooccurred"].string) ?? now])
            }
            for link in links {
                guard let from = link["from_unit_id"].string, let to = link["to_unit_id"].string, imported.contains(from), imported.contains(to),
                      let kind = MemoryLink.Kind(rawValue: link["link_type"].string ?? "") else { continue }
                try MemoryLink(fromId: from, toId: to, kind: kind, weight: link["weight"].double ?? 1).insert(db, onConflict: .ignore)
                summary.links += 1
            }
            for chunk in chunks {
                guard let document = chunk["document_id"].string, let index = chunk["chunk_index"].int, let digest = chunk["content_hash"].string else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO memoryChunks (documentId, chunkIndex, spaceId, digest) VALUES (?, ?, ?, ?)",
                               arguments: [local[document] ?? document, index, spaceID, digest])
            }
            for document in documents where document.state == "completed" {
                try db.execute(sql: "INSERT OR REPLACE INTO memoryRetained (documentId, spaceId, digest, retainedAt, attempts, nextAttempt) VALUES (?, ?, ?, ?, 0, ?)",
                               arguments: [document.id, spaceID, document.digest, now, now])
                summary.retainedSources += 1
            }
            return summary
        }
    }

    static func clearNativeMemory(_ db: Database, spaceID: String) throws {
        try db.execute(sql: "DELETE FROM memoryUnitSearch WHERE unitId IN (SELECT id FROM memoryUnits WHERE spaceId = ?)", arguments: [spaceID])
        try db.execute(sql: "DELETE FROM memoryObservationHistory WHERE observationId IN (SELECT id FROM memoryUnits WHERE spaceId = ?)", arguments: [spaceID])
        try db.execute(sql: "DELETE FROM memoryUnits WHERE spaceId = ?", arguments: [spaceID])
        try db.execute(sql: "DELETE FROM memoryEntities WHERE spaceId = ?", arguments: [spaceID])
        try db.execute(sql: "DELETE FROM memoryChunks WHERE spaceId = ?", arguments: [spaceID])
        try db.execute(sql: "DELETE FROM memoryRetained WHERE spaceId = ?", arguments: [spaceID])
    }

    /// pgvector's text form: `[0.1,-0.2,…]`.
    static func parseVector(_ text: String?) -> [Float]? {
        guard let text else { return nil }
        let values = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").compactMap { Float($0) }
        return values.isEmpty ? nil : values
    }
}

extension JSONValue {
    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
