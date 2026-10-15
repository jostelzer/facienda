import Foundation
import GRDB

public struct TaskWait: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "waits"
    public var taskId: String
    public var plan: WaitPlan
    /// active, met, gaveUp, blocked or cancelled.
    public var state: String
    public var outcome: String
    /// Parking created the check plan, so ending the wait removes it.
    public var ownsCheckPlan: Bool
    public var createdAt: Date
    public var settledAt: Date?
    public var notifiedAt: Date?
    /// The task's state before parking, restored by undo.
    public var priorState: TaskState? = nil
    public var isActive: Bool { state == "active" }
}

extension FaciendaStore {
    static func registerWaits(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16_waits") { db in
            try db.execute(sql: """
            CREATE TABLE waits (
              taskId TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id), plan TEXT NOT NULL, state TEXT NOT NULL,
              outcome TEXT NOT NULL, ownsCheckPlan BOOLEAN NOT NULL, createdAt DATETIME NOT NULL,
              settledAt DATETIME, notifiedAt DATETIME
            );
            CREATE INDEX waits_state ON waits(state);
            """)
        }
        migrator.registerMigration("waits_prior_state") { db in try db.execute(sql: "ALTER TABLE waits ADD COLUMN priorState TEXT") }
    }

    public func wait(_ taskId: String) throws -> TaskWait? { try db.read { try TaskWait.fetchOne($0, key: taskId) } }
    public func waits() throws -> [TaskWait] { try db.read { try TaskWait.fetchAll($0) } }

    /// Parks a task until its conditions hold. Replaces any earlier wait on the task.
    @discardableResult public func park(_ taskId: String, plan: WaitPlan, now: Date = Date()) throws -> TaskWait {
        try plan.validate(now: now)
        return try write { db in
            guard var task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.notFound }
            let owner = try Self.workThreadID(db, taskId: taskId)
            if plan.then == .tell && owner == nil { throw StoreError.invalid("This task has no chat yet. Choose Start the work instead.") }
            let previous = try TaskWait.fetchOne(db, key: taskId).flatMap { $0.isActive ? $0 : nil }
            if let previous { try release(db, previous, now: now) }
            // Like a snooze, parking withdraws work that has not been delivered yet.
            try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE taskId = ? AND state IN ('queued', 'claimed', 'held')", arguments: [taskId])
            var plan = plan
            let hadCheckPlan = try CheckPlan.fetchOne(db, key: taskId) != nil
            for index in plan.conditions.indices {
                plan.conditions[index] = try track(db, plan.conditions[index], taskId: taskId)
            }
            var ownsCheckPlan = false
            if plan.hasObservedConditions {
                try watchObservedConditions(db, taskId: taskId, plan: plan, hasChat: owner != nil, now: now)
                // The plan may only appear once the checking chat exists; it still belongs to this wait.
                ownsCheckPlan = !hadCheckPlan
            }
            // Choosing to pause answers what was still pending: the agent's open asks and any proposal to finish.
            // Asks that arrive while paused still bring the task back.
            try closePendingAsks(db, taskId: taskId, now: now)
            let wait = TaskWait(taskId: taskId, plan: plan, state: "active", outcome: "", ownsCheckPlan: ownsCheckPlan, createdAt: now, priorState: previous?.priorState ?? task.state)
            try wait.save(db)
            task.snoozeCount += 1
            try present(db, &task, wait, now: now, force: true)
            try TaskEvent(taskId: taskId, source: .user, kind: "wait.parked", payload: plan.summary, at: now).insert(db)
            try reconcileBlockers(db, now: now)
            return try TaskWait.fetchOne(db, key: taskId) ?? wait
        }
    }

    /// Saves the prerequisite that tracks a condition. A task the parked one already depends on keeps its link.
    private func track(_ db: Database, _ condition: WaitCondition, taskId: String) throws -> WaitCondition {
        var condition = condition
        switch condition.kind {
        case .time: break
        case .task:
            let prerequisiteId = condition.taskId!
            try validateDependency(db, taskId: taskId, prerequisiteId: prerequisiteId)
            guard try FaciendaTask.fetchOne(db, key: prerequisiteId)?.state.isOpen == true else { throw StoreError.invalid("That task is already closed.") }
            if let existing = try TaskBlocker.fetchOne(db, sql: "SELECT * FROM taskBlockers WHERE taskId = ? AND prerequisiteId = ? AND removed = 0", arguments: [taskId, prerequisiteId]) {
                condition.blockerId = existing.id
            } else {
                let blocker = TaskBlocker(taskId: taskId, kind: "task", prerequisiteId: prerequisiteId, title: try FaciendaTask.fetchOne(db, key: prerequisiteId)!.displayName)
                try blocker.insert(db)
                condition.blockerId = blocker.id; condition.ownsBlocker = true
            }
        case .observed:
            var blocker = TaskBlocker(taskId: taskId, kind: "condition", title: condition.what)
            blocker.sourceReference = condition.source; blocker.criterion = condition.criterion
            try blocker.insert(db)
            condition.blockerId = blocker.id; condition.ownsBlocker = true
        }
        return condition
    }

    /// Observed conditions are checked by the task's chat at the wait's cadence, until the wait gives up.
    private func watchObservedConditions(_ db: Database, taskId: String, plan: WaitPlan, hasChat: Bool, now: Date) throws {
        try arrangeBlockerCheck(db, taskId: taskId, threadId: nil, reset: true, now: now)
        if !hasChat {
            // Something has to look. A small chat is created for the checks only.
            try Self.queueAssessment(db, taskId: taskId, now: now)
        }
        guard var check = try CheckPlan.fetchOne(db, key: taskId) else { return }
        if check.paused && check.lastOutcome != "All conditions met" { check.paused = false; check.failures = 0; check.checks = 0 }
        if let giveUpAt = plan.giveUpAt { check.deadline = giveUpAt; check.nextCheck = min(check.nextCheck, giveUpAt) }
        else if check.deadline <= now { check.deadline = now.addingTimeInterval(30 * 86400) }
        // The cadence is both the floor the store enforces and the rhythm the chat is asked to keep.
        check.minimumInterval = plan.checkInterval
        check.reason = "Look about " + WaitPlan.cadenceLabel(plan.checkInterval) + (plan.giveUpAt.map { ", giving up " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "") + "."
        check.revision += 1; try check.update(db)
    }

    /// The user ends the wait early and takes the task back.
    public func wake(_ taskId: String, now: Date = Date()) throws {
        try write { db in
            guard var wait = try TaskWait.fetchOne(db, key: taskId), wait.isActive, var task = try FaciendaTask.fetchOne(db, key: taskId) else { throw StoreError.conflict }
            try cancel(db, &wait, now: now)
            if task.state == .waiting || task.state == .scheduled {
                task.state = .needsMe; task.checkAt = nil; task.returnAt = now; task.revision += 1; task.updatedAt = now; try task.update(db)
            }
            try TaskEvent(taskId: taskId, source: .user, kind: "wait.cancelled", payload: wait.plan.summary, at: now).insert(db)
            try reconcileBlockers(db, now: now)
        }
    }

    /// Undo of parking: the wait is withdrawn and the task goes back to how it was.
    public func unpark(_ taskId: String, now: Date = Date()) throws {
        try write { db in
            guard var wait = try TaskWait.fetchOne(db, key: taskId), wait.isActive, var task = try FaciendaTask.fetchOne(db, key: taskId) else { throw StoreError.conflict }
            try cancel(db, &wait, now: now)
            if task.state == .waiting || task.state == .scheduled {
                let prior = wait.priorState ?? .needsMe
                task.state = [.waiting, .scheduled, .done, .dropped].contains(prior) ? .needsMe : prior
                task.checkAt = nil; task.returnAt = now; task.revision += 1; task.updatedAt = now; try task.update(db)
            }
            try TaskEvent(taskId: taskId, source: .user, kind: "wait.undone", payload: wait.plan.summary, at: now).insert(db)
            try reconcileBlockers(db, now: now)
        }
    }

    /// Waits that ended and have not been announced yet. The app turns them into notifications.
    public func claimWaitNotices(now: Date = Date()) throws -> [TaskWait] {
        try write { db in
            try settleWaits(db, now: now)
            let ended = try TaskWait.fetchAll(db, sql: "SELECT * FROM waits WHERE state != 'active' AND notifiedAt IS NULL")
            try db.execute(sql: "UPDATE waits SET notifiedAt = ? WHERE state != 'active' AND notifiedAt IS NULL", arguments: [now])
            return ended
        }
    }

    /// Ends a wait quietly: nothing is announced, and what parking added is removed.
    func cancel(_ db: Database, _ wait: inout TaskWait, now: Date) throws {
        try release(db, wait, now: now)
        wait.state = "cancelled"; wait.settledAt = now; wait.notifiedAt = now; try wait.update(db)
    }

    /// Removes what parking added: its unmet prerequisites and the check plan it created.
    func release(_ db: Database, _ wait: TaskWait, now: Date) throws {
        let tasks = try FaciendaTask.fetchAll(db)
        var external = false
        for condition in wait.plan.conditions where condition.ownsBlocker {
            guard let id = condition.blockerId, var blocker = try TaskBlocker.fetchOne(db, key: id), !blocker.removed, !blocker.isMet(tasks: tasks, now: now) else { continue }
            blocker.removed = true; blocker.revision += 1; try blocker.update(db)
            external = external || blocker.kind != "task"
        }
        let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taskBlockers WHERE taskId = ? AND removed = 0 AND kind != 'task'", arguments: [wait.taskId]) ?? 0
        if wait.ownsCheckPlan && remaining == 0 {
            try db.execute(sql: "DELETE FROM checkPlans WHERE taskId = ?", arguments: [wait.taskId])
            try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE taskId = ? AND kind IN ('check', 'assess') AND state IN ('queued', 'claimed')", arguments: [wait.taskId])
        } else if external, var check = try CheckPlan.fetchOne(db, key: wait.taskId) {
            check.revision += 1; try check.update(db)
            try Self.cancelQueuedChecks(db, taskId: wait.taskId)
        }
    }

    /// Keeps a parked task looking parked. Only writes when something differs.
    private func present(_ db: Database, _ task: inout FaciendaTask, _ wait: TaskWait, now: Date, force: Bool = false) throws {
        guard task.state != .running else { if force { task.revision += 1; task.updatedAt = now; try task.update(db) }; return }
        let original = task
        let others = wait.plan.conditions.filter { $0.kind != .time }
        let check = try CheckPlan.fetchOne(db, key: task.id)
        task.state = others.isEmpty ? .scheduled : .waiting
        task.returnAt = wait.plan.wakeTime ?? wait.plan.giveUpAt ?? task.returnAt
        if let first = others.first {
            let name = first.kind == .task ? (try FaciendaTask.fetchOne(db, key: first.taskId ?? "")?.displayName ?? "Another task") : first.what
            task.waitingOn = others.count > 1 ? "\(name) and \(others.count - 1) more" : name
            task.checkAt = (check.flatMap { $0.paused ? nil : $0.nextCheck }) ?? wait.plan.giveUpAt ?? wait.plan.wakeTime ?? task.checkAt ?? now
        } else { task.waitingOn = nil; task.checkAt = nil }
        // Stored dates lose sub-millisecond precision, so compare loosely or every tick would rewrite the task.
        func moved(_ a: Date?, _ b: Date?) -> Bool { (a == nil) != (b == nil) || abs((a ?? .distantPast).timeIntervalSince(b ?? .distantPast)) > 0.01 }
        if force || task.state != original.state || task.waitingOn != original.waitingOn || moved(task.checkAt, original.checkAt) || moved(task.returnAt, original.returnAt) {
            task.revision = original.revision + 1; task.updatedAt = force ? now : original.updatedAt; try task.update(db)
        }
    }

    func hasActiveWait(_ db: Database, taskId: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM waits WHERE taskId = ? AND state = 'active'", arguments: [taskId]) ?? 0 > 0
    }

    /// Decides every active wait: still waiting, met, given up, or impossible. No model needed.
    func settleWaits(_ db: Database, now: Date) throws {
        let active = try TaskWait.fetchAll(db, sql: "SELECT * FROM waits WHERE state = 'active'")
        guard !active.isEmpty else { return }
        let tasks = try FaciendaTask.fetchAll(db)
        for var wait in active {
            guard var task = tasks.first(where: { $0.id == wait.taskId }) else { continue }
            guard task.state.isOpen else {
                try cancel(db, &wait, now: now)
                continue
            }
            var unmet: [String] = [], impossible: String?
            for condition in wait.plan.conditions {
                switch condition.kind {
                case .time: if let at = condition.at, at > now { unmet.append("the set time") }
                case .task:
                    let prerequisite = tasks.first { $0.id == condition.taskId }
                    if prerequisite?.state == .dropped || prerequisite == nil { impossible = (prerequisite?.displayName ?? "A task it waited for") + " is not happening" }
                    else if prerequisite?.state != .done { unmet.append(prerequisite!.displayName) }
                case .observed:
                    let blocker = try condition.blockerId.flatMap { try TaskBlocker.fetchOne(db, key: $0) }
                    if blocker == nil || blocker!.removed { continue }
                    if !blocker!.isMet(tasks: tasks, now: now) { unmet.append(condition.what) }
                }
            }
            if unmet.isEmpty && impossible == nil {
                try finish(db, &wait, &task, state: "met", outcome: wait.plan.summary.isEmpty ? "The wait is over" : "Ready: " + wait.plan.summary, now: now)
            } else if let impossible {
                try finish(db, &wait, &task, state: "blocked", outcome: impossible, now: now)
            } else if let giveUpAt = wait.plan.giveUpAt, giveUpAt <= now {
                try finish(db, &wait, &task, state: "gaveUp", outcome: "Gave up waiting for " + unmet.filter { $0 != "the set time" }.joined(separator: ", "), now: now)
            } else if !(try needsAttention(db, wait: wait)) {
                try present(db, &task, wait, now: now)
            }
        }
    }

    /// A parked task stays visible when something about the waiting itself needs the user.
    private func needsAttention(_ db: Database, wait: TaskWait) throws -> Bool {
        if try Self.hasPendingDecision(db, taskId: wait.taskId) { return true }
        if let check = try CheckPlan.fetchOne(db, key: wait.taskId), check.paused, check.lastOutcome != "All conditions met",
           wait.plan.conditions.contains(where: { $0.kind == .observed }) { return true }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE taskId = ? AND kind = 'dispatch.blocked' AND at >= ?", arguments: [wait.taskId, wait.createdAt]) ?? 0 > 0
    }

    private func finish(_ db: Database, _ wait: inout TaskWait, _ task: inout FaciendaTask, state: String, outcome: String, now: Date) throws {
        try release(db, wait, now: now)
        wait.state = state; wait.outcome = outcome; wait.settledAt = now
        // Saved first: queueing work reconciles prerequisites, which settles waits again.
        try wait.update(db)
        var delivered = false
        if state == "met" && wait.plan.then != .surface && task.state != .running {
            let note = wait.plan.note.trimmingCharacters(in: .whitespacesAndNewlines)
            // A delivery that cannot be queued falls back to bringing the task to the user.
            delivered = (try? queueDispatch(db, taskId: task.id, triggerKey: "wait:\(task.id):\(Int(wait.createdAt.timeIntervalSince1970))", message: wait.plan.then == .tell || !note.isEmpty ? note : nil, source: .app)) != nil
        }
        // The app announces what it brings to the user; handed-over work speaks for itself.
        if delivered { wait.notifiedAt = now; try wait.update(db) }
        if task.state != .running {
            task.state = .needsMe; task.checkAt = nil; task.returnAt = now
            if !delivered {
                // A met wait keeps the user's note, or the task's own next step; the result says what happened.
                let note = wait.plan.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if state != "met" { task.nextAction = outcome } else if !note.isEmpty { task.nextAction = note }
            }
            task.revision += 1; task.updatedAt = now; try task.update(db)
        }
        // A watch the agent could not finish becomes the user's to check: it shows as their step until they say how it went.
        if state == "gaveUp" || state == "blocked", task.state.isOpen, try OwnStep.fetchOne(db, key: task.id) == nil {
            let watched = wait.plan.conditions.filter { $0.kind == .observed }.map { $0.criterion.isEmpty ? $0.what : $0.criterion }
            if !watched.isEmpty {
                try OwnStep(taskId: task.id, text: TaskHeadline.clip("Check: " + watched.joined(separator: "; "), limit: 200), createdAt: now).save(db)
            }
        }
        try TaskEvent(taskId: task.id, source: .app, kind: "wait.\(state)", payload: outcome, at: now).insert(db)
    }
}
