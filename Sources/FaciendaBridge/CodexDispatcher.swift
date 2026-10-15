import Foundation
import FaciendaCore

/// Delivers queued Codex work through Codex's shared app server, the daemon Codex keeps for its own clients. It sleeps
/// on the queue and wakes only when Facienda writes to it, so an empty queue costs nothing and no chat is made just to look.
///
/// A turn started here runs in the daemon, and the Codex app shows its chat read-only until it ends ("open in another
/// app"). Only this connection hears what the turn asks, so the dispatcher follows each turn it starts: it keeps every
/// approval request in the library for the user to answer in Facienda, sends the answer back, and lets go of the chat
/// when the turn ends. The daemon then releases it within a minute and the chat is the user's again in Codex.
///
/// Delivery keeps the queue's guarantees: intent is recorded before the one native create or send, the chat is
/// acknowledged right after, and a delivery interrupted in between is found by its marker or parked for recovery,
/// never sent twice.
public actor CodexDispatcher {
    public static let runnerId = FaciendaStore.codexDispatcherId

    private let store: FaciendaStore
    private let bridge = CodexBridge()
    /// The bundled helper, given to chats that cannot reach Facienda's tools.
    private let base: String
    private let executable: String?
    /// How this process signs its hold on the queue, so the app can tell whether its own dispatcher or the agent runs.
    public static var processHolder: String { FaciendaStore.dispatcherHolder() }
    private let holder = CodexDispatcher.processHolder
    private let log: @Sendable (String) -> Void
    /// Overrides the approval policy of chats it makes, for testing; nil keeps the user's Codex settings.
    private let approvalPolicy: String?
    /// Chats with a turn this dispatcher follows.
    private var following: Set<String> = []
    private var listening: Task<Void, Never>?

    public init(store: FaciendaStore, helper: String, executable: String? = CodexBridge.discoverExecutable(), approvalPolicy: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store; self.executable = executable; self.approvalPolicy = approvalPolicy; self.log = log
        base = "\(FaciendaStore.shellQuote(helper)) --database \(FaciendaStore.shellQuote(store.url.path))"
    }

    /// Works the queue until cancelled. Only one dispatcher works a library at a time; another one waits its turn.
    public func run() async {
        var pause: Duration = .seconds(2)
        defer { try? store.endRunnerTurn(runnerId: Self.runnerId, holder: holder) }
        while !Task.isCancelled {
            do {
                if try await cycle() { pause = .seconds(2); continue }
                pause = .seconds(30)
            } catch is CancellationError { return }
            catch {
                log("Dispatcher: \(error.localizedDescription)")
                await bridge.disconnect()
                pause = min(pause * 2, .seconds(120))
            }
            try? await Task.sleep(for: pause)
        }
    }

    /// One look at the queue, waiting up to 50 seconds for work. False when this dispatcher should rest instead.
    func cycle() async throws -> Bool {
        store.adoptServiceModel()
        guard let runner = try store.runnerState(), runner.isDispatcher,
              try store.beginRunnerTurn(runnerId: Self.runnerId, holder: holder) else { return false }
        // A nearly full disk holds the queue: a task started now could fill it. Facienda shows why on the board.
        if let free = DiskUsage.available(at: store.workFolder), free < DiskUsage.lowSpaceThreshold { return false }
        if await !bridge.isConnected { try await connect() }
        try await inspectUnreportedChecks()
        let store = store
        let item = try await Task.detached { try store.waitForDispatch(runnerId: Self.runnerId, seconds: 50) }.value
        try store.renewRunnerLease(runnerId: Self.runnerId, holder: holder)
        if let item { await deliver(item) }
        return true
    }

    // MARK: Delivery

    func deliver(_ item: NativeDispatch) async {
        do {
            if item.state == "dispatching" { try await recover(item); return }
            if let thread = item.threadId {
                // Replies, checks and further starts go to the task's own chat, once it is free.
                let chat: FaciendaStore.ChatState
                switch try await load(thread) {
                case .missing:
                    return try store.deferDispatch(item.id, runnerId: Self.runnerId, reason: "The task's Codex chat could not be found. It may have been archived or deleted.", blocked: true)
                // The Codex app keeps chats the user opened for hours. A check only looks, so it runs in a copy of the chat.
                case .openInCodex where item.kind == "check":
                    return try await send(item.id, inCopy: true)
                case .openInCodex:
                    return try store.deferDispatch(item.id, runnerId: Self.runnerId, reason: "The chat is open in the Codex app. Facienda sends this once Codex lets go of it, or send it there yourself.")
                case .loaded(let state): chat = state
                }
                guard chat.status == .idle else {
                    if !following.contains(thread) { _ = try? await bridge.request("thread/unsubscribe", params: .object(["threadId": .string(thread)])) }
                    return try store.deferDispatch(item.id, runnerId: Self.runnerId, reason: chat.status == .awaitingUser ? "The chat is waiting for an answer." : "The chat is busy.")
                }
                if item.kind != "check" {
                    try store.saveDispatchContext(store.directContext(for: item, owner: chat, projects: []), dispatchId: item.id, runnerId: Self.runnerId)
                }
            } else {
                let projects = try await bridge.projects().map { FaciendaStore.ProjectRoots(id: $0.id, paths: $0.roots.map(\.path)) }
                try store.saveDispatchContext(store.directContext(for: item, owner: nil, projects: projects), dispatchId: item.id, runnerId: Self.runnerId)
            }
            try await send(item.id)
        } catch {
            log("Delivery \(item.id): \(error.localizedDescription)")
            // Nothing was sent yet: the entry waits a minute, or for the user when routing itself failed.
            let routing = (error as? StoreError).map { if case .invalid = $0 { true } else { false } } ?? false
            try? store.deferDispatch(item.id, runnerId: Self.runnerId, reason: error.localizedDescription, blocked: routing)
        }
    }

    /// Records intent, then makes exactly one native create or send, then acknowledges the chat.
    /// `inCopy` runs a check in an unsaved copy of the task's chat, which Codex drops once the turn ends.
    private func send(_ id: String, inCopy: Bool = false) async throws {
        guard let item = try store.dispatches().first(where: { $0.id == id }) else { throw StoreError.notFound }
        let task = try store.task(item.taskId)
        let snapshot = try NativeDispatchPreparation(dispatch: item, task: task, context: store.dispatchContext(id))
        let delivery = try await DispatchPrompt.payload(item, store: store, base: base)
        guard let prompt = delivery["workerPrompt"].string else { throw StoreError.invalid("The delivery has no prompt.") }
        let started = try store.beginDispatch(id, runnerId: Self.runnerId, preparation: snapshot)
        // From here on a failure is uncertain unless Codex itself refused the call.
        var thread = started.threadId
        var copy: String?
        let title = task.displayTitle ?? task.displayName
        do {
            if inCopy, let owner = thread {
                var params: [String: JSONValue] = ["threadId": .string(owner), "ephemeral": .bool(true), "excludeTurns": .bool(true)]
                if let approvalPolicy { params["approvalPolicy"] = .string(approvalPolicy) }
                let forked = try await bridge.request("thread/fork", params: .object(params), timeout: .seconds(60))
                guard let forkedID = forked["thread"]["id"].string else { throw BridgeError.server("Codex did not return the copy of the chat.") }
                copy = forkedID; thread = forkedID
                // Recorded before the turn starts, so what the turn asks reaches the task.
                try store.runCheckInCopy(id, runnerId: Self.runnerId, threadId: forkedID)
            }
            if thread == nil {
                let folder = delivery["workingFolder"].string ?? delivery["targetProject"]["path"].string ?? store.workFolder.path
                var params: [String: JSONValue] = ["cwd": .string(folder)]
                if let model = delivery["workerModel"].string { params["model"] = .string(model) }
                if let tier = delivery["workerServiceTier"].string { params["serviceTier"] = .string(tier) }
                if let approvalPolicy { params["approvalPolicy"] = .string(approvalPolicy) }
                let created = try await bridge.request("thread/start", params: .object(params), timeout: .seconds(60))
                guard let newThread = created["thread"]["id"].string else { throw BridgeError.server("Codex did not return the new chat.") }
                thread = newThread
                _ = try? await bridge.request("thread/name/set", params: .object(["threadId": .string(newThread), "name": .string(title)]))
            }
            var turn: [String: JSONValue] = ["threadId": .string(thread!), "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])]
            // A chat that already works keeps its own model and settings.
            if started.threadId == nil {
                if let effort = delivery["workerReasoningEffort"].string { turn["effort"] = .string(effort) }
                if let tier = delivery["workerServiceTier"].string { turn["serviceTier"] = .string(tier) }
            }
            _ = try await bridge.request("turn/start", params: .object(turn), timeout: .seconds(60))
        } catch BridgeError.server(let message) {
            // Codex refused: nothing reached the chat. A chat made just for this goes; the entry is tried again.
            if started.threadId == nil, let thread { _ = try? await bridge.request("thread/archive", params: .object(["threadId": .string(thread)])) }
            if let copy { _ = try? await bridge.request("thread/unsubscribe", params: .object(["threadId": .string(copy)])) }
            try store.releaseUndelivered(id, runnerId: Self.runnerId, reason: message)
            return
        } catch {
            try? store.deferDispatch(id, runnerId: Self.runnerId, reason: "Delivery was interrupted (\(error.localizedDescription)). Check whether the chat received it.", blocked: true)
            return
        }
        // The turn runs: follow it, so what it asks reaches the user and the chat is let go once it ends.
        following.insert(thread!)
        try store.acknowledgeDispatch(id, runnerId: Self.runnerId, threadId: thread!)
        if started.threadId == nil {
            try? store.recordChatName(taskID: task.id, threadID: thread!, observedTitle: title, runnerID: Self.runnerId)
            // The short name comes after the start, so asking for it never holds up the work.
            if task.displayTitle == nil { let thread = thread!; Task { await self.nameNewChat(task.id, thread: thread) } }
        }
    }

    // MARK: Following turns

    /// Connects, starts listening, and takes up the turns that were running when the last connection ended. Codex
    /// sends their open requests again.
    private func connect() async throws {
        listening?.cancel(); following = []
        try await bridge.connectDaemon()
        let messages = bridge.subscribe()
        listening = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await message in messages { await self?.handle(message) } }
                group.addTask { await self?.passAnswers() }
                await group.next(); group.cancelAll()
            }
        }
        for thread in try store.codexChatsToFollow(since: Date().addingTimeInterval(-12 * 3600)) where !following.contains(thread) {
            guard let state = try? await chatState(thread), state.status != .idle else {
                try? store.closeCodexApprovals(threadId: thread); continue
            }
            if case .loaded = try await load(thread) { following.insert(thread) }
        }
    }

    private func handle(_ message: BridgeMessage) async {
        if message.method == "facienda/disconnected" { following = []; return }
        if let id = message.requestID {
            guard CodexApproval.methods.contains(message.method) else { try? await bridge.rejectUnsupported(id: id); return }
            do { try store.recordCodexApproval(method: message.method, params: message.params, requestId: id) }
            catch { log("Approval request: \(error.localizedDescription)") }
            return
        }
        guard let thread = message.params["threadId"].string else { return }
        switch message.method {
        case "serverRequest/resolved":
            try? store.closeCodexApprovals(threadId: thread, requestId: message.params["requestId"])
        case "turn/completed" where following.contains(thread):
            following.remove(thread)
            try? store.closeCodexApprovals(threadId: thread)
            // Codex releases a chat nobody follows within a minute; then it is the user's again in the Codex app.
            _ = try? await bridge.request("thread/unsubscribe", params: .object(["threadId": .string(thread)]))
        default: break
        }
    }

    /// Sends the user's answers as they come in.
    private func passAnswers() async {
        while !Task.isCancelled {
            for approval in (try? store.codexApprovalsToSend()) ?? [] where following.contains(approval.threadId) {
                guard let id = try? JSONDecoder().decode(JSONValue.self, from: Data(approval.requestId.utf8)),
                      let response = try? JSONDecoder().decode(JSONValue.self, from: Data((approval.response ?? "").utf8)) else { continue }
                do { try await bridge.respond(id: id, result: response); try store.markCodexApprovalSent(approval.id) }
                catch { log("Answer \(approval.id): \(error.localizedDescription)") }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private enum Loaded { case loaded(FaciendaStore.ChatState), openInCodex, missing }

    /// Loads a chat into the daemon and follows it. A chat the Codex app has open can only be written there.
    private func load(_ thread: String) async throws -> Loaded {
        do {
            let response = try await bridge.request("thread/resume", params: .object(["threadId": .string(thread)]), timeout: .seconds(60))
            return .loaded(Self.state(thread, response["thread"]))
        } catch BridgeError.server(let message) {
            return message.contains("active writer") ? .openInCodex : .missing
        }
    }

    /// A delivery interrupted between intent and acknowledgement. Its exact marker tells whether it arrived.
    private func recover(_ item: NativeDispatch) async throws {
        let found = try await DeliveryFinder.find(item, runnerThreadId: nil, bridge: bridge)
        if found.chats.count == 1 {
            try store.acknowledgeDispatch(item.id, runnerId: Self.runnerId, threadId: found.chats[0].id)
        } else {
            try store.deferDispatch(item.id, runnerId: Self.runnerId, reason: found.chats.isEmpty ? "A delivery was interrupted and no chat holds it yet." : "A delivery was interrupted and several chats hold it.", blocked: true)
        }
    }

    /// The chat as Codex has it now; nil when it cannot be read.
    private func chatState(_ thread: String) async throws -> FaciendaStore.ChatState? {
        let response: JSONValue
        do { response = try await bridge.request("thread/read", params: .object(["threadId": .string(thread)])) }
        catch BridgeError.server { return nil }
        return Self.state(thread, response["thread"])
    }

    private static func state(_ thread: String, _ value: JSONValue) -> FaciendaStore.ChatState {
        let status = value["status"], flags = (status["activeFlags"].array ?? []).compactMap(\.string)
        let state: DispatchContext.Chat.Status = switch status["type"].string {
        case "idle", "notLoaded": .idle
        case "active": flags.contains { $0.hasPrefix("waitingOn") } ? .awaitingUser : .active
        default: .unknown
        }
        let name = value["name"].string ?? ""
        return .init(threadId: thread, title: name.isEmpty ? String((value["preview"].string ?? "").prefix(90)) : name, status: state)
    }

    /// A check whose chat went quiet without reporting is recorded as failed, so its plan backs off and tries again.
    private func inspectUnreportedChecks() async throws {
        for item in try store.unreportedChecksToInspect() where item.runnerId == Self.runnerId {
            guard let thread = item.threadId, let revision = item.checkRevision else { continue }
            let chat = try await chatState(thread)
            // A copy made for the check is gone once its turn ended and Codex dropped it.
            guard chat?.status == .idle || (chat == nil && store.isCheckCopy(item)) else { continue }
            _ = try? store.reportCheck(taskId: item.taskId, dispatchId: item.id, expectedRevision: revision, outcome: "failed", summary: "The chat finished without saving a check outcome.",
                                       nextCheck: Date().addingTimeInterval(3600), reason: "Retry after a missing outcome; bounded failure backoff applies.")
        }
    }

    /// Names a new chat with the task's short name once its turn runs.
    private func nameNewChat(_ taskId: String, thread: String) async {
        await nameIfNeeded(taskId)
        guard let task = try? store.task(taskId), let name = task.displayTitle else { return }
        guard (try? await bridge.request("thread/name/set", params: .object(["threadId": .string(thread), "name": .string(name)]))) != nil else { return }
        try? store.recordChatName(taskID: taskId, threadID: thread, observedTitle: name, runnerID: Self.runnerId)
    }

    /// Asks a fast model for the task's short name when it has none.
    private func nameIfNeeded(_ taskId: String) async {
        guard let task = try? store.task(taskId), task.displayTitle == nil, let executable else { return }
        let luna = BackgroundModel()
        defer { Task { await luna.shutdown() } }
        do {
            try await luna.warm(executable: executable)
            let thread = try await luna.open(.name)
            let reply = try await luna.ask(thread, text: TaskNameWriter.prompt(for: task, latestResult: nil), schema: TaskNameWriter.schema, effort: TaskNameWriter.reasoningEffort, timeout: .seconds(30))
            try store.nameTask(taskId, runnerID: Self.runnerId, expectedTitle: task.title, displayTitle: TaskNameWriter.read(reply), context: "Named by Facienda from the request.")
        } catch { log("Naming \(taskId): \(error.localizedDescription)") }
    }
}
