import AppKit
import FaciendaCore
import FaciendaBridge

extension AppModel {
    /// The selected task's saved conversation. Read on first ask after each refresh: a snapshot can run to many
    /// megabytes, and decoding it on every refresh stalled the main thread while nothing on screen shows it.
    var conversation: CodexConversation? { selectedSnapshot?.conversation }
    var conversationFetchedAt: Date? { selectedSnapshot?.fetchedAt }
    private var selectedSnapshot: CodexConversationSnapshot? {
        guard let task = selectedTask, let link = resultLink(for: task) else { return nil }
        let key = task.id + "\n" + link.codexThreadId
        if let cached = snapshotCache, cached.key == key { return cached.snapshot }
        let snapshot = try? store.conversationSnapshot(taskId: task.id, threadId: link.codexThreadId)
        snapshotCache = (key, snapshot)
        return snapshot
    }
    func resultLink(for task: FaciendaTask) -> ThreadLink? {
        let taskLinks = links(for: task.id)
        return taskLinks.last(where: { $0.role == "work" }) ?? taskLinks.last(where: { $0.role == "review" })
    }
    func loadConversation(for task: FaciendaTask) async {
        guard !loadingResults.contains(task.id), let link = resultLink(for: task) else { return }
        if link.provider == .claude { await loadClaudeConversation(for: task, link: link); return }
        guard connected else { return }
        loadingResults.insert(task.id)
        defer { loadingResults.remove(task.id) }
        do {
            let fetchedAt = Date(), store = store, taskID = task.id, threadID = link.codexThreadId
            let response = try await bridge.readThread(threadID)
            try Task.checkCancellation()
            // Long chats run to many megabytes; reading and saving them stays off the main thread.
            try await Task.detached(priority: .userInitiated) {
                try store.saveConversation(taskId: taskID, conversation: ThreadConversation.read(response, threadId: threadID), fetchedAt: fetchedAt)
            }.value
            resultErrors[task.id] = nil
            refresh()
        } catch is CancellationError { }
        catch { resultErrors[task.id] = "Could not refresh the conversation. " + error.localizedDescription }
    }
    /// Keeps every open Claude task's conversation and status current. Unchanged transcripts are not read again.
    func refreshClaudeSessions() async {
        for task in tasks where task.state.isOpen {
            guard let link = resultLink(for: task), link.provider == .claude, !loadingResults.contains(task.id) else { continue }
            await loadClaudeConversation(for: task, link: link)
        }
    }
    /// Claude sessions are read straight from their transcript on this Mac, only when it changed.
    func loadClaudeConversation(for task: FaciendaTask, link: ThreadLink, force: Bool = false) async {
        guard let session = claudeSessions[link.threadId] ?? (try? store.claudeSession(link.threadId)), let cli = session.cliSessionId else {
            resultErrors[task.id] = "This Claude session hasn't reported where it keeps its transcript."
            return
        }
        loadingResults.insert(task.id)
        defer { loadingResults.remove(task.id) }
        let threadId = link.threadId, title = link.title, cwd = session.cwd, last = transcriptStamps[threadId]
        // The hook marks a turn running before it is written; one that never is, its prompt held back, is read again.
        let known = force || last?.running == false && link.lastKnownStatus == "active" ? nil : last?.modified
        do {
            let read = try await Task.detached(priority: .userInitiated) { () throws -> (CodexConversation, Date)? in
                guard let file = ClaudeTranscript.locate(cliSessionId: cli, cwd: cwd) else {
                    throw StoreError.invalid("Its transcript was not found on this Mac.")
                }
                let modified = (try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if let known, known >= modified { return nil }
                return (try ClaudeTranscript.read(file, threadId: threadId, fallbackTitle: title), modified)
            }.value
            resultErrors[task.id] = nil
            guard let (conversation, modified) = read else { return }
            let store = store, taskID = task.id
            try await Task.detached(priority: .userInitiated) { try store.saveConversation(taskId: taskID, conversation: conversation, fetchedAt: Date()) }.value
            // A session about to continue (its model is still being applied) is not finished.
            let settling = claudeSessions[threadId].map { !$0.isSettled } ?? false
            let running = settling || conversation.turns.last?.status == "inProgress"
            // A turn stopped at a permission prompt is still in progress; the hook's prompt holds until the session writes on.
            let prompt = links(for: task.id).first { $0.threadId == threadId && $0.lastKnownStatus == "waitingOnApproval" }
            let held = running && prompt.map { modified <= ($0.lastActivityAt ?? .distantPast).addingTimeInterval(3) } == true
            if !held {
                try store.observe(threadId: threadId, status: running ? "active" : "idle", source: .app, verified: true,
                                  title: conversation.title == title || conversation.title == "Claude session" ? nil : conversation.title)
            }
            transcriptStamps[threadId] = (modified, running)
            refresh()
        } catch { resultErrors[task.id] = "Could not read the Claude conversation. " + error.localizedDescription }
    }
    /// Spawns a task that tracks a Codex chat. A chat known only by its link takes its title and folder from Codex.
    @discardableResult func importThread(_ thread: CodexThread, groupID: String? = nil, reveal: Bool = true) async -> Bool {
        guard connected else { error = "Connect Codex in Settings to add a chat as a task."; return false }
        guard importingThreadID == nil else { return false }
        importingThreadID = thread.id
        defer { importingThreadID = nil }
        do {
            let response = try await bridge.readThread(thread.id)
            // A long chat's history may come back without its first turns; Codex's preview still holds the request.
            let preview = response["thread"]["preview"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            guard response["thread"]["id"].string == thread.id,
                  let request = AgentReply.originalRequest(in: response) ?? preview else { throw StoreError.invalid("Could not read this chat's original request. Nothing was imported.") }
            let read = response["thread"], name = read["name"].string ?? ""
            let title = !thread.title.isEmpty ? thread.title : !name.isEmpty ? name : String((read["preview"].string ?? "").prefix(90))
            let task = try store.importThread(originalRequest: request, title: title, cwd: thread.cwd.isEmpty ? read["cwd"].string ?? "" : thread.cwd,
                conversation: ThreadConversation.read(response, threadId: thread.id))
            if let groupID { try store.assignGroup(taskId: task.id, groupId: groupID == Self.unsortedGroup ? nil : groupID) }
            refresh()
            if reveal { showTask(task) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func pollThreads(loadMore: Bool = false) async {
        guard connected else { return }
        do {
            let page = try await bridge.listThreads(cursor: loadMore ? nextCursor : nil)
            if loadMore { let ids = Set(threads.map(\.id)); threads += page.data.filter { !ids.contains($0.id) } }
            else { threads = page.data }
            nextCursor = page.nextCursor
            // One write per chat, which may wait on a helper's write; kept off the main thread.
            let store = store, listed = page.data
            try await Task.detached(priority: .utility) {
                for thread in listed {
                    try store.observe(threadId: thread.id, status: thread.statusLabel, source: .app, verified: false, title: thread.title, preview: thread.preview)
                }
            }.value
            await followThreadsElsewhere(page.data)
            refresh()
            if let task = selectedTask, destination != .inbox {
                await loadConversation(for: task)
            }
        } catch { self.error = error.localizedDescription }
    }
    /// A chat continued in the Codex app is only `notLoaded` here, and hooks may not run, so its turns never reach
    /// the task. A running task is checked once its chat stops changing for a poll; any other open task as soon as
    /// its chat moves, once per burst of activity. Every workspace's tasks are checked, not only the one on screen.
    private func followThreadsElsewhere(_ listed: [CodexThread]) async {
        for thread in listed {
            let previous = threadStamps[thread.id]
            threadStamps[thread.id] = thread.updatedAt
            let moving = previous != thread.updatedAt
            if !moving { quietlyHeldThreads.remove(thread.id) }
            guard previous != nil, let task = try? store.currentTask(threadId: thread.id), task.state.isOpen else { continue }
            if task.state == .running {
                guard !moving, settledThreadStamps[thread.id] != thread.updatedAt else { continue }
            } else {
                guard moving, quietlyHeldThreads.insert(thread.id).inserted else { continue }
            }
            settledThreadStamps[thread.id] = thread.updatedAt
            do {
                let fetchedAt = Date(), store = store, threadID = thread.id
                let response = try await bridge.readThread(threadID)
                let status = try await Task.detached(priority: .utility) {
                    let conversation = try ThreadConversation.read(response, threadId: threadID)
                    try store.saveConversation(taskId: task.id, conversation: conversation, fetchedAt: fetchedAt)
                    return conversation.observedStatus(for: task)
                }.value
                if let status {
                    try store.observe(threadId: thread.id, status: status, source: .app, verified: true)
                }
            } catch { resultErrors[task.id] = "Could not check this task's Codex chat. " + error.localizedDescription }
        }
    }
    /// Opens a chat in the app that holds it: a Claude session in Claude, anything else in Codex.
    func openThread(_ id: String) {
        if provider(ofThread: id) == .claude {
            guard let url = FaciendaStore.claudeSessionURL(id) else { return }
            _ = openURL(url)
            return
        }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "codex://threads/\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
    func provider(ofThread id: String) -> AgentProvider {
        if let link = links.first(where: { $0.threadId == id }) { return link.provider }
        return id.hasPrefix("local_") || id == claudeRunner?.sessionId || claudeSessions[id] != nil ? .claude : .codex
    }
    /// The app a task's work lives in: its chat's, else the model it was started with.
    func agent(for task: FaciendaTask) -> AgentProvider {
        (resultLink(for: task) ?? links(for: task.id).last)?.provider ?? task.provider
    }
    func copyResume(_ id: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("codex resume \(ConnectionInstaller.shellQuote(id))", forType: .string)
        notice = "Resume command copied."
    }
    func link(_ thread: CodexThread, taskID: String) {
        perform { try store.link(ThreadLink(taskId: taskID, codexThreadId: thread.id, title: thread.title, preview: thread.preview)); refresh() }
    }
    /// The task continues in this chat, which replaces the one it had.
    @discardableResult func handOver(_ chat: ChatCandidate, taskID: String) -> Bool {
        do { try store.handOver(taskId: taskID, to: chat) } catch { self.error = error.localizedDescription; return false }
        refresh()
        renameAfterHandover(taskID)
        return true
    }
    /// Chats the task's request or latest answer links to, which the task could continue in instead of its own:
    /// never its own chat, a runner's, another task's, or a Claude session the app no longer has. Once the task moved to
    /// a chat, none: picking one of two found chats ends the offer, and switching again is the ⋯ menu's.
    func linkedChats(for task: FaciendaTask) -> [ChatCandidate] {
        guard task.state.isOpen, !handedOver.contains(task.id) else { return [] }
        let result = latestResults[task.id]
        let key = task.title + "\n" + (result?.eventId ?? "")
        let found: [ChatLinks.Found]
        if let cached = linkedChatsCache[task.id], cached.key == key { found = cached.chats }
        else {
            found = ChatLinks.find(in: task.title + "\n" + (result.map { $0.isQuestion ? "" : $0.excerpt } ?? ""))
            linkedChatsCache[task.id] = (key, found)
        }
        let own = Set(links(for: task.id).filter { $0.role == "work" }.map(\.threadId))
        let runners = Set([claudeRunner?.sessionId, nativeRunner?.threadId].compactMap { $0 })
        return found.prefix(3).compactMap { chat in
            guard !own.contains(chat.threadId), !runners.contains(chat.threadId),
                  links.first(where: { $0.threadId == chat.threadId }).map({ $0.taskId == task.id }) ?? true else { return nil }
            if chat.provider == .claude {
                if claudeSessionLookups[chat.threadId] == nil { claudeSessionLookups[chat.threadId] = .some(ClaudeDesktop.session(id: chat.threadId)) }
                guard let session = claudeSessionLookups[chat.threadId] ?? nil, !session.archived else { return nil }
                return session.chat
            }
            let title = linkedChatTitles[chat.threadId] ?? threads.first { $0.id == chat.threadId }?.title ?? ""
            return ChatCandidate(threadId: chat.threadId, provider: .codex, title: title)
        }
    }
    /// Asks Codex for the titles of linked chats Facienda hasn't seen, without reading their turns.
    func lookUpLinkedChatTitles(for task: FaciendaTask) async {
        guard connected, !demo else { return }
        for chat in linkedChats(for: task) where chat.provider == .codex && chat.title.isEmpty && linkedChatTitles[chat.threadId] == nil {
            guard let read = try? await bridge.request("thread/read", params: .object(["threadId": .string(chat.threadId), "includeTurns": .bool(false)])) else { continue }
            let name = read["thread"]["name"].string ?? ""
            linkedChatTitles[chat.threadId] = name.isEmpty ? String((read["thread"]["preview"].string ?? "").prefix(90)) : name
        }
    }
    /// A task that moved to another chat gets a fresh name, written from its request and the chat it now holds.
    private func renameAfterHandover(_ taskID: String) {
        guard let task = tasksByID[taskID] else { return }
        if serviceModelReady { generateName(for: task) } else { Task { await loadConversation(for: task) } }
    }
    /// The Claude app's sessions, newest first, without the runner's and archived ones. Read off the main thread.
    func claudeAppSessions() async -> [ClaudeDesktop.Session] {
        let runner = claudeRunner?.sessionId
        return await Task.detached(priority: .userInitiated) {
            ClaudeDesktop.sessions().filter { !$0.archived && $0.id != runner }
        }.value
    }
    /// Spawns a task that tracks a session of the Claude app, known by its `local_…` ID.
    @discardableResult func importClaudeSession(_ id: String, groupID: String? = nil, reveal: Bool = true) async -> Bool {
        guard importingThreadID == nil else { return false }
        importingThreadID = id
        defer { importingThreadID = nil }
        do {
            guard let session = await Task.detached(operation: { ClaudeDesktop.session(id: id) }).value else {
                throw StoreError.invalid("The Claude app has no session \(id) on this Mac.")
            }
            let store = store
            let task = try await Task.detached(priority: .userInitiated) { try store.importClaudeSession(session) }.value
            if let groupID { try store.assignGroup(taskId: task.id, groupId: groupID == Self.unsortedGroup ? nil : groupID) }
            refresh()
            if reveal { showTask(task) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
