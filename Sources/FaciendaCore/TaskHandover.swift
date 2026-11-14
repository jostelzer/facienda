import Foundation
import GRDB

/// What the agent hands over at the end of a turn: the one line the user's row shows, the subject the work moved to,
/// and what it recommends they do. The agent knows all of this; reading it back out of the chat afterwards only loses it.
/// The recommendation is kept for the task's return card and shown nowhere on the board.
public struct TaskHandover: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "handovers"
    public var taskId: String
    /// What the user has to do now, verb first. Nil when nothing is open for them.
    public var wants: String?
    /// What came of the turn, when it asks the user for nothing.
    public var outcome: String?
    /// Where the thread stands now, in a word or three, written only when the subject changed. It follows the task's
    /// name on the row, so the name can stay the one the user recognises.
    public var tail: String?
    /// The move the agent recommends, why, a reply the user can send as it stands, and up to two alternatives.
    public var recommendation: String?
    public var why: String?
    public var reply: String?
    public var alternatives: [String]
    /// What in the workspace's memory the recommendation rests on, when it rests on memory at all.
    public var memory: String?
    public var at: Date

    public init(taskId: String, wants: String? = nil, outcome: String? = nil, tail: String? = nil, recommendation: String? = nil,
                why: String? = nil, reply: String? = nil, alternatives: [String] = [], memory: String? = nil, at: Date = Date()) {
        self.taskId = taskId; self.wants = wants; self.outcome = outcome; self.tail = tail
        self.recommendation = recommendation; self.why = why; self.reply = reply; self.alternatives = alternatives
        self.memory = memory; self.at = at
    }

    /// The line the row shows: what the task wants from the user, or else what came of the turn.
    public var line: String? { wants ?? outcome }

    /// Limits for what an agent writes here, so one row's line can never push the others out of shape.
    public static let wantsLimit = 80, outcomeLimit = 90, tailLimit = 24, recommendationLimit = 120
    public static let whyLimit = 240, replyLimit = 160, memoryLimit = 160, alternativeLimit = 120, alternativeCount = 2

    /// The agent's words as one line for the eye: markdown off, one line, cut to length. Empty becomes nil, so a blank
    /// field clears nothing by accident.
    public static func clean(_ raw: String?, _ limit: Int) -> String? {
        guard let raw else { return nil }
        let line = TaskHeadline.clip(raw, limit: limit).trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
        return line.isEmpty ? nil : line
    }

    /// The agent's words as it wrote them, only trimmed and cut. A reply the user sends as it stands, and a why that
    /// may name a file or a tool, keep their own punctuation and line breaks: clipping them turned task_update into
    /// taskupdate.
    public static func text(_ raw: String?, _ limit: Int) -> String? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

extension FaciendaStore {
    static func registerTurnHandovers(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("turn_handovers") { db in
            // Beside tasks, like recaps: a handover never changes a task's revision or activity date.
            try db.execute(sql: """
            CREATE TABLE handovers (
              taskId TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id), wants TEXT, outcome TEXT, tail TEXT,
              recommendation TEXT, why TEXT, reply TEXT, alternatives TEXT NOT NULL, memory TEXT, at DATETIME NOT NULL
            )
            """)
        }
    }

    public func handover(taskId: String) throws -> TaskHandover? { try db.read { try TaskHandover.fetchOne($0, key: taskId) } }
    public func handovers() throws -> [TaskHandover] { try db.read { try TaskHandover.fetchAll($0) } }

    /// The agent's handover for its task. A turn that says what it wants replaces the handover, recommendation included,
    /// so an old recommendation can never outlive the line it was written for; only the thread's tail carries over.
    /// A plain progress update in between leaves everything standing.
    @discardableResult public func saveHandover(taskId: String, _ change: (inout TaskHandover) -> Void, replacing: Bool, at: Date = Date()) throws -> TaskHandover {
        try write { db in
            guard try FaciendaTask.fetchOne(db, key: taskId) != nil else { throw StoreError.notFound }
            let existing = try TaskHandover.fetchOne(db, key: taskId)
            // The tail outlives the turn that wrote it: the agent writes one only when the subject moves, so where the
            // thread stands keeps standing until it moves again.
            var handover = replacing ? TaskHandover(taskId: taskId, tail: existing?.tail) : (existing ?? TaskHandover(taskId: taskId))
            change(&handover)
            handover.taskId = taskId
            handover.at = at
            try handover.save(db)
            return handover
        }
    }
}
