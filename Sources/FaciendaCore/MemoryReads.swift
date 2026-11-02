import Foundation
import GRDB

/// One workspace reading another's memory: live, one way, and set only by the user. The reader's agents see the
/// source's accepted entries, and its understanding when the user allows it, each marked with where it comes from. They
/// never write there, the source's rules and moves never apply here, and reading never passes on: a workspace that reads
/// one that reads a third still sees only the one it reads.
public struct MemoryRead: Codable, FetchableRecord, PersistableRecord, Equatable, Hashable, Sendable {
    public static let databaseTableName = "memoryReads"
    public var readerSpaceId: String
    public var sourceSpaceId: String
    /// The source's inferred understanding comes too, marked as inferred. Its evidence, past tasks and chats never do.
    public var understanding: Bool
    public var createdAt: Date
}

/// An entry another workspace's memory lends to this one, with the name of the memory it lives in.
public struct LinkedMemoryEntry: Codable, Equatable, Sendable {
    public var entry: MemoryEntry
    public var from: String

    /// What an agent sees: the entry, the memory it comes from, and that it is only to read.
    public var forAgent: JSONValue {
        guard case .object(var fields) = (try? JSONValue.encoded(entry)) ?? .null else { return .null }
        fields["embedding"] = nil
        fields["from"] = .string(from); fields["readOnly"] = .bool(true)
        return .object(fields)
    }
}

extension FaciendaStore {
    static func registerMemoryReads(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("memory_reads") { db in
            try db.execute(sql: """
                CREATE TABLE memoryReads (
                    readerSpaceId TEXT NOT NULL REFERENCES memorySpaces(id),
                    sourceSpaceId TEXT NOT NULL REFERENCES memorySpaces(id),
                    understanding BOOLEAN NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL,
                    PRIMARY KEY (readerSpaceId, sourceSpaceId),
                    CHECK (readerSpaceId != sourceSpaceId)
                )
                """)
        }
    }

    /// The shelves a read lends. Rules are the source's standing instructions and moves its habits; both stay home.
    static let lentShelves: Set<MemoryShelf> = [.places, .people, .choices, .howtos]

    /// Every read between workspaces that are still there.
    public func memoryReads() throws -> [MemoryRead] {
        try db.read { db in
            try MemoryRead.fetchAll(db, sql: """
                SELECT r.* FROM memoryReads r
                WHERE EXISTS (SELECT 1 FROM workspaces w WHERE w.memorySpaceId = r.readerSpaceId AND w.removedAt IS NULL)
                  AND EXISTS (SELECT 1 FROM workspaces w WHERE w.memorySpaceId = r.sourceSpaceId AND w.removedAt IS NULL)
                ORDER BY r.createdAt
                """)
        }
    }

    /// Starts one memory reading another, or changes what it reads. Only the app calls this, on the user's gesture; no
    /// agent tool reaches it.
    public func setMemoryRead(reader: String, source: String, understanding: Bool = false) throws {
        guard reader != source else { throw StoreError.invalid("A memory already reads itself.") }
        try write { db in
            _ = try Self.memorySpace(db, reader); _ = try Self.memorySpace(db, source)
            try db.execute(sql: """
                INSERT INTO memoryReads (readerSpaceId, sourceSpaceId, understanding, createdAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(readerSpaceId, sourceSpaceId) DO UPDATE SET understanding = excluded.understanding
                """, arguments: [reader, source, understanding, Date()])
            try TaskEvent(source: .user, kind: "memory.read", payload: reader + " " + source).insert(db)
        }
    }

    public func removeMemoryRead(reader: String, source: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM memoryReads WHERE readerSpaceId = ? AND sourceSpaceId = ?", arguments: [reader, source])
            try TaskEvent(source: .user, kind: "memory.unread", payload: reader + " " + source).insert(db)
        }
    }

    /// The memories one memory reads, with what each read includes. Never the memories those read in turn.
    public func memoriesRead(by spaceID: String) throws -> [(space: MemorySpace, read: MemoryRead)] {
        try memoryReads().filter { $0.readerSpaceId == spaceID }.compactMap { read in (try? memorySpace(read.sourceSpaceId)).map { ($0, read) } }
    }

    /// The memories that read this one.
    public func memoriesReading(_ spaceID: String) throws -> [MemorySpace] {
        try memoryReads().filter { $0.sourceSpaceId == spaceID }.compactMap { try? memorySpace($0.readerSpaceId) }
    }

    /// The live entries a memory lends to readers: its own, on the lent shelves. Shared About you entries are left out,
    /// since the reader has them already.
    public func lentMemoryEntries(_ sourceID: String) throws -> [MemoryEntry] {
        try memoryEntries(spaceID: sourceID, states: [.live]).filter { $0.spaceId == sourceID && Self.lentShelves.contains($0.shelf) }
    }

    /// Entries from the memories this one reads that match the words. The reader's own wording wins: an entry about a
    /// subject the reader already has on the same shelf is left out.
    public func linkedMemoryEntries(_ query: String, spaceID: String, limit: Int = 8) throws -> [LinkedMemoryEntry] {
        let own = Set(try memoryEntries(spaceID: spaceID, states: [.live]).map { $0.shelf.rawValue + " " + $0.subjectKey })
        let words = Set(MemoryEntry.key(query).split(separator: " ").filter { $0.count > 2 }.map(String.init))
        func score(_ entry: MemoryEntry) -> Int {
            let subject = MemoryEntry.key(entry.subject), text = MemoryEntry.key(entry.text)
            return words.reduce(0) { $0 + (subject.contains($1) ? 3 : text.contains($1) ? 1 : 0) }
        }
        var found: [(LinkedMemoryEntry, Int)] = []
        for (space, _) in try memoriesRead(by: spaceID) {
            for entry in try lentMemoryEntries(space.id) where !own.contains(entry.shelf.rawValue + " " + entry.subjectKey) {
                let value = score(entry)
                if words.isEmpty || value > 0 { found.append((LinkedMemoryEntry(entry: entry, from: space.name), value)) }
            }
        }
        return Array(found.sorted { $0.1 == $1.1 ? $0.0.entry.updatedAt > $1.0.entry.updatedAt : $0.1 > $1.1 }.prefix(min(30, max(1, limit))).map(\.0))
    }

    /// Opens an entry, or an understanding the user allowed, from a memory this one reads. Evidence, past tasks, chats,
    /// sections and archives stay with their own workspace.
    public func openLinkedMemoryReference(_ id: String, spaceID: String) throws -> JSONValue {
        let reads = try memoriesRead(by: spaceID)
        if id.hasPrefix("understanding:") {
            let key = String(id.dropFirst(14))
            for (space, read) in reads where read.understanding {
                if let item = try memoryUnderstanding(spaceID: space.id).first(where: { $0.id == key }) {
                    return try .object(["understanding": .encoded(item.forInference), "from": .string(space.name),
                                        "status": .string("Read from another workspace's memory. Inferred, never a rule here; its evidence stays there.")])
                }
            }
            throw StoreError.notFound
        }
        for (space, _) in reads {
            if let entry = try lentMemoryEntries(space.id).first(where: { $0.id == id }) {
                return try .object(["entry": .encoded(entry), "from": .string(space.name),
                                    "status": .string("Read from another workspace's memory. Read-only here; this workspace's own entries win.")])
            }
        }
        throw StoreError.notFound
    }

    /// One line for an agent's instructions naming what its memory reads, or nothing when it reads no other.
    public func memoryReadsSummary(spaceID: String) throws -> String? {
        let reads = try memoriesRead(by: spaceID)
        guard !reads.isEmpty else { return nil }
        return try reads.map { space, read in
            "\(space.name) (\(try lentMemoryEntries(space.id).count) entries\(read.understanding ? ", with understanding" : ""))"
        }.joined(separator: ", ")
    }
}
