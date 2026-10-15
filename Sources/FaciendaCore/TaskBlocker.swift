import Foundation
import GRDB

public struct TaskBlocker: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "taskBlockers"
    public var id: String = UUID().uuidString
    public var taskId: String
    public var kind: String
    public var prerequisiteId: String?
    public var title: String
    public var sourceReference: String = ""
    public var criterion: String = ""
    public var freshnessSeconds: TimeInterval?
    public var revision: Int = 1
    public var status: String = "unknown"
    public var evidence: String = ""
    public var observedAt: Date?
    public var removed: Bool = false

    public func isMet(tasks: [FaciendaTask], now: Date = Date()) -> Bool {
        if kind == "task" { return tasks.first { $0.id == prerequisiteId }?.state == .done }
        guard status == "met", let observedAt else { return false }
        return freshnessSeconds.map { now.timeIntervalSince(observedAt) < $0 } ?? true
    }
}

public struct TaskReadiness: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "taskReadiness"
    public var taskId: String
    public var armed: Bool = false
    public var revision: Int = 0
    public var notBefore: Date?
    public var userInstruction: String = ""
}

public struct BlockerObservation: Codable, Sendable {
    public var blockerId: String
    public var expectedRevision: Int
    public var status: String
    public var evidence: String
    public init(blockerId: String, expectedRevision: Int, status: String, evidence: String) {
        self.blockerId = blockerId; self.expectedRevision = expectedRevision; self.status = status; self.evidence = evidence
    }
}

extension FaciendaStore {
    public func blockers(taskId: String? = nil) throws -> [TaskBlocker] {
        try db.read { db in
            if let taskId { return try TaskBlocker.fetchAll(db, sql: "SELECT * FROM taskBlockers WHERE taskId = ? AND removed = 0 ORDER BY rowid", arguments: [taskId]) }
            return try TaskBlocker.fetchAll(db, sql: "SELECT * FROM taskBlockers WHERE removed = 0 ORDER BY rowid")
        }
    }
    public func readiness(_ taskId: String) throws -> TaskReadiness {
        try db.read { try TaskReadiness.fetchOne($0, key: taskId) ?? TaskReadiness(taskId: taskId) }
    }
    public func readinessPlans() throws -> [TaskReadiness] { try db.read { try TaskReadiness.fetchAll($0) } }

    func unmetBlockers(_ db: Database, taskId: String, now: Date) throws -> [TaskBlocker] {
        let blockers = try TaskBlocker.fetchAll(db, sql: "SELECT * FROM taskBlockers WHERE taskId = ? AND removed = 0", arguments: [taskId])
        let tasks = try FaciendaTask.fetchAll(db)
        return blockers.filter { !$0.isMet(tasks: tasks, now: now) }
    }

    /// The task's conditions on people or the outside world, as opposed to other tasks.
    static func externalBlockers(_ db: Database, taskId: String) throws -> [TaskBlocker] {
        try TaskBlocker.fetchAll(db, sql: "SELECT * FROM taskBlockers WHERE taskId = ? AND removed = 0 AND kind != 'task'", arguments: [taskId])
    }

    func validateDependency(_ db: Database, taskId: String, prerequisiteId: String) throws {
        guard taskId != prerequisiteId, try FaciendaTask.fetchOne(db, key: prerequisiteId) != nil else { throw StoreError.invalid("Choose another existing task.") }
        let cycle = try Int.fetchOne(db, sql: """
        WITH RECURSIVE upstream(id) AS (
          SELECT ? UNION SELECT b.prerequisiteId FROM taskBlockers b JOIN upstream u ON b.taskId = u.id
          WHERE b.kind = 'task' AND b.removed = 0
        ) SELECT COUNT(*) FROM upstream WHERE id = ?
        """, arguments: [prerequisiteId, taskId]) ?? 0
        guard cycle == 0 else { throw StoreError.invalid("That task already depends on this one. Linking it would create a circular dependency.") }
    }

    public func addTaskDependencies(taskId: String, prerequisiteIDs: [String], source: EventSource = .user) throws {
        try write { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.notFound }
            for id in Set(prerequisiteIDs) {
                try validateDependency(db, taskId: taskId, prerequisiteId: id)
                if try TaskBlocker.fetchOne(db, sql: "SELECT * FROM taskBlockers WHERE taskId = ? AND prerequisiteId = ? AND removed = 0", arguments: [taskId, id]) != nil { continue }
                let prerequisite = try FaciendaTask.fetchOne(db, key: id)!
                let blocker = TaskBlocker(taskId: taskId, kind: "task", prerequisiteId: id, title: prerequisite.displayName)
                try blocker.insert(db)
                try TaskEvent(taskId: taskId, source: source, kind: "blocker.added", payload: try JSONValue.encoded(blocker).json, verified: source == .user).insert(db)
            }
            try reconcileBlockers(db, now: Date())
        }
    }

    @discardableResult public func setExternalBlocker(taskId: String, id: String? = nil, expectedRevision: Int = 0, kind: String, title: String, sourceReference: String, criterion: String, freshnessSeconds: TimeInterval?, threadId: String? = nil, source: EventSource = .user) throws -> TaskBlocker {
        guard ["person", "condition"].contains(kind), [title, sourceReference, criterion].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), freshnessSeconds.map({ $0 >= 60 && $0 <= 30 * 86400 }) ?? true else { throw StoreError.invalid("Specify who or what, where to check, and what counts as ready. Freshness must be at least one minute.") }
        return try write { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.notFound }
            var blocker: TaskBlocker
            if let id {
                guard let old = try TaskBlocker.fetchOne(db, key: id), old.taskId == taskId, old.kind != "task", !old.removed, old.revision == expectedRevision else { throw StoreError.conflict }
                blocker = old; blocker.revision += 1
            } else {
                guard expectedRevision == 0 else { throw StoreError.conflict }
                blocker = TaskBlocker(taskId: taskId, kind: kind, title: title)
            }
            blocker.kind = kind; blocker.title = title; blocker.sourceReference = sourceReference; blocker.criterion = criterion
            blocker.freshnessSeconds = freshnessSeconds; blocker.status = "unknown"; blocker.evidence = ""; blocker.observedAt = nil
            try blocker.save(db)
            if let threadId {
                guard try Self.isLinked(db, taskId: taskId, threadId: threadId) else { throw StoreError.invalid("Use the task's linked owning chat.") }
            }
            try arrangeBlockerCheck(db, taskId: taskId, threadId: threadId, reset: true, now: Date())
            try TaskEvent(taskId: taskId, source: source, kind: "blocker.saved", payload: try JSONValue.encoded(blocker).json, verified: source == .user).insert(db)
            try reconcileBlockers(db, now: Date())
            return blocker
        }
    }

    /// `taskId`, when given, is the task the blocker must belong to: a chat removes only its own task's prerequisites.
    public func removeBlocker(_ id: String, expectedRevision: Int, taskId: String? = nil, source: EventSource = .user) throws {
        try write { db in
            guard var blocker = try TaskBlocker.fetchOne(db, key: id), taskId.map({ $0 == blocker.taskId }) ?? true,
                  !blocker.removed, blocker.revision == expectedRevision else { throw StoreError.conflict }
            blocker.removed = true; blocker.revision += 1; try blocker.update(db)
            if blocker.kind != "task", var plan = try CheckPlan.fetchOne(db, key: blocker.taskId) {
                plan.revision += 1; try plan.update(db)
                try Self.cancelQueuedChecks(db, taskId: blocker.taskId)
            }
            try TaskEvent(taskId: blocker.taskId, source: source, kind: "blocker.removed", payload: id, verified: source == .user).insert(db)
            try reconcileBlockers(db, now: Date())
        }
    }

    /// Arms or pauses a task's start. Only the user arms: an agent's request goes through `requestReadiness`.
    @discardableResult public func setReadiness(taskId: String, armed: Bool, notBefore: Date? = nil, userInstruction: String, source: EventSource = .user) throws -> TaskReadiness {
        guard !userInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("An explicit instruction is required to start when ready.") }
        guard !armed || source != .mcp else { throw StoreError.userOnly }
        return try write { db in
            let ready = try applyReadiness(db, taskId: taskId, armed: armed, notBefore: notBefore, userInstruction: userInstruction, source: source)
            try reconcileBlockers(db, now: Date())
            return ready
        }
    }

    func applyReadiness(_ db: Database, taskId: String, armed: Bool, notBefore: Date?, userInstruction: String, source: EventSource) throws -> TaskReadiness {
        guard let task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen else { throw StoreError.notFound }
        var ready = try TaskReadiness.fetchOne(db, key: taskId) ?? TaskReadiness(taskId: taskId)
        ready.armed = armed; ready.revision += 1; ready.userInstruction = userInstruction
        ready.notBefore = notBefore ?? ready.notBefore ?? (task.state == .scheduled ? task.returnAt : nil)
        try ready.save(db)
        if !armed { try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE taskId = ? AND kind NOT IN ('check', 'assess', 'reply') AND state IN ('queued', 'claimed', 'held')", arguments: [taskId]) }
        else {
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dispatches WHERE taskId = ? AND state IN ('queued', 'claimed', 'dispatching', 'held') AND kind NOT IN ('check', 'assess', 'reply')", arguments: [taskId]) ?? 0
            if exists == 0 {
                let thread = try Self.workThreadID(db, taskId: taskId)
                try NativeDispatch(id: UUID().uuidString, taskId: taskId, state: "held", requestedAt: Date(), threadId: thread, triggerKey: "ready:\(taskId):\(ready.revision)", kind: "ready").insert(db)
            }
            try arrangeBlockerCheck(db, taskId: taskId, threadId: nil, reset: false, now: Date())
        }
        try TaskEvent(taskId: taskId, source: source, kind: armed ? "readiness.armed" : "readiness.paused", payload: userInstruction, verified: source == .user).insert(db)
        return ready
    }

    /// The permission question an agent's request to start when ready becomes. Agents may not ask it themselves.
    public static let readinessQuestion = "May Facienda start this task by itself once its prerequisites and start date are met?"
    public static let readinessApproval = "Start when ready"

    /// An agent asked for its task to start by itself when ready. Agents never arm a task: the user is asked, with the
    /// agent's words quoted as the agent's, and only their answer `readinessApproval` arms it (see `armApprovedReadiness`).
    public func requestReadiness(taskId: String, notBefore: Date?, agentWords: String) throws -> JSONValue {
        let words = agentWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw StoreError.invalid("Quote the user's request to start when ready.") }
        try write { try reconcileBlockers($0, now: Date()) }
        let current = try readiness(taskId)
        if current.armed { return .object(["readiness": try .encoded(current), "status": .string("The user already allowed this task to start when ready.")]) }
        let when = notBefore.map { ", not before " + ISO8601DateFormatter().string(from: $0) } ?? ""
        let context = "The agent working on this task asked Facienda to start it by itself once it is ready\(when). In the agent's own words, which are not yours: “\(String(words.prefix(1_000)))”. Agents cannot start tasks; only your answer can."
        let decision = try requestDecision(Decision(taskId: taskId, question: Self.readinessQuestion, context: context, recommendation: Self.readinessApproval,
                                                    options: [Self.readinessApproval, "Not now"], kind: "permission"))
        try write { db in
            let request: JSONValue = .object(["decisionId": .string(decision.id), "notBefore": notBefore.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null])
            try TaskEvent(taskId: taskId, source: .mcp, kind: "readiness.requested", payload: request.json, verified: false).insert(db)
        }
        return .object(["decision": try .encoded(decision), "readiness": try .encoded(current),
                        "status": .string("Facienda asked the user whether this task may start by itself when ready. It is not armed; do not claim it will start.")])
    }

    /// Arms each task whose user answered an agent's readiness request with `readinessApproval`, once per answer. The
    /// answer is the user's own: only the app answers decisions, and agents cannot ask this exact question.
    func armApprovedReadiness(_ db: Database) throws {
        let approved = try Decision.fetchAll(db, sql: "SELECT * FROM decisions WHERE kind = 'permission' AND state = 'answered' AND question = ? AND answer = ?",
                                             arguments: [Self.readinessQuestion, Self.readinessApproval])
        for decision in approved {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM events WHERE taskId = ? AND kind = 'readiness.approved' AND payload = ?)", arguments: [decision.taskId, decision.id]) != true else { continue }
            try TaskEvent(taskId: decision.taskId, source: .user, kind: "readiness.approved", payload: decision.id).insert(db)
            guard try FaciendaTask.fetchOne(db, key: decision.taskId)?.state.isOpen == true else { continue }
            let requests = try String.fetchAll(db, sql: "SELECT payload FROM events WHERE taskId = ? AND kind = 'readiness.requested' ORDER BY at DESC", arguments: [decision.taskId])
            let request = requests.lazy.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }.first { $0["decisionId"].string == decision.id }
            let notBefore = request?["notBefore"].string.flatMap { ISO8601DateFormatter().date(from: $0) }
            _ = try applyReadiness(db, taskId: decision.taskId, armed: true, notBefore: notBefore, userInstruction: "Approved in Facienda: \(Self.readinessApproval)", source: .user)
        }
    }

    /// Reuses one check plan per task: the owning chat evaluates all external blockers together.
    func arrangeBlockerCheck(_ db: Database, taskId: String, threadId: String?, reset: Bool, now: Date) throws {
        let external = try Self.externalBlockers(db, taskId: taskId)
        guard !external.isEmpty else { return }
        let owner = try threadId ?? Self.workThreadID(db, taskId: taskId)
        if let owner {
            if var plan = try CheckPlan.fetchOne(db, key: taskId) {
                if reset {
                    plan.revision += 1
                    if plan.lastOutcome == "All conditions met" { plan.paused = false }
                    if !plan.pinned && !plan.paused { plan.nextCheck = now }
                    try plan.update(db)
                    try Self.cancelQueuedChecks(db, taskId: taskId)
                }
            } else {
                let plan = CheckPlan(taskId: taskId, threadId: owner, revision: 1, nextCheck: now, purpose: "Check the saved external blockers", reason: "Observe each saved source and report whether its condition is met.", paused: false, pinned: false, minimumInterval: 3600, deadline: now.addingTimeInterval(30 * 86400), failures: 0, checks: 0)
                try plan.insert(db)
            }
        } else if try TaskReadiness.fetchOne(db, key: taskId)?.armed == true {
            try Self.queueAssessment(db, taskId: taskId, now: now)
        }
    }

    func applyBlockerObservations(_ db: Database, taskId: String, observations: [BlockerObservation], now: Date) throws {
        let external = try Self.externalBlockers(db, taskId: taskId)
        let required = external.filter { $0.status != "met" || $0.freshnessSeconds != nil }
        guard Set(observations.map(\.blockerId)).count == observations.count,
              Set(required.map(\.id)).isSubset(of: Set(observations.map(\.blockerId))) else { throw StoreError.invalid("Report every unresolved or freshness-sensitive condition once.") }
        for report in observations {
            guard var blocker = external.first(where: { $0.id == report.blockerId }), blocker.revision == report.expectedRevision,
                  ["met", "notMet", "unknown"].contains(report.status), !report.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.conflict }
            blocker.status = report.status; blocker.evidence = report.evidence; blocker.observedAt = now
            // Definition revision changes only when the user/chat edits the condition.
            try blocker.update(db)
        }
    }

    /// Called on prerequisite edits, check results and every runner claim. No model needed for task edges.
    func reconcileBlockers(_ db: Database, now: Date) throws {
        try armApprovedReadiness(db)
        let taskIDs = try String.fetchAll(db, sql: "SELECT DISTINCT taskId FROM taskBlockers UNION SELECT taskId FROM taskReadiness")
        for id in taskIDs {
            guard var task = try FaciendaTask.fetchOne(db, key: id) else { continue }
            var ready = try TaskReadiness.fetchOne(db, key: id) ?? TaskReadiness(taskId: id)
            if !task.state.isOpen {
                if ready.armed { ready.armed = false; ready.revision += 1; try ready.save(db) }
                try db.execute(sql: "UPDATE dispatches SET state = 'cancelled' WHERE taskId = ? AND state IN ('held', 'queued', 'claimed')", arguments: [id])
                continue
            }
            let original = task
            // A parked task is presented and woken by its wait, not by this gate.
            let parked = try hasActiveWait(db, taskId: id)
            if task.state == .scheduled && ready.notBefore == nil && !parked { ready.notBefore = task.returnAt; try ready.save(db) }
            let unmet = try unmetBlockers(db, taskId: id, now: now)
            let blocked = !unmet.isEmpty
            let pending = try NativeDispatch.fetchAll(db, sql: "SELECT * FROM dispatches WHERE taskId = ? AND COALESCE(kind, 'start') NOT IN ('check', 'assess', 'reply') AND state IN ('queued', 'claimed', 'held')", arguments: [id])
            let due = ready.notBefore.map { $0 <= now } ?? true
            let plan = try CheckPlan.fetchOne(db, key: id)
            let needsAttention = try (plan?.paused == true && plan?.lastOutcome != "All conditions met") || Self.hasPendingDecision(db, taskId: id)
            if blocked || !due {
                for var item in pending where item.state != "held" {
                    item.state = "held"; try item.update(db)
                    // An already-requested start remains authorized when a prerequisite is added.
                    if !ready.armed { ready.armed = true; ready.revision += 1; ready.userInstruction = "Previously requested start"; try ready.save(db) }
                }
                if task.state != .running && !parked {
                    task.state = needsAttention ? .needsMe : (blocked ? .waiting : .scheduled)
                    task.waitingOn = "Prerequisites"
                    task.checkAt = plan?.nextCheck ?? ready.notBefore ?? task.checkAt ?? now
                    if !due { task.returnAt = ready.notBefore }
                }
                // A completed but time-sensitive observation must be checked again before execution.
                if unmet.contains(where: { $0.kind != "task" && $0.status == "met" }), var current = plan, !current.paused, !current.pinned, current.nextCheck > now {
                    current.nextCheck = now; try current.update(db)
                }
            } else {
                if try ready.armed && !needsAttention && !Self.hasDispatchUnderway(db, taskId: id), var held = pending.first(where: { $0.state == "held" }) {
                    held.state = "queued"; held.availableAt = nil
                    held.threadId = try Self.workThreadID(db, taskId: id)
                    try held.update(db)
                }
                if (task.state == .waiting || task.state == .scheduled) && !parked { task.state = .needsMe }
            }
            if task.state != original.state || task.waitingOn != original.waitingOn || task.checkAt != original.checkAt || task.returnAt != original.returnAt {
                task.revision += 1; task.updatedAt = now; try task.update(db)
            }
        }
        try settleWaits(db, now: now)
    }
}
