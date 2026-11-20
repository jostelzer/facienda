import Foundation
import GRDB

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

    /// Native memory progress for one memory: sources waiting, done, failing, and how much was learned.
    public func nativeMemoryStatus(spaceID: String) throws -> NativeMemoryStatus {
        try db.read { db in
            let waiting = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM memoryDocuments d LEFT JOIN memoryRetained r ON r.documentId = d.id
                WHERE d.spaceId = ? AND d.id NOT LIKE 'curated-notes-%' AND (r.documentId IS NULL OR r.digest != d.digest OR r.spaceId != d.spaceId OR r.retainedAt IS NULL)
                """, arguments: [spaceID]) ?? 0
            let retained = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryRetained WHERE spaceId = ? AND retainedAt IS NOT NULL", arguments: [spaceID]) ?? 0
            let error = try String.fetchOne(db, sql: "SELECT error FROM memoryRetained WHERE spaceId = ? AND error IS NOT NULL ORDER BY nextAttempt DESC LIMIT 1", arguments: [spaceID])
            let counts = try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM memoryUnits WHERE spaceId = ? AND forgottenAt IS NULL GROUP BY kind", arguments: [spaceID])
            let byKind = Dictionary(uniqueKeysWithValues: counts.map { ($0["kind"] as String, $0["n"] as Int) })
            let unconsolidated = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryUnits WHERE spaceId = ? AND kind != 'observation' AND consolidatedAt IS NULL AND consolidationFailedAt IS NULL AND forgottenAt IS NULL", arguments: [spaceID]) ?? 0
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

/// Reads the dates found in chat records.
public enum MemoryText {
    static let posix = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
