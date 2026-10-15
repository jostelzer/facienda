import Foundation
import GRDB
import Darwin
import CryptoKit

public struct NativeDispatch: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "dispatches"
    public var id: String
    public var taskId: String
    public var state: String
    public var requestedAt: Date
    public var runnerId: String?
    public var threadId: String?
    public var triggerKey: String?
    public var kind: String?
    public var message: String?
    public var checkRevision: Int?
    public var availableAt: Date?
    /// The app that delivers this entry. Filled by the database from the owning chat, else the task's choice.
    public var provider: AgentProvider?
    public var agent: AgentProvider { provider ?? .codex }
    /// A new Claude session waiting for the user to press Send in the Claude app.
    public var awaitsClaudeSend: Bool { state == "dispatching" && runnerId == FaciendaStore.claudeComposer }
    /// Whether this delivery starts the task's work. Checks, assessments and replies do not, so they never wait for prerequisites.
    var startsWork: Bool { !["check", "assess", "reply"].contains(kind ?? "start") }
}

public struct NativeRunnerState: Codable, FetchableRecord, Equatable, Sendable {
    /// The runner's ID: its chat for a heartbeat runner, or a Facienda-made ID for a scheduled one.
    public var threadId: String
    public var automationId: String?
    public var lastSeen: Date?
    /// A scheduled runner is a Codex automation that runs each minute in a fresh chat, so there is no runner chat to open.
    public var scheduled: Bool
    /// The run currently working the queue, so overlapping runs never deliver the same entry twice.
    public var leaseHolder: String?
    public var leaseUntil: Date?
    public var unreportedSeenAt: Date?
    /// Facienda's own dispatcher, rather than a runner that lives in Codex.
    public var isDispatcher: Bool { threadId == FaciendaStore.codexDispatcherId }
}

/// Snapshot used to prepare a complete handoff before recording delivery intent.
public struct NativeDispatchPreparation: Codable, Sendable {
    public var dispatchId: String
    public var runnerId: String
    public var taskRevision: Int
    public var contextKey: String
    public var threadId: String?
    public var contextDigest: String?

    public init(dispatch: NativeDispatch, task: FaciendaTask, context: DispatchContext?) throws {
        dispatchId = dispatch.id; runnerId = dispatch.runnerId ?? ""
        taskRevision = task.revision; contextKey = DispatchContext.key(task: task, dispatch: dispatch)
        threadId = dispatch.threadId; contextDigest = try Self.digest(context)
    }
    static func digest(_ context: DispatchContext?) throws -> String? {
        guard let context else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(context)).map { String(format: "%02x", $0) }.joined()
    }
}

extension FaciendaStore {
    public func saveResult(taskId: String, text: String) throws {
        try write { db in
            guard var task = try FaciendaTask.fetchOne(db, key: taskId) else { throw StoreError.notFound }
            try TaskEvent(taskId: taskId, source: .mcp, kind: "codex.result", payload: text, verified: false).insert(db)
            if task.state == .running, try !Self.claudeTurnRuns(db, taskId: taskId) {
                task.state = .needsMe; task.revision += 1; task.updatedAt = Date()
                try task.update(db)
                try settleWaits(db, now: Date())
            }
        }
        // The documents the answer links to are offered to the task's group. The answer is saved whatever happens here.
        _ = try? proposeSources(fromAnswer: text, taskId: taskId)
    }
    public func runnerState() throws -> NativeRunnerState? {
        try db.read { try NativeRunnerState.fetchOne($0, sql: "SELECT * FROM runnerState WHERE id = 1") }
    }

    public func bindRunner(threadId: String, automationId: String?) throws {
        guard !threadId.isEmpty else { throw StoreError.invalid("A native runner chat is required.") }
        try write { db in
            if let existing = try NativeRunnerState.fetchOne(db, sql: "SELECT * FROM runnerState WHERE id = 1"), existing.threadId != threadId {
                throw StoreError.invalid("This workspace already has a runner. Reuse its chat.")
            }
            try db.execute(sql: "INSERT INTO runnerState(id, threadId, automationId) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET automationId = COALESCE(excluded.automationId, runnerState.automationId)", arguments: [threadId, automationId])
        }
    }

    /// Binds a scheduled runner, or returns the one already bound. A runner chat already bound must be retired first.
    public func bindScheduledRunner(id: String) throws -> String {
        guard !id.isEmpty else { throw StoreError.invalid("A runner ID is required.") }
        return try write { db in
            if let existing = try NativeRunnerState.fetchOne(db, sql: "SELECT * FROM runnerState WHERE id = 1") {
                guard existing.scheduled else { throw StoreError.invalid("This workspace already has a runner chat. Start a new runner in Facienda first.") }
                return existing.threadId
            }
            try db.execute(sql: "INSERT INTO runnerState(id, threadId, scheduled) VALUES (1, ?, 1)", arguments: [id])
            return id
        }
    }

    static let runnerLease: TimeInterval = 300

    /// Starts a scheduled run's turn unless another run holds the queue. A lease that ran out is taken over, and so is
    /// the hold of a dispatcher process that no longer exists, such as an app that quit or crashed while it held it.
    public func beginRunnerTurn(runnerId: String, holder: String, now: Date = Date()) throws -> Bool {
        try write { db in
            guard let runner = try NativeRunnerState.fetchOne(db, sql: "SELECT * FROM runnerState WHERE id = 1"), runner.threadId == runnerId else { throw StoreError.conflict }
            if let other = runner.leaseHolder, other != holder, (runner.leaseUntil ?? .distantPast) > now, !Self.holderIsGone(other) { return false }
            try db.execute(sql: "UPDATE runnerState SET leaseHolder = ?, leaseUntil = ?, lastSeen = ? WHERE id = 1", arguments: [holder, now.addingTimeInterval(Self.runnerLease), now])
            return true
        }
    }

    /// Keeps the lease while the holding run delivers.
    public func renewRunnerLease(runnerId: String, holder: String, now: Date = Date()) throws {
        try write { db in
            try db.execute(sql: "UPDATE runnerState SET leaseUntil = ? WHERE id = 1 AND threadId = ? AND leaseHolder = ?", arguments: [now.addingTimeInterval(Self.runnerLease), runnerId, holder])
        }
    }

    /// How a dispatcher signs its hold on the queue: by its process, so a hold left by a process that is gone is known.
    public static func dispatcherHolder(pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> String { "dispatcher-\(pid)" }

    /// A dispatcher's hold whose process has exited. Other holders, such as scheduled runs, keep their lease.
    public static func holderIsGone(_ holder: String) -> Bool {
        guard holder.hasPrefix("dispatcher-"), let pid = pid_t(holder.dropFirst("dispatcher-".count)), pid > 0 else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    public func endRunnerTurn(runnerId: String, holder: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE runnerState SET leaseHolder = NULL, leaseUntil = NULL WHERE id = 1 AND threadId = ? AND leaseHolder = ?", arguments: [runnerId, holder])
        }
    }

    // MARK: Archiving the runner's runs

    /// Each scheduled run is its own Codex chat. Codex cannot be told to archive them from outside, so a run that ends
    /// cleanly records its chat and the app archives it. A failed run never gets here and stays visible.
    static func registerRunnerRuns(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("runner_runs") { db in
            try db.execute(sql: "CREATE TABLE runnerRuns (threadId TEXT PRIMARY KEY NOT NULL, endedAt DATETIME NOT NULL, archivedAt DATETIME, attempts INTEGER NOT NULL DEFAULT 0)")
        }
    }

    public func recordFinishedRun(_ threadId: String, now: Date = Date()) throws {
        guard !threadId.isEmpty, threadId != "unknown" else { return }
        try write { db in
            // The runner's own bound chat is never one of its runs.
            guard try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") != threadId else { return }
            try db.execute(sql: "INSERT OR IGNORE INTO runnerRuns(threadId, endedAt) VALUES (?, ?)", arguments: [threadId, now])
        }
    }

    /// Finished runs not archived yet. A minute's grace lets the run's last turn close first; three failed tries give up.
    public func runnerRunsToArchive(now: Date = Date()) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT threadId FROM runnerRuns WHERE archivedAt IS NULL AND attempts < 3 AND endedAt < ? ORDER BY endedAt LIMIT 20", arguments: [now.addingTimeInterval(-60)]) }
    }

    public func markRunnerRun(_ threadId: String, archived: Bool, now: Date = Date()) throws {
        try write { db in
            if archived { try db.execute(sql: "UPDATE runnerRuns SET archivedAt = ? WHERE threadId = ?", arguments: [now, threadId]) }
            else { try db.execute(sql: "UPDATE runnerRuns SET attempts = attempts + 1 WHERE threadId = ?", arguments: [threadId]) }
            // Archived runs are forgotten after a week.
            try db.execute(sql: "DELETE FROM runnerRuns WHERE archivedAt < ?", arguments: [now.addingTimeInterval(-7 * 86_400)])
        }
    }

    /// Started checks whose chat has not reported after two minutes. Each is shown to the runner at most every ten
    /// minutes, so a check chat still at work does not cost a full runner turn every minute.
    public func unreportedChecksToInspect(now: Date = Date()) throws -> [NativeDispatch] {
        let waiting = try dispatches().filter { item in
            guard item.agent == .codex, item.kind == "check", item.state == "started", item.requestedAt < now.addingTimeInterval(-120),
                  let plan = try? checkPlan(item.taskId) else { return false }
            return plan.revision == item.checkRevision && !plan.paused
        }
        guard !waiting.isEmpty else { return [] }
        return try write { db in
            let seen = try Date.fetchOne(db, sql: "SELECT unreportedSeenAt FROM runnerState WHERE id = 1")
            guard (seen ?? .distantPast) <= now.addingTimeInterval(-600) else { return [] }
            try db.execute(sql: "UPDATE runnerState SET unreportedSeenAt = ? WHERE id = 1", arguments: [now])
            return waiting
        }
    }

    public func dispatches() throws -> [NativeDispatch] {
        try db.read { try NativeDispatch.fetchAll($0, sql: "SELECT * FROM dispatches ORDER BY requestedAt") }
    }

    /// Whether a chat already took a delivery for this task, so it holds Facienda's instructions and a reply there needs only the user's words.
    public func chatHasInstructions(taskId: String, threadId: String, besides dispatchId: String) throws -> Bool {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dispatches WHERE taskId = ? AND threadId = ? AND state IN ('started', 'finished') AND id != ?",
                             arguments: [taskId, threadId, dispatchId]) ?? 0 > 0
        }
    }

    /// Only explicit UI starts/answers enqueue work. The runner never sweeps tasks.
    @discardableResult public func enqueueDispatch(taskId: String, triggerKey: String? = nil, message: String? = nil) throws -> NativeDispatch {
        let dispatch = try write { db in
            // Starting or answering a parked task by hand takes it back from its wait.
            if var wait = try TaskWait.fetchOne(db, key: taskId), wait.isActive { try cancel(db, &wait, now: Date()) }
            return try queueDispatch(db, taskId: taskId, triggerKey: triggerKey, message: message, source: .user)
        }
        signalRunners(dispatch.id)
        return dispatch
    }

    /// Whether a delivery for the task is queued or on its way.
    static func hasDispatchUnderway(_ db: Database, taskId: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dispatches WHERE taskId = ? AND state IN ('queued', 'claimed', 'dispatching')", arguments: [taskId]) ?? 0 > 0
    }

    /// Queues a delivery that only gives the task a chat to check its conditions in, unless one is already on its way.
    static func queueAssessment(_ db: Database, taskId: String, now: Date) throws {
        guard try !hasDispatchUnderway(db, taskId: taskId) else { return }
        try NativeDispatch(id: UUID().uuidString, taskId: taskId, state: "queued", requestedAt: now, kind: "assess").insert(db)
    }

    /// Wakes a runner's queue wait. Notifications are a hint: a committed queue item survives a missed wake.
    func signalRunners(_ note: String) {
        try? Data(note.utf8).write(to: url.deletingLastPathComponent().appending(path: "runner.signal"), options: .atomic)
    }

    func queueDispatch(_ db: Database, taskId: String, triggerKey: String?, message: String?, source: EventSource) throws -> NativeDispatch {
        do {
            guard let task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.notFound }
            if let triggerKey, let existing = try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE triggerKey = ?", arguments: [triggerKey]) { return existing }
            if let existing = try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND state IN ('queued', 'claimed', 'dispatching')", arguments: [taskId]) {
                if message != nil { throw StoreError.invalid("A delivery is already queued. Cancel it before sending another reply.") }
                return existing
            }
            if message == nil, let held = try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND state = 'held'", arguments: [taskId]) { return held }
            if let message, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StoreError.invalid("Write a reply before sending.") }
            if message != nil, var plan = try CheckPlan.fetchOne(db, key: taskId) {
                plan.paused = true; plan.revision += 1; plan.lastOutcome = CheckPlan.replyPause
                try plan.update(db)
            }
            let previous = try String.fetchOne(db, sql: "SELECT d.threadId FROM dispatches d JOIN threadLinks l ON l.codexThreadId = d.threadId AND l.taskId = d.taskId WHERE d.taskId = ? AND d.state = 'started' ORDER BY d.requestedAt DESC LIMIT 1", arguments: [taskId]) ?? Self.workThreadID(db, taskId: taskId)
            let item = NativeDispatch(id: UUID().uuidString, taskId: taskId, state: "queued", requestedAt: Date(), threadId: previous, triggerKey: triggerKey, kind: message == nil ? "start" : "reply", message: message)
            try item.insert(db)
            if let message { try TaskEvent(taskId: taskId, source: source, kind: source == .user ? "user.reply" : "wait.message", payload: message).insert(db) }
            try TaskEvent(taskId: taskId, source: source, kind: "dispatch.queued", payload: item.id).insert(db)
            try reconcileBlockers(db, now: Date())
            try arrangeBlockerCheck(db, taskId: taskId, threadId: nil, reset: false, now: Date())
            return try NativeDispatch.fetchOne(db, key: item.id) ?? item
        }
    }

    public func cancelDispatch(_ id: String) throws {
        try write { db in
            // A delivery the runner parked for recovery can be dropped too. If it did arrive, its chat stays unlinked.
            guard let item = try NativeDispatch.fetchOne(db, key: id),
                  ["queued", "claimed", "held"].contains(item.state) || (item.state == "dispatching" && item.availableAt != nil) || item.awaitsClaudeSend else {
                throw StoreError.invalid("This start is already being delivered. Open its runner chat to inspect it.")
            }
            try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE id = ?", arguments: [id])
            if item.startsWork, var ready = try TaskReadiness.fetchOne(db, key: item.taskId) {
                ready.armed = false; ready.revision += 1; try ready.update(db)
            }
            if item.kind == "check", var plan = try CheckPlan.fetchOne(db, key: item.taskId) {
                plan.paused = true; plan.revision += 1; try plan.update(db)
            }
            try TaskEvent(taskId: item.taskId, source: .user, kind: "dispatch.cancelled", payload: id).insert(db)
        }
    }

    public func claimDispatch(runnerId: String) throws -> NativeDispatch? {
        try db.write { try reconcileBlockers($0, now: Date()) }
        try enqueueDueChecks(runnerId: runnerId)
        return try db.write { db in
            guard try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") == runnerId else { throw StoreError.invalid("This is not the configured runner.") }
            // Claude entries belong to the Claude runner or the Claude app's composer.
            try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE provider IS NOT 'claude' AND state IN ('queued', 'claimed') AND taskId IN (SELECT id FROM tasks WHERE state IN ('done', 'dropped'))")
            // An uncertain delivery must be reconciled, never silently retried. The runner gets one look at an
            // interrupted one; once it defers it, the delivery is parked for recovery in Facienda and stays there.
            if let existing = try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE provider IS NOT 'claude' AND ((state = 'claimed' AND (availableAt IS NULL OR availableAt <= ?)) OR (state = 'dispatching' AND availableAt IS NULL)) ORDER BY requestedAt LIMIT 1", arguments: [Date()]) { return existing }
            guard var item = try NativeDispatch.fetchOne(db, sql: "SELECT * FROM dispatches WHERE provider IS NOT 'claude' AND state = 'queued' AND (availableAt IS NULL OR availableAt <= ?) ORDER BY requestedAt LIMIT 1", arguments: [Date()]) else { return nil }
            item.state = "claimed"; item.runnerId = runnerId
            try item.update(db)
            return item
        }
    }

    public func beginDispatch(_ id: String, runnerId: String, expectedContextKey: String? = nil, preparation: NativeDispatchPreparation? = nil) throws -> NativeDispatch {
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.state == "claimed", item.runnerId == runnerId,
                  let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen else { throw StoreError.conflict }
            try Self.validateDispatchContext(db, item: item, task: task)
            if let preparation {
                guard preparation.dispatchId == id, preparation.runnerId == runnerId,
                      preparation.taskRevision == task.revision, preparation.threadId == item.threadId,
                      preparation.contextKey == DispatchContext.key(task: task, dispatch: item),
                      preparation.contextDigest == (try NativeDispatchPreparation.digest(Self.readDispatchContext(db, id: id))) else { throw StoreError.conflict }
            }
            if let expectedContextKey, expectedContextKey != DispatchContext.key(task: task, dispatch: item) { throw StoreError.conflict }
            if item.kind == "check" {
                guard let plan = try CheckPlan.fetchOne(db, key: item.taskId), !plan.paused,
                      plan.revision == item.checkRevision, plan.threadId == item.threadId,
                      plan.deadline > Date() else { throw StoreError.conflict }
            }
            try validateStart(db, item: item, now: Date())
            // An entry put off before goes out now; a date left on it would read as a delivery parked for recovery.
            item.state = "dispatching"; item.availableAt = nil; try item.update(db)
            return item
        }
    }

    /// Starts wait for prerequisites and the scheduled date; replies and checks go through.
    func validateStart(_ db: Database, item: NativeDispatch, now: Date) throws {
        guard item.startsWork else { return }
        guard try unmetBlockers(db, taskId: item.taskId, now: now).isEmpty,
              try TaskReadiness.fetchOne(db, key: item.taskId)?.notBefore.map({ $0 <= now }) ?? true else {
            throw StoreError.invalid("This task is still waiting for its prerequisites or scheduled date.")
        }
    }

    /// When the user sends a delivery again after the runner blocked one for this task, the runner must not
    /// read that old block, or the brief it left, as a reason to block again.
    public func userRestartNote(for item: NativeDispatch) throws -> String? {
        guard let blocked = try latestEvent(taskId: item.taskId, kind: "dispatch.blocked") else { return nil }
        let resent = try events(taskId: item.taskId).contains { event in
            event.source == .user && event.at > blocked.at
                && ((event.kind == "dispatch.queued" && event.payload == item.id) || (event.kind == "dispatch.recovery" && event.payload.hasPrefix(item.id + ":")))
        }
        guard resent else { return nil }
        return "The user sent this again after an earlier delivery was blocked (\(blocked.payload)). That block, and the same note in the task brief or past uncertainties, is history, not prior uncertain creation: no chat holds this dispatch's marker. Discover, then create or send normally."
    }

    /// Explicit recovery after inspecting native delivery evidence. Never called by
    /// automatic queue reconciliation: an absent search result cannot prove failure.
    public func retryUndeliveredDispatch(_ id: String, evidence: String) throws {
        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalid("Record why the native create/send operation did not happen before retrying.")
        }
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.state == "dispatching", item.availableAt != nil,
                  let task = try FaciendaTask.fetchOne(db, key: item.taskId), task.state.isOpen,
                  try TaskEvent.fetchOne(db, sql: "SELECT * FROM events WHERE taskId = ? AND kind = 'dispatch.blocked' ORDER BY at DESC LIMIT 1", arguments: [task.id]) != nil else { throw StoreError.conflict }
            guard item.kind != "check" else { throw StoreError.invalid("This check was paused after delivery failed. Reconcile its owning chat and review the saved check plan instead of retrying a stale check.") }
            item.state = "queued"; item.runnerId = nil; item.availableAt = nil
            try item.update(db)
            try TaskEvent(taskId: task.id, source: .user, kind: "dispatch.recovery", payload: "\(id): \(evidence)").insert(db)
        }
        signalRunners(id)
    }

    /// `markerEvidence` is the chat message that holds this delivery's exact marker. A parked delivery, one the
    /// runner deferred as uncertain, is acknowledged only with it: an empty search must never become a delivery.
    public func acknowledgeDispatch(_ id: String, runnerId: String, threadId: String, markerEvidence: String? = nil) throws {
        guard !threadId.isEmpty else { throw StoreError.invalid("A confirmed native chat ID is required.") }
        try write { db in
            guard let item = try NativeDispatch.fetchOne(db, key: id), item.runnerId == runnerId else { throw StoreError.conflict }
            let parked = item.state == "dispatching" && item.availableAt != nil && item.agent != .claude
            if parked {
                guard let markerEvidence, markerEvidence.contains("Facienda dispatch: \(id)") else {
                    throw StoreError.invalid("This delivery was parked as uncertain. Acknowledge it only with --marker-file holding the chat message with its exact marker, Facienda dispatch: \(id). Without one, leave it to recovery in Facienda.")
                }
            }
            try confirmDelivery(db, item, threadId: threadId, status: "active")
            if parked { try TaskEvent(taskId: item.taskId, threadId: threadId, source: .app, kind: "dispatch.recovery", payload: "\(id): runner found the delivery marker in this chat", verified: false).insert(db) }
        }
    }

    /// A check whose chat the Codex app holds runs in a copy of that chat Codex never saves. The copy takes the
    /// delivery before its turn starts, so what the turn asks reaches the task; it is never linked, so the task keeps its chat.
    public func runCheckInCopy(_ id: String, runnerId: String, threadId copy: String) throws {
        guard !copy.isEmpty else { throw StoreError.invalid("A confirmed native chat ID is required.") }
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.runnerId == runnerId, item.kind == "check",
                  item.state == "dispatching", item.availableAt == nil, let owner = item.threadId,
                  try Self.isLinked(db, taskId: item.taskId, threadId: owner) else { throw StoreError.conflict }
            item.threadId = copy; try item.update(db)
        }
    }

    /// Whether a check ran in a copy of the task's chat rather than the chat itself.
    public func isCheckCopy(_ item: NativeDispatch) -> Bool {
        guard item.kind == "check", let thread = item.threadId else { return false }
        return (try? db.read { try !Self.isLinked($0, taskId: item.taskId, threadId: thread) }) ?? false
    }

    /// Recovery once the chat holding this delivery's exact marker is known: the native call did happen,
    /// so that chat is linked instead of sending again. `status` is the chat's current state in Codex,
    /// because a delivery found late may have finished long ago.
    public func acknowledgeRecoveredDispatch(_ id: String, threadId: String, status: String, source: EventSource) throws {
        guard !threadId.isEmpty else { throw StoreError.invalid("A confirmed native chat ID is required.") }
        try write { db in
            guard let item = try NativeDispatch.fetchOne(db, key: id) else { throw StoreError.notFound }
            if ["started", "finished"].contains(item.state), item.threadId == threadId { return }
            guard item.state == "dispatching", item.availableAt != nil else { throw StoreError.conflict }
            try confirmDelivery(db, item, threadId: threadId, status: status)
            try TaskEvent(taskId: item.taskId, threadId: threadId, source: source, kind: "dispatch.recovery", payload: "\(id): delivery marker found in this chat").insert(db)
        }
    }

    func confirmDelivery(_ db: Database, _ item: NativeDispatch, threadId: String, status: String) throws {
        var item = item
        let id = item.id
        if ["started", "finished"].contains(item.state), item.threadId == threadId { return }
        guard item.state == "dispatching", let task = try FaciendaTask.fetchOne(db, key: item.taskId) else { throw StoreError.conflict }
        if let expected = item.threadId, expected != threadId { throw StoreError.invalid("Continue the existing chat instead of creating a replacement.") }
        // A new chat is linked to its task. A check goes to the task's linked chat, or to a copy of it that stays unlinked.
        if let link = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [threadId]) {
            guard link.taskId == item.taskId else { throw StoreError.conflict }
        } else if item.kind != "check" {
            let context = try Self.readDispatchContext(db, id: item.id)
            try ThreadLink(taskId: item.taskId, codexThreadId: threadId, linkedBy: item.agent == .claude ? "Claude session" : "native runner", title: context?.owner?.title ?? task.displayName, provider: item.agent).insert(db)
        }
        item.state = "started"; item.threadId = threadId; try item.update(db)
        if !["check", "assess"].contains(item.kind ?? "start") {
            // Codex starts the turn before the runner can ack, so hooks fired during delivery may have found no
            // linked task. Replay the latest; without any, confirmed delivery itself means the turn is underway.
            let early = try TaskEvent.fetchAll(db, sql: "SELECT * FROM events WHERE threadId = ? AND source = 'hook' AND kind LIKE 'hook.%' AND at >= ? ORDER BY at DESC", arguments: [threadId, item.requestedAt])
                .lazy.compactMap { event in HookEvent.status(for: String(event.kind.dropFirst("hook.".count))).map { (status: $0, at: event.at) } }.first
            if let early { try observe(db, threadId: threadId, status: early.status, source: .hook, verified: true, at: early.at) }
            else { try observe(db, threadId: threadId, status: status, source: .app, verified: true) }
        }
        if item.kind == "assess" {
            try arrangeBlockerCheck(db, taskId: item.taskId, threadId: threadId, reset: false, now: Date())
        } else if item.startsWork, var ready = try TaskReadiness.fetchOne(db, key: item.taskId) {
            ready.armed = false; ready.revision += 1; try ready.update(db)
        }
        try TaskEvent(taskId: item.taskId, threadId: threadId, source: .app, kind: "dispatch.started", payload: id, verified: false).insert(db)
    }

    public func runnerHeartbeat(_ runnerId: String) throws {
        try write { db in
            guard try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") == runnerId else { throw StoreError.conflict }
            try db.execute(sql: "UPDATE runnerState SET lastSeen = ? WHERE id = 1", arguments: [Date()])
        }
    }

    /// Intended for the bundled command-line helper, never the app's main thread.
    public func waitForDispatch(runnerId: String, seconds: TimeInterval) throws -> NativeDispatch? {
        guard seconds >= 0, seconds <= 50 else { throw StoreError.invalid("Wait must be between 0 and 50 seconds.") }
        return try watchingQueue { wake in
            try runnerHeartbeat(runnerId)
            let deadline = DispatchTime.now() + seconds
            repeat {
                if let item = try claimDispatch(runnerId: runnerId) { return item }
                let next = try db.read { try Date.fetchOne($0, sql: "SELECT MIN(nextCheck) FROM checkPlans WHERE paused = 0 AND nextCheck > ?", arguments: [Date()]) }
                let nextWake = next.map { min(deadline, DispatchTime.now() + max(0.05, $0.timeIntervalSinceNow)) } ?? deadline
                _ = wake.wait(timeout: nextWake)
            } while DispatchTime.now() < deadline
            // Last check covers a committed write whose hint could not be delivered.
            return try claimDispatch(runnerId: runnerId)
        }
    }

    /// Runs a queue wait that wakes early whenever the library folder changes, as it does when work is queued.
    func watchingQueue<T>(_ body: (DispatchSemaphore) throws -> T) throws -> T {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { throw StoreError.invalid("Could not watch the task queue.") }
        let wake = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { wake.signal() }
        source.setCancelHandler { close(fd) }
        source.activate()
        defer { source.cancel() }
        return try body(wake)
    }
}
