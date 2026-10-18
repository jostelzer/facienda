import Foundation
import GRDB

/// The Claude runner: one ordinary session in the Claude app. It applies each new task session's model,
/// relays replies and scheduled checks, and starts sessions itself when the Claude app offers it a tool for that.
public struct ClaudeRunnerState: Codable, FetchableRecord, Equatable, Sendable {
    /// The Claude app's own session ID (`local_…`), as the session read it from its environment.
    public var sessionId: String?
    public var canStartSessions: Bool
    public var lastSeen: Date?
    public var boundAt: Date?
    public var challenge: String
    public var requestedAt: Date
    public var verifiedAt: Date?
    /// The setup request the bound session answered. Each request binds one session.
    public var answeredChallenge: String?

    public var isBound: Bool { sessionId != nil && verifiedAt != nil }
    /// The runner's background wait marks it seen every minute while its session is running.
    public func isAwake(at now: Date = Date()) -> Bool {
        isBound && (lastSeen ?? .distantPast) > now.addingTimeInterval(-Self.awakeWindow)
    }
    public static let awakeWindow: TimeInterval = 180
    /// The runner session's title and folder name, apart from the Codex runner's.
    public static let name = "facienda-claude-runner"
    /// The runner only passes work on, and each step rereads its whole conversation. Sonnet or Haiku does that as well
    /// as Opus or Fable for far less; the task sessions it starts keep the model each task asked for.
    public static func isCostly(model: String) -> Bool { ["opus", "fable"].contains { model.lowercased().contains($0) } }
}

/// A Claude session carrying a task, as it reported itself when it linked.
public struct ClaudeSession: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "claudeSessions"
    public var threadId: String
    public var taskId: String
    /// Claude Code's own session ID, which names the transcript file.
    public var cliSessionId: String?
    public var cwd: String?
    public var linkedAt: Date
    /// What the task asked for when the session linked.
    public var model: String?
    public var effort: String?
    public var fast: Bool
    /// pending: the runner should apply the model. configuring: it is doing so. done or failed: it finished.
    /// skipped: no runner was awake, so the session kept the Claude app's own choice.
    public var configureState: String
    public var configureClaimedAt: Date?
    public var configuredAt: Date?
    public var configureNote: String?

    public var isSettled: Bool { ["done", "failed", "skipped"].contains(configureState) }
}

/// One thing for the Claude runner to do.
public enum ClaudeWork: Sendable {
    /// Apply the task's model, reasoning and title to a session that just linked. A session Facienda had the app adopt
    /// comes with its start already begun, so the runner sends it straight after the settings rather than in a job of its own.
    case configure(ClaudeSession, start: NativeDispatch?)
    /// Send a reply, answer or scheduled check to the task's existing session.
    case deliver(NativeDispatch)
    /// Start a new session. Offered only when the runner can start sessions itself.
    case create(NativeDispatch)
}

extension FaciendaStore {
    /// Marks a new session's delivery as handed to the Claude app's composer, where the user presses Send.
    public static let claudeComposer = "claude-composer"

    static func registerClaude(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("claude_provider") { db in
            try db.execute(sql: """
            ALTER TABLE tasks ADD COLUMN workerProvider TEXT;
            ALTER TABLE threadLinks ADD COLUMN provider TEXT NOT NULL DEFAULT 'codex';
            ALTER TABLE dispatches ADD COLUMN provider TEXT;
            UPDATE dispatches SET provider = 'codex';
            CREATE TABLE claudeRunner (
              id INTEGER PRIMARY KEY CHECK(id = 1), sessionId TEXT, canStartSessions BOOLEAN NOT NULL DEFAULT 0,
              lastSeen DATETIME, boundAt DATETIME, challenge TEXT NOT NULL, requestedAt DATETIME NOT NULL, verifiedAt DATETIME,
              answeredChallenge TEXT
            );
            CREATE TABLE claudeSessions (
              threadId TEXT PRIMARY KEY NOT NULL, taskId TEXT NOT NULL, cliSessionId TEXT, cwd TEXT, linkedAt DATETIME NOT NULL,
              model TEXT, effort TEXT, fast BOOLEAN NOT NULL DEFAULT 0, configureState TEXT NOT NULL DEFAULT 'skipped',
              configureClaimedAt DATETIME, configuredAt DATETIME, configureNote TEXT
            );
            CREATE INDEX claude_sessions_task ON claudeSessions(taskId);
            CREATE INDEX claude_sessions_configure ON claudeSessions(configureState);
            -- Every queue entry knows which app delivers it: the owning chat's, else the task's choice.
            CREATE TRIGGER dispatch_provider_insert AFTER INSERT ON dispatches WHEN NEW.provider IS NULL BEGIN
              UPDATE dispatches SET provider = COALESCE(
                (SELECT provider FROM threadLinks WHERE codexThreadId = NEW.threadId),
                (SELECT COALESCE(workerProvider, CASE WHEN workerModel LIKE 'claude%' THEN 'claude' END) FROM tasks WHERE id = NEW.taskId),
                'codex') WHERE id = NEW.id;
            END;
            CREATE TRIGGER dispatch_provider_thread AFTER UPDATE OF threadId ON dispatches
              WHEN NEW.threadId IS NOT NULL AND NEW.threadId IS NOT OLD.threadId BEGIN
              UPDATE dispatches SET provider = COALESCE((SELECT provider FROM threadLinks WHERE codexThreadId = NEW.threadId), NEW.provider)
              WHERE id = NEW.id;
            END;
            CREATE TRIGGER dispatch_provider_cleared AFTER UPDATE OF provider ON dispatches WHEN NEW.provider IS NULL BEGIN
              UPDATE dispatches SET provider = COALESCE(
                (SELECT provider FROM threadLinks WHERE codexThreadId = NEW.threadId),
                (SELECT COALESCE(workerProvider, CASE WHEN workerModel LIKE 'claude%' THEN 'claude' END) FROM tasks WHERE id = NEW.taskId),
                'codex') WHERE id = NEW.id;
            END;
            """)
        }
    }

    // MARK: Runner setup

    public func claudeRunner() throws -> ClaudeRunnerState? {
        try db.read { try Self.claudeRunner($0) }
    }

    static func claudeRunner(_ db: Database) throws -> ClaudeRunnerState? {
        try ClaudeRunnerState.fetchOne(db, sql: "SELECT * FROM claudeRunner WHERE id = 1")
    }

    /// Reopening an unanswered setup keeps its challenge. Repair issues a new one; the old runner keeps working until a new session answers it.
    @discardableResult public func prepareClaudeSetup(repair: Bool = false) throws -> ClaudeRunnerState {
        try write { db in
            if let existing = try Self.claudeRunner(db), !repair { return existing }
            try db.execute(sql: """
                INSERT INTO claudeRunner(id, challenge, requestedAt) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET challenge = excluded.challenge, requestedAt = excluded.requestedAt
                """, arguments: [UUID().uuidString, Date()])
            return try Self.claudeRunner(db)!
        }
    }

    /// The setup session answers the current challenge with its own session ID and becomes the runner.
    /// A challenge binds once; a newer setup moves the runner, returning anything the old one had claimed.
    @discardableResult public func bindClaudeRunner(sessionId: String, challenge: String, canStartSessions: Bool, now: Date = Date()) throws -> ClaudeRunnerState {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else {
            throw StoreError.invalid("Run this inside a Claude app session. CLAUDE_CODE_HOST_SESSION_ID is missing from its environment.")
        }
        return try write { db in
            guard let state = try Self.claudeRunner(db), state.challenge == challenge else {
                throw StoreError.invalid("This setup request is out of date. Click Connect Claude in Facienda again.")
            }
            if let bound = state.sessionId, bound != sessionId, state.answeredChallenge == challenge {
                throw StoreError.invalid("Another Claude session already answered this setup. Use Repair in Facienda to move the runner.")
            }
            if try ClaudeSession.fetchOne(db, key: sessionId) != nil {
                throw StoreError.invalid("This session carries a Facienda task, so it cannot become the runner. Start setup in a new session.")
            }
            try db.execute(sql: """
                UPDATE claudeRunner SET boundAt = CASE WHEN sessionId IS ? THEN boundAt ELSE ? END,
                  sessionId = ?, canStartSessions = ?, lastSeen = ?, verifiedAt = ?, answeredChallenge = ? WHERE id = 1
                """, arguments: [sessionId, now, sessionId, canStartSessions, now, now, challenge])
            if let previous = state.sessionId, previous != sessionId {
                try db.execute(sql: "UPDATE dispatches SET state = 'queued', runnerId = NULL, availableAt = NULL WHERE state = 'claimed' AND runnerId = ?", arguments: [previous])
                // A message the old runner began may have gone out already; the new one looks for its marker before sending.
                try db.execute(sql: "UPDATE dispatches SET runnerId = ?, availableAt = NULL WHERE provider = 'claude' AND state = 'dispatching' AND threadId IS NOT NULL AND runnerId = ?", arguments: [sessionId, previous])
                try db.execute(sql: "UPDATE claudeSessions SET configureState = 'pending', configureClaimedAt = NULL WHERE configureState = 'configuring'")
            }
            try TaskEvent(source: .app, kind: "claude.runner.bound", payload: sessionId, verified: false, at: now).insert(db)
            return try Self.claudeRunner(db)!
        }
    }

    /// The runner reports whether the Claude app gave it a tool for starting sessions.
    public func setClaudeRunnerCapabilities(_ sessionId: String, canStartSessions: Bool) throws {
        try write { db in
            try Self.requireClaudeRunner(db, sessionId)
            try db.execute(sql: "UPDATE claudeRunner SET canStartSessions = ? WHERE id = 1", arguments: [canStartSessions])
        }
    }

    public func claudeRunnerHeartbeat(_ sessionId: String, now: Date = Date()) throws {
        try write { db in try Self.requireClaudeRunner(db, sessionId); try db.execute(sql: "UPDATE claudeRunner SET lastSeen = ? WHERE id = 1", arguments: [now]) }
    }

    @discardableResult static func requireClaudeRunner(_ db: Database, _ sessionId: String) throws -> ClaudeRunnerState {
        guard let runner = try Self.claudeRunner(db),
              runner.isBound, runner.sessionId == sessionId else { throw StoreError.invalid("This is not the connected Claude runner.") }
        return runner
    }

    /// Either app's runner: both may name tasks and file them into groups.
    static func isRunner(_ db: Database, _ id: String) throws -> Bool {
        if try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") == id { return true }
        guard let runner = try Self.claudeRunner(db) else { return false }
        return runner.isBound && runner.sessionId == id
    }

    /// Which app's runner this is, if either.
    static func runnerProvider(_ db: Database, _ id: String) throws -> AgentProvider? {
        if try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") == id { return .codex }
        if let runner = try Self.claudeRunner(db), runner.isBound, runner.sessionId == id { return .claude }
        return nil
    }

    // MARK: Sessions

    public func claudeSessions() throws -> [ClaudeSession] {
        try db.read { try ClaudeSession.fetchAll($0, sql: "SELECT * FROM claudeSessions ORDER BY linkedAt") }
    }
    public func claudeSession(_ threadId: String) throws -> ClaudeSession? {
        try db.read { try ClaudeSession.fetchOne($0, key: threadId) }
    }
    /// The task session Claude Code knows by this CLI session ID, as its hooks name it.
    public func claudeSession(cliSessionId: String) throws -> ClaudeSession? {
        guard !cliSessionId.isEmpty else { return nil }
        return try db.read { try ClaudeSession.fetchOne($0, sql: "SELECT * FROM claudeSessions WHERE lower(cliSessionId) = lower(?) ORDER BY linkedAt DESC LIMIT 1", arguments: [cliSessionId]) }
    }
    public func threadLink(threadId: String) throws -> ThreadLink? {
        try db.read { try ThreadLink.fetchOne($0, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [threadId]) }
    }

    /// Records intent before the Claude app opens: the user may press Send in its composer any time after this.
    @discardableResult public func handOffToClaudeComposer(_ id: String, now: Date = Date()) throws -> NativeDispatch {
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.agent == .claude else { throw StoreError.notFound }
            if item.awaitsClaudeSend { return item }
            guard item.threadId == nil else { throw StoreError.invalid("This task already has its Claude session. Replies reach it through the Claude runner.") }
            guard item.state == "queued" else { throw StoreError.invalid("This request isn't ready to start yet.") }
            guard let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen else { throw StoreError.notFound }
            try validateStart(db, item: item, now: now)
            item.state = "dispatching"; item.runnerId = Self.claudeComposer; item.availableAt = nil
            try item.update(db)
            try TaskEvent(taskId: task.id, source: .app, kind: "dispatch.composer", payload: item.id, at: now).insert(db)
            return item
        }
    }

    /// A Claude session started for a Facienda request links itself, using the IDs the Claude app gives it.
    /// Linking twice from the same session is harmless; any other session is told to stop.
    @discardableResult public func attachClaudeSession(dispatchId: String, sessionId: String, cliSessionId: String?, cwd: String?, now: Date = Date()) throws -> ClaudeSession {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else {
            throw StoreError.invalid("Run this inside a Claude app session. CLAUDE_CODE_HOST_SESSION_ID is missing from its environment.")
        }
        let session = try write { db -> ClaudeSession in
            guard let item = try NativeDispatch.fetchOne(db, key: dispatchId), item.agent == .claude,
                  let task = try FaciendaTask.fetchOne(db, key: item.taskId) else { throw StoreError.invalid("Facienda has no Claude request with this ID. Stop here.") }
            if ["started", "finished"].contains(item.state) {
                guard item.threadId == sessionId, let session = try ClaudeSession.fetchOne(db, key: sessionId) else {
                    throw StoreError.invalid("This Facienda request already runs in another Claude session. Stop here and do not work on it in this session.")
                }
                return session
            }
            guard item.state == "dispatching", item.threadId == nil || item.threadId == sessionId else {
                throw StoreError.invalid(item.state == "cancelled" ? "This Facienda request was cancelled. Stop here." : "This Facienda request is not waiting for a new Claude session. Stop here.")
            }
            guard task.state.isOpen else { throw StoreError.invalid("This Facienda task is closed. Stop here.") }
            let runner = try Self.claudeRunner(db)
            guard runner?.sessionId != sessionId else { throw StoreError.invalid("The Claude runner cannot carry a task. Start the request in a new session.") }
            try confirmDelivery(db, item, threadId: sessionId, status: "active")
            let session = ClaudeSession(threadId: sessionId, taskId: task.id, cliSessionId: cliSessionId?.isEmpty == false ? cliSessionId : nil,
                cwd: cwd, linkedAt: now, model: task.workerModel, effort: task.workerReasoningEffort, fast: task.workerServiceTier != nil,
                configureState: runner?.isAwake(at: now) == true ? "pending" : "skipped")
            try session.save(db)
            try TaskEvent(taskId: task.id, threadId: sessionId, source: .mcp, kind: "claude.session.linked", payload: session.cliSessionId ?? "", verified: false, at: now).insert(db)
            return session
        }
        if session.configureState == "pending" { signalRunners(session.threadId) }
        return session
    }

    /// The Claude runner's next job. Configuring new sessions comes first, so a session never waits behind a queue.
    /// Work handed out again is leased for two minutes, so an unfinished job cannot wake the runner in a loop.
    public func claimClaudeWork(runnerId: String, now: Date = Date()) throws -> ClaudeWork? {
        // A replaced runner learns that first, not from a later step.
        try db.read { _ = try Self.requireClaudeRunner($0, runnerId) }
        try db.write { try reconcileBlockers($0, now: now) }
        try enqueueDueChecks(runnerId: runnerId, now: now)
        return try write { db in
            let runner = try Self.requireClaudeRunner(db, runnerId)
            try db.execute(sql: "UPDATE claudeRunner SET lastSeen = ? WHERE id = 1", arguments: [now])
            try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE provider = 'claude' AND state IN ('queued', 'claimed') AND taskId IN (SELECT id FROM tasks WHERE state IN ('done', 'dropped'))")
            try Self.expireClaudeConfiguring(db, now: now)
            if var session = try ClaudeSession.fetchOne(db, sql: "SELECT * FROM claudeSessions WHERE configureState = 'pending' ORDER BY linkedAt LIMIT 1") {
                session.configureState = "configuring"; session.configureClaimedAt = now
                try session.update(db)
                return .configure(session, start: try claimClaudeStart(db, for: session, runnerId: runnerId, now: now))
            }
            if var existing = try NativeDispatch.fetchOne(db, sql: """
                SELECT * FROM dispatches WHERE provider = 'claude' AND runnerId = ? AND state IN ('claimed', 'dispatching')
                AND (availableAt IS NULL OR availableAt <= ?) ORDER BY requestedAt LIMIT 1
                """, arguments: [runnerId, now]) {
                existing.availableAt = now.addingTimeInterval(120)
                try existing.update(db)
                return existing.threadId == nil ? .create(existing) : .deliver(existing)
            }
            let newSessions = runner.canStartSessions ? "" : " AND threadId IS NOT NULL"
            guard var item = try NativeDispatch.fetchOne(db, sql: """
                SELECT * FROM dispatches WHERE provider = 'claude' AND state = 'queued'
                AND (availableAt IS NULL OR availableAt <= ?)\(newSessions) ORDER BY requestedAt LIMIT 1
                """, arguments: [now]) else { return nil }
            item.state = "claimed"; item.runnerId = runnerId
            try item.update(db)
            return item.threadId == nil ? .create(item) : .deliver(item)
        }
    }

    /// The start waiting for this session, claimed and begun with its settings. Every runner step reads the runner's
    /// whole conversation, so a start in its own job cost five more steps before the session heard anything.
    /// It stays leased for two minutes: if the runner stops before sending, it comes back as a delivery already begun.
    func claimClaudeStart(_ db: Database, for session: ClaudeSession, runnerId: String, now: Date) throws -> NativeDispatch? {
        guard var item = try NativeDispatch.fetchOne(db, sql: """
            SELECT * FROM dispatches WHERE provider = 'claude' AND state = 'queued' AND threadId = ? AND taskId = ?
            AND (kind IS NULL OR kind = 'start') AND (availableAt IS NULL OR availableAt <= ?) ORDER BY requestedAt LIMIT 1
            """, arguments: [session.threadId, session.taskId, now]),
              let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen else { return nil }
        // A start still held by its prerequisites goes the usual way, where beginning it says why.
        do { try validateStart(db, item: item, now: now) } catch { return nil }
        item.state = "dispatching"; item.runnerId = runnerId; item.availableAt = now.addingTimeInterval(120)
        try item.update(db)
        return item
    }

    /// A start this runner took with a session's settings and has not yet acknowledged. A runner that set up from older
    /// instructions, or lost them in a compaction, hears about it when it reports the settings.
    public func claudeStartToSend(threadId: String, runnerId: String) throws -> NativeDispatch? {
        try db.read { db in
            try NativeDispatch.fetchOne(db, sql: """
                SELECT * FROM dispatches WHERE provider = 'claude' AND state = 'dispatching' AND threadId = ? AND runnerId = ?
                AND (kind IS NULL OR kind = 'start') ORDER BY requestedAt LIMIT 1
                """, arguments: [threadId, runnerId])
        }
    }

    /// Whether the runner has anything to do now. Read-only, for its background wait.
    public func hasClaudeWork(runnerId: String, now: Date = Date()) throws -> Bool {
        try db.read { db in
            let runner = try Self.requireClaudeRunner(db, runnerId)
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM claudeSessions WHERE configureState = 'pending')") == true { return true }
            let newSessions = runner.canStartSessions ? "" : " AND threadId IS NOT NULL"
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM dispatches WHERE provider = 'claude' AND (availableAt IS NULL OR availableAt <= ?) AND (
                  (runnerId = ? AND state IN ('claimed', 'dispatching')) OR (state = 'queued'\(newSessions))))
                """, arguments: [now, runnerId]) == true
        }
    }

    /// A configuration claimed ten minutes ago without an outcome failed; its session goes ahead with the Claude app's choice.
    static func expireClaudeConfiguring(_ db: Database, now: Date) throws {
        try db.execute(sql: """
            UPDATE claudeSessions SET configureState = 'failed', configuredAt = ?, configureNote = 'The runner did not finish applying the model.'
            WHERE configureState = 'configuring' AND configureClaimedAt < ?
            """, arguments: [now, now.addingTimeInterval(-600)])
    }

    public func finishClaudeConfigure(threadId: String, runnerId: String, applied: Bool, note: String?, now: Date = Date()) throws {
        try write { db in
            try Self.requireClaudeRunner(db, runnerId)
            guard var session = try ClaudeSession.fetchOne(db, key: threadId) else { throw StoreError.notFound }
            if session.isSettled { return }
            session.configureState = applied ? "done" : "failed"; session.configuredAt = now
            session.configureNote = note.map { String($0.prefix(500)) }
            try session.update(db)
            try TaskEvent(taskId: session.taskId, threadId: threadId, source: .mcp, kind: applied ? "claude.session.configured" : "claude.session.unconfigured", payload: session.configureNote ?? "", verified: false, at: now).insert(db)
        }
    }

    /// For a new session's background wait. A configuration that ran out of time counts as settled.
    public func settledClaudeSession(_ threadId: String, now: Date = Date()) throws -> ClaudeSession? {
        try write { db in
            try Self.expireClaudeConfiguring(db, now: now)
            if var session = try ClaudeSession.fetchOne(db, key: threadId), session.configureState == "pending", session.linkedAt < now.addingTimeInterval(-300) {
                session.configureState = "failed"; session.configuredAt = now; session.configureNote = "The runner did not pick this session up."
                try session.update(db)
            }
            return try ClaudeSession.fetchOne(db, key: threadId).flatMap { $0.isSettled ? $0 : nil }
        }
    }

    /// Records intent before the runner sends a message to a session or starts a new one.
    @discardableResult public func beginClaudeDelivery(_ id: String, runnerId: String, now: Date = Date()) throws -> NativeDispatch {
        try write { db in
            try Self.requireClaudeRunner(db, runnerId)
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.agent == .claude, item.runnerId == runnerId,
                  let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen else { throw StoreError.conflict }
            if item.state == "dispatching" { return item }
            guard item.state == "claimed" else { throw StoreError.conflict }
            if item.kind == "check" {
                guard let plan = try CheckPlan.fetchOne(db, key: item.taskId), !plan.paused,
                      plan.revision == item.checkRevision, plan.threadId == item.threadId,
                      plan.deadline > now else { throw StoreError.conflict }
            }
            if item.threadId == nil, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM threadLinks WHERE taskId = ? AND role = 'work')", arguments: [task.id]) == true {
                throw StoreError.invalid("This task now has its own session. Send to it instead of starting another.")
            }
            try validateStart(db, item: item, now: now)
            item.state = "dispatching"; item.availableAt = nil
            try item.update(db)
            return item
        }
    }

    /// A delivery the session itself may read: its own reply, check or first instructions.
    public func claudeDelivery(_ id: String, sessionId: String) throws -> NativeDispatch {
        try db.read { db in
            guard let item = try NativeDispatch.fetchOne(db, key: id), item.agent == .claude else { throw StoreError.invalid("Facienda has no Claude request with this ID.") }
            guard item.threadId == sessionId, ["dispatching", "started", "finished"].contains(item.state) else {
                throw StoreError.invalid("This Facienda request belongs to another session. Do not act on it here.")
            }
            return item
        }
    }

    /// The runner's background wait: returns when there is work, or at the deadline. It keeps the runner marked awake
    /// and enqueues due checks itself, so a plan that is due but cannot be delivered never wakes the runner.
    public func waitForClaudeWork(runnerId: String, seconds: TimeInterval) throws -> Bool {
        guard seconds > 0, seconds <= 3600 else { throw StoreError.invalid("Wait between 1 second and one hour.") }
        return try watchingQueue { wake in
            let deadline = Date().addingTimeInterval(seconds)
            var beat = Date.distantPast
            repeat {
                let now = Date()
                if now.timeIntervalSince(beat) >= 60 { try claudeRunnerHeartbeat(runnerId, now: now); beat = now }
                try db.write { try reconcileBlockers($0, now: now) }
                try enqueueDueChecks(runnerId: runnerId, now: now)
                if try hasClaudeWork(runnerId: runnerId, now: now) { return true }
                let soonest = try db.read { db in
                    try Date.fetchOne(db, sql: """
                        SELECT MIN(t) FROM (SELECT MIN(nextCheck) AS t FROM checkPlans WHERE paused = 0 AND nextCheck > ?
                        UNION ALL SELECT MIN(availableAt) FROM dispatches WHERE provider = 'claude' AND availableAt > ?)
                        """, arguments: [now, now])
                }
                let nextBeat = beat.addingTimeInterval(60)
                let until = [deadline, nextBeat, soonest.map { max($0, now.addingTimeInterval(0.05)) } ?? deadline].min()!
                _ = wake.wait(timeout: .now() + max(0.05, until.timeIntervalSinceNow))
            } while Date() < deadline
            return try hasClaudeWork(runnerId: runnerId)
        }
    }
}
