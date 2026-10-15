import Foundation
import GRDB

/// A task's capability handle, `TASK-ID.SECRET`: its ID and a random secret only that task's own Facienda instructions
/// carry. Every tool that reads or changes a task's private data takes the handle, so a chat reaches its own task only,
/// whatever task IDs it has seen.
public enum TaskHandle {
    /// Hex characters of a secret: 128 random bits.
    static let secretLength = 32
    static let missing = "Pass taskId: this task's Facienda handle, from your latest Facienda instructions."
    static let bare = "taskId must be this task's Facienda handle (TASK-ID.SECRET), not a bare task ID. Use the handle from your latest Facienda instructions."
    static let invalid = "This taskId is not a valid Facienda task handle. Use the handle from your latest Facienda instructions; a handle reaches only its own task."

    /// The task ID and secret of a well-formed handle.
    static func parts(_ handle: String) -> (taskId: String, secret: String)? {
        guard let dot = handle.lastIndex(of: ".") else { return nil }
        let id = String(handle[..<dot]), secret = String(handle[handle.index(after: dot)...])
        guard !id.isEmpty, secret.utf8.count == secretLength, secret.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return (id, secret)
    }

    static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<secretLength / 2).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// Compares in time independent of where the two differ.
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return x.indices.reduce(UInt8(0)) { $0 | (x[$1] ^ y[$1]) } == 0
    }

    /// Text with every handle but `keeping` cut back to its bare task ID, so no tool output or prompt passes on
    /// another task's handle.
    public static func redact(_ text: String, keeping: String? = nil) -> String {
        guard text.contains(".") else { return text }
        return text.replacing(/([0-9A-Za-z][0-9A-Za-z-]{7,})\.[0-9a-f]{32}/) { match in
            String(match.output.0) == keeping ? String(match.output.0) : String(match.output.1)
        }
    }

    /// Every string in a JSON value, redacted.
    public static func redact(_ value: JSONValue, keeping: String? = nil) -> JSONValue {
        switch value {
        case .string(let text): .string(redact(text, keeping: keeping))
        case .array(let items): .array(items.map { redact($0, keeping: keeping) })
        case .object(let fields): .object(fields.mapValues { redact($0, keeping: keeping) })
        default: value
        }
    }
}

extension FaciendaStore {
    static func registerTaskHandles(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("task_handles") { db in
            try db.execute(sql: "CREATE TABLE taskHandles (taskId TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id), secret TEXT NOT NULL, createdAt DATETIME NOT NULL)")
        }
    }

    /// The task's handle, made the first time a chat is told about the task.
    public func taskHandle(_ taskId: String) throws -> String {
        let query = "SELECT secret FROM taskHandles WHERE taskId = ?"
        if let saved = try db.read({ try String.fetchOne($0, sql: query, arguments: [taskId]) }) { return taskId + "." + saved }
        let secret = try write { db -> String in
            guard try FaciendaTask.exists(db, key: taskId) else { throw StoreError.notFound }
            if let saved = try String.fetchOne(db, sql: query, arguments: [taskId]) { return saved }
            let secret = TaskHandle.newSecret()
            try db.execute(sql: "INSERT INTO taskHandles(taskId, secret, createdAt) VALUES (?, ?, ?)", arguments: [taskId, secret, Date()])
            return secret
        }
        return taskId + "." + secret
    }

    /// The task a handle opens. A bare task ID, another task's secret or a made-up one opens nothing.
    public func taskID(forHandle handle: String) throws -> String {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else { throw StoreError.invalid(TaskHandle.missing) }
        guard let (id, secret) = TaskHandle.parts(handle) else { throw StoreError.invalid(TaskHandle.bare) }
        let saved = try db.read { try String.fetchOne($0, sql: "SELECT secret FROM taskHandles WHERE taskId = ?", arguments: [id]) }
        // An unknown task is compared against a stand-in, so it takes as long as a wrong secret.
        guard TaskHandle.matches(saved ?? String(repeating: "-", count: TaskHandle.secretLength), secret), saved != nil else {
            throw StoreError.invalid(TaskHandle.invalid)
        }
        return id
    }
}
