import Foundation
import GRDB
import CoreFoundation
import Darwin

public final class FaciendaStore: Sendable {
    let db: DatabasePool
    public let url: URL
    /// Set on a store that shows one workspace of the library. Nil sees the whole library.
    public let workspaceID: String?
    public static let changeNotification = "org.facienda.store.changed"

    /// Opens the database at `url`, making it when `create` is set. Only first-run setup and tests make one;
    /// everything else opens an existing library with `init(existing:)`.
    public init(url: URL, busyTimeout: TimeInterval = 2, migrate: Bool = true, create: Bool = true) throws {
        self.url = url
        workspaceID = nil
        db = try Self.openPrivateDatabase(at: url, busyTimeout: busyTimeout, create: create)
        if migrate {
            try Self.migrator.migrate(db)
            if let setup = try workspaceSetup(), setup.projectPath != nativeProjectDirectory.path {
                _ = try prepareWorkspaceSetup()
            }
        }
    }

    /// Opens a library that is already there. The app, the MCP helper and the hooks all open it this way, so a deleted
    /// library is reported instead of being replaced by an empty one at the same path.
    public convenience init(existing url: URL, busyTimeout: TimeInterval = 2, migrate: Bool = true) throws {
        try self.init(url: url, busyTimeout: busyTimeout, migrate: migrate, create: false)
    }

    private init(db: DatabasePool, url: URL, workspaceID: String?) {
        self.db = db; self.url = url; self.workspaceID = workspaceID
    }

    /// The same library, showing one workspace's tasks, groups and memory.
    public func scoped(to workspaceID: String) -> FaciendaStore { FaciendaStore(db: db, url: url, workspaceID: workspaceID) }
    /// The whole library: every workspace, as the runner and helpers see it.
    public var library: FaciendaStore { workspaceID == nil ? self : FaciendaStore(db: db, url: url, workspaceID: nil) }

    /// Opens a database only this account can read, in a private folder.
    static func openPrivateDatabase(at url: URL, busyTimeout: TimeInterval, create: Bool = true) throws -> DatabasePool {
        if create {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if !FileManager.default.fileExists(atPath: url.path) {
            throw StoreError.libraryMissing(url.path)
        }
        // SQLite inherits database permissions for future WAL/SHM files. Secure
        // the initial file before GRDB opens it, and tighten existing sidecars.
        try makePrivateDatabaseFile(url, create: create, required: true)
        for suffix in ["-wal", "-shm"] {
            try makePrivateDatabaseFile(URL(fileURLWithPath: url.path + suffix), create: false)
        }
        var config = Configuration()
        config.busyMode = .timeout(busyTimeout)
        // Deleted task text is overwritten rather than left in free pages and the WAL.
        config.prepareDatabase { try $0.execute(sql: "PRAGMA secure_delete = ON") }
        return try DatabasePool(path: url.path, configuration: config)
    }

    /// A `required` file that is missing, for example deleted just now, is an error: SQLite would otherwise make an empty one.
    static func makePrivateDatabaseFile(_ url: URL, create: Bool, required: Bool = false) throws {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        if descriptor < 0, !create, errno == ENOENT {
            if required { throw StoreError.libraryMissing(url.path) }
            return
        }
        guard descriptor >= 0 else { throw StoreError.invalid("Cannot securely open workspace storage.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else {
            throw StoreError.invalid("Workspace storage must be a private file owned by your account.")
        }
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        let recorder = UndoRecorder.current
        let result = try db.write { db in
            guard let recorder else { return try body(db) }
            try UndoLog.start(db)
            let result = try body(db)
            recorder.append(try UndoLog.stop(db))
            return result
        }
        Self.postChange()
        return result
    }

    /// Tells the app and helpers in other processes that the library changed.
    static func postChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(changeNotification as CFString), nil, nil, true)
    }

    /// The scoped workspace's tasks, or the named workspaces' tasks, or the whole library's.
    public func tasks(search: String = "", inWorkspaces workspaceIDs: [String]? = nil) throws -> [FaciendaTask] {
        let workspaces = workspaceIDs ?? workspaceID.map { [$0] }
        if workspaces?.isEmpty == true { return [] }
        let scope = workspaces.map { ids in "workspaceId IN (" + ids.map { _ in "?" }.joined(separator: ", ") + ")" }
        return try db.read { db in
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return try FaciendaTask.fetchAll(db, sql: "SELECT * FROM tasks \(scope.map { "WHERE " + $0 } ?? "") ORDER BY updatedAt DESC", arguments: StatementArguments(workspaces ?? []))
            }
            let query = search.split(whereSeparator: { $0.isWhitespace }).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
            // The display name is not in the full-text index: each word must appear in it, in any order and as part of a word.
            let words = search.split(whereSeparator: { $0.isWhitespace }).map { Self.likePattern($0) }
            let displayMatch = words.map { _ in "displayTitle LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            return try FaciendaTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE (id IN (SELECT id FROM taskSearch WHERE taskSearch MATCH ? UNION SELECT taskId FROM threadSearch WHERE threadSearch MATCH ?) OR (\(displayMatch)))\(scope.map { " AND " + $0 } ?? "") ORDER BY updatedAt DESC", arguments: StatementArguments([query, query] + words + (workspaces ?? [])))
        }
    }

    /// A LIKE pattern matching the text anywhere in a value, its wildcards taken literally by a backslash escape.
    static func likePattern(_ text: some StringProtocol) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    public func task(_ id: String) throws -> FaciendaTask {
        try db.read { db in guard let task = try FaciendaTask.fetchOne(db, key: id) else { throw StoreError.notFound }; return task }
    }

    @discardableResult public func create(_ task: FaciendaTask, source: EventSource = .user) throws -> FaciendaTask {
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Give this task a title.") }
        if source == .mcp && (!task.state.isOpen || task.automationScope != .prepareOnly) { throw StoreError.userOnly }
        var task = task
        if task.workspaceId == nil { task.workspaceId = workspaceID }
        return try write { db in
            if let id = task.workspaceId { _ = try Self.workspace(db, id) }
            try task.insert(db)
            if task.workspaceId == nil { task.workspaceId = try String.fetchOne(db, sql: "SELECT workspaceId FROM tasks WHERE id = ?", arguments: [task.id]) }
            try TaskEvent(taskId: task.id, source: source, kind: "task.created", payload: task.title).insert(db)
            return task
        }
    }

    @discardableResult public func update(_ id: String, source: EventSource = .user, expectedRevision: Int? = nil, _ change: (inout FaciendaTask) throws -> Void) throws -> FaciendaTask {
        try write { db in
            guard var task = try FaciendaTask.fetchOne(db, key: id) else { throw StoreError.notFound }
            if let expectedRevision, expectedRevision != task.revision { throw StoreError.conflict }
            let old = task
            try change(&task)
            // Only moving a task changes its workspace.
            task.workspaceId = old.workspaceId
            if let title = task.displayTitle, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw StoreError.invalid("Give this task a title.")
            }
            if source == .user && task.displayTitle != old.displayTitle { task.displayTitleSource = "user" }
            guard task.id == old.id, !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Invalid task update.") }
            if source != .user && (!task.state.isOpen || task.automationScope != old.automationScope || task.completedBy != old.completedBy || !old.state.isOpen) { throw StoreError.userOnly }
            if source != .user && task.state == .running && old.state != .running {
                guard try unmetBlockers(db, taskId: id, now: Date()).isEmpty else { throw StoreError.invalid("Resolve the task's prerequisites before starting work.") }
                guard try TaskReadiness.fetchOne(db, key: id)?.notBefore.map({ $0 <= Date() }) ?? true else { throw StoreError.invalid("The scheduled start date has not arrived.") }
            }
            if task.state == .scheduled && task.returnAt != old.returnAt, var ready = try TaskReadiness.fetchOne(db, key: id) { ready.notBefore = task.returnAt; ready.revision += 1; try ready.update(db) }
            if task.state == .waiting && (task.waitingOn?.isEmpty != false || task.checkAt == nil) { throw StoreError.invalid("Waiting requires a person or dependency and a check date.") }
            if task.state.isOpen && task.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StoreError.invalid("Open tasks need a next action.") }
            if task.state == .scheduled && task.returnAt == nil { throw StoreError.invalid("Scheduled tasks need a return date.") }
            task.revision = old.revision + 1; task.updatedAt = Date()
            if !task.state.isOpen { task.completedBy = "user"; task.returnAt = nil; task.checkAt = nil
                try db.execute(sql: "UPDATE decisions SET state = 'closed', answeredAt = ? WHERE taskId = ? AND state = 'pending'", arguments: [Date(), id])
                // A closed task has nothing left for the user to do.
                try db.execute(sql: "DELETE FROM ownSteps WHERE taskId = ?", arguments: [id])
            }
            else { task.completedBy = nil }
            if let plan = try CheckPlan.fetchOne(db, key: id) {
                if source != .user && (task.checkAt != old.checkAt || task.waitingOn != old.waitingOn || (!plan.paused && task.state != old.state && task.state != .running)) {
                    throw StoreError.invalid("Use the versioned check-plan tools to change a monitored task.")
                }
                if source == .user && (task.checkAt != old.checkAt || task.state != old.state) {
                    var changed = plan
                    changed.revision += 1; changed.paused = task.state != .waiting
                    if let date = task.checkAt { changed.nextCheck = date; changed.pinned = true }
                    try changed.update(db)
                    try Self.cancelQueuedChecks(db, taskId: id)
                }
            }
            try task.update(db)
            if !task.state.isOpen || task.snoozeCount > old.snoozeCount {
                try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE taskId = ? AND state IN ('queued', 'claimed')", arguments: [id])
            }
            try reconcileBlockers(db, now: Date())
            try TaskEvent(taskId: id, source: source, kind: old.state != task.state ? "task.\(task.state.rawValue)" : "task.updated", payload: task.nextAction).insert(db)
            return try FaciendaTask.fetchOne(db, key: id) ?? task
        }
    }

    public func links(taskId: String? = nil) throws -> [ThreadLink] {
        try db.read { db in
            if let taskId { return try ThreadLink.fetchAll(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? ORDER BY rowid", arguments: [taskId]) }
            return try ThreadLink.fetchAll(db, sql: "SELECT * FROM threadLinks ORDER BY rowid")
        }
    }
    /// The chat doing a task's work: the one linked most recently.
    static func workThreadID(_ db: Database, taskId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT codexThreadId FROM threadLinks WHERE taskId = ? AND role = 'work' ORDER BY rowid DESC LIMIT 1", arguments: [taskId])
    }
    static func isLinked(_ db: Database, taskId: String, threadId: String) throws -> Bool {
        try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? AND codexThreadId = ?", arguments: [taskId, threadId]) != nil
    }
    public func currentTask(threadId: String) throws -> FaciendaTask? {
        try db.read { db in try FaciendaTask.fetchOne(db, sql: "SELECT tasks.* FROM tasks JOIN threadLinks ON tasks.id = threadLinks.taskId WHERE codexThreadId = ?", arguments: [threadId]) }
    }
    public func link(_ link: ThreadLink, source: EventSource = .user) throws {
        try write { db in
            guard try FaciendaTask.fetchOne(db, key: link.taskId) != nil else { throw StoreError.notFound }
            if let existing = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [link.codexThreadId]) {
                if existing.taskId == link.taskId { return }
                throw StoreError.invalid("This thread already belongs to another task. Unlink it there first.")
            }
            try link.insert(db)
            try TaskEvent(taskId: link.taskId, threadId: link.codexThreadId, source: source, kind: "thread.linked").insert(db)
        }
    }
    public func unlink(_ link: ThreadLink) throws {
        try write { db in
            _ = try ThreadLink.deleteOne(db, key: link.id)
            try TaskEvent(taskId: link.taskId, threadId: link.codexThreadId, source: .user, kind: "thread.unlinked").insert(db)
        }
    }
    public func events(taskId: String, limit: Int = 100) throws -> [TaskEvent] {
        try db.read { db in try TaskEvent.fetchAll(db, sql: "SELECT * FROM events WHERE taskId = ? ORDER BY at DESC LIMIT ?", arguments: [taskId, limit]) }
    }
    public func record(_ event: TaskEvent) throws { try write { db in try event.insert(db) } }
    public func latestEvent(taskId: String, kind: String) throws -> TaskEvent? {
        try db.read { db in
            try TaskEvent.fetchOne(db, sql: "SELECT * FROM events WHERE taskId = ? AND kind = ? ORDER BY at DESC LIMIT 1", arguments: [taskId, kind])
        }
    }

    public func observe(threadId: String, status: String, source: EventSource, verified: Bool, title: String? = nil, preview: String? = nil, at: Date = Date()) throws {
        try write { db in try observe(db, threadId: threadId, status: status, source: source, verified: verified, title: title, preview: preview, at: at) }
    }
    func observe(_ db: Database, threadId: String, status: String, source: EventSource, verified: Bool, title: String? = nil, preview: String? = nil, at: Date = Date()) throws {
        guard var link = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [threadId]) else { return }
        // A poll cannot demote fresh lifecycle evidence from the owning server or a hook.
        if source == .app && !verified && link.statusVerified && at.timeIntervalSince(link.lastActivityAt ?? .distantPast) < 120 { return }
        if let last = link.lastActivityAt, last > at { return }
        let changed = link.lastKnownStatus != status || link.statusVerified != verified || link.statusSource != source
        link.lastKnownStatus = status; link.statusSource = source; link.statusVerified = verified; link.lastActivityAt = at
        if let title { link.title = title }; if let preview { link.preview = preview }
        try link.update(db)
        if changed { try TaskEvent(taskId: link.taskId, threadId: threadId, source: source, kind: "thread.\(status)", verified: verified, at: at).insert(db) }
        guard verified else { return }
        try reconcileThreads(db, taskId: link.taskId, provider: link.provider, at: at, now: max(at, Date()))
    }

    /// How long a Codex approval prompt may stay open before its task needs the user. Someone at the chat answers
    /// within seconds, and the task keeps showing as running meanwhile instead of flickering on every prompt.
    public static let approvalGrace: TimeInterval = 120

    /// Approval prompts left unanswered past the grace period bring their tasks to the user.
    public func surfaceStaleApprovals(now: Date = Date()) throws {
        try write { db in
            let stale = try ThreadLink.fetchAll(db, sql: """
                SELECT threadLinks.* FROM threadLinks JOIN tasks ON tasks.id = threadLinks.taskId
                WHERE statusVerified = 1 AND lastKnownStatus = 'waitingOnApproval' AND lastActivityAt <= ?
                  AND tasks.state NOT IN ('needsMe', 'done', 'dropped')
                """, arguments: [now.addingTimeInterval(-Self.approvalGrace)])
            for link in stale { try reconcileThreads(db, taskId: link.taskId, provider: link.provider, at: now, now: now) }
        }
    }

    private func reconcileThreads(_ db: Database, taskId: String, provider: AgentProvider, at: Date, now: Date) throws {
        guard var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { return }
        let original = task
        let all = try ThreadLink.fetchAll(db, sql: "SELECT * FROM threadLinks WHERE taskId = ?", arguments: [taskId])
        let approvalIsStale = { (link: ThreadLink) in now.timeIntervalSince(link.lastActivityAt ?? .distantPast) >= Self.approvalGrace }
        let active = Self.turnRuns(all, now: now)
        let needsInput = all.contains { $0.statusVerified && (["waitingOnUserInput", "error"].contains($0.lastKnownStatus) || $0.lastKnownStatus == "waitingOnApproval" && approvalIsStale($0)) }
        // A turn running now outranks a decision left open from earlier work, such as an unanswered completion proposal.
        if needsInput { task.state = .needsMe }
        else if active { task.state = .running }
        else if try Self.hasPendingDecision(db, taskId: taskId) { task.state = .needsMe }
        else if task.state == .running { task.state = .needsMe; task.nextAction = "Review the latest \(provider.name) result" }
        else { return }
        guard task.state != original.state || task.nextAction != original.nextAction || task.returnAt == nil else { return }
        task.returnAt = task.returnAt ?? at; task.updatedAt = at; task.revision += 1
        try task.update(db)
        // A parked task's result is held quietly until its wait ends.
        try settleWaits(db, now: Date())
    }

    /// Whether one of these chats runs a turn now. A permission prompt counts until its grace runs out.
    static func turnRuns(_ links: [ThreadLink], now: Date = Date()) -> Bool {
        links.contains { $0.statusVerified && ($0.lastKnownStatus == "active" || $0.lastKnownStatus == "waitingOnApproval" && now.timeIntervalSince($0.lastActivityAt ?? .distantPast) < approvalGrace) }
    }
    /// A Claude agent asking or reporting mid-turn leaves its task running; the task comes back once the turn stops.
    /// Claude transcripts are read throughout, so that end is seen. A Codex chat without hooks may never report it,
    /// so there the question or result brings the task back at once.
    static func claudeTurnRuns(_ db: Database, taskId: String) throws -> Bool {
        turnRuns(try ThreadLink.fetchAll(db, sql: "SELECT * FROM threadLinks WHERE taskId = ? AND provider = 'claude'", arguments: [taskId]))
    }

    static func hasPendingDecision(_ db: Database, taskId: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decisions WHERE taskId = ? AND state = 'pending'", arguments: [taskId]) ?? 0 > 0
    }

    public func decisions(taskId: String? = nil, pendingOnly: Bool = true) throws -> [Decision] {
        try db.read { db in
            var query = Decision.all()
            if pendingOnly { query = query.filter(Column("state") == "pending") }
            if let taskId { query = query.filter(Column("taskId") == taskId) }
            return try query.order(Column("createdAt")).fetchAll(db)
        }
    }
    @discardableResult public func requestDecision(_ decision: Decision, source: EventSource = .mcp) throws -> Decision {
        guard !decision.question.isEmpty, !decision.recommendation.isEmpty, !decision.options.isEmpty, decision.options.contains(decision.recommendation) else { throw StoreError.invalid("Decisions need a question, options, and a recommendation from those options.") }
        return try write { db in
            guard var task = try FaciendaTask.fetchOne(db, key: decision.taskId), task.state.isOpen else { throw StoreError.invalid("The task is closed or missing.") }
            if let existing = try Decision.fetchOne(db, sql: "SELECT * FROM decisions WHERE taskId = ? AND question = ? AND state = 'pending'", arguments: [decision.taskId, decision.question]) { return existing }
            try decision.insert(db)
            if try task.state != .running || !Self.claudeTurnRuns(db, taskId: task.id) { task.state = .needsMe }
            task.nextAction = decision.question; task.returnAt = Date(); task.revision += 1; task.updatedAt = Date()
            try task.update(db)
            try TaskEvent(taskId: task.id, source: source, kind: "decision.requested", payload: decision.question).insert(db)
            return decision
        }
    }
    public func answerDecision(_ id: String, answer: String) throws {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Add your answer.") }
        try write { db in
            guard var decision = try Decision.fetchOne(db, key: id), decision.state == "pending" else { throw StoreError.conflict }
            decision.answer = answer; decision.answeredAt = Date(); decision.state = "answered"; try decision.update(db)
            guard var task = try FaciendaTask.fetchOne(db, key: decision.taskId) else { throw StoreError.notFound }
            task.state = .needsMe; task.nextAction = "Continue with: \(answer)"; task.returnAt = Date(); task.revision += 1; task.updatedAt = Date(); try task.update(db)
            try TaskEvent(taskId: task.id, source: .user, kind: "decision.answered", payload: answer).insert(db)
        }
    }
    public func snooze(_ id: String, until: Date) throws {
        guard until > Date() else { throw StoreError.invalid("Choose a future return date.") }
        try update(id) { task in task.state = .scheduled; task.returnAt = until; task.checkAt = nil; task.snoozeCount += 1 }
    }
    /// Transactional claim prevents duplicate delivery across app launches and scheduler ticks.
    public func claimDue(now: Date = Date()) throws -> [FaciendaTask] {
        try write { db in
            let due = try FaciendaTask.fetchAll(db, sql: "SELECT * FROM tasks WHERE ((state = 'scheduled' AND returnAt <= ?) OR (state = 'waiting' AND checkAt <= ? AND id NOT IN (SELECT taskId FROM checkPlans))) AND id NOT IN (SELECT taskId FROM taskBlockers WHERE removed = 0) AND id NOT IN (SELECT taskId FROM taskReadiness WHERE armed = 1) AND id NOT IN (SELECT taskId FROM waits WHERE state = 'active')", arguments: [now, now])
            for var task in due {
                task.state = .needsMe; task.checkAt = nil; task.returnAt = now; task.updatedAt = now; task.revision += 1
                try task.update(db)
                try TaskEvent(taskId: task.id, source: .app, kind: "followup.due", payload: task.nextAction, at: now).insert(db)
            }
            return due
        }
    }
}
