import Foundation
import CryptoKit
import GRDB

public struct DispatchContext: Codable, Equatable, Sendable {
    public enum Route: String, Codable, Sendable { case new, reuse, blocked }
    public enum SearchStatus: String, Codable, Sendable { case complete, limited, blocked }
    public struct Project: Codable, Equatable, Sendable {
        public var id: String
        public var path: String
        public var reason: String
    }
    public struct Evidence: Codable, Equatable, Sendable {
        public var sourceReference: String
        public var excerpt: String
        public var supports: String
    }
    public struct Chat: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case owner, background }
        public enum Status: String, Codable, Sendable { case idle, active, awaitingUser, archived, unknown }
        public var threadId: String
        public var title: String
        public var projectId: String?
        public var hostId: String?
        public var role: Role
        public var status: Status
        public var relevance: String
        public var evidence: [Evidence]
        public var url: String {
            let id = threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
            return "codex://threads/" + id
        }
    }
    public var contextKey: String
    public var searchStatus: SearchStatus
    public var searchSummary: String
    public var route: Route
    public var project: Project?
    public var chats: [Chat]
    public var uncertainties: [String]
    public var owner: Chat? { chats.first { $0.role == .owner } }

    public static func key(task: FaciendaTask, dispatch: NativeDispatch) -> String {
        var fields: [JSONValue] = [task.id, task.title, task.intention, task.definitionOfDone, task.nextAction, task.brief, task.area,
                                      task.cwd ?? "", task.automationScope.rawValue, dispatch.message ?? "", dispatch.kind ?? "start"].map(JSONValue.string)
        if let attachments = task.attachments, !attachments.isEmpty {
            fields.append(.array(attachments.map { .object(["name": .string($0.name), "path": .string($0.path)]) }))
        }
        if let folders = task.folders, !folders.isEmpty { fields.append(.object(["folders": .array(folders.map(JSONValue.string))])) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Object key order must not change the identity of an unchanged request.
        let data = try! encoder.encode(JSONValue.array(fields))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension FaciendaStore {
    public func dispatchContext(_ id: String) throws -> DispatchContext? {
        try db.read { try Self.readDispatchContext($0, id: id) }
    }
    public func latestDispatchContext(taskId: String) throws -> DispatchContext? {
        try db.read { db in
            guard let text = try String.fetchOne(db, sql: "SELECT payload FROM dispatchContext WHERE taskId = ? ORDER BY savedAt DESC LIMIT 1", arguments: [taskId]) else { return nil }
            return try JSONDecoder().decode(DispatchContext.self, from: Data(text.utf8))
        }
    }
    public func excludedOwningThreads(taskId: String) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT e.threadId FROM events e WHERE e.taskId = ? AND e.kind = 'thread.unlinked' AND e.threadId IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM threadLinks l WHERE l.taskId = e.taskId AND l.codexThreadId = e.threadId)
                """, arguments: [taskId])
        }
    }
    static func readDispatchContext(_ db: Database, id: String) throws -> DispatchContext? {
        guard let text = try String.fetchOne(db, sql: "SELECT payload FROM dispatchContext WHERE dispatchId = ?", arguments: [id]) else { return nil }
        return try JSONDecoder().decode(DispatchContext.self, from: Data(text.utf8))
    }

    /// Runner-attested discovery, with original excerpts. Never silently promotes a
    /// background reference to ownership or treats the receipt as user authorization.
    public func saveDispatchContext(_ context: DispatchContext, dispatchId: String, runnerId: String) throws {
        let encoded = try JSONValue.encoded(context).json
        guard encoded.utf8.count <= 32_000, !context.searchSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.chats.count <= 6, context.uncertainties.count <= 10,
              Set(context.chats.map(\.threadId)).count == context.chats.count,
              context.chats.filter({ $0.role == .owner }).count <= 1 else {
            throw StoreError.invalid("Save a bounded discovery summary with unique chat references.")
        }
        for chat in context.chats {
            guard !chat.threadId.isEmpty, !chat.title.isEmpty, !chat.relevance.isEmpty,
                  !chat.evidence.isEmpty, chat.evidence.count <= 3,
                  chat.evidence.allSatisfy({ !$0.sourceReference.isEmpty && !$0.excerpt.isEmpty && $0.excerpt.count <= 1200 && !$0.supports.isEmpty }) else {
                throw StoreError.invalid("Every related chat needs its exact title, relevance and a bounded excerpt with a source reference.")
            }
        }
        guard context.route != .reuse || context.owner != nil,
              context.route != .new || context.owner == nil,
              context.searchStatus != .blocked || context.route == .blocked else { throw StoreError.invalid("Discovery route and ownership disagree.") }
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: dispatchId), item.state == "claimed", item.runnerId == runnerId,
                  try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") == runnerId,
                  let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen,
                  context.contextKey == DispatchContext.key(task: task, dispatch: item) else { throw StoreError.conflict }
            if let expected = item.threadId {
                guard context.route != .new, context.owner?.threadId == expected else {
                    throw StoreError.invalid("Preserve the owning chat; related context cannot replace it.")
                }
            }
            if let owner = context.owner {
                guard owner.threadId != runnerId, owner.hostId == nil || owner.hostId == "local" else {
                    throw StoreError.invalid("Reuse a local task chat, not the runner or a remote chat.")
                }
                if let link = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [owner.threadId]), link.taskId != task.id {
                    throw StoreError.invalid("That chat already owns another Facienda task. Keep it as a background reference.")
                }
                try Self.validateOwner(db, taskId: task.id, threadId: owner.threadId)
                if context.route == .reuse {
                    guard owner.status != .archived && owner.status != .unknown else { throw StoreError.invalid("An archived or unverified chat cannot be adopted.") }
                    if let project = context.project, project.id != owner.projectId { throw StoreError.invalid("Reused chats keep their existing project.") }
                    item.threadId = owner.threadId
                    try item.update(db)
                }
            }
            // Folders the user linked to the task's group decide where a new chat works.
            if context.route == .new, let folders = task.folders, folders.count > 1 {
                let path = context.project.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
                guard let path, folders.contains(path) else {
                    throw StoreError.invalid("Start this task in the project spanning its group's linked folders, at \(folders[0]).")
                }
            }
            if let project = context.project {
                guard !project.id.isEmpty, project.path.hasPrefix("/"), !project.reason.isEmpty else { throw StoreError.invalid("Record the verified local project ID, path and routing reason.") }
                if context.route == .new, let cwd = task.cwd,
                   !isAutomaticWorkingDirectory(cwd, taskID: task.id) {
                    let root = URL(fileURLWithPath: project.path).standardizedFileURL.path
                    let working = URL(fileURLWithPath: cwd).standardizedFileURL.path
                    guard working == root || working.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                        throw StoreError.invalid("The discovered project must preserve the task's explicitly selected working folder.")
                    }
                }
            } else if context.route == .new, task.cwd.map({ isAutomaticWorkingDirectory($0, taskID: task.id) }) ?? true,
                      try WorkspaceSetup.fetchOne(db, sql: "SELECT * FROM workspaceSetup WHERE id = 1") != nil {
                // A folder the user chose may lie outside every Codex project; a task's own folder never does.
                throw StoreError.invalid("Choose a verified local project or the configured workspace project.")
            }
            try db.execute(sql: "INSERT INTO dispatchContext(dispatchId, taskId, payload, savedAt) VALUES (?, ?, ?, ?) ON CONFLICT(dispatchId) DO UPDATE SET payload = excluded.payload, savedAt = excluded.savedAt", arguments: [item.id, task.id, encoded, Date()])
            try TaskEvent(taskId: task.id, source: .mcp, kind: "context.discovered", payload: encoded, verified: false).insert(db)
        }
    }

    static func validateDispatchContext(_ db: Database, item: NativeDispatch, task: FaciendaTask) throws {
        // Timed checks stay with their saved owner and use the last contextual handoff.
        guard item.kind != "check" else { return }
        guard let context = try readDispatchContext(db, id: item.id),
              context.contextKey == DispatchContext.key(task: task, dispatch: item),
              context.route != .blocked, context.searchStatus != .blocked else {
            throw StoreError.invalid("Complete and save current chat discovery before dispatching this request.")
        }
        if context.route == .reuse {
            guard context.owner?.threadId == item.threadId, context.owner?.status == .idle,
                  let saved = try Date.fetchOne(db, sql: "SELECT savedAt FROM dispatchContext WHERE dispatchId = ?", arguments: [item.id]),
                  Date().timeIntervalSince(saved) < 900 else {
                throw StoreError.invalid("Recheck the owning chat: it must be idle, available and not awaiting the user.")
            }
            try validateOwner(db, taskId: task.id, threadId: item.threadId!)
        } else if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM threadLinks WHERE taskId = ? AND role = 'work')", arguments: [task.id]) == true {
            throw StoreError.invalid("This task now has an owning chat. Refresh discovery instead of creating another.")
        }
    }

    private static func validateOwner(_ db: Database, taskId: String, threadId: String) throws {
        if let link = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [threadId]) {
            guard link.taskId == taskId else { throw StoreError.invalid("The selected chat now belongs to another task.") }
        } else if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM events WHERE taskId = ? AND threadId = ? AND kind = 'thread.unlinked')", arguments: [taskId, threadId]) == true {
            throw StoreError.invalid("The user unlinked this chat. Only the user can link it again.")
        }
    }
}
