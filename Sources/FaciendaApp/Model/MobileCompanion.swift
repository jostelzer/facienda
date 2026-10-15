import Foundation
import SwiftData
import CoreData
import Security
import FaciendaCore
import FaciendaCompanion

/// One Mac mailbox routes requests to the library's named workspaces. SwiftData handles iCloud transport.
@MainActor final class MobileCompanion {
    static var isCloudBuild: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] else { return false }
        return containers.contains(CompanionStorage.containerID)
    }

    let container: ModelContainer
    /// The workspace that receives phone requests sent before workspaces existed.
    let store: FaciendaStore
    private(set) var lastCloudDownload: Date?
    private var cloudErrors: [NSPersistentCloudKitContainer.EventType: String] = [:]
    private var cloudActivities: Set<NSPersistentCloudKitContainer.EventType> = []
    var cloudStatus: String {
        if let error = cloudErrors[.setup] ?? cloudErrors[.import] ?? cloudErrors[.export] { return error }
        if cloudActivities.contains(.import) { return "Downloading from iCloud…" }
        if let lastCloudDownload {
            return "Last iCloud download: " + lastCloudDownload.formatted(date: .abbreviated, time: .standard)
        }
        return "Waiting for the first iCloud download…"
    }
    private var cloudEvents: Task<Void, Never>?
    deinit { cloudEvents?.cancel() }

    init(store: FaciendaStore, cloudEnabled: Bool = true) throws {
        self.store = store.workspaceID == nil ? store.scoped(to: try store.defaultWorkspace().id) : store
        let url = store.url.deletingLastPathComponent().appending(path: "companion.store")
        container = try CompanionStorage.makeContainer(cloudEnabled: cloudEnabled, url: url)
        if cloudEnabled {
            let events = NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification)
            cloudEvents = Task { [weak self] in
                for await notification in events {
                    guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                          !Task.isCancelled else { continue }
                    self?.recordCloudEvent(type: event.type, completedAt: event.endDate, error: event.error?.localizedDescription)
                }
            }
        }
    }

    func recordCloudEvent(type: NSPersistentCloudKitContainer.EventType, completedAt: Date?, error: String?) {
        guard let completedAt else { cloudActivities.insert(type); return }
        cloudActivities.remove(type)
        // An unrelated successful export must not hide a failed download.
        cloudErrors[type] = error
        if type == .import, error == nil { lastCloudDownload = completedAt }
    }

    /// Settings › Connections: also show tasks made on the Mac on the phone, with their latest line. Off by default.
    nonisolated static let sharesAllTasksKey = "mobileSharesAllTasks"

    /// Every workspace of the library syncs through the one mailbox. All share this Mac's runner, so all are ready together.
    /// Only tasks the phone sent are published, by their status and the phone's own text, unless `sharesAllTasks` is set.
    /// It reads every workspace and the iCloud store, so the app runs it off the main thread.
    nonisolated func synchronize(ready: Bool, sharesAllTasks: Bool = UserDefaults.standard.bool(forKey: sharesAllTasksKey),
                                 status: (FaciendaTask) -> String, isProcessing: (FaciendaTask) -> Bool) throws {
        // A fresh context sees CloudKit imports as well as writes by the other local helpers.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let library = store.library
        try synchronizeCatalog(context: context, library: library, ready: ready)
        let plans = try library.checkPlans(), dispatches = try library.dispatches()
        var phoneTexts = try library.mobileRequestTexts()
        for workspace in try library.workspaces() {
            let isOwner = workspace.id == store.workspaceID
            try synchronize(context: context, store: library.scoped(to: workspace.id), workspaceID: workspace.id, acceptUnassigned: isOwner,
                ready: ready, sharesAllTasks: sharesAllTasks, phoneTexts: &phoneTexts, status: isOwner ? status : { $0.state.label },
                isProcessing: isOwner ? isProcessing : { task in
                    let queued = dispatches.contains { $0.taskId == task.id && ["queued", "claimed", "dispatching"].contains($0.state) }
                    let checking = plans.contains { plan in
                        plan.taskId == task.id && !plan.paused && dispatches.contains { dispatch in
                            dispatch.taskId == task.id && dispatch.kind == "check" && dispatch.state == "started" && dispatch.checkRevision == plan.revision
                        }
                    }
                    return TaskSection.classify(task, queued: queued) == .processing || checking
                })
        }
        if context.hasChanges { try context.save() }
    }

    nonisolated private func synchronizeCatalog(context: ModelContext, library: FaciendaStore, ready: Bool) throws {
        let remote = try context.fetch(FetchDescriptor<CompanionWorkspace>())
        let removedIDs = Set(try library.workspaces(includeRemoved: true).filter { $0.removedAt != nil }.map(\.id))
        for record in remote where removedIDs.contains(record.workspaceID) { context.delete(record) }
        // A workspace made on the phone uses the owner's memory until you choose another on the Mac.
        // The phone can add a workspace but never change one: a name it changes is put back below.
        let memory = try library.workspace(store.workspaceID ?? "").memorySpaceId
        let localIDs = Set(try library.workspaces().map(\.id))
        for workspace in CompanionWorkspace.unique(remote) where !removedIDs.contains(workspace.workspaceID) && !localIDs.contains(workspace.workspaceID) {
            let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: workspace.workspaceID) != nil, !name.isEmpty, name.count <= 200 {
                try library.createWorkspace(name: name, memorySpaceID: memory, id: workspace.workspaceID, nameUpdatedAt: workspace.nameUpdatedAt)
            }
        }
        for workspace in try library.workspaces() {
            let copies = remote.filter { $0.workspaceID == workspace.id }
            let records: [CompanionWorkspace]
            if copies.isEmpty {
                let record = CompanionWorkspace(id: workspace.id, name: workspace.name, updatedAt: workspace.nameUpdatedAt)
                context.insert(record); records = [record]
            } else { records = copies }
            for record in records {
                if record.name != workspace.name || record.nameUpdatedAt != workspace.nameUpdatedAt {
                    record.name = workspace.name; record.nameUpdatedAt = workspace.nameUpdatedAt
                }
                if record.syncedAt == nil || record.ready != ready { record.syncedAt = Date() }
                if record.ready != ready { record.ready = ready }
                let isDefault = workspace.id == store.workspaceID
                if record.isDefault != isDefault { record.isDefault = isDefault }
            }
        }
    }

    nonisolated private func synchronize(context: ModelContext, store: FaciendaStore, workspaceID: String, acceptUnassigned: Bool,
                             ready: Bool, sharesAllTasks: Bool, phoneTexts: inout [String: String],
                             status: (FaciendaTask) -> String, isProcessing: (FaciendaTask) -> Bool) throws {
        let requests = try context.fetch(FetchDescriptor<CompanionRequest>())
        let localTasks = Set(try store.tasks().map(\.id))
        for request in requests {
            guard request.workspaceID == workspaceID || (acceptUnassigned && request.workspaceID.isEmpty) else { continue }
            if localTasks.contains(request.requestID) {
                // Only a task the phone sent answers to its request; a task made on this Mac is never reached this way.
                guard phoneTexts[request.requestID] != nil else { continue }
            } else {
                // An acknowledged request belongs to the workspace that originally received it.
                guard request.receivedAt == nil else { continue }
                // Never started from here: the task waits on the Mac until the user starts it. A refused request stays unreceived.
                do { _ = try store.receiveMobileRequest(id: request.requestID, text: request.text, createdAt: request.createdAt) }
                catch StoreError.invalid { continue }
                phoneTexts[request.requestID] = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if request.workspaceID != workspaceID { request.workspaceID = workspaceID }
            if request.receivedAt == nil { request.receivedAt = Date() }
        }
        let startedIDs = Set(try store.dispatches().filter { ($0.kind ?? "start") == "start" }.map(\.taskId))
        let tasks = try store.tasks().filter { sharesAllTasks || phoneTexts[$0.id] != nil }
        let published = Set(tasks.map(\.id))
        let summaries = try context.fetch(FetchDescriptor<CompanionTask>()).filter { $0.workspaceID == workspaceID || (acceptUnassigned && $0.workspaceID.isEmpty) }
        // A task no longer shared, moved to another workspace or deleted leaves iCloud.
        for summary in summaries where !published.contains(summary.taskID) { context.delete(summary) }
        let byID = Dictionary(grouping: summaries.filter { published.contains($0.taskID) }, by: \.taskID)
        let pending = Dictionary(grouping: try store.dispatches().filter { ["queued", "claimed", "dispatching"].contains($0.state) && !($0.state == "dispatching" && $0.availableAt != nil) }, by: \.taskId)
        let results = sharesAllTasks ? Dictionary(try store.latestResults().map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        let headlines = sharesAllTasks ? Dictionary(try store.headlines().map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        for task in tasks {
            let processing = pending[task.id] != nil || isProcessing(task)
            let section: String
            switch TaskSection.classify(task, queued: processing) {
            case .processing: section = CompanionSection.processing.rawValue
            case .waiting: section = CompanionSection.waiting.rawValue
            case .scheduled: section = CompanionSection.scheduled.rawValue
            case .done: section = CompanionSection.done.rawValue
            case .inbox, .forYou: section = CompanionSection.review.rawValue
            }
            let reportedStatus = pending[task.id]?.first.map { $0.state == "queued" ? "Queued" : "Starting" } ?? status(task)
            let awaitsStart = task.state == .inbox && pending[task.id] == nil && !startedIDs.contains(task.id)
            let taskStatus = awaitsStart ? (ready ? "Start it on your Mac" : "Connect Codex on your Mac") : reportedStatus.isEmpty ? "Needs you" : reportedStatus
            let title: String, detail: String
            if sharesAllTasks {
                // The same short line as the Mac card: the latest result's headline once one is written.
                let headline = results[task.id].map { source in headlines[task.id].flatMap { $0.eventId == source.eventId ? $0.text : nil } ?? TaskHeadline.fallback(source.excerpt) }
                title = task.displayName
                detail = task.waitingOn ?? headline ?? (task.brief.isEmpty ? task.nextAction : TaskHeadline.fallback(task.brief))
            } else {
                // Only what the phone already knows: its own text, and the status.
                title = phoneTexts[task.id].flatMap { $0.isEmpty ? nil : $0 } ?? task.title
                detail = ""
            }
            if let copies = byID[task.id] {
                for summary in copies {
                    guard summary.workspaceID != workspaceID || summary.revision != task.revision || summary.title != title || summary.section != section || summary.status != taskStatus || summary.detail != detail else { continue }
                    summary.workspaceID = workspaceID
                    summary.title = title; summary.detail = detail; summary.section = section
                    summary.status = taskStatus; summary.revision = task.revision; summary.updatedAt = task.updatedAt
                }
            } else {
                context.insert(CompanionTask(id: task.id, title: title, detail: detail, section: section,
                    status: taskStatus, revision: task.revision, updatedAt: task.updatedAt, workspaceID: workspaceID))
            }
        }
    }
}
