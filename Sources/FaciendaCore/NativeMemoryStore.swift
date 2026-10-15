import Foundation
import GRDB

/// One remembered unit: a fact extracted from a source (`world` or `experience`) or an `observation` consolidated from facts.
public struct MemoryUnit: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "memoryUnits"
    public enum Kind: String, Codable, Sendable, CaseIterable { case world, experience, observation }

    public var id: String
    public var spaceId: String
    /// The local `memoryDocuments` source; nil for observations.
    public var documentId: String?
    public var chunkIndex: Int?
    public var kind: Kind
    public var text: String
    public var context: String?
    public var occurredStart: Date?
    public var occurredEnd: Date?
    public var mentionedAt: Date?
    /// `occurredStart ?? mentionedAt`, used for temporal links and recency.
    public var eventDate: Date
    public var embedding: Data
    public var proofCount: Int
    /// Observations only: the facts behind it, as a JSON array of unit IDs.
    public var sourceIds: String?
    public var consolidatedAt: Date?
    public var consolidationFailedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Who it comes from (`MemoryLevel`): the user's words and notes rank above agent reports.
    public var level: String? = nil
    /// What kind of knowledge it is (`MemoryKind`), which decides how fast it fades.
    public var memoryKind: String? = nil
    /// The Facienda task it was learned from, when there is exactly one.
    public var taskId: String? = nil

    public var vector: [Float] { MemoryVector.decode(embedding) }
    func with(kind: String?) -> MemoryUnit { var copy = self; copy.memoryKind = kind; return copy }
    public var sources: [String] {
        guard let sourceIds, let ids = try? JSONDecoder().decode([String].self, from: Data(sourceIds.utf8)) else { return [] }
        return ids
    }
}

public struct MemoryEntity: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "memoryEntities"
    public var id: String
    public var spaceId: String
    public var name: String
    public var mentionCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
}

public struct MemoryLink: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "memoryLinks"
    public enum Kind: String, Codable, Sendable { case temporal, semantic, causedBy = "caused_by" }
    public var fromId: String
    public var toId: String
    public var kind: Kind
    public var weight: Double
}

/// Little-endian Float32 storage for 384-dimensional unit vectors.
public enum MemoryVector {
    public static func encode(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }
    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }
}

extension FaciendaStore {
    static func registerNativeMemory(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("native_memory") { db in
            try db.execute(sql: """
            CREATE TABLE memoryUnits (
                id TEXT PRIMARY KEY NOT NULL,
                spaceId TEXT NOT NULL REFERENCES memorySpaces(id) ON DELETE CASCADE,
                documentId TEXT,
                chunkIndex INTEGER,
                kind TEXT NOT NULL CHECK (kind IN ('world', 'experience', 'observation')),
                text TEXT NOT NULL,
                context TEXT,
                occurredStart DATETIME,
                occurredEnd DATETIME,
                mentionedAt DATETIME,
                eventDate DATETIME NOT NULL,
                embedding BLOB NOT NULL,
                proofCount INTEGER NOT NULL DEFAULT 1,
                sourceIds TEXT,
                consolidatedAt DATETIME,
                consolidationFailedAt DATETIME,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL,
                level TEXT,
                memoryKind TEXT,
                taskId TEXT
            );
            CREATE INDEX memory_units_task ON memoryUnits(taskId);
            CREATE INDEX memory_units_space ON memoryUnits(spaceId, kind, eventDate);
            CREATE INDEX memory_units_document ON memoryUnits(documentId, chunkIndex);
            CREATE INDEX memory_units_unconsolidated ON memoryUnits(spaceId, createdAt) WHERE kind != 'observation' AND consolidatedAt IS NULL AND consolidationFailedAt IS NULL;
            CREATE VIRTUAL TABLE memoryUnitSearch USING fts5(unitId UNINDEXED, body, tokenize = 'porter unicode61 remove_diacritics 2');

            CREATE TABLE memoryEntities (
                id TEXT PRIMARY KEY NOT NULL,
                spaceId TEXT NOT NULL REFERENCES memorySpaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                mentionCount INTEGER NOT NULL DEFAULT 0,
                firstSeen DATETIME NOT NULL,
                lastSeen DATETIME NOT NULL
            );
            CREATE UNIQUE INDEX memory_entities_name ON memoryEntities(spaceId, lower(name));
            CREATE TABLE memoryUnitEntities (
                unitId TEXT NOT NULL REFERENCES memoryUnits(id) ON DELETE CASCADE,
                entityId TEXT NOT NULL REFERENCES memoryEntities(id) ON DELETE CASCADE,
                PRIMARY KEY (unitId, entityId)
            );
            CREATE INDEX memory_unit_entities_entity ON memoryUnitEntities(entityId);
            CREATE TABLE memoryEntityPairs (
                a TEXT NOT NULL REFERENCES memoryEntities(id) ON DELETE CASCADE,
                b TEXT NOT NULL REFERENCES memoryEntities(id) ON DELETE CASCADE,
                count INTEGER NOT NULL,
                lastSeen DATETIME NOT NULL,
                PRIMARY KEY (a, b)
            );

            CREATE TABLE memoryLinks (
                fromId TEXT NOT NULL REFERENCES memoryUnits(id) ON DELETE CASCADE,
                toId TEXT NOT NULL REFERENCES memoryUnits(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                weight DOUBLE NOT NULL,
                PRIMARY KEY (fromId, toId, kind)
            );
            CREATE INDEX memory_links_to ON memoryLinks(toId, kind);

            CREATE TABLE memoryChunks (
                documentId TEXT NOT NULL,
                chunkIndex INTEGER NOT NULL,
                spaceId TEXT NOT NULL,
                digest TEXT NOT NULL,
                PRIMARY KEY (documentId, chunkIndex)
            );
            CREATE TABLE memoryRetained (
                documentId TEXT PRIMARY KEY NOT NULL,
                spaceId TEXT NOT NULL,
                digest TEXT NOT NULL,
                retainedAt DATETIME,
                attempts INTEGER NOT NULL DEFAULT 0,
                nextAttempt DATETIME NOT NULL,
                leaseUntil DATETIME,
                error TEXT
            );
            CREATE TABLE memoryObservationHistory (
                id TEXT PRIMARY KEY NOT NULL,
                observationId TEXT NOT NULL,
                text TEXT NOT NULL,
                sourceIds TEXT,
                changedAt DATETIME NOT NULL
            );
            CREATE INDEX memory_observation_history ON memoryObservationHistory(observationId, changedAt);

            ALTER TABLE memorySettings ADD COLUMN engine TEXT NOT NULL DEFAULT 'native';
            UPDATE memorySettings SET engine = 'hindsight' WHERE enabled = 1;
            """)
        }
    }

    // MARK: Units

    public func memoryUnits(spaceID: String, kinds: [MemoryUnit.Kind] = MemoryUnit.Kind.allCases) throws -> [MemoryUnit] {
        try db.read { db in
            try MemoryUnit.fetchAll(db, sql: "SELECT * FROM memoryUnits WHERE spaceId = ? AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))",
                                    arguments: StatementArguments([spaceID] + kinds.map(\.rawValue)))
        }
    }

    public func memoryUnits(ids: [String]) throws -> [MemoryUnit] {
        guard !ids.isEmpty else { return [] }
        return try db.read { db in try MemoryUnit.fetchAll(db, keys: ids) }
    }

    /// A cheap fingerprint of a memory's contents, used to invalidate in-process caches.
    public func memoryRevision(spaceID: String) throws -> String {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, MAX(updatedAt) AS at FROM memoryUnits WHERE spaceId = ?", arguments: [spaceID])
            return "\(row?["n"] as Int? ?? 0)-\(row?["at"] as String? ?? "")"
        }
    }

    static func indexUnit(_ db: Database, _ unit: MemoryUnit, entities: [String]) throws {
        try db.execute(sql: "DELETE FROM memoryUnitSearch WHERE unitId = ?", arguments: [unit.id])
        let dates = [unit.occurredStart, unit.occurredEnd].compactMap { $0 }.map(MemoryText.spokenDate)
        let body = ([unit.text, unit.context ?? ""] + entities + dates).joined(separator: " ")
        try db.execute(sql: "INSERT INTO memoryUnitSearch (unitId, body) VALUES (?, ?)", arguments: [unit.id, body])
    }

    static func deleteUnits(_ db: Database, ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "DELETE FROM memoryUnitSearch WHERE unitId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memoryUnits WHERE id = ?", arguments: [id])
        }
    }

    public func memoryEntityNames(unitIDs: [String]) throws -> [String: [String]] {
        guard !unitIDs.isEmpty else { return [:] }
        return try db.read { db in
            var names: [String: [String]] = [:]
            for chunk in stride(from: 0, to: unitIDs.count, by: 500).map({ Array(unitIDs[$0..<min($0 + 500, unitIDs.count)]) }) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT ue.unitId, e.name FROM memoryUnitEntities ue JOIN memoryEntities e ON e.id = ue.entityId
                    WHERE ue.unitId IN (\(chunk.map { _ in "?" }.joined(separator: ","))) ORDER BY e.name
                    """, arguments: StatementArguments(chunk))
                for row in rows { names[row["unitId"], default: []].append(row["name"]) }
            }
            return names
        }
    }

    /// Native memory progress for one memory: sources waiting, done, failing, and how much was learned.
    public func nativeMemoryStatus(spaceID: String) throws -> NativeMemoryStatus {
        try db.read { db in
            let waiting = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM memoryDocuments d LEFT JOIN memoryRetained r ON r.documentId = d.id
                WHERE d.spaceId = ? AND d.id NOT LIKE 'curated-notes-%' AND (r.documentId IS NULL OR r.digest != d.digest OR r.spaceId != d.spaceId OR r.retainedAt IS NULL)
                """, arguments: [spaceID]) ?? 0
            let retained = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryRetained WHERE spaceId = ? AND retainedAt IS NOT NULL", arguments: [spaceID]) ?? 0
            let error = try String.fetchOne(db, sql: "SELECT error FROM memoryRetained WHERE spaceId = ? AND error IS NOT NULL ORDER BY nextAttempt DESC LIMIT 1", arguments: [spaceID])
            let counts = try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM memoryUnits WHERE spaceId = ? GROUP BY kind", arguments: [spaceID])
            let byKind = Dictionary(uniqueKeysWithValues: counts.map { ($0["kind"] as String, $0["n"] as Int) })
            let unconsolidated = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryUnits WHERE spaceId = ? AND kind != 'observation' AND consolidatedAt IS NULL AND consolidationFailedAt IS NULL", arguments: [spaceID]) ?? 0
            return NativeMemoryStatus(waiting: waiting, retained: retained, facts: (byKind["world"] ?? 0) + (byKind["experience"] ?? 0),
                                      observations: byKind["observation"] ?? 0, unconsolidated: unconsolidated, error: error)
        }
    }
}

public struct NativeMemoryStatus: Codable, Equatable, Sendable {
    public var waiting: Int
    public var retained: Int
    public var facts: Int
    public var observations: Int
    public var unconsolidated: Int
    public var error: String?
}

/// Shared text forms, matching Hindsight's so imported memories embed and search identically.
public enum MemoryText {
    static let posix = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix; formatter.timeZone = utc; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// "October 12 2026", used for keyword search.
    public static func spokenDate(_ date: Date) -> String { format(date, "MMMM d yyyy") }

    /// The text that is embedded: the fact, when it happened (month precision) and the entities it names.
    public static func embeddingText(_ text: String, start: Date?, end: Date?, mentioned: Date?, entities: [String]) -> String {
        var result = text
        if let first = start ?? mentioned {
            let a = format(first, "MMMM yyyy")
            if let end, let start, end != start, format(end, "MMMM yyyy") != a {
                result += " (happened from \(a) to \(format(end, "MMMM yyyy")))"
            } else {
                result += " (happened in \(a))"
            }
        }
        if !entities.isEmpty { result += " [" + entities.joined(separator: ", ") + "]" }
        return result
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func isoString(_ date: Date?) -> JSONValue { date.map { .string(iso.string(from: $0)) } ?? .null }

    /// Accepts full ISO timestamps or plain `yyyy-MM-dd` dates.
    public static func parseDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.lowercased() != "n/a", value != "null" else { return nil }
        if let date = iso.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = posix; formatter.timeZone = utc; formatter.dateFormat = pattern
            if let date = formatter.date(from: String(value.prefix(pattern.replacingOccurrences(of: "'", with: "").count))) { return date }
        }
        return nil
    }
}
