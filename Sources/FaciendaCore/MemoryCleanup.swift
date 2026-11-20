import Foundation
import GRDB

extension FaciendaStore {
    static let memorySlimming = "slim-2026-11"
    static let proposalClearing = "proposals-2026-11"

    /// The tables the cleanup empties or thins, copied whole into the archive first. The history of rewrites is
    /// left out: it was three quarters of what memory weighed and held nothing the last versions do not.
    private static let archivedTables = ["memoryUnderstanding", "memoryMoves", "memoryMoveOffers", "memoryUtterances", "memoryUnits", "memoryEntities",
                                         "memoryUnitEntities", "memoryEntityPairs", "memoryLinks", "memoryObservationHistory"]

    public var memoryArchiveURL: URL { url.deletingLastPathComponent().appending(path: "memory-before-cleanup.sqlite") }

    /// Brings a library that grew under the earlier learner down to what memory keeps now, once. The user agreed to
    /// the deletion; what goes is first copied to a file beside the library, so nothing is lost for good.
    public func slimMemoryOnce() throws {
        guard try db.read({ try Int.fetchOne($0, sql: "SELECT 1 FROM memoryUpkeep WHERE name = ?", arguments: [Self.memorySlimming]) }) == nil else { return }
        let archive = memoryArchiveURL
        try db.writeWithoutTransaction { db in
            // A copy an interrupted run left behind is incomplete: the library is still whole, so start over.
            try? FileManager.default.removeItem(at: archive)
            try db.execute(sql: "ATTACH DATABASE ? AS kept", arguments: [archive.path])
            defer { try? db.execute(sql: "DETACH DATABASE kept") }
            for table in Self.archivedTables { try db.execute(sql: "CREATE TABLE kept.\(table) AS SELECT * FROM main.\(table)") }
            try db.inTransaction {
                try Self.slimMemory(db)
                try db.execute(sql: "INSERT INTO memoryUpkeep(name, at) VALUES (?, ?)", arguments: [Self.memorySlimming, Date()])
                return .commit
            }
        }
    }

    /// Puts away, once, the proposals that piled up while agents and the old migration suggested entries. The user
    /// never answered them and wanted them gone. Archived rather than deleted, so a proposal can still be brought back.
    public func archiveProposalsOnce() throws {
        try db.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM memoryUpkeep WHERE name = ?", arguments: [Self.proposalClearing]) == nil else { return }
            try db.execute(sql: """
                UPDATE memoryEntries SET state = 'archived' WHERE state = 'proposed';
                UPDATE memoryRoutines SET state = 'archived' WHERE state = 'proposed';
                UPDATE memorySections SET state = 'archived' WHERE state = 'proposed';
                """)
            try db.execute(sql: "INSERT INTO memoryUpkeep(name, at) VALUES (?, ?)", arguments: [Self.proposalClearing, Date()])
        }
    }

    static func slimMemory(_ db: Database) throws {
        // Text an agent app wrote in the person's place was read as theirs: a session's summary, a reminder.
        let chats = try Row.fetchAll(db, sql: "SELECT id, text FROM memoryUtterances WHERE sourceKind IN (?, ?)",
                                     arguments: [MemorySourceKind.claudeUser.rawValue, MemorySourceKind.codexUser.rawValue])
        for row in chats {
            let id: String = row["id"], text: String = row["text"]
            guard let words = MemoryUserMessages.words(in: text) else {
                try db.execute(sql: "DELETE FROM memoryUtterances WHERE id = ?", arguments: [id]); continue
            }
            if words != text { try db.execute(sql: "UPDATE memoryUtterances SET text = ? WHERE id = ?", arguments: [words, id]) }
        }
        // Moves nobody accepted. The ones the user accepted or put away are theirs and stay.
        try db.execute(sql: """
            UPDATE memoryUtterances SET moveId = NULL, situationId = NULL WHERE moveId IN (SELECT id FROM memoryMoves WHERE stage IN ('noticed', 'offered'));
            DELETE FROM memoryMoveOffers WHERE moveId IN (SELECT id FROM memoryMoves WHERE stage IN ('noticed', 'offered'));
            DELETE FROM memoryMoves WHERE stage IN ('noticed', 'offered');
            """)
        for space in try String.fetchAll(db, sql: "SELECT DISTINCT spaceId FROM memoryUnderstanding") {
            try trimMemoryUnderstanding(db, spaceID: space, keep: MemoryUnderstanding.kept)
        }
        try db.execute(sql: """
            DELETE FROM memoryUnderstandingHistory WHERE id IN (
                SELECT id FROM (SELECT id, row_number() OVER (PARTITION BY understandingId ORDER BY at DESC, id) AS place FROM memoryUnderstandingHistory)
                WHERE place > ?)
            """, arguments: [MemoryUnderstanding.keptVersions])
        // The first memory engine. Nothing has written to it since the curated memory replaced it. Its small
        // record of which sources it had read stays, because the capture queue still counts against it.
        try db.execute(sql: """
            DELETE FROM memoryUnitEntities; DELETE FROM memoryEntityPairs; DELETE FROM memoryLinks; DELETE FROM memoryObservationHistory;
            DELETE FROM memoryUnitSearch; DELETE FROM memoryUnits; DELETE FROM memoryEntities;
            """)
    }
}
