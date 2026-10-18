import AppKit
import FaciendaCore
import FaciendaBridge


/// One look through Codex for the chat that received a parked delivery.
struct DeliverySearch: Equatable {
    var searching = true
    var chats: [CodexThread] = []
    var complete = false
    var error: String?
    var at = Date()
    /// Every chat since the delivery was read and none held its marker.
    var provedMissing: Bool { !searching && error == nil && complete && chats.isEmpty }
}

extension AppModel {
    func dispatch(_ task: FaciendaTask, reveal: Bool = true) async {
        guard !demo, !dispatching else { return }
        // Handing a Claude task to the Claude app can take seconds; the next task may start meanwhile and joins the line.
        guard let item = await enqueue(task, reveal: reveal) else { return }
        // An awake runner starts the session without a click; otherwise the task waits here until it wakes.
        if waitsForClaudeRunner(item) { await startWaitingClaudeTasks() }
    }
    private func enqueue(_ task: FaciendaTask, reveal: Bool) async -> NativeDispatch? {
        dispatching = true; startingTaskID = task.id
        defer { dispatching = false; startingTaskID = nil }
        do {
            let claude = agent(for: task) == .claude
            if claude {
                guard claudeInstalled else { throw StoreError.invalid("Install the Claude app to run tasks with Claude models. Your task is saved.") }
            } else {
                guard workspaceReady else {
                    error = "Finish connecting Codex in Settings before starting tasks. Your task is saved."
                    showSettings = true
                    return nil
                }
            }
            let task = try store.prepareWorkingFolder(taskId: task.id)
            if !claude, task.folders?.isEmpty == false, let group = groupMembers[task.id] { await syncCodexProject(group) }
            let item = try store.enqueueDispatch(taskId: task.id)
            if reveal { destination = .dashboard; selection = task.id }
            refresh()
            return item
        } catch { self.error = error.localizedDescription; return nil }
    }
    func pendingDispatch(for taskID: String) -> NativeDispatch? {
        dispatches(for: taskID).first { item in
            if ["queued", "claimed", "dispatching"].contains(item.state) { return true }
            return item.kind == "check" && item.state == "started" && (checkPlansByTask[taskID] ?? []).contains { !$0.paused && $0.revision == item.checkRevision }
        }
    }
    /// Why the dispatcher last put this entry off, such as the chat being open in the Codex app.
    func deferReason(_ item: NativeDispatch) -> String? {
        guard item.availableAt != nil, let event = try? store.latestEvent(taskId: item.taskId, kind: "dispatch.deferred"), event.at >= item.requestedAt else { return nil }
        return event.payload
    }
    func recoveryDispatch(for taskID: String) -> NativeDispatch? {
        // Claude deliveries are retried by the Claude runner, which checks the session before sending again.
        dispatches(for: taskID).first { $0.state == "dispatching" && $0.availableAt != nil && $0.agent != .claude }
    }
    func retryUndelivered(_ item: NativeDispatch) {
        let evidence = deliverySearches[item.id]?.provedMissing == true
            ? "Facienda read every Codex chat active since this delivery was requested and none held its marker; the user selected Send again."
            : "User inspected native delivery and confirmed no chat/message was created, then selected Retry delivery in Facienda."
        perform {
            try store.retryUndeliveredDispatch(item.id, evidence: evidence)
            deliverySearches[item.id] = nil
            refresh()
            // On the board the task stays where it is; its dot shows it queued again.
            if destination != .dashboard { showTask(try store.task(item.taskId)) }
        }
    }
    /// Sends at once when every chat was read and none had it; otherwise asks first.
    func sendAgain(_ item: NativeDispatch) {
        if deliverySearches[item.id]?.provedMissing == true { retryUndelivered(item) } else { resendConfirmation = item }
    }
    /// What the last look for a parked delivery found, in one line.
    func deliverySummary(_ item: NativeDispatch) -> String {
        let checkNote = item.kind == "check" ? " Scheduled checks are not resent: drop it, then resume the check from its plan." : ""
        guard let search = deliverySearches[item.id] else {
            return (connected ? "Waiting to look through your Codex chats." : "Connect Codex so Facienda can look for the chat that received this.") + checkNote
        }
        if search.searching { return "Looking for this delivery in your Codex chats…" }
        if let error = search.error { return "Facienda could not look through your chats. " + error + checkNote }
        if search.chats.count > 1 { return "This delivery reached more than one chat. Keep the one that should carry on the task." }
        if search.provedMissing { return "Facienda checked every chat since this was sent and none received it." + checkNote }
        return "Facienda could not read every chat since this was sent, and found it in none it could read." + checkNote
    }
    /// Looks again for parked deliveries no search has covered in the last ten minutes.
    func findParkedDeliveries() async {
        for item in nativeDispatches where item.state == "dispatching" && item.availableAt != nil && item.agent != .claude {
            if let last = deliverySearches[item.id], last.searching || Date().timeIntervalSince(last.at) < 600 { continue }
            await findDelivery(item)
        }
    }
    /// One exact marker match proves the delivery happened, so that chat is linked straight away.
    /// Anything else waits for the user: no match is weaker evidence than a match.
    func findDelivery(_ item: NativeDispatch) async {
        guard connected, !demo, deliverySearches[item.id]?.searching != true else { return }
        deliverySearches[item.id] = DeliverySearch()
        do {
            let result = try await DeliveryFinder.find(item, runnerThreadId: nativeRunner?.threadId, bridge: bridge)
            if result.chats.count == 1, let chat = result.chats.first {
                try store.acknowledgeRecoveredDispatch(item.id, threadId: chat.id, status: status(of: chat), source: .app)
                deliverySearches[item.id] = nil
                refresh()
                return
            }
            deliverySearches[item.id] = DeliverySearch(searching: false, chats: result.chats, complete: result.complete)
        } catch is CancellationError { deliverySearches[item.id] = nil }
        catch { deliverySearches[item.id] = DeliverySearch(searching: false, error: error.localizedDescription) }
    }
    func useDeliveryChat(_ item: NativeDispatch, _ chat: CodexThread) {
        perform {
            try store.acknowledgeRecoveredDispatch(item.id, threadId: chat.id, status: status(of: chat), source: .user)
            deliverySearches[item.id] = nil
            refresh()
        }
    }
    private func status(of chat: CodexThread) -> String {
        (threads.first { $0.id == chat.id } ?? chat).statusLabel
    }
    func cancelStart(_ id: String) {
        perform {
            let cancelled = nativeDispatches.first { $0.id == id }
            let taskID = cancelled?.taskId
            if let taskID, let message = cancelled?.message { replyDrafts[taskID] = message }
            try store.cancelDispatch(id); refresh()
            if destination != .dashboard, let taskID, let task = tasks.first(where: { $0.id == taskID }) { showTask(task) }
        }
    }
    func reply(to task: FaciendaTask, text: String, reveal: Bool = true, userAuthored: Bool = true) -> Bool {
        guard !demo, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            if agent(for: task) == .claude {
                guard claudeConnected else { throw StoreError.invalid("Connect Claude in Settings so Facienda can relay replies, or answer in the Claude app. Your reply is still here.") }
            } else {
                guard workspaceReady else { throw StoreError.invalid("Connect Codex in Settings first. Your reply is still here.") }
            }
            guard pendingDispatch(for: task.id) == nil else { throw StoreError.invalid("A message is already queued for this task.") }
            _ = try store.enqueueDispatch(taskId: task.id, message: text, userAuthored: userAuthored)
            replyDrafts[task.id] = ""
            refresh(); if reveal { showTask(task) }; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
