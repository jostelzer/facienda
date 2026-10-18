import AppKit
import UserNotifications
import FaciendaCore
import FaciendaBridge

/// Built-in memory talks to one warm, hidden Luna for the life of the app.
let memoryLuna = LunaMemoryInference()

extension AppModel {
    func start() {
        if !started {
            started = true
            serviceTask = Task { await runServices() }
            if !demo { Task { await offerAutomaticSources() } }
        }
    }
    func stop() async {
        serviceTask?.cancel(); serviceTask = nil
        memoryTask?.cancel(); memoryTask = nil
        deliveryTask?.cancel(); deliveryTask = nil
        indexTask?.cancel(); indexTask = nil
        // The Codex connection is shared with the other workspaces, so it stays up.
        started = false
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }
    func runServices() async {
        // Darwin notifications wake the app after writes from another process. The timer is a fallback.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, pointer, _, _, _ in
            guard let pointer else { return }
            let address = UInt(bitPattern: pointer)
            Task { @MainActor in
                guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
                let model = Unmanaged<AppModel>.fromOpaque(pointer).takeUnretainedValue()
                model.refreshSoon()
            }
        }, FaciendaStore.changeNotification as CFString, nil, .deliverImmediately)
        if !demo, !connected { await codex.connectOnLaunch(); if connected { await pollThreads() } }
        while !Task.isCancelled {
            if !demo {
                await ClaudeUsage.shared.refreshIfDue()
                if memoryTask == nil {
                    memoryTask = Task { [weak self] in
                        await self?.syncMemory()
                        self?.memoryTask = nil
                    }
                }
                await sweep()
                freeDiskSpace = DiskUsage.available(at: store.workFolder)
                if let today = Calendar.current.ordinality(of: .day, in: .era, for: Date()), backedUpDay != today {
                    backedUpDay = today
                    let library = store.library
                    Task.detached(priority: .utility) { LibraryHome.backUp(library) }
                }
                // Codex work goes out through Facienda's dispatcher, which needs no Codex connection here.
                if workspaceReady, nativeRunner?.isDispatcher == true { startDispatcher(self) }
                // Claude sessions are read from their transcripts, with or without a Codex connection.
                await refreshClaudeSessions()
                // A connection that survived a whole tick is stable, so reset the backoff.
                if connected {
                    codex.confirmStable(); await pollThreads(); indexChats()
                    await confirmPendingProjectName()
                    await archiveRunnerRuns()
                    if codex.usageIsStale { await refreshUsage() }
                    if deliveryTask == nil {
                        deliveryTask = Task { [weak self] in
                            await self?.findParkedDeliveries()
                            self?.deliveryTask = nil
                        }
                    }
                }
                else if codex.reconnectIsDue { await connect() }
                refresh()
            }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }
    func syncMemory() async {
        guard !demo, !memorySyncing, (try? store.memorySettings().enabled) == true else { return }
        memorySyncing = true
        defer { memorySyncing = false; refresh() }
        do {
            memoryError = nil
            if connected {
                let ids = Array(Set(links.map(\.codexThreadId))).sorted()
                for _ in 0..<min(2, ids.count) {
                    let id = ids[memoryCursor % ids.count]
                    memoryCursor += 1
                    do {
                        let response = try await bridge.readThread(id), store = store
                        try await Task.detached(priority: .utility) { try ThreadMemory.capture(response, threadId: id, store: store) }.value
                    }
                    catch { memoryError = "Chat capture: " + error.localizedDescription }
                }
            }
            try await WorkspaceMemoryService(store: store, inference: memoryLuna).synchronize()
        } catch { memoryError = error.localizedDescription }
    }

    func enableNotifications() async {
        do { notificationEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); UserDefaults.standard.set(notificationEnabled, forKey: "notificationsEnabled") }
        catch { self.error = error.localizedDescription }
    }
    func sweep() async {
        do {
            try store.surfaceStaleApprovals()
            let due = try store.claimDue()
            for task in due where notificationEnabled { try await notify(task, identifier: "followup-\(task.id)") }
            // Waits that ended since the last sweep, whichever process noticed first.
            for wait in try store.claimWaitNotices() where wait.state != "cancelled" && notificationEnabled {
                guard let task = try? store.task(wait.taskId) else { continue }
                try await notify(task, identifier: "wait-\(task.id)")
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Shows the task's next step as a notification. A failure is recorded on the task.
    private func notify(_ task: FaciendaTask, identifier: String) async throws {
        let content = UNMutableNotificationContent(); content.title = task.displayName; content.body = task.nextAction; content.sound = .default; content.userInfo = ["taskId": task.id]
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) }
        catch { try store.record(TaskEvent(taskId: task.id, source: .app, kind: "notification.failed", payload: error.localizedDescription)) }
    }
}
