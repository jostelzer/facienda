import Foundation
import GRDB

/// A chat a task can continue in: a Codex thread or a Claude app session, picked by the user or linked in a task's answer.
public struct ChatCandidate: Codable, Equatable, Sendable {
    /// The app's own chat ID: a Codex thread, or the Claude app's `local_…` session.
    public var threadId: String
    public var provider: AgentProvider
    public var title: String
    public var cwd: String?
    /// A Claude session's Claude Code ID, which names its transcript.
    public var cliSessionId: String?

    public init(threadId: String, provider: AgentProvider, title: String, cwd: String? = nil, cliSessionId: String? = nil) {
        self.threadId = threadId; self.provider = provider; self.title = title; self.cwd = cwd; self.cliSessionId = cliSessionId
    }
}

extension FaciendaStore {
    static func registerHandovers(_ migrator: inout DatabaseMigrator) {
        // A test build kept agents' proposed chats in a table of their own; links in answers replaced it.
        migrator.registerMigration("chat_handovers_dropped") { db in try db.execute(sql: "DROP TABLE IF EXISTS chatHandovers") }
    }

    /// The task continues in `chat`: it becomes the task's chat and replaces the one it had, so replies, checks and the
    /// conversation all follow it. The replaced chat leaves the task and is never sent anything again. A chat belongs to one task.
    @discardableResult public func handOver(taskId: String, to chat: ChatCandidate, source: EventSource = .user, now: Date = Date()) throws -> ThreadLink {
        try write { db in try Self.handOver(db, taskId: taskId, to: chat, source: source, now: now) }
    }

    static func handOver(_ db: Database, taskId: String, to chat: ChatCandidate, source: EventSource, now: Date) throws -> ThreadLink {
        guard var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.invalid("The task is closed or missing.") }
        try validateCandidate(db, taskId: taskId, chat: chat)
        if try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND state IN ('claimed', 'dispatching')", arguments: [taskId]) != nil {
            throw StoreError.invalid("A message to this task's chat is being delivered right now. Switch once it has arrived.")
        }
        let replaced = try unlinkWorkChats(db, taskId: taskId, except: chat.threadId, source: source, now: now)
        let link: ThreadLink
        if var existing = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? AND codexThreadId = ?", arguments: [taskId, chat.threadId]) {
            existing.role = "work"
            try existing.update(db)
            link = existing
        } else {
            link = ThreadLink(taskId: taskId, codexThreadId: chat.threadId, linkedBy: source == .user ? "user" : "agent", title: chat.title, provider: chat.provider)
            try link.insert(db)
        }
        if chat.provider == .claude, try ClaudeSession.fetchOne(db, key: chat.threadId)?.taskId != taskId {
            // A session started outside Facienda keeps the model it has.
            try ClaudeSession(threadId: chat.threadId, taskId: taskId, cliSessionId: chat.cliSessionId, cwd: chat.cwd, linkedAt: now,
                              model: nil, effort: nil, fast: false, configureState: "skipped").save(db)
        }
        // Waiting replies and starts go to the new chat; the runner looks at it afresh before delivering.
        for var item in try NativeDispatch.fetchAll(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND state IN ('queued', 'held')", arguments: [taskId])
        where item.threadId != chat.threadId {
            item.threadId = chat.threadId
            try item.update(db)
            try db.execute(sql: "DELETE FROM dispatchContext WHERE dispatchId = ?", arguments: [item.id])
        }
        if var plan = try CheckPlan.fetchOne(db, key: taskId), plan.threadId != chat.threadId {
            plan.threadId = chat.threadId; plan.revision += 1
            try plan.update(db)
        }
        task.revision += 1; task.updatedAt = now
        try task.update(db)
        try TaskEvent(taskId: taskId, threadId: chat.threadId, source: source, kind: "thread.handover", payload: replaced.map(\.threadId).joined(separator: "\n"), at: now).insert(db)
        return link
    }

    /// The task's chats leave it and are never sent anything again. Recorded as unlinked, so discovery never makes one the task's chat again.
    static func unlinkWorkChats(_ db: Database, taskId: String, except kept: String? = nil, source: EventSource, now: Date) throws -> [ThreadLink] {
        let replaced = try ThreadLink.fetchAll(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? AND role = 'work'", arguments: [taskId]).filter { $0.threadId != kept }
        for link in replaced {
            _ = try ThreadLink.deleteOne(db, key: link.id)
            try db.execute(sql: "DELETE FROM claudeSessions WHERE threadId = ? AND taskId = ?", arguments: [link.threadId, taskId])
            try TaskEvent(taskId: taskId, threadId: link.threadId, source: source, kind: "thread.unlinked", payload: "replaced", at: now).insert(db)
        }
        return replaced
    }

    /// The task carries on in a new chat on `choice`'s model, often in the other app. Its chat leaves it as in `handOver`,
    /// and a handover note in the task's private folder gives the new chat what the old one knew: its last answer and
    /// the conversation. Nothing is started here; the caller starts the task as usual, and the start prompt points to the note.
    @discardableResult public func continueInNewChat(taskId: String, on choice: TaskModelChoice, now: Date = Date()) throws -> URL {
        let (task, chats, answer, dispatches) = try db.read { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.invalid("The task is closed or missing.") }
            let links = try ThreadLink.fetchAll(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? AND role = 'work' ORDER BY rowid", arguments: [taskId])
            guard !links.isEmpty else { throw StoreError.invalid("This task has no chat yet. Pick its model and start it instead.") }
            if try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND state IN ('queued', 'claimed', 'dispatching')", arguments: [taskId]) != nil {
                throw Self.deliveryUnderway
            }
            let answer = try String.fetchOne(db, sql: "SELECT payload FROM events WHERE taskId = ? AND kind = 'codex.result' ORDER BY at DESC, rowid DESC LIMIT 1", arguments: [taskId])
            let dispatches = try NativeDispatch.fetchAll(db, sql: "SELECT * FROM dispatches WHERE taskId = ?", arguments: [taskId])
            return (task, links, answer, dispatches)
        }
        let conversations = try chats.map { try conversationSnapshot(taskId: taskId, threadId: $0.threadId)?.conversation }
        let note = HandoverNote.text(task: task, chats: Array(zip(chats, conversations)), lastAnswer: answer, dispatches: dispatches, to: choice, at: now)
        let file = try privateTaskFolder(taskId).appending(path: "handover-\(HandoverNote.stamp(now)).md")
        try DispatchPrompt.writePrivately(note, to: file)
        try write { db in
            guard var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.invalid("The task is closed or missing.") }
            if try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND state IN ('queued', 'claimed', 'dispatching')", arguments: [taskId]) != nil {
                throw Self.deliveryUnderway
            }
            let replaced = try Self.unlinkWorkChats(db, taskId: taskId, source: .user, now: now)
            // Another window may have moved the task meanwhile; the note would then describe the wrong chat.
            guard Set(replaced.map(\.threadId)) == Set(chats.map(\.threadId)) else { throw StoreError.conflict }
            task.workerModel = choice.model; task.workerReasoningEffort = choice.effort
            task.workerServiceTier = choice.serviceTier; task.workerProvider = choice.provider
            task.revision += 1; task.updatedAt = now
            try task.update(db)
            // A start held for prerequisites goes to the new chat; clearing its provider makes the queue take the task's new one.
            try db.execute(sql: "DELETE FROM dispatchContext WHERE dispatchId IN (SELECT id FROM dispatches WHERE taskId = ? AND state = 'held')", arguments: [taskId])
            try db.execute(sql: "UPDATE dispatches SET threadId = NULL, provider = NULL WHERE taskId = ? AND state = 'held'", arguments: [taskId])
            // Checks wait for the new chat, which may take the plan on once it is there.
            if var plan = try CheckPlan.fetchOne(db, key: taskId), !plan.paused {
                plan.paused = true; plan.revision += 1; plan.lastOutcome = CheckPlan.handoverPause
                try plan.update(db)
            }
            try TaskEvent(taskId: taskId, source: .user, kind: "thread.handover", payload: replaced.map(\.threadId).joined(separator: "\n"), at: now).insert(db)
            let record = HandoverNote.Record(file: file.path, from: replaced.map { ChatCandidate(threadId: $0.threadId, provider: $0.provider, title: $0.title) })
            try TaskEvent(taskId: taskId, source: .user, kind: HandoverNote.eventKind, payload: try JSONValue.encoded(record).json, at: now).insert(db)
        }
        return file
    }

    static let deliveryUnderway = StoreError.invalid("A message to this task's chat is on its way. Switch once it has arrived, or cancel it.")

    /// The note a fresh start reads first: there is one while the task has had no chat since it moved to a new one.
    public func pendingHandoverNote(taskId: String) throws -> HandoverNote.Record? {
        try db.read { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM threadLinks WHERE taskId = ? AND role = 'work'", arguments: [taskId]) == 0,
                  let payload = try String.fetchOne(db, sql: "SELECT payload FROM events WHERE taskId = ? AND kind = ? ORDER BY at DESC, rowid DESC LIMIT 1",
                                                    arguments: [taskId, HandoverNote.eventKind]) else { return nil }
            return try? JSONDecoder().decode(HandoverNote.Record.self, from: Data(payload.utf8))
        }
    }

    /// Tasks already moved to another chat. The choice is made: their request and answers stop offering chats to continue in.
    public func handedOverTasks() throws -> Set<String> {
        try db.read { db in Set(try String.fetchAll(db, sql: "SELECT DISTINCT taskId FROM events WHERE kind = 'thread.handover' AND taskId IS NOT NULL")) }
    }

    /// A chat a task may continue in: not a runner's, not another task's, and for Claude a session the app still has.
    static func validateCandidate(_ db: Database, taskId: String, chat: ChatCandidate) throws {
        guard !chat.threadId.trimmingCharacters(in: .whitespaces).isEmpty else { throw StoreError.invalid("Name the chat to continue in.") }
        guard try !isRunner(db, chat.threadId) else { throw StoreError.invalid("A Facienda runner's chat cannot carry a task.") }
        if let owner = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [chat.threadId]), owner.taskId != taskId {
            throw StoreError.invalid(try takenMessage(db, owner: owner.taskId, asking: taskId))
        }
        if chat.provider == .claude {
            guard chat.threadId.hasPrefix("local_"), chat.cliSessionId?.isEmpty == false else {
                throw StoreError.invalid("Only sessions of the Claude app can carry a task.")
            }
        }
    }

    /// Says which task has the chat, and where it is when that isn't where you are: a task in another workspace or a
    /// finished one is easy to forget, and without its place the refusal reads like a riddle.
    static func takenMessage(_ db: Database, owner: String, asking taskId: String) throws -> String {
        guard let other = try FaciendaTask.fetchOne(db, key: owner) else { return "This chat is taken by another task. A chat carries one task." }
        let here = try FaciendaTask.fetchOne(db, key: taskId)?.workspaceId
        let place = other.workspaceId == here ? nil : try other.workspaceId.flatMap { try Workspace.fetchOne(db, key: $0)?.name }
        let notes = [other.state.isOpen ? nil : "done", place.map { "in \($0)" }].compactMap { $0 }
        return "This chat is taken by “\(other.displayName)”\(notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"). A chat carries one task."
    }

    /// A Claude app session as a new task, its first message as the original request. A session that already carries
    /// a task gives that task back.
    public func importClaudeSession(_ session: ClaudeDesktop.Session, transcripts: URL = ClaudeTranscript.projectsDirectory) throws -> FaciendaTask {
        guard !session.archived else { throw StoreError.invalid("This Claude session is archived. Unarchive it in Claude first.") }
        guard let file = ClaudeTranscript.locate(cliSessionId: session.cliSessionId, cwd: session.cwd, in: transcripts) else {
            throw StoreError.invalid("This Claude session's transcript was not found on this Mac.")
        }
        let conversation = try ClaudeTranscript.read(file, threadId: session.id, fallbackTitle: session.title)
        guard let request = conversation.firstUserText else { throw StoreError.invalid("This Claude session has no request yet. Nothing was imported.") }
        try db.read { db in
            guard try !Self.isRunner(db, session.id) else { throw StoreError.invalid("The Facienda runner's session cannot carry a task.") }
        }
        return try importThread(originalRequest: request, title: session.title, cwd: session.cwd, conversation: conversation,
                                provider: .claude, cliSessionId: session.cliSessionId)
    }
}

/// Chats a text links to: Codex chat links, and Claude app session links or IDs, in order of first mention.
public enum ChatLinks {
    public struct Found: Equatable, Sendable {
        public var threadId: String
        public var provider: AgentProvider
    }
    nonisolated(unsafe) private static let codex = try! NSRegularExpression(pattern: #"codex://threads?/([A-Za-z0-9_-]+)"#)
    nonisolated(unsafe) private static let claude = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])local_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?![0-9a-fA-F])"#)

    public static func find(in text: String) -> [Found] {
        let range = NSRange(text.startIndex..., in: text)
        var hits: [(at: Int, found: Found)] = []
        for match in codex.matches(in: text, range: range) {
            if let id = Range(match.range(at: 1), in: text) { hits.append((match.range.location, Found(threadId: String(text[id]), provider: .codex))) }
        }
        for match in claude.matches(in: text, range: range) {
            if let id = Range(match.range(at: 1), in: text) { hits.append((match.range.location, Found(threadId: "local_" + text[id].lowercased(), provider: .claude))) }
        }
        var seen = Set<String>()
        return hits.sorted { $0.at < $1.at }.map(\.found).filter { seen.insert($0.threadId).inserted }
    }
}

extension CodexConversation {
    /// The first thing the user wrote, which is the chat's original request. Facienda's own deliveries are skipped.
    public var firstUserText: String? {
        for turn in turns {
            for item in turn.items where item["type"].string == "userMessage" {
                let text = (item["content"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && !text.hasPrefix("Facienda dispatch: ") { return text }
            }
        }
        return nil
    }
}

extension ClaudeDesktop {
    /// A session as the Claude app lists it. Titles and folders only; Facienda never shows what was said.
    public struct Session: Equatable, Sendable, Identifiable {
        /// The Claude app's own session ID, `local_…`.
        public var id: String
        public var cliSessionId: String
        public var title: String
        public var cwd: String
        public var lastActivityAt: Date
        public var archived: Bool
        /// What the session is set to now in the Claude app, such as `claude-sonnet-5-5` and `medium`.
        public var model: String? = nil
        public var effort: String? = nil
        /// The error that ended its last turn, as the app shows it, such as a usage limit and when it resets.
        public var error: String? = nil
        public var errorAt: Date? = nil
        /// When the user last opened the session in the Claude app, and when its latest turn ended.
        public var focusedAt: Date? = nil
        public var turnEdgeAt: Date? = nil
        public var turnEndedAt: Date { max(turnEdgeAt ?? .distantPast, lastActivityAt) }
        public var chat: ChatCandidate { ChatCandidate(threadId: id, provider: .claude, title: title, cwd: cwd, cliSessionId: cliSessionId) }
    }

    /// Every session the Claude app keeps on this Mac, newest first.
    public static func sessions(registry: URL = sessionRegistry) -> [Session] {
        let files = FileManager.default
        var result: [Session] = []
        for account in (try? files.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [] {
            for organisation in (try? files.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let archived = archivedSessions(in: organisation)
                for file in (try? files.contentsOfDirectory(at: organisation, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    if let session = session(file, archived: archived) { result.append(session) }
                }
            }
        }
        return result.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// One session by its `local_…` ID.
    public static func session(id: String, registry: URL = sessionRegistry) -> Session? {
        guard id.hasPrefix("local_"), !id.contains("/") else { return nil }
        let files = FileManager.default
        for account in (try? files.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [] {
            for organisation in (try? files.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let file = organisation.appending(path: id + ".json")
                if files.fileExists(atPath: file.path) { return session(file, archived: archivedSessions(in: organisation)) }
            }
        }
        return nil
    }

    /// The session a Claude app link or a bare `local_…` ID names, such as `claude://code/continue?session=local_…`.
    public static func sessionID(inLink text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if text.hasPrefix("local_") { candidate = text }
        else if let parts = URLComponents(string: text), parts.scheme?.lowercased() == "claude",
                let value = parts.queryItems?.first(where: { $0.name == "session" })?.value, value.hasPrefix("local_") { candidate = value }
        else { return nil }
        return UUID(uuidString: String(candidate.dropFirst("local_".count))) == nil ? nil : candidate.lowercased()
    }

    private static func session(_ file: URL, archived: Set<String>) -> Session? {
        guard let data = try? Data(contentsOf: file), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["sessionId"] as? String, let cli = root["cliSessionId"] as? String, !cli.isEmpty else { return nil }
        let cwd = (root["cwd"] as? String) ?? (root["originCwd"] as? String) ?? ""
        let activity = (root["lastActivityAt"] as? Double) ?? (root["createdAt"] as? Double) ?? 0
        let date = { (key: String) in (root[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        return Session(id: id, cliSessionId: cli, title: (root["title"] as? String) ?? "", cwd: cwd,
                       lastActivityAt: Date(timeIntervalSince1970: activity / 1000),
                       archived: (root["isArchived"] as? Bool) == true || archived.contains(id),
                       model: root["model"] as? String, effort: root["effort"] as? String,
                       error: (root["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       errorAt: date("errorAt"), focusedAt: date("lastFocusedAt"), turnEdgeAt: date("lastTurnEdgeAt"))
    }

    private static func archivedSessions(in organisation: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: organisation.appending(path: "archived-sessions.idx")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(root["archived"] as? [String] ?? [])
    }
}
