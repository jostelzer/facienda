import Foundation
import GRDB

/// Something a running Codex turn asks before it goes on: run a command, change files, get more access, call a tool,
/// or answer a question. A turn Facienda's dispatcher started runs in Codex's shared app server, where only the
/// dispatcher hears it ask, and the Codex app shows that chat read-only until the turn ends. So the question is kept
/// here, answered in Facienda, and the dispatcher passes the answer on.
public struct CodexApproval: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "codexApprovals"
    public enum Kind: Sendable { case command, fileChange, permissions, toolCall, question, other }
    /// What the user can answer. Each kind offers the choices that make sense for it.
    public enum Choice: String, Sendable, CaseIterable { case allow, allowForChat, decline }

    public var id: String
    public var taskId: String?
    public var threadId: String
    public var turnId: String
    public var itemId: String
    public var method: String
    /// The request as Codex sent it.
    public var params: String
    /// The request's ID on the dispatcher's current connection; a reconnect hands it a new one.
    public var requestId: String
    public var requestedAt: Date
    /// The response to send, once the user answered.
    public var response: String?
    public var answeredAt: Date?
    public var sentAt: Date?
    public var closedAt: Date?

    public var request: JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(params.utf8))) ?? .null }
    public var kind: Kind {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval": .command
        case "item/fileChange/requestApproval", "applyPatchApproval": .fileChange
        case "item/permissions/requestApproval": .permissions
        case "mcpServer/elicitation/request": .toolCall
        case "item/tool/requestUserInput": .question
        default: .other
        }
    }
    /// The requests Facienda can answer. Anything else stays with the turn until it ends.
    public static let methods: Set<String> = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                                             "item/permissions/requestApproval", "mcpServer/elicitation/request", "item/tool/requestUserInput"]

    /// One line saying what Codex wants to do.
    public var summary: String {
        let request = request
        switch kind {
        case .command: return request["command"].string.map { "Run \($0)" } ?? "Run a command"
        case .fileChange: return request["grantRoot"].string.map { "Change files in \($0)" } ?? "Change files"
        case .permissions: return "Get more access to files or the network"
        case .toolCall: return request["message"].string ?? "Use a tool"
        case .question: return request["questions"].array?.first?["question"].string ?? "Answer a question"
        case .other: return method
        }
    }
    /// Why, when Codex said so.
    public var reason: String? {
        let request = request
        return request["reason"].string ?? (kind == .command ? request["cwd"].string.map { "In \($0)" } : nil)
    }

    /// One file a change would touch: its path, what happens to it, and the diff when the request carries one.
    public struct FileChange: Equatable, Sendable {
        public var path: String
        public var change: String
        public var diff: String?
    }

    /// Everything the card shows, read from the request and made safe to read. The request is written by the agent,
    /// so it is shown in full, invisible characters are made visible, and the agent's reason never stands in for
    /// what would actually run. When the request does not say exactly what Allow would permit, `gap` says so and
    /// the card offers only Decline.
    public struct Display: Equatable, Sendable {
        public var title: String
        public var command: String?
        public var cwd: String?
        public var reason: String?
        public var files: [FileChange] = []
        /// Extra write access a file change asks for along with it.
        public var grantRoot: String?
        public var permissions: [String] = []
        public var gap: String?
        public var canAllow: Bool { gap == nil }
    }

    public var display: Display {
        let request = request
        let reason = request["reason"].string.map(Self.visible)
        let cwd = request["cwd"].string.map(Self.visible)
        switch kind {
        case .command:
            var shown = Display(title: "Run a command", cwd: cwd, reason: reason)
            if let line = request["command"].string { shown.command = Self.visible(line) }
            else if let argv = request["command"].array, !argv.isEmpty, argv.allSatisfy({ $0.string != nil }) {
                shown.command = Self.visible(argv.compactMap(\.string).map(Self.shellWord).joined(separator: " "))
            }
            if shown.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { shown.command = nil; shown.gap = "Codex did not say which command it wants to run." }
            else if cwd == nil { shown.gap = "Codex did not say which folder the command runs in." }
            return shown
        case .fileChange:
            var shown = Display(title: "Change files", cwd: cwd, reason: reason, grantRoot: request["grantRoot"].string.map(Self.visible))
            if let changes = request["changes"].array {
                shown.files = changes.compactMap { change in
                    guard let path = change["path"].string else { return nil }
                    let kind = change["kind"]["type"].string ?? change["kind"].string ?? change["type"].string ?? "change"
                    let moved = change["kind"]["move_path"].string ?? change["kind"]["movePath"].string
                    return FileChange(path: Self.visible(path), change: Self.visible(kind + (moved.map { " → " + $0 } ?? "")),
                                      diff: (change["diff"].string ?? change["unified_diff"].string).map(Self.visible))
                }
            } else if let changes = request["fileChanges"].object {
                shown.files = changes.keys.sorted().map { path in
                    let change = changes[path] ?? .null
                    let kind = change["type"].string ?? change.object?.keys.sorted().first ?? "change"
                    let body = change["unified_diff"].string ?? change["content"].string ?? change[kind]["unified_diff"].string ?? change[kind]["content"].string
                    let moved = change["move_path"].string ?? change[kind]["move_path"].string
                    return FileChange(path: Self.visible(path), change: Self.visible(kind + (moved.map { " → " + $0 } ?? "")), diff: body.map(Self.visible))
                }
            }
            if shown.files.isEmpty { shown.gap = "Codex did not list the files it wants to change. Look at the change in Codex, or decline." }
            return shown
        case .permissions:
            var shown = Display(title: "Get more access", cwd: cwd, reason: reason)
            shown.permissions = Self.lines(request["permissions"])
            if shown.permissions.isEmpty { shown.gap = "Codex did not say which access it wants." }
            return shown
        case .toolCall:
            var shown = Display(title: Self.visible(request["message"].string ?? "Use a tool"), cwd: cwd, reason: reason)
            if let server = request["serverName"].string { shown.permissions = ["Tool server: " + Self.visible(server)] }
            if request["message"].string?.isEmpty != false { shown.gap = "The tool did not say what it wants to do." }
            return shown
        case .question:
            return Display(title: Self.visible(summary), cwd: cwd, reason: reason)
        case .other:
            return Display(title: Self.visible(method), cwd: cwd, reason: reason, gap: "Facienda can't show this kind of request.")
        }
    }

    /// Requested access as readable lines, one per setting: `fileSystem · write: /a, /b`.
    static func lines(_ value: JSONValue, path: [String] = []) -> [String] {
        let label = path.map(visible).joined(separator: " · ")
        switch value {
        case .object(let fields):
            return fields.keys.sorted().flatMap { lines(fields[$0] ?? .null, path: path + [$0]) }
        case .array(let items):
            guard !items.isEmpty else { return [label + ": none"] }
            if items.allSatisfy({ $0.string != nil || $0.number != nil || $0.bool != nil }) {
                return [label + ": " + items.map { scalar($0) }.joined(separator: ", ")]
            }
            return items.enumerated().flatMap { lines($1, path: path + ["\($0 + 1)"]) }
        case .null:
            return path.isEmpty ? [] : [label + ": none"]
        default:
            return [(label.isEmpty ? "" : label + ": ") + scalar(value)]
        }
    }

    private static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): visible(text)
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let flag): flag ? "yes" : "no"
        default: visible(value.json)
        }
    }

    /// One argument as a shell would need it written, quoted only when it has to be.
    static func shellWord(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./+-@%=:,")
        return !text.isEmpty && text.unicodeScalars.allSatisfy(plain.contains) ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Text with characters that hide or reorder what is shown (zero-width, bidi controls, other control characters) written out as ⟨U+202E⟩.
    public static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let hidden = (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0xFEFF
                || v == 0x061C || v == 0x00AD || v == 0x2028 || v == 0x2029 || (0x2060...0x2064).contains(v)
                || (v < 0x20 && v != 0x0A && v != 0x09) || (0x7F...0x9F).contains(v)
            if hidden { out += String(format: "⟨U+%04X⟩", v) } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }
    /// The choices this request offers. A question is answered with its own options instead.
    public var choices: [Choice] {
        switch kind {
        case .command, .fileChange: [.allow, .allowForChat, .decline]
        case .permissions: [.allow, .allowForChat, .decline]
        case .toolCall: request["_meta"]["persist"].string == "session" || request["_meta"]["persist"].array?.contains(.string("session")) == true ? [.allow, .allowForChat, .decline] : [.allow, .decline]
        case .question, .other: []
        }
    }

    /// The response Codex expects for a choice.
    public func response(for choice: Choice) throws -> JSONValue {
        switch kind {
        case .command, .fileChange:
            return .object(["decision": .string(choice == .allow ? "accept" : choice == .allowForChat ? "acceptForSession" : "decline")])
        case .permissions:
            guard choice != .decline else { return .object(["permissions": .object([:]), "scope": .string("turn")]) }
            return .object(["permissions": request["permissions"], "scope": .string(choice == .allowForChat ? "session" : "turn")])
        case .toolCall:
            guard choice != .decline else { return .object(["action": .string("decline"), "content": .null]) }
            var answer: [String: JSONValue] = ["action": .string("accept"), "content": .object([:])]
            if choice == .allowForChat { answer["_meta"] = .object(["persist": .string("session")]) }
            return .object(answer)
        case .question, .other:
            throw StoreError.invalid("Answer this question with its own options.")
        }
    }

    /// The response to a question: one answer for each of its questions, by ID.
    public func response(answers: [String: String]) throws -> JSONValue {
        guard kind == .question else { throw StoreError.invalid("This request is not a question.") }
        let questions = request["questions"].array ?? []
        var result: [String: JSONValue] = [:]
        for question in questions {
            guard let id = question["id"].string, let answer = answers[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                throw StoreError.invalid("Answer every question.")
            }
            result[id] = .object(["answers": .array([.string(answer)])])
        }
        return .object(["answers": .object(result)])
    }
}

extension FaciendaStore {
    static func registerCodexApprovals(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("codex_approvals") { db in
            try db.execute(sql: """
                CREATE TABLE codexApprovals (
                  id TEXT PRIMARY KEY NOT NULL, taskId TEXT, threadId TEXT NOT NULL, turnId TEXT NOT NULL, itemId TEXT NOT NULL,
                  method TEXT NOT NULL, params TEXT NOT NULL, requestId TEXT NOT NULL, requestedAt DATETIME NOT NULL,
                  response TEXT, answeredAt DATETIME, sentAt DATETIME, closedAt DATETIME);
                CREATE UNIQUE INDEX codexApprovalsItem ON codexApprovals(threadId, turnId, itemId);
                """)
        }
    }

    /// Keeps a request Codex sent. The same request sent again after a reconnect keeps its answer and only takes the new ID.
    @discardableResult public func recordCodexApproval(method: String, params: JSONValue, requestId: JSONValue, now: Date = Date()) throws -> CodexApproval {
        guard let thread = params["threadId"].string, let turn = params["turnId"].string else { throw StoreError.invalid("The request names no chat.") }
        let item = params["itemId"].string ?? params["approvalId"].string ?? requestId.json
        return try write { db in
            if var existing = try CodexApproval.fetchOne(db, sql: "SELECT * FROM codexApprovals WHERE threadId = ? AND turnId = ? AND itemId = ?", arguments: [thread, turn, item]) {
                existing.requestId = requestId.json
                // An answer already sent on the old connection never arrived; it goes again on this one.
                if existing.closedAt == nil { existing.sentAt = nil }
                try existing.update(db)
                return existing
            }
            // A check running in a copy of its task's chat asks for that task.
            let task = try String.fetchOne(db, sql: "SELECT taskId FROM threadLinks WHERE codexThreadId = ?", arguments: [thread])
                ?? String.fetchOne(db, sql: "SELECT taskId FROM dispatches WHERE threadId = ? AND kind = 'check' ORDER BY requestedAt DESC LIMIT 1", arguments: [thread])
            let approval = CodexApproval(id: UUID().uuidString, taskId: task, threadId: thread, turnId: turn, itemId: item, method: method,
                                         params: params.json, requestId: requestId.json, requestedAt: now)
            try approval.insert(db)
            try observe(db, threadId: thread, status: "waitingOnApproval", source: .app, verified: true, at: now)
            if let task { try TaskEvent(taskId: task, threadId: thread, source: .app, kind: "approval.requested", payload: approval.summary).insert(db) }
            return approval
        }
    }

    /// Requests still waiting for the user, oldest first.
    public func openCodexApprovals(taskId: String? = nil) throws -> [CodexApproval] {
        try db.read { db in
            if let taskId {
                return try CodexApproval.fetchAll(db, sql: "SELECT * FROM codexApprovals WHERE taskId = ? AND response IS NULL AND closedAt IS NULL ORDER BY requestedAt", arguments: [taskId])
            }
            return try CodexApproval.fetchAll(db, sql: "SELECT * FROM codexApprovals WHERE response IS NULL AND closedAt IS NULL ORDER BY requestedAt")
        }
    }

    /// The user's answer. The dispatcher sends it to Codex.
    public func answerCodexApproval(_ id: String, response: JSONValue, now: Date = Date()) throws {
        try write { db in
            guard var approval = try CodexApproval.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard approval.closedAt == nil else { throw StoreError.invalid("Codex no longer waits for this answer.") }
            guard approval.response == nil else { return }
            approval.response = response.json; approval.answeredAt = now
            try approval.update(db)
            try observe(db, threadId: approval.threadId, status: "active", source: .app, verified: true, at: now)
            if let task = approval.taskId { try TaskEvent(taskId: task, threadId: approval.threadId, source: .user, kind: "approval.answered", payload: approval.summary).insert(db) }
        }
    }

    /// Answers the dispatcher has not passed on yet.
    public func codexApprovalsToSend() throws -> [CodexApproval] {
        try db.read { try CodexApproval.fetchAll($0, sql: "SELECT * FROM codexApprovals WHERE response IS NOT NULL AND sentAt IS NULL AND closedAt IS NULL ORDER BY answeredAt") }
    }

    public func markCodexApprovalSent(_ id: String, now: Date = Date()) throws {
        try write { db in
            try db.execute(sql: "UPDATE codexApprovals SET sentAt = ?, closedAt = ? WHERE id = ?", arguments: [now, now, id])
        }
    }

    /// Codex stopped waiting: the turn ended, or the request was settled elsewhere. Pass `requestId` to close only that one.
    public func closeCodexApprovals(threadId: String, requestId: JSONValue? = nil, now: Date = Date()) throws {
        try write { db in
            if let requestId {
                try db.execute(sql: "UPDATE codexApprovals SET closedAt = ? WHERE threadId = ? AND requestId = ? AND closedAt IS NULL", arguments: [now, threadId, requestId.json])
            } else {
                try db.execute(sql: "UPDATE codexApprovals SET closedAt = ? WHERE threadId = ? AND closedAt IS NULL", arguments: [now, threadId])
            }
        }
    }

    /// Chats whose turns the dispatcher should follow after it connects: those it delivered to lately, and any
    /// still waiting for an answer.
    public func codexChatsToFollow(since: Date) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT threadId FROM dispatches WHERE runnerId = ? AND state IN ('started', 'finished') AND threadId IS NOT NULL AND requestedAt >= ?
                UNION SELECT threadId FROM codexApprovals WHERE closedAt IS NULL
                """, arguments: [Self.codexDispatcherId, since])
        }
    }
}
