import Foundation
import GRDB

/// One change this app made to the library, kept as the statements that take it back.
/// Replaying a step records its own reverse, so undo and redo are the same operation.
public struct UndoStep: Sendable {
    /// Newest first, so they run in the reverse order of the writes they undo.
    let statements: [String]
    public var isEmpty: Bool { statements.isEmpty }

    /// Runs the body and records what its writes change. Only this app's own writes are caught: the hook, the MCP
    /// helper and the runner write through other connections, so taking a step back never undoes their work.
    public static func recording(_ body: () throws -> Void) rethrows -> UndoStep {
        let recorder = UndoRecorder()
        try UndoRecorder.$current.withValue(recorder) { try body() }
        return recorder.step
    }
}

/// Collects the reverse of each write made while it is current, across however many transactions the body runs.
final class UndoRecorder: @unchecked Sendable {
    @TaskLocal static var current: UndoRecorder?
    private let lock = NSLock()
    private var batches: [[String]] = []

    func append(_ statements: [String]) {
        guard !statements.isEmpty else { return }
        lock.withLock { batches.append(statements) }
    }
    var step: UndoStep { lock.withLock { UndoStep(statements: batches.reversed().flatMap { $0 }) } }
}

/// Temporary triggers on the app's write connection that log the reverse of every change, the way SQLite's own
/// undo/redo example does. They exist only for the length of a recorded transaction.
enum UndoLog {
    /// The tables a step can touch. Search indexes rebuild themselves from the tables' own triggers.
    static func tables(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM pragma_table_list WHERE schema = 'main' AND type = 'table'")
            .filter { !$0.hasPrefix("sqlite_") && !$0.hasPrefix("grdb_") }
    }

    static func start(_ db: Database) throws {
        try db.execute(sql: "CREATE TEMP TABLE undoLog (seq INTEGER PRIMARY KEY, statement TEXT NOT NULL)")
        for table in try tables(db) {
            let columns = try db.columns(in: table).map(\.name)
            let name = quoted(table)
            let list = (["rowid"] + columns.map(quoted)).joined(separator: ",")
            let values = (["old.rowid"] + columns.map { "quote(old.\(quoted($0)))" }).joined(separator: " || ',' || ")
            // An undone update only puts back the columns it changed, so a helper's later edit to the same row survives.
            // The revision keeps counting up: undoing is another change, not time travel.
            // Rows are found by rowid and checked by primary key, so a rowid SQLite handed to a newer row is left alone.
            let key = try db.primaryKey(table).columns.filter { $0 != "rowid" }
            let match = { (row: String) -> String in (["'rowid=' || \(row).rowid"] + key.map { "' AND \(literal(quoted($0)))=' || quote(\(row).\(quoted($0)))" }).joined(separator: " || ") }
            let sets = columns.map { column -> String in
                let field = quoted(column)
                if column == "revision" { return "CASE WHEN old.\(field) IS NOT new.\(field) THEN '\(field)=\(field)+1,' ELSE '' END" }
                return "CASE WHEN old.\(field) IS NOT new.\(field) THEN '\(field)=' || quote(old.\(field)) || ',' ELSE '' END"
            }.joined(separator: " || ")
            try db.execute(sql: """
            CREATE TEMP TRIGGER \(quoted("undo_insert_" + table)) AFTER INSERT ON main.\(name) BEGIN
              INSERT INTO undoLog(statement) VALUES ('DELETE FROM \(literal(name)) WHERE ' || \(match("new")));
            END;
            CREATE TEMP TRIGGER \(quoted("undo_delete_" + table)) AFTER DELETE ON main.\(name) BEGIN
              INSERT INTO undoLog(statement) VALUES ('INSERT INTO \(literal(name))(\(literal(list))) VALUES(' || \(values) || ')');
            END;
            CREATE TEMP TRIGGER \(quoted("undo_update_" + table)) AFTER UPDATE ON main.\(name) BEGIN
              INSERT INTO undoLog(statement) VALUES ('UPDATE \(literal(name)) SET ' || \(sets) || 'rowid=' || old.rowid || ' WHERE ' || \(match("new")));
            END;
            """)
        }
    }

    /// Ends recording and hands back the reverse statements, oldest first.
    static func stop(_ db: Database) throws -> [String] {
        let statements = try String.fetchAll(db, sql: "SELECT statement FROM undoLog ORDER BY seq")
        for table in try tables(db) {
            for kind in ["insert", "delete", "update"] { try db.execute(sql: "DROP TRIGGER IF EXISTS temp.\(quoted("undo_\(kind)_" + table))") }
        }
        try db.execute(sql: "DROP TABLE temp.undoLog")
        return statements
    }

    private static func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    /// Text placed inside a single-quoted SQL string.
    private static func literal(_ text: String) -> String { text.replacingOccurrences(of: "'", with: "''") }
}

extension FaciendaStore {
    /// Takes a recorded step back and returns the step that puts it forward again.
    /// Fails without changing anything if the library moved on in a way that conflicts, such as a row taken again.
    public func replay(_ step: UndoStep) throws -> UndoStep {
        guard !step.isEmpty else { return step }
        return try UndoStep.recording {
            try write { db in
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                for statement in step.statements { try db.execute(sql: statement) }
            }
        }
    }
}
