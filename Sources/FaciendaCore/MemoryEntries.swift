import Foundation
import GRDB

public enum MemoryShelf: String, Codable, CaseIterable, Sendable {
    case rules, places, people, choices, howtos, moves
    public var title: String {
        switch self { case .rules: "Rules"; case .places: "Places"; case .people: "People"; case .choices: "Choices"; case .howtos: "How-tos"; case .moves: "Moves" }
    }
}

public struct MemoryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "memoryEntries"
    public enum Origin: String, Codable, Sendable { case you, facienda, agent }
    public enum State: String, Codable, Sendable { case proposed, live, archived }
    public var id: String
    public var spaceId: String?
    public var shelf: MemoryShelf
    public var sectionId: String?
    public var subject: String
    public var subjectKey: String
    public var text: String
    public var fields: [String: String]
    public var origin: Origin
    public var state: State
    public var sources: [String]
    public var reason: String
    public var replacesId: String?
    public var replacesRevision: Int?
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var embedding: Data

    public init(spaceID: String?, shelf: MemoryShelf, subject: String, text: String, origin: Origin, sources: [String],
                fields: [String: String] = [:], reason: String = "", at: Date = Date()) {
        id = UUID().uuidString; spaceId = spaceID; self.shelf = shelf; sectionId = nil
        self.subject = MemoryRedaction.redact(subject); subjectKey = Self.key(subject)
        self.text = MemoryRedaction.redact(text); self.fields = Self.cleanFields(fields)
        self.origin = origin; state = origin == .you ? .live : .proposed
        self.sources = sources.map(MemoryRedaction.redact); self.reason = MemoryRedaction.redact(reason)
        replacesId = nil; replacesRevision = nil; revision = 1; createdAt = at; updatedAt = at; embedding = Data()
    }

    static func key(_ text: String) -> String {
        MemoryRedaction.redact(text).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func cleanFields(_ fields: [String: String]) -> [String: String] {
        let clean = MemoryRedaction.redact(.object(fields.mapValues(JSONValue.string)))
        guard case .object(let values) = clean else { return [:] }
        return Dictionary(values.compactMap { key, value in value.string.map { (MemoryRedaction.redact(key), $0) } }, uniquingKeysWith: { _, last in last })
    }
}

public struct MemoryEntryVersion: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memoryEntryHistory"
    public var id: String
    public var entryId: String
    public var snapshot: MemoryEntry
    public var at: Date
}

extension FaciendaStore {
    static func registerMemoryEntries(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("curated_memory_entries") { db in
            try db.execute(sql: """
                ALTER TABLE memoryFacts ADD COLUMN forgottenAt DATETIME;
                ALTER TABLE memorySettings ADD COLUMN useAIWorker BOOLEAN NOT NULL DEFAULT 1;
                CREATE TABLE memoryEntries (
                    id TEXT PRIMARY KEY, spaceId TEXT REFERENCES memorySpaces(id), shelf TEXT NOT NULL, sectionId TEXT,
                    subject TEXT NOT NULL, subjectKey TEXT NOT NULL, text TEXT NOT NULL, fields TEXT NOT NULL,
                    origin TEXT NOT NULL, state TEXT NOT NULL, sources TEXT NOT NULL, reason TEXT NOT NULL,
                    replacesId TEXT, replacesRevision INTEGER, revision INTEGER NOT NULL,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, embedding BLOB NOT NULL
                );
                CREATE UNIQUE INDEX entry_subject ON memoryEntries(coalesce(spaceId, ''), shelf, subjectKey) WHERE state = 'live';
                CREATE INDEX entry_scope ON memoryEntries(spaceId, state, shelf);
                CREATE TABLE memoryEntryHistory (id TEXT PRIMARY KEY, entryId TEXT NOT NULL REFERENCES memoryEntries(id), snapshot TEXT NOT NULL, at DATETIME NOT NULL);
                CREATE TABLE memoryArchive (
                    id TEXT PRIMARY KEY, spaceId TEXT NOT NULL REFERENCES memorySpaces(id), kind TEXT NOT NULL,
                    sourceId TEXT NOT NULL, snapshot TEXT NOT NULL, at DATETIME NOT NULL,
                    UNIQUE(spaceId, kind, sourceId)
                );
                CREATE TABLE memoryMigrations (spaceId TEXT PRIMARY KEY REFERENCES memorySpaces(id), at DATETIME NOT NULL, entryIds TEXT NOT NULL, reversedAt DATETIME);
                """)
        }
        // A running older app must not refill a migrated workspace while the user reviews the new build.
        migrator.registerMigration("retired_memory_writers") { db in
            for table in ["memoryFacts", "memoryUnits", "memoryDocuments"] {
                let retired = table == "memoryDocuments" ? "NEW.sourceKind = 'legacy'" : "NEW.forgottenAt IS NULL"
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER retired_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN \(retired) AND EXISTS (SELECT 1 FROM memoryMigrations WHERE spaceId = NEW.spaceId AND reversedAt IS NULL)
                        BEGIN SELECT RAISE(ABORT, 'This workspace uses curated memory. Open the updated Facienda app to change it.'); END;
                        """)
                }
            }
        }
        migrator.registerMigration("memory_migration_leases") { db in
            try db.execute(sql: "CREATE TABLE memoryMigrationLeases (spaceId TEXT PRIMARY KEY REFERENCES memorySpaces(id), owner TEXT NOT NULL, expiresAt DATETIME NOT NULL)")
            for table in ["memoryFacts", "memoryUnits", "memoryDocuments"] {
                let retired = table == "memoryDocuments" ? "NEW.sourceKind = 'legacy'" : "NEW.forgottenAt IS NULL"
                // User note edits during preparation are allowed; the generation check makes them win.
                let preparing = table == "memoryFacts" ? "0" : "EXISTS (SELECT 1 FROM memoryMigrationLeases WHERE spaceId = NEW.spaceId AND julianday(expiresAt) > julianday('now'))"
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        DROP TRIGGER retired_\(table)_\(operation);
                        CREATE TRIGGER retired_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN \(retired) AND (\(preparing) OR EXISTS (SELECT 1 FROM memoryMigrations WHERE spaceId = NEW.spaceId AND reversedAt IS NULL))
                        BEGIN SELECT RAISE(ABORT, 'This workspace is being migrated or uses curated memory. Open the updated Facienda app to change it.'); END;
                        """)
                }
            }
        }
    }

    public func memoryEntries(spaceID: String, states: [MemoryEntry.State] = [.live, .proposed]) throws -> [MemoryEntry] {
        try db.read { db in
            try MemoryEntry.fetchAll(db, sql: "SELECT * FROM memoryEntries WHERE spaceId = ? OR (spaceId IS NULL AND state = 'live') ORDER BY shelf, subject", arguments: [spaceID])
                .filter { states.contains($0.state) }
        }
    }

    public func memoryEntry(_ id: String, spaceID: String) throws -> MemoryEntry {
        try db.read { db in
            guard let entry = try MemoryEntry.fetchOne(db, key: id), entry.spaceId == spaceID || (entry.spaceId == nil && entry.state == .live) else { throw StoreError.notFound }
            return entry
        }
    }

    public func memoryEntryHistory(_ id: String, spaceID: String) throws -> [MemoryEntryVersion] {
        _ = try memoryEntry(id, spaceID: spaceID)
        return try db.read { try MemoryEntryVersion.fetchAll($0, sql: "SELECT * FROM memoryEntryHistory WHERE entryId = ? ORDER BY at DESC", arguments: [id]) }
    }

    static func saveEntryVersion(_ db: Database, _ entry: MemoryEntry) throws {
        try MemoryEntryVersion(id: UUID().uuidString, entryId: entry.id, snapshot: entry, at: Date()).insert(db)
    }

    /// Every agent or keeper proposal remains inert; only a user action promotes it.
    @discardableResult public func proposeMemoryEntry(spaceID: String, shelf: MemoryShelf, subject: String, text: String,
                                                      source: String, reason: String, origin: MemoryEntry.Origin = .agent) throws -> MemoryEntry {
        guard origin != .you else { throw StoreError.invalid("A proposal cannot claim to be the user.") }
        var entry = MemoryEntry(spaceID: spaceID, shelf: shelf, subject: subject, text: text, origin: origin, sources: [source], reason: reason)
        guard !entry.text.isEmpty, !entry.subjectKey.isEmpty else { throw StoreError.invalid("Give this memory a subject and some words.") }
        return try write { db in
            if let duplicate = try MemoryEntry.fetchAll(db, sql: "SELECT * FROM memoryEntries WHERE spaceId = ? AND shelf = ? AND subjectKey = ? AND state != 'archived'", arguments: [spaceID, shelf.rawValue, entry.subjectKey]).first(where: { $0.text == entry.text }) { return duplicate }
            if let live = try Self.liveEntry(db, spaceID: spaceID, shelf: shelf, key: entry.subjectKey) {
                entry.replacesId = live.id; entry.replacesRevision = live.revision
            }
            try entry.insert(db); return entry
        }
    }

    static func liveEntry(_ db: Database, spaceID: String?, shelf: MemoryShelf, key: String) throws -> MemoryEntry? {
        try MemoryEntry.fetchOne(db, sql: "SELECT * FROM memoryEntries WHERE spaceId IS ? AND shelf = ? AND subjectKey = ? AND state = 'live'", arguments: [spaceID, shelf.rawValue, key])
    }

    /// Used by the editor and by the keeper with a verified user quotation. Earlier wording stays in history.
    @discardableResult public func writeMemoryEntry(_ entry: MemoryEntry) throws -> MemoryEntry {
        guard entry.origin == .you else { throw StoreError.invalid("Only the user's words can be written directly.") }
        var clean = entry
        clean.text = MemoryRedaction.redact(entry.text); clean.subject = MemoryRedaction.redact(entry.subject)
        clean.subjectKey = MemoryEntry.key(clean.subject); clean.sources = entry.sources.map(MemoryRedaction.redact)
        clean.fields = MemoryEntry.cleanFields(entry.fields); clean.reason = MemoryRedaction.redact(entry.reason)
        guard !clean.subjectKey.isEmpty, !clean.text.isEmpty else { throw StoreError.invalid("Give this memory a subject and some words.") }
        return try write { db in
            if let existing = try Self.liveEntry(db, spaceID: clean.spaceId, shelf: clean.shelf, key: clean.subjectKey) {
                guard clean.updatedAt >= existing.updatedAt else { return existing }
                if existing.text == clean.text && existing.fields == clean.fields { return existing }
                try Self.saveEntryVersion(db, existing)
                clean.id = existing.id; clean.createdAt = existing.createdAt; clean.revision = existing.revision + 1
                clean.sources = Array(Set(existing.sources + clean.sources)).sorted()
            }
            clean.state = .live; clean.replacesId = nil; clean.replacesRevision = nil
            try clean.save(db); return clean
        }
    }

    public func acceptMemoryEntry(_ id: String, spaceID: String) throws {
        try write { db in
            guard var entry = try MemoryEntry.fetchOne(db, key: id), entry.spaceId == spaceID, entry.state == .proposed else { throw StoreError.notFound }
            if var old = try Self.liveEntry(db, spaceID: spaceID, shelf: entry.shelf, key: entry.subjectKey) {
                guard entry.replacesId == old.id, entry.replacesRevision == old.revision else { throw StoreError.invalid("The current entry changed. Review it before accepting this proposal.") }
                try Self.saveEntryVersion(db, old)
                old.text = entry.text; old.fields = entry.fields; old.sources = Array(Set(old.sources + entry.sources)).sorted()
                old.origin = .you; old.reason = "Accepted by you"; old.updatedAt = Date(); old.revision += 1; old.embedding = Data()
                try old.update(db); entry.state = .archived; try entry.update(db)
            } else {
                entry.state = .live; entry.origin = .you; entry.reason = "Accepted by you"; entry.updatedAt = Date(); entry.revision += 1
                try entry.update(db)
            }
        }
    }

    public func editMemoryEntry(_ id: String, spaceID: String, text: String, subject: String? = nil, fields: [String: String]? = nil) throws {
        try write { db in
            guard var entry = try MemoryEntry.fetchOne(db, key: id), entry.spaceId == spaceID || (entry.spaceId == nil && entry.state == .live) else { throw StoreError.notFound }
            try Self.saveEntryVersion(db, entry)
            entry.text = MemoryRedaction.redact(text); entry.origin = .you; entry.updatedAt = Date(); entry.revision += 1; entry.embedding = Data()
            if let subject { entry.subject = MemoryRedaction.redact(subject); entry.subjectKey = MemoryEntry.key(subject) }
            if let fields { entry.fields = MemoryEntry.cleanFields(fields) }
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Write something, or forget this memory.") }
            try entry.update(db)
        }
    }

    public func forgetMemoryEntry(_ id: String, spaceID: String) throws {
        try write { db in
            guard var entry = try MemoryEntry.fetchOne(db, key: id), entry.spaceId == spaceID || (entry.spaceId == nil && entry.state == .live) else { throw StoreError.notFound }
            try Self.saveEntryVersion(db, entry); entry.state = .archived; entry.revision += 1; entry.updatedAt = Date(); try entry.update(db)
        }
    }

    /// Sharing is a user action: an independent, accepted copy, never a cross-workspace lookup by an agent.
    public func shareMemoryEntry(_ id: String, spaceID: String) throws {
        var entry = try memoryEntry(id, spaceID: spaceID)
        guard entry.spaceId == spaceID, entry.state == .live else { throw StoreError.invalid("Accept this entry before sharing it.") }
        entry.id = UUID().uuidString; entry.spaceId = nil; entry.sectionId = nil; entry.origin = .you
        entry.sources = ["Shared by you from a workspace"]; entry.createdAt = Date(); entry.updatedAt = Date()
        _ = try writeMemoryEntry(entry)
    }
}
