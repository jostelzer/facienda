import Foundation
import GRDB

public struct MemoryRedactionSummary: Codable, Equatable, Sendable {
    public var documents = 0
    public var events = 0
    public var notes = 0
    public var errors = 0
    public var total: Int { documents + events + notes + errors }
}

extension FaciendaStore {
    /// Explicit maintenance, never an opening migration. The preview and result contain counts only.
    public func redactStoredMemory(spaceID: String, apply: Bool = false) throws -> MemoryRedactionSummary {
        try db.write { try Self.redactStoredMemory($0, spaceID: spaceID, apply: apply) }
    }

    static func redactStoredMemory(_ db: Database, spaceID: String, apply: Bool) throws -> MemoryRedactionSummary {
        _ = try Self.memorySpace(db, spaceID)
        var counts = MemoryRedactionSummary()
        for var document in try MemoryDocument.fetchAll(db, sql: "SELECT * FROM memoryDocuments WHERE spaceId = ?", arguments: [spaceID]) {
            let content = MemoryRedaction.redact(document.content), source = MemoryRedaction.redact(document.source)
            guard content != document.content || source != document.source || document.error.map(MemoryRedaction.redact) != document.error else { continue }
            counts.documents += 1
            if apply {
                document.content = content; document.source = source
                try db.execute(sql: "UPDATE memoryDocuments SET content = ?, source = ?, digest = ?, error = NULL WHERE id = ?",
                               arguments: [content, source, MemoryChunker.digest(content), document.id])
            }
        }
        for event in try TaskEvent.fetchAll(db, sql: """
            SELECT e.* FROM events e JOIN tasks t ON t.id = e.taskId JOIN workspaces w ON w.id = t.workspaceId WHERE w.memorySpaceId = ?
            """, arguments: [spaceID]) {
            let payload = MemoryRedaction.payload(event.payload)
            guard payload != event.payload else { continue }
            counts.events += 1
            if apply { try db.execute(sql: "UPDATE events SET payload = ? WHERE id = ?", arguments: [payload, event.id]) }
        }
        for note in try MemoryFact.fetchAll(db, sql: "SELECT * FROM memoryFacts WHERE spaceId = ?", arguments: [spaceID]) {
            let text = MemoryRedaction.redact(note.text), source = MemoryRedaction.redact(note.source)
            guard text != note.text || source != note.source else { continue }
            counts.notes += 1
            if apply { try db.execute(sql: "UPDATE memoryFacts SET text = ?, source = ? WHERE id = ?", arguments: [text, source, note.id]) }
        }
        for row in try Row.fetchAll(db, sql: "SELECT documentId, error FROM memoryRetained WHERE spaceId = ? AND error IS NOT NULL", arguments: [spaceID]) {
            let error: String = row["error"], clean = MemoryRedaction.redact(error)
            guard clean != error else { continue }
            counts.errors += 1
            if apply { try db.execute(sql: "UPDATE memoryRetained SET error = ? WHERE documentId = ?", arguments: [clean, row["documentId"] as String]) }
        }
        return counts
    }
}
