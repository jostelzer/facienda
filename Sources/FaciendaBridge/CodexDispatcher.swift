import Foundation
import FaciendaCore

/// Delivers through the desktop app's queue. This connection only reads and queues; the app owns the turn,
/// so the user can steer it while it runs and continue afterwards. Legacy daemon turns are followed until done.
/// Intent, destination and queue receipt are persisted separately: an interrupted add is inspected, never repeated.
public actor CodexDispatcher {
    public static let runnerId = FaciendaStore.codexDispatcherId

    private let store: FaciendaStore
    private let bridge: CodexBridge
    /// The bundled helper, given to chats that cannot reach Facienda's tools.
    private let base: String
    private let executable: String?
    /// How this process signs its hold on the queue, so the app can tell whether its own dispatcher or the agent runs.
    public static var processHolder: String { FaciendaStore.dispatcherHolder() }
    private let holder = CodexDispatcher.processHolder
    private let log: @Sendable (String) -> Void
    /// Overrides the approval policy of chats it makes, for testing; nil keeps the user's Codex settings.
    private let approvalPolicy: String?
    private let wake: @Sendable (String) async throws -> Void
    private var lastWake: [String: Date] = [:]
    private var missingQueueSince: [String: Date] = [:]
    /// Chats with a turn this dispatcher follows.
    private var following: Set<String> = []
    /// Failed releases stay here until Codex acknowledges them or the connection closes.
    private var releasing: Set<String> = []
    private var releasesInFlight: [String: Task<Void, Error>] = [:]
    private var listening: Task<Void, Never>?

    public init(store: FaciendaStore, helper: String, executable: String? = CodexBridge.discoverExecutable(), approvalPolicy: String? = nil, bridge: CodexBridge = CodexBridge(), wake: (@Sendable (String) async throws -> Void)? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store; self.executable = executable; self.approvalPolicy = approvalPolicy; self.bridge = bridge; self.log = log
        self.wake = wake ?? { try await CodexAppDelivery.wake($0) }
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
            } catch is CancellationError { break }
            catch {
                log("Dispatcher: \(error.localizedDescription)")
                await bridge.disconnect()
                pause = min(pause * 2, .seconds(120))
            }
            try? await Task.sleep(for: pause)
        }
        listening?.cancel(); listening = nil
        await bridge.disconnect()
        following = []; releasing = []
    }

    /// One look at the queue, waiting up to 50 seconds for work. False when this dispatcher should rest instead.
    func cycle() async throws -> Bool {
        store.adoptServiceModel()
        guard let runner = try store.runnerState(), runner.isDispatcher,
              try store.beginRunnerTurn(runnerId: Self.runnerId, holder: holder) else { return false }
        // A nearly full disk holds the queue: a task started now could fill it. Facienda shows why on the board.
        if let free = DiskUsage.available(at: store.workFolder), free < DiskUsage.lowSpaceThreshold { return false }
        if await !bridge.isConnected { try await connect() }
        await releaseFinishedChats()
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
                guard let chat = try await chatState(thread) else {
                    return try store.deferDispatch(item.id, runnerId: Self.runnerId, reason: "The task's Codex chat could not be found. It may have been archived or deleted.", blocked: true)
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
            let routing = (error as? StoreError).map { if case .invalid = $0 { true } else { false } } ?? false
            try? store.deferDispatch(item.id, runnerId: Self.runnerId, reason: error.localizedDescription, blocked: routing)
        }
    }

    private func send(_ id: String) async throws {
        guard let item = try store.dispatches().first(where: { $0.id == id }) else { throw StoreError.notFound }
        let task = try store.task(item.taskId)
        let snapshot = try NativeDispatchPreparation(dispatch: item, task: task, context: store.dispatchContext(id))
        let delivery = try await DispatchPrompt.payload(item, store: store, base: base)
        guard let prompt = delivery["workerPrompt"].string else { throw StoreError.invalid("The delivery has no prompt.") }
        let started = try store.beginDispatch(id, runnerId: Self.runnerId, preparation: snapshot)
        var thread = started.threadId
        let title = task.displayTitle ?? task.displayName
        do {
            if thread == nil {
                guard let executable else { throw BridgeError.unavailable }
                let folder = delivery["workingFolder"].string ?? delivery["targetProject"]["path"].string ?? store.workFolder.path
                var params: [String: JSONValue] = ["cwd": .string(folder)]
                if let model = delivery["workerModel"].string { params["model"] = .string(model) }
                if let tier = delivery["workerServiceTier"].string { params["serviceTier"] = .string(tier) }
                if let approvalPolicy { params["approvalPolicy"] = .string(approvalPolicy) }
                thread = try await CodexAppDelivery.create(executable: executable, params: .object(params), title: title, effort: delivery["workerReasoningEffort"].string)
            }
            try store.prepareCodexQueue(id, runnerId: Self.runnerId, threadId: thread!)
        } catch {
            // No message has been submitted, so retrying this preparation cannot duplicate work.
            try store.releaseUndelivered(id, runnerId: Self.runnerId, reason: error.localizedDescription)
            return
        }
        let receipt: JSONValue
        do {
            receipt = try await bridge.request("thread/queue/add", params: .object([
                "threadId": .string(thread!), "clientUserMessageId": .string(id),
                "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])
            ]), timeout: .seconds(60))
        } catch BridgeError.server(let message) {
            try store.releaseUndelivered(id, runnerId: Self.runnerId, reason: message)
            return
        } catch {
            // It may have arrived. Recovery inspects the saved destination, never repeats queue/add.
            log("Queue acceptance uncertain for \(id): \(error.localizedDescription)")
            return
        }
        guard let queueID = receipt["queuedSubmission"]["id"].string else {
            log("Codex omitted the queue receipt for \(id); recovery will inspect the chat.")
            return
        }
        try store.recordCodexQueue(id, runnerId: Self.runnerId, queuedSubmissionId: queueID)
        if started.threadId == nil {
            try? store.recordChatName(taskID: task.id, threadID: thread!, observedTitle: title, runnerID: Self.runnerId)
        }
        await wakeQueuedChat(thread!)
    }

    private func wakeQueuedChat(_ thread: String) async {
        guard Date().timeIntervalSince(lastWake[thread] ?? .distantPast) >= 30 else { return }
        lastWake[thread] = Date()
        do { try await wake(thread) }
        catch { log("Wake Codex chat \(thread): \(error.localizedDescription)") }
    }

    /// Queue acceptance and execution are separate. A removed queue entry is not proof that the turn started.
    func reconcileQueuedDeliveries() async {
        // While the dispatcher waits to reconnect there is nothing to ask.
        guard await bridge.isConnected else { return }
        for item in (try? store.codexQueuedDeliveries(runnerId: Self.runnerId)) ?? [] {
            guard let thread = item.threadId else { continue }
            do {
                let conversation = try await ThreadConversation.recent(thread, since: item.requestedAt.addingTimeInterval(-60), bridge: bridge)
                if conversation.containsDelivery(item.id) {
                    try store.acknowledgeDispatch(item.id, runnerId: Self.runnerId, threadId: thread, status: conversation.settledStatus ?? "active")
                    missingQueueSince[item.id] = nil
                    lastWake[thread] = nil
                    if (try? store.task(item.taskId).displayTitle) == nil { Task { await self.nameNewChat(item.taskId, thread: thread) } }
                } else if try await CodexAppDelivery.queued(item, bridge: bridge) != nil {
                    missingQueueSince[item.id] = nil
                    await wakeQueuedChat(thread)
                } else {
                    let since = missingQueueSince[item.id] ?? Date()
                    missingQueueSince[item.id] = since
                    if Date().timeIntervalSince(since) >= 30 {
                        try store.deferDispatch(item.id, runnerId: Self.runnerId, reason: "The message left Codex's queue, but its delivery is not in the chat. Inspect the chat before sending again.", blocked: true)
                        missingQueueSince[item.id] = nil
                    }
                }
            } catch { log("Inspect Codex queue \(item.id): \(error.localizedDescription)") }
        }
    }

    // MARK: Following turns

    /// Connects, starts listening, and takes up the turns that were running when the last connection ended. Codex
    /// sends their open requests again.
    private func connect() async throws {
        listening?.cancel()
        await listening?.value
        following = []; releasing = []; releasesInFlight = [:]
        do { try await bridge.connectDaemon() }
        catch {
            guard let executable else { throw error }
            try await bridge.connect(executable: executable)
        }
        let messages = bridge.subscribe()
        listening = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await message in messages { await self?.handle(message) } }
                group.addTask { await self?.passAnswers() }
                group.addTask {
                    while !Task.isCancelled {
                        await self?.reconcileQueuedDeliveries()
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                await group.next(); group.cancelAll()
            }
        }
        for thread in try store.codexChatsToFollow(since: Date().addingTimeInterval(-12 * 3600)) where !following.contains(thread) {
            try await followIfActive(thread)
        }
    }

    func handle(_ message: BridgeMessage) async {
        if message.method == "facienda/disconnected" { following = []; releasing = []; return }
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
            await releaseUnlessFollowing(thread)
        default: break
        }
    }

    private func releaseUnlessFollowing(_ thread: String) async {
        guard !following.contains(thread) else { return }
        if let release = releasesInFlight[thread] { _ = try? await release.value; return }
        releasing.insert(thread)
        let bridge = bridge
        let release = Task { try await bridge.unsubscribe(thread) }
        releasesInFlight[thread] = release
        do { try await release.value; releasing.remove(thread) }
        catch { log("Release chat \(thread): \(error.localizedDescription)") }
        releasesInFlight[thread] = nil
    }

    /// Covers a missed completion and retries a failed unsubscribe without disturbing a running turn.
    func releaseFinishedChats() async {
        for thread in following {
            guard let state = try? await chatState(thread), state.status == .idle else { continue }
            following.remove(thread)
            try? store.closeCodexApprovals(threadId: thread)
            releasing.insert(thread)
        }
        for thread in releasing { await releaseUnlessFollowing(thread) }
    }

    func followIfActive(_ thread: String) async throws {
        guard let state = try await chatState(thread) else { return }
        guard state.status != .idle else {
            try? store.closeCodexApprovals(threadId: thread)
            return
        }
        following.insert(thread)
        do {
            if case .loaded(let resumed) = try await load(thread), resumed.status != .idle { return }
        } catch {
            following.remove(thread)
            await releaseUnlessFollowing(thread)
            throw error
        }
        following.remove(thread)
        await releaseUnlessFollowing(thread)
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
        // A previous completion may still be unsubscribing. Let it finish before subscribing for another turn.
        if let release = releasesInFlight[thread] { _ = try? await release.value }
        do {
            // Only the chat's state is needed; its whole history can be far larger than one message may be.
            let response = try await bridge.request("thread/resume", params: .object(["threadId": .string(thread), "excludeTurns": .bool(true)]), timeout: .seconds(60))
            return .loaded(Self.state(thread, response["thread"]))
        } catch BridgeError.server(let message) {
            return message.contains("active writer") ? .openInCodex : .missing
        }
    }

    /// A delivery interrupted between intent and acknowledgement. Its exact marker tells whether it arrived.
    private func recover(_ item: NativeDispatch) async throws {
        if let queueID = try await CodexAppDelivery.queued(item, bridge: bridge), let thread = item.threadId {
            try store.recordCodexQueue(item.id, runnerId: Self.runnerId, queuedSubmissionId: queueID)
            await wakeQueuedChat(thread)
            return
        }
        let found = try await DeliveryFinder.find(item, runnerThreadId: nil, bridge: bridge)
        if found.chats.count == 1 {
            let thread = found.chats[0].id
            let conversation = try await ThreadConversation.recent(thread, since: item.requestedAt.addingTimeInterval(-60), bridge: bridge)
            try store.acknowledgeDispatch(item.id, runnerId: Self.runnerId, threadId: thread, status: conversation.settledStatus ?? "active")
            // Only a daemon-owned turn needs this legacy subscription. Native turns read as notLoaded here.
            try await followIfActive(thread)
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
            if item.codexQueuePreparedAt != nil {
                let conversation = try await ThreadConversation.recent(thread, since: item.requestedAt.addingTimeInterval(-60), bridge: bridge)
                guard conversation.containsDelivery(item.id), conversation.settledStatus != nil else { continue }
            } else {
                let chat = try await chatState(thread)
                guard chat?.status == .idle || (chat == nil && store.isCheckCopy(item)) else { continue }
            }
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
