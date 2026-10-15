import Foundation
import GRDB

extension FaciendaStore {
    /// A phone request has the same stable ID as its task. Re-delivery never alters a task.
    /// It joins the scoped workspace the phone chose, not started: the user starts it on the Mac.
    /// An ID that belongs to a task the phone did not send is refused.
    @discardableResult public func receiveMobileRequest(id: String, text: String, createdAt: Date) throws -> FaciendaTask {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil, !text.isEmpty, text.count <= 20_000 else {
            throw StoreError.invalid("The mobile request is empty or invalid.")
        }
        return try write { db in
            if let existing = try FaciendaTask.fetchOne(db, key: id) {
                guard try Self.isMobileTask(db, id) else { throw StoreError.invalid("The mobile request reuses the ID of a task made on this Mac.") }
                return existing
            }
            var task = FaciendaTask(id: id, title: text, intention: text, state: .inbox, nextAction: text, returnAt: createdAt)
            task.createdAt = createdAt
            task.workspaceId = workspaceID
            try task.insert(db)
            try TaskEvent(taskId: id, source: .user, kind: "task.created", payload: text).insert(db)
            try TaskEvent(taskId: id, source: .user, kind: "mobile.received", payload: id).insert(db)
            return task
        }
    }

    /// The tasks the phone sent, each with the text it sent: all the companion shows of a task unless the user shares more.
    public func mobileRequestTexts() throws -> [String: String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.taskId, c.payload FROM events r LEFT JOIN events c ON c.taskId = r.taskId AND c.kind = 'task.created' AND c.source = 'user'
                WHERE r.kind = 'mobile.received' AND r.source = 'user' AND r.payload = r.taskId
                """)
            var texts: [String: String] = [:]
            for row in rows { if let id: String = row["taskId"], texts[id] == nil { texts[id] = row["payload"] ?? "" } }
            return texts
        }
    }

    static func isMobileTask(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM events WHERE taskId = ? AND kind = 'mobile.received' AND source = 'user' AND payload = taskId)", arguments: [id]) ?? false
    }
}
