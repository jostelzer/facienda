import Foundation
import FaciendaCore

extension AppModel {
    func renameTask(_ task: FaciendaTask, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != task.displayName else { return }
        perform(undo: "Rename Task") { _ = try store.update(task.id) { $0.displayTitle = name }; refresh() }
    }
    /// How freely the task's agent may act: prepare and ask first, or go ahead. Its next delivery says so.
    func setScope(_ task: FaciendaTask, _ scope: AutomationScope) {
        guard scope != task.automationScope else { return }
        perform(undo: "Change What the Agent May Do") { _ = try store.update(task.id) { $0.automationScope = scope }; refresh() }
    }
    /// Opens the task's chat in Codex, or the Claude session waiting to be sent. A task without either has nothing to open.
    func open(_ task: FaciendaTask) {
        markReviewed(task.id)
        if let link = resultLink(for: task) ?? links(for: task.id).last { openThread(link.threadId); refresh() }
        else if canOpen(task), let pending = pendingDispatch(for: task.id) { openInClaude(pending) }
    }
    @discardableResult func capture(title: String, intention: String, area: String, date: Date, startNow: Bool, attachments: [URL] = [], groupID: String? = nil, reveal: Bool = true, model choice: TaskModelChoice? = nil) async -> Bool {
        guard !capturing else { return false }
        capturing = true
        defer { capturing = false }
        do {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalid("Describe what you would like done.") }
            var draft = FaciendaTask(title: title, intention: intention, area: area, state: .inbox, nextAction: intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : intention, returnAt: date)
            if !attachments.isEmpty {
                let folder = store.taskFolder(draft.id)
                let directory = folder.appending(path: "Attachments")
                draft.attachments = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    return try attachments.map { source in
                        let access = source.startAccessingSecurityScopedResource()
                        defer { if access { source.stopAccessingSecurityScopedResource() } }
                        guard source.isFileURL, try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                            throw StoreError.invalid("Attach files such as images, videos, audio, or documents. Folders cannot be attached.")
                        }
                        let destination = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let file = destination.appendingPathComponent(source.lastPathComponent)
                        try FileManager.default.copyItem(at: source, to: file)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        return TaskAttachment(name: source.lastPathComponent, path: file.path)
                    }
                }.value
                draft.cwd = folder.path
            }
            if let choice {
                draft.workerModel = choice.model; draft.workerReasoningEffort = choice.effort
                draft.workerServiceTier = choice.serviceTier; draft.workerProvider = choice.provider
            }
            let task = try store.create(draft)
            lastCaptured = task.id
            if let groupID { try store.assignGroup(taskId: task.id, groupId: groupID == Self.unsortedGroup ? nil : groupID) }
            if reveal { destination = .dashboard; selection = task.id }
            showCapture = false; refresh()
            if startNow { Task { await dispatch(task, reveal: reveal) } }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func complete(_ task: FaciendaTask) {
        perform(undo: "Mark Done", offering: "Marked “\(task.displayName)” done") { try store.update(task.id) { $0.state = .done }; refresh() }
    }

    // MARK: Choices on a clicked task

    /// Open tasks with a chat offer choices on click; the rest open as before.
    func offersChoices(_ task: FaciendaTask) -> Bool { task.state.isOpen && resultLink(for: task) != nil }
    /// Whether there is a chat to open yet: a queued task has none until the agent starts it.
    func canOpen(_ task: FaciendaTask) -> Bool {
        if resultLink(for: task) != nil || !links(for: task.id).isEmpty { return true }
        guard let pending = pendingDispatch(for: task.id) else { return false }
        return pending.awaitsClaudeSend
    }
    /// Opening the choices counts as looking at the task.
    func noteOpened(_ task: FaciendaTask) { markReviewed(task.id); refresh() }
    func ownStep(for task: FaciendaTask) -> OwnStep? { task.state.isOpen ? ownSteps[task.id] : nil }
    /// The continuation offered for the task's current result, if one was written for it.
    func continuation(for task: FaciendaTask) -> StoredNextSteps? {
        guard let steps = nextSteps[task.id], steps.eventId == latestResults[task.id]?.eventId else { return nil }
        return steps
    }
    /// True while the continuation for the latest result is still being written.
    func writingContinuation(for task: FaciendaTask) -> Bool {
        guard accountReady, !demo, task.state == .needsMe, let source = latestResults[task.id], !source.isQuestion,
              nextSteps[task.id]?.eventId != source.eventId else { return false }
        // Not tried yet, or the background writer is still at it.
        return !headlineAttempts.contains("s" + source.eventId) || headlineTask != nil
    }
    /// Sends a message to the task's chat without leaving the board.
    @discardableResult func tell(_ task: FaciendaTask, _ text: String) -> Bool { reply(to: task, text: text, reveal: false) }

    @discardableResult func takeOn(_ task: FaciendaTask, step: String, at: Date?) -> Bool {
        do { try store.takeOn(task.id, step: step, remindAt: at); refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    /// Did it: with a note the agent hears how it went and carries on; without one the task comes back for review.
    func didStep(_ task: FaciendaTask, note: String) {
        guard let step = ownStep(for: task) else { return }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { try store.finishStep(task.id, done: true) }
        if !note.isEmpty { tell(task, "I did this myself: \(step.text). \(note)") }
        refresh()
    }
    func dropStep(_ task: FaciendaTask) { perform { try store.finishStep(task.id, done: false) }; refresh() }
    /// Answers what a running Codex turn asks; Facienda's dispatcher passes it on.
    func answer(_ approval: CodexApproval, _ choice: CodexApproval.Choice) {
        perform { try store.answerCodexApproval(approval.id, response: approval.response(for: choice)); refresh() }
    }
    func answer(_ approval: CodexApproval, answers: [String: String]) {
        perform { try store.answerCodexApproval(approval.id, response: approval.response(answers: answers)); refresh() }
    }
    func answer(_ decision: Decision, text: String) {
        perform {
            if decision.kind == "completion" && text == "Mark done" { try store.update(decision.taskId) { $0.state = .done } }
            else {
                try store.answerDecision(decision.id, answer: text)
                let task = tasks.first { $0.id == decision.taskId }
                let runner = task.map { agent(for: $0) == .claude } == true ? (try store.claudeRunner()?.isBound == true) : (try store.runnerState() != nil)
                if runner, nativeDispatches.contains(where: { $0.taskId == decision.taskId && $0.state == "started" }) {
                    _ = try store.enqueueDispatch(taskId: decision.taskId, triggerKey: "decision:\(decision.id)")
                }
            }
            refresh()
        }
    }
    func setReady(_ task: FaciendaTask, armed: Bool) {
        perform {
            if armed && agent(for: task) == .codex && !workspaceReady { throw StoreError.invalid("Connect Codex in Settings first.") }
            _ = try store.setReadiness(taskId: task.id, armed: armed, userInstruction: armed ? "Start when ready" : "Pause automatic start")
            refresh(); showTask(try store.task(task.id))
        }
    }
    func controlCheck(_ plan: CheckPlan, paused: Bool, pinned: Bool, date: Date, interval: TimeInterval? = nil, deadline: Date? = nil) {
        perform {
            _ = try store.controlCheck(taskId: plan.taskId, expectedRevision: plan.revision, paused: paused, pinned: pinned, nextCheck: date, minimumInterval: interval, deadline: deadline)
            refresh()
            if let task = tasks.first(where: { $0.id == plan.taskId }) { showTask(task) }
        }
    }
    func deleteTask(_ task: FaciendaTask) {
        perform(undo: "Delete Task", offering: "Deleted “\(task.displayName)”") {
            try store.deleteTask(task.id)
            if selection == task.id { selection = nil }
            refresh()
        }
    }
    func archive(_ task: FaciendaTask, reveal: Bool = true) {
        perform(undo: "Archive Task", offering: "Archived “\(task.displayName)”") { _ = try store.update(task.id) { $0.state = .dropped }; refresh(); if reveal { showTask(try store.task(task.id)) } }
    }

    func wait(for task: FaciendaTask) -> TaskWait? { waits[task.id].flatMap { $0.isActive ? $0 : nil } }
    func dependents(of task: FaciendaTask) -> [FaciendaTask] {
        let ids = Set(blockers.filter { $0.prerequisiteId == task.id }.map(\.taskId))
        return tasks.filter { ids.contains($0.id) && $0.state.isOpen }
    }
    @discardableResult func park(_ task: FaciendaTask, plan: WaitPlan) -> Bool {
        var saved = false
        perform(undo: "Park Task") { try store.park(task.id, plan: plan); saved = true; refresh() }
        return saved
    }
    func wake(_ task: FaciendaTask) { perform { try store.wake(task.id); refresh() } }
    func unpark(_ task: FaciendaTask) { perform(undo: "Unpark Task") { try store.unpark(task.id); refresh() } }
    /// Brings an earlier task back onto the board and opens it there: reopened if it was finished, at the top of its card
    /// or of the group whose sheet is up, with anything more that was asked sent on to its chat.
    func bringBack(_ task: FaciendaTask, into groupID: String?, message: String = "") {
        if !task.state.isOpen { reopen(task) }
        let own = groupMembers[task.id].flatMap { id in groups.contains { $0.id == id } ? id : nil }
        place(taskID: task.id, in: groupID ?? own, at: .top)
        if !message.isEmpty, let current = tasks.first(where: { $0.id == task.id }) { tell(current, message) }
        search = ""; destination = .dashboard
        boardOpenRequest = task.id
    }
    func reopen(_ task: FaciendaTask) { perform(undo: "Reopen Task") { _ = try store.update(task.id) { $0.state = .needsMe; $0.returnAt = Date() }; refresh() } }
}
