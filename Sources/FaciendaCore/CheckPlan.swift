import Foundation
import GRDB

public struct CheckPlan: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "checkPlans"
    public var taskId: String
    public var threadId: String
    public var revision: Int
    public var nextCheck: Date
    public var purpose: String
    public var reason: String
    public var paused: Bool
    public var pinned: Bool
    public var minimumInterval: TimeInterval
    public var deadline: Date
    public var failures: Int
    public var checks: Int
    public var lastChecked: Date?
    public var lastOutcome: String?

    /// Why a plan stopped when the user replied. That pause is Facienda's, not the user's, so the chat may plan again.
    public static let replyPause = "Checks paused while your new instruction is handled."
    public var pausedForReply: Bool { paused && lastOutcome == Self.replyPause }

    /// Twenty checks, or as many as the cadence needs to reach the deadline, up to a sane ceiling.
    public func checkLimit(now: Date) -> Int {
        min(200, max(20, checks + Int(ceil(max(0, deadline.timeIntervalSince(now)) / max(60, minimumInterval))) + 1))
    }
}

extension FaciendaStore {
    public func checkPlan(_ taskId: String) throws -> CheckPlan? {
        try db.read { try CheckPlan.fetchOne($0, key: taskId) }
    }
    public func checkPlans() throws -> [CheckPlan] { try db.read { try CheckPlan.fetchAll($0) } }

    /// Agent proposals use compare-and-swap; the user may pin/pause the accepted plan.
    @discardableResult public func planCheck(taskId: String, threadId: String, expectedRevision: Int, nextCheck: Date, purpose: String, reason: String, waitingOn: String, now: Date = Date()) throws -> CheckPlan {
        guard nextCheck > now, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !waitingOn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("A check needs a future date, purpose, reason and dependency.") }
        return try write { db in
            guard var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen,
                  try Self.isLinked(db, taskId: taskId, threadId: threadId) else { throw StoreError.notFound }
            let old = try CheckPlan.fetchOne(db, key: taskId)
            guard (old?.revision ?? 0) == expectedRevision else { throw StoreError.conflict }
            if let old, (old.paused && !old.pausedForReply) || old.pinned || old.threadId != threadId { throw StoreError.invalid("The user controls this plan. Preserve its pause, pinned time and owning chat.") }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dispatches WHERE taskId = ? AND kind = 'check' AND state IN ('queued', 'claimed', 'dispatching', 'started') AND checkRevision = ?", arguments: [taskId, expectedRevision]) == 0 else { throw StoreError.invalid("Finish the outstanding check with report_check.") }
            var plan = old.map { old in
                guard old.pausedForReply else { return old }
                // Picking up after a reply: a fresh run of checks with room to reach the new date.
                var resumed = old
                resumed.paused = false; resumed.failures = 0; resumed.checks = 0; resumed.lastOutcome = nil
                resumed.deadline = max(old.deadline, nextCheck.addingTimeInterval(86400))
                return resumed
            } ?? CheckPlan(taskId: taskId, threadId: threadId, revision: 0, nextCheck: nextCheck, purpose: purpose, reason: reason, paused: false, pinned: false, minimumInterval: 3600, deadline: max(now.addingTimeInterval(30 * 86400), nextCheck.addingTimeInterval(86400)), failures: 0, checks: 0)
            guard nextCheck <= plan.deadline else { throw StoreError.invalid("The check is beyond the plan's review deadline.") }
            plan.revision += 1; plan.nextCheck = nextCheck; plan.purpose = purpose; plan.reason = reason
            try plan.save(db)
            task.state = .waiting; task.waitingOn = waitingOn; task.checkAt = nextCheck; task.returnAt = nextCheck; task.nextAction = purpose
            task.revision += 1; task.updatedAt = now; try task.update(db)
            try TaskEvent(taskId: taskId, threadId: threadId, source: .mcp, kind: "check.planned", payload: try JSONValue.encoded(plan).json, verified: false).insert(db)
            return try CheckPlan.fetchOne(db, key: taskId) ?? plan
        }
    }

    /// One user control path for pause, resume, check now, date and cadence changes.
    @discardableResult public func controlCheck(taskId: String, expectedRevision: Int, paused: Bool, pinned: Bool, nextCheck: Date, minimumInterval: TimeInterval? = nil, deadline: Date? = nil) throws -> CheckPlan {
        try write { db in
            guard var plan = try CheckPlan.fetchOne(db, key: taskId), plan.revision == expectedRevision,
                  var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.conflict }
            let interval = minimumInterval ?? plan.minimumInterval
            let end = deadline ?? plan.deadline
            guard interval >= 60, interval <= 30 * 86400, end >= nextCheck else { throw StoreError.invalid("Choose a review deadline after the check and a check interval of at least one minute.") }
            plan.revision += 1; plan.paused = paused; plan.pinned = pinned; plan.nextCheck = nextCheck
            plan.minimumInterval = interval; plan.deadline = end
            if !paused { plan.failures = 0; plan.checks = 0 }
            try plan.update(db)
            try Self.cancelQueuedChecks(db, taskId: taskId)
            task.state = .waiting; task.checkAt = nextCheck; task.returnAt = nextCheck; task.revision += 1; task.updatedAt = Date(); try task.update(db)
            try TaskEvent(taskId: taskId, source: .user, kind: paused ? "check.paused" : "check.changed", payload: try JSONValue.encoded(plan).json).insert(db)
            return try CheckPlan.fetchOne(db, key: taskId) ?? plan
        }
    }

    /// Withdraws checks not delivered yet, once their plan has changed.
    static func cancelQueuedChecks(_ db: Database, taskId: String) throws {
        try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE taskId = ? AND kind = 'check' AND state IN ('queued', 'claimed')", arguments: [taskId])
    }

    /// Called by the existing runner, so closing the dashboard does not lose dates.
    public func enqueueDueChecks(runnerId: String, now: Date = Date()) throws {
        try db.write { db in
            // Each app's runner checks through its own chats; Codex also settles plans whose chat is gone.
            guard let provider = try Self.runnerProvider(db, runnerId) else { throw StoreError.conflict }
            let plans = try CheckPlan.fetchAll(db, sql: "SELECT * FROM checkPlans WHERE paused = 0 AND (nextCheck <= ? OR deadline <= ?)", arguments: [now, now])
            for var plan in plans {
                let owner = try AgentProvider.fetchOne(db, sql: "SELECT provider FROM threadLinks WHERE taskId = ? AND codexThreadId = ?", arguments: [plan.taskId, plan.threadId])
                guard owner == provider || (owner == nil && provider == .codex) else { continue }
                guard var task = try FaciendaTask.fetchOne(db, key: plan.taskId), task.state.isOpen else { continue }
                if plan.deadline <= now || plan.checks >= plan.checkLimit(now: now) {
                    plan.paused = true; plan.revision += 1; plan.lastOutcome = "Review this follow-up before checking again."
                    try plan.update(db)
                    try Self.cancelQueuedChecks(db, taskId: task.id)
                    task.state = .needsMe; task.revision += 1; task.updatedAt = now; try task.update(db)
                    try TaskEvent(taskId: task.id, source: .app, kind: "check.review", payload: plan.lastOutcome!).insert(db)
                    continue
                }
                // Once observed met, volatile conditions only need refreshing when the rest of the gate is ready.
                let external = try Self.externalBlockers(db, taskId: task.id)
                if !external.isEmpty && external.allSatisfy({ $0.status == "met" }) {
                    let later = try TaskReadiness.fetchOne(db, key: task.id)?.notBefore.map { $0 > now } ?? false
                    if try later || unmetBlockers(db, taskId: task.id, now: now).contains(where: { $0.kind == "task" }) { continue }
                }
                guard task.state == .waiting else { continue }
                guard try Self.isLinked(db, taskId: task.id, threadId: plan.threadId) else {
                    plan.paused = true; plan.revision += 1; plan.lastOutcome = "The owning chat is no longer linked."
                    try plan.update(db); task.state = .needsMe; task.revision += 1; try task.update(db)
                    continue
                }
                let key = "check:\(task.id):\(plan.revision)"
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dispatches WHERE triggerKey = ? OR (taskId = ? AND state IN ('queued', 'claimed', 'dispatching'))", arguments: [key, task.id]) == 0 else { continue }
                let item = NativeDispatch(id: UUID().uuidString, taskId: task.id, state: "queued", requestedAt: now, threadId: plan.threadId, triggerKey: key, kind: "check", checkRevision: plan.revision)
                try item.insert(db)
                try TaskEvent(taskId: task.id, source: .app, kind: "check.queued", payload: item.id, at: now).insert(db)
            }
        }
    }

    /// Outcome and the next appointment commit together. Replays are idempotent.
    /// Facienda sets the next appointment from the plan's cadence; a date the chat proposes is ignored.
    @discardableResult public func reportCheck(taskId: String, dispatchId: String, expectedRevision: Int, outcome: String, summary: String, nextCheck: Date?, reason: String, blockerReports: [BlockerObservation] = [], now: Date = Date()) throws -> CheckPlan {
        guard ["unchanged", "changed", "failed"].contains(outcome), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Report unchanged, changed or failed with evidence.") }
        return try write { db in
            guard var plan = try CheckPlan.fetchOne(db, key: taskId),
                  var item = try NativeDispatch.fetchOne(db, key: dispatchId), item.taskId == taskId, item.kind == "check", item.checkRevision == expectedRevision,
                  var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.conflict }
            if item.state == "finished" { return plan }
            guard plan.revision == expectedRevision, !plan.paused, ["dispatching", "started"].contains(item.state) else { throw StoreError.conflict }
            let blockers = try TaskBlocker.fetchAll(db, sql: "SELECT * FROM taskBlockers WHERE taskId = ? AND removed = 0", arguments: [taskId])
            if outcome != "failed" { try applyBlockerObservations(db, taskId: taskId, observations: blockerReports, now: now) }
            else {
                for var blocker in blockers where blocker.kind != "task" && (blocker.status != "met" || blocker.freshnessSeconds != nil) {
                    blocker.status = "unknown"; blocker.evidence = summary; blocker.observedAt = now; try blocker.update(db)
                }
            }
            let allMet = try unmetBlockers(db, taskId: taskId, now: now).isEmpty
            let conditionsMet = try unmetBlockers(db, taskId: taskId, now: now).allSatisfy { $0.kind == "task" }
            let settled = !blockers.isEmpty && conditionsMet && !blockers.contains { $0.freshnessSeconds != nil }
            let changed = blockers.isEmpty ? outcome == "changed" : allMet
            plan.lastChecked = now; plan.lastOutcome = summary; plan.checks += 1
            plan.failures = outcome == "failed" ? plan.failures + 1 : 0
            let stop = (blockers.isEmpty && changed) || settled || plan.failures >= 3 || plan.checks >= plan.checkLimit(now: now) || now >= plan.deadline
            if stop {
                plan.paused = true; task.state = .needsMe
                if settled { plan.lastOutcome = "All conditions met" }
                else if plan.failures >= 3 { plan.lastOutcome = summary + " Checks paused after three failures." }
                else if outcome != "changed" { plan.lastOutcome = summary + " Review this follow-up before checking again." }
            } else {
                let spacing = plan.minimumInterval * pow(2, Double(outcome == "failed" ? plan.failures : 0))
                plan.nextCheck = min(plan.deadline, now.addingTimeInterval(spacing))
                plan.pinned = false; task.state = .waiting
            }
            plan.revision += 1; try plan.update(db)
            item.state = "finished"; try item.update(db)
            task.checkAt = plan.nextCheck; task.returnAt = plan.nextCheck; task.revision += 1; task.updatedAt = now
            if changed { task.brief = summary; try TaskEvent(taskId: taskId, source: .mcp, kind: "codex.result", payload: summary, verified: false).insert(db) }
            try task.update(db)
            try TaskEvent(taskId: taskId, threadId: plan.threadId, source: .mcp, kind: "check.\(outcome)", payload: summary, verified: false, at: now).insert(db)
            try reconcileBlockers(db, now: now)
            return try CheckPlan.fetchOne(db, key: taskId) ?? plan
        }
    }

    public func deferDispatch(_ id: String, runnerId: String, reason: String, blocked: Bool = false, now: Date = Date()) throws {
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.runnerId == runnerId, (["claimed", "dispatching"].contains(item.state) || (blocked && item.kind == "check" && item.state == "started")) else { throw StoreError.conflict }
            item.availableAt = now.addingTimeInterval(blocked ? 3600 : 60)
            try item.update(db)
            // Why it waits, once each time the reason changes rather than on every retry, so the task can say so.
            if !blocked, try String.fetchOne(db, sql: "SELECT payload FROM events WHERE taskId = ? AND kind = 'dispatch.deferred' AND at >= ? ORDER BY at DESC LIMIT 1",
                                              arguments: [item.taskId, item.requestedAt]) != reason {
                try TaskEvent(taskId: item.taskId, threadId: item.threadId, source: .app, kind: "dispatch.deferred", payload: reason, verified: false, at: now).insert(db)
            }
            if blocked, var task = try FaciendaTask.fetchOne(db, key: item.taskId) {
                if var plan = try CheckPlan.fetchOne(db, key: task.id) { plan.paused = true; plan.revision += 1; plan.lastOutcome = reason; try plan.update(db) }
                if item.state == "claimed" { item.state = "cancelled"; try item.update(db) }
                else if item.state == "started" { item.state = "finished"; try item.update(db) }
                task.state = .needsMe; task.brief = reason; task.revision += 1; try task.update(db)
                try TaskEvent(taskId: task.id, source: .app, kind: "dispatch.blocked", payload: reason, verified: false).insert(db)
            }
        }
    }

    /// The user wrote in a task's chat in the Codex app while a reply from Facienda still waited for that chat, which
    /// Codex keeps to itself while it shows it. The conversation moved on without the reply, so it is withdrawn rather
    /// than sent late, and the task says so. Facienda's own sends are already dispatching when their turn starts.
    public func withdrawOvertakenReplies(threadId: String, now: Date = Date()) throws {
        try write { db in
            let items = try NativeDispatch.fetchAll(db, sql: "SELECT * FROM dispatches WHERE threadId = ? AND kind = 'reply' AND state IN ('queued', 'claimed') AND provider IS NOT 'claude'", arguments: [threadId])
            for var item in items {
                item.state = "cancelled"; try item.update(db)
                try TaskEvent(taskId: item.taskId, threadId: threadId, source: .hook, kind: "dispatch.overtaken", payload: item.id, verified: true, at: now).insert(db)
                guard var task = try FaciendaTask.fetchOne(db, key: item.taskId) else { continue }
                let words = (item.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                task.brief = "You carried on in the Codex app, so Facienda did not send your reply" + (words.isEmpty ? "." : ": “\(String(words.prefix(200)))”. Send it again if it still applies.")
                task.revision += 1; task.updatedAt = now; try task.update(db)
            }
        }
    }
}
