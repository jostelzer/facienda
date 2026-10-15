import Foundation
import FaciendaCore

enum Destination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", inbox = "New task", processing = "In progress", forYou = "For review", waiting = "Waiting", scheduled = "Scheduled", done = "Done"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .inbox: "plus"
        case .processing: "circle.dotted"
        case .forYou: "eye"
        case .waiting: "hourglass"
        case .scheduled: "clock"
        case .done: "checkmark.circle"
        }
    }
}

enum TaskStatus: Equatable {
    /// For review, by what the user is asked: close it (ready), answer (needsInput), allow (needsPermission) or just read.
    case ready, needsInput, needsPermission, needsReview, recovery, prerequisiteChanged, paused
    case checking, waitingForChat, starting, queued, notStarted, working, done, dropped
    /// A new Claude session is ready in the Claude app's composer; the user presses Send there.
    case awaitingSend
    /// A Claude start waiting for the runner to wake, or for the user after the Claude app did not pick it up.
    case waitingForClaude
    /// Facienda handed the Claude app a new session for this task; the runner is starting it.
    case startingInClaude
    case prerequisites(Int, Int), waiting(String), scheduled(String)

    var label: String {
        switch self {
        case .ready: "Ready to close"
        case .needsInput: "Has a question"
        case .needsPermission: "Needs permission"
        case .needsReview: "For review"
        case .recovery: "Needs recovery"
        case .prerequisiteChanged: "Prerequisite changed"
        case .paused: "Paused"
        case .checking: "Checking"
        case .waitingForChat: "Waiting for chat"
        case .starting: "Starting"
        case .awaitingSend: "Press Send in Claude"
        case .waitingForClaude: "Waiting to start in Claude"
        case .startingInClaude: "Starting in Claude"
        case .queued: "Queued"
        case .notStarted: "Not started"
        case .working: "Working"
        case .done: "Done"
        case .dropped: "Archived"
        case let .prerequisites(met, total): "\(met) of \(total) ready"
        case let .waiting(text), let .scheduled(text): text
        }
    }
}

extension AppModel {
    func belongs(_ task: FaciendaTask, to destination: Destination) -> Bool {
        if recoveryDispatch(for: task.id) != nil && task.state.isOpen { return destination == .forYou }
        let section = TaskSection.classify(task, queued: underway(task) != nil)
        switch destination {
        case .dashboard, .inbox: return false
        case .processing: return section == .processing
        case .forYou: return section == .forYou
        case .waiting: return section == .waiting
        case .scheduled: return section == .scheduled
        case .done: return section == .done
        }
    }
    func count(_ destination: Destination) -> Int { tasks.filter { belongs($0, to: destination) }.count }
    func taskStatus(_ task: FaciendaTask) -> String { status(for: task).label }
    /// The delivery a task waits on. A parked task's check that has not gone out yet is not one: the task stays parked
    /// and keeps saying what the agent watches for, until the check runs.
    func underway(_ task: FaciendaTask) -> NativeDispatch? {
        guard let pending = pendingDispatch(for: task.id) else { return nil }
        let parked = task.state == .waiting || task.state == .scheduled
        return parked && pending.kind == "check" && ["queued", "claimed"].contains(pending.state) ? nil : pending
    }
    func status(for task: FaciendaTask) -> TaskStatus {
        if recoveryDispatch(for: task.id) != nil { return .recovery }
        let underway = underway(task)
        if let wait = wait(for: task), underway == nil, task.state == .waiting || task.state == .scheduled {
            return task.state == .waiting ? .waiting(waitLine(wait)) : .scheduled(waitLine(wait))
        }
        let prerequisites = blockers(of: task.id)
        if !prerequisites.isEmpty && task.state.isOpen && underway == nil {
            let met = prerequisites.filter(isMet).count
            if task.state == .running && met < prerequisites.count { return .prerequisiteChanged }
            return .prerequisites(met, prerequisites.count)
        }
        if let plan = checkPlan(for: task.id), plan.paused, task.state == .waiting { return .paused }
        if let pending = underway {
            if pending.state == "started" { return .checking }
            if pending.awaitsClaudeSend { return .awaitingSend }
            if pending.agent == .claude, pending.threadId != nil, ["start", nil].contains(pending.kind), ["queued", "claimed", "dispatching"].contains(pending.state) { return .startingInClaude }
            // A put-off entry keeps saying so between the dispatcher's looks, instead of flickering back to queued.
            if let date = pending.availableAt, date > Date() || pending.state == "claimed" { return .waitingForChat }
            if waitsForClaudeRunner(pending), claudeRunner?.isAwake() != true || claudeStartsHeld.contains(pending.id) { return .waitingForClaude }
            return pending.state == "dispatching" ? .starting : .queued
        }
        // A turn underway outranks questions left open from earlier work, as it does for the task's own state; they
        // show again once the turn stops. A chat stopped at a permission prompt still asks for it.
        if task.state == .running, permissionPrompt(for: task) == nil,
           links(for: task.id).contains(where: { $0.statusVerified && $0.lastKnownStatus == "active" }) { return .working }
        let decisions = decisions(for: task.id)
        if permissionPrompt(for: task) != nil || codexApprovals[task.id]?.isEmpty == false || decisions.contains(where: { $0.kind == "permission" }) { return .needsPermission }
        if !decisions.isEmpty {
            return decisions.contains(where: { $0.kind != "completion" }) ? .needsInput : .ready
        }
        if task.state == .needsMe, links(for: task.id).contains(where: { $0.statusVerified && $0.lastKnownStatus == "waitingOnUserInput" }) { return .needsInput }
        return Self.plainStatus(of: task)
    }
    /// A chat of this task stopped at a permission prompt, in Codex or Claude. It counts at once, before the task
    /// itself moves to review, so a running task already shows it waits for the user.
    func permissionPrompt(for task: FaciendaTask) -> ThreadLink? {
        guard task.state.isOpen else { return nil }
        return links(for: task.id).first { $0.statusVerified && $0.lastKnownStatus == "waitingOnApproval" }
    }
    /// What a task's state alone says, with nothing queued, waiting or blocking it.
    nonisolated static func plainStatus(of task: FaciendaTask) -> TaskStatus {
        switch task.state {
        case .inbox: return .notStarted
        case .running: return .working
        case .waiting: return .waiting(task.checkAt.map { "Check " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Waiting")
        case .scheduled: return .scheduled(task.returnAt?.formatted(date: .abbreviated, time: .omitted) ?? "Later")
        case .done: return .done
        case .dropped: return .dropped
        case .needsMe: return .needsReview
        }
    }

    private func when(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 6 * 86400 ? date.formatted(Date.FormatStyle().weekday(.abbreviated).hour().minute()) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What a new row shows in place of its line: the recap written from the turn that brought the work back.
    /// Nil once the task is read (on the board, when its choices close), and until a recap for this return is written.
    func recap(for task: FaciendaTask) -> TaskRecap? {
        guard isUnread(task), let recap = recaps[task.id], recap.at >= (cameBack(task) ?? .distantPast) else { return nil }
        return recap
    }

    /// The line under a task's name: the newest thing worth knowing, in a few words.
    /// Nil when there is nothing worth a line: the glyph already says "not started" or "running".
    func subtitle(for task: FaciendaTask) -> String? {
        let status = status(for: task)
        switch status {
        case .recovery, .prerequisiteChanged, .paused, .queued, .starting, .waitingForChat, .checking, .awaitingSend, .waitingForClaude, .startingInClaude: return status.label
        default: break
        }
        if status == .needsPermission, codexApprovals[task.id]?.isEmpty == false { return "Answer it here to carry on" }
        if status == .needsPermission, let prompt = permissionPrompt(for: task) { return "Allow it in \(prompt.provider.name) to carry on" }
        if let step = ownStep(for: task) {
            guard let wait = wait(for: task), let at = wait.plan.wakeTime else { return TaskHeadline.clip("You: " + step.text) }
            return TaskHeadline.clip("You: " + step.text, limit: TaskHeadline.maximumLength - 12) + " · " + when(at)
        }
        if let wait = wait(for: task), task.state == .waiting || task.state == .scheduled { return waitSubtitle(wait) }
        let unmet = blockers(of: task.id).filter { !isMet($0) }
        if task.state.isOpen, task.state != .running, !unmet.isEmpty {
            let names = unmet.map { blocker in blocker.prerequisiteId.flatMap { libraryTask($0)?.displayName } ?? blocker.title }
            return TaskHeadline.clip("Waiting for " + names.joined(separator: ", "))
        }
        let source = latestResults[task.id]
        // A reminder that went off after the latest result speaks for itself.
        if let ended = waits[task.id], !["active", "cancelled"].contains(ended.state), task.state == .needsMe,
           let settled = ended.settledAt, settled > (source?.at ?? .distantPast).addingTimeInterval(5) { return TaskHeadline.clip(task.nextAction) }
        if let source { return headlines[task.id].flatMap { $0.eventId == source.eventId ? $0.text : nil } ?? TaskHeadline.fallback(source.excerpt) }
        if let decision = decisions(for: task.id).first(where: { $0.kind != "completion" }) { return TaskHeadline.clip(decision.question) }
        guard task.state.isOpen, ![.inbox, .running].contains(task.state), task.nextAction != FaciendaTask(title: "-").nextAction else { return nil }
        return TaskHeadline.clip(task.nextAction)
    }

    /// A parked card's line: what it waits for, kept short. The long version lives in the task's menu.
    func waitSubtitle(_ wait: TaskWait) -> String {
        var parts = wait.plan.conditions.map { condition -> String in
            switch condition.kind {
            case .time: return "Until " + (condition.at.map(when) ?? "later")
            case .task: return "After “" + (condition.taskId.flatMap(libraryTask)?.displayName ?? "another task") + "”"
            case .observed:
                let seen = blockers.first { $0.id == condition.blockerId }?.observedAt
                return "Waiting for " + condition.what + (seen.map { ", checked " + $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) } ?? "")
            }
        }
        if let giveUpAt = wait.plan.giveUpAt { parts.append("gives up " + when(giveUpAt)) }
        return TaskHeadline.clip(parts.joined(separator: " · "))
    }

    /// The parked card's subtitle: what it waits for and how that is going.
    func waitLine(_ wait: TaskWait) -> String {
        var parts = wait.plan.conditions.map { condition -> String in
            switch condition.kind {
            case .time: return condition.at.map(when) ?? "later"
            case .task: return "“" + (condition.taskId.flatMap(libraryTask)?.displayName ?? "another task") + "” is done"
            case .observed:
                guard let blocker = blockers.first(where: { $0.id == condition.blockerId }), let seen = blocker.observedAt else { return condition.what + " · not checked yet" }
                let age = seen.formatted(.relative(presentation: .named))
                return condition.what + (blocker.status == "met" ? " · ready" : blocker.status == "notMet" ? " · not yet" : " · unclear") + ", checked " + age
            }
        }
        if let giveUpAt = wait.plan.giveUpAt { parts.append("gives up " + when(giveUpAt)) }
        if let check = checkPlan(for: wait.taskId), wait.plan.hasObservedConditions {
            parts.append(check.paused ? "checks paused" : "next check " + when(check.nextCheck) + ", " + WaitPlan.cadenceLabel(check.minimumInterval))
        }
        return "Until " + parts.joined(separator: " · ")
    }
}
