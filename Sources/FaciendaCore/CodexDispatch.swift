import Foundation
import GRDB

/// Codex work is delivered by Facienda's own dispatcher, which talks to the Codex app's app server directly. It wakes
/// only when work is queued, so nothing runs while the queue is empty, and setup needs nothing pressed in Codex.
extension FaciendaStore {
    /// The runner ID the dispatcher claims queue entries with.
    public static let codexDispatcherId = "codex-dispatcher"

    /// Makes the dispatcher this library's Codex runner. A runner bound before it, a scheduled automation or a runner
    /// chat, is retired: its next run sees that and pauses itself. Entries it claimed but never delivered go back to the queue.
    public func bindCodexDispatcher(now: Date = Date()) throws {
        try write { db in
            if let old = try NativeRunnerState.fetchOne(db, sql: "SELECT * FROM runnerState WHERE id = 1") {
                guard old.threadId != Self.codexDispatcherId else { return }
                try db.execute(sql: "DELETE FROM runnerState WHERE id = 1")
                try db.execute(sql: "UPDATE dispatches SET state = 'queued', runnerId = NULL WHERE state = 'claimed' AND runnerId = ?", arguments: [old.threadId])
                try db.execute(sql: "UPDATE workspaceSetup SET retiredRunnerId = ?, retiredAutomationId = ? WHERE id = 1", arguments: [old.threadId, old.automationId])
            }
            try db.execute(sql: "INSERT INTO runnerState(id, threadId, lastSeen) VALUES (1, ?, ?)", arguments: [Self.codexDispatcherId, now])
        }
    }

    /// Records the workspace's Codex project and marks setup complete. Facienda made or found the project itself.
    public func verifyDispatcherSetup(projectId: String, now: Date = Date()) throws {
        guard !projectId.isEmpty else { throw StoreError.invalid("Codex did not return the workspace project.") }
        try write { db in
            guard try WorkspaceSetup.fetchOne(db, sql: "SELECT * FROM workspaceSetup WHERE id = 1") != nil,
                  try String.fetchOne(db, sql: "SELECT threadId FROM runnerState WHERE id = 1") == Self.codexDispatcherId else { throw StoreError.conflict }
            try db.execute(sql: "UPDATE workspaceSetup SET projectId = ?, codexProjectId = ?, confirmedProjectName = ?, projectNameVerifiedAt = ?, runnerId = ?, automationId = NULL, verifiedAt = ? WHERE id = 1",
                           arguments: [projectId, projectId, WorkspaceSetup.projectName, now, Self.codexDispatcherId, now])
        }
    }

    /// A delivery whose native call certainly never happened, because Codex refused it before creating or sending
    /// anything, goes back to the queue. An uncertain one never comes here: it is parked for recovery instead.
    public func releaseUndelivered(_ id: String, runnerId: String, reason: String, now: Date = Date()) throws {
        try write { db in
            guard var item = try NativeDispatch.fetchOne(db, key: id), item.runnerId == runnerId, item.state == "dispatching" else { throw StoreError.conflict }
            item.state = "queued"; item.runnerId = nil; item.availableAt = now.addingTimeInterval(60)
            // A check refused in a copy of its chat goes back to the chat itself.
            if item.kind == "check", let plan = try CheckPlan.fetchOne(db, key: item.taskId) { item.threadId = plan.threadId }
            try item.update(db)
            try TaskEvent(taskId: item.taskId, source: .app, kind: "dispatch.retry", payload: reason, verified: false).insert(db)
        }
    }

    /// A Codex chat as the dispatcher found it just now.
    public struct ChatState: Sendable, Equatable {
        public var threadId: String
        public var title: String
        public var status: DispatchContext.Chat.Status
        public init(threadId: String, title: String, status: DispatchContext.Chat.Status) {
            self.threadId = threadId; self.title = title; self.status = status
        }
    }

    /// A local Codex project and the folders it spans.
    public struct ProjectRoots: Sendable, Equatable {
        public var id: String
        public var paths: [String]
        public init(id: String, paths: [String]) { self.id = id; self.paths = paths }
    }

    /// Where a delivery goes, decided from what Facienda already knows instead of a search through the user's chats:
    /// the task's own chat when it has one, otherwise a new chat in the project its folder belongs to. The new chat
    /// looks for related history itself, with facienda_chat_search.
    public func directContext(for item: NativeDispatch, owner: ChatState?, projects: [ProjectRoots]) throws -> DispatchContext {
        let task = try self.task(item.taskId)
        let key = DispatchContext.key(task: task, dispatch: item)
        if let owner {
            guard owner.threadId == item.threadId else { throw StoreError.invalid("Deliver to the task's own chat.") }
            let chat = DispatchContext.Chat(threadId: owner.threadId, title: owner.title.isEmpty ? task.displayName : owner.title, projectId: nil, hostId: "local",
                                            role: .owner, status: owner.status, relevance: "The chat this task already works in.",
                                            evidence: [.init(sourceReference: "Facienda task link", excerpt: "Linked to “\(task.displayName)” in Facienda.", supports: "This chat owns the task.")])
            return DispatchContext(contextKey: key, searchStatus: .limited, searchSummary: "Delivered to the task's own chat; no other chats were searched.",
                                   route: .reuse, project: nil, chats: [chat], uncertainties: [])
        }
        guard item.threadId == nil else { throw StoreError.invalid("The task's chat could not be found in Codex.") }
        func normal(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        let summary = "Facienda routed this start itself; the new chat searches related history with facienda_chat_search."
        let project: DispatchContext.Project?
        if let folders = task.folders, !folders.isEmpty {
            // Folders the user linked to the task's group decide where it works.
            let wanted = Set(folders.map(normal))
            let id = try linkedProjectId(task: task) ?? projects.first { Set($0.paths.map(normal)) == wanted }?.id
            guard let id else { throw StoreError.invalid("This task's group has no Codex project for its linked folders yet. Open the group's folders in Facienda to create it.") }
            project = .init(id: id, path: folders[0], reason: "The folders linked to the task's group.")
        } else if task.cwd == nil || isAutomaticWorkingDirectory(task.cwd!, taskID: task.id) {
            guard let id = try workspaceSetup()?.projectId else { throw StoreError.invalid("Connect Codex in Settings first.") }
            let folder = task.cwd ?? taskFolder(task.id).path
            try Self.makePrivateFolder(URL(fileURLWithPath: folder))
            project = .init(id: id, path: folder, reason: "The task's own folder in the \(WorkspaceSetup.projectName) project.")
        } else {
            // A folder the user chose stays the working folder, in whichever project spans it, if any.
            let working = normal(task.cwd!)
            project = projects.first { $0.paths.contains { contains(normal($0), working) } }
                .map { .init(id: $0.id, path: task.cwd!, reason: "The folder chosen for this task.") }
        }
        return DispatchContext(contextKey: key, searchStatus: .limited, searchSummary: summary, route: .new, project: project, chats: [], uncertainties: [])
    }
}
