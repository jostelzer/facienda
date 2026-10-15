import Foundation
import FaciendaCore
import FaciendaBridge

extension AppModel {
    private static let headlineLuna = BackgroundModel()
    /// Its own process, so a name the user asks for never waits behind background headlines.
    private static let nameLuna = BackgroundModel()
    /// Reads a typed step and its time right away, never behind background headlines.
    private static let stepLuna = BackgroundModel()
    /// Finds the earlier task the top bar asks for while you wait, so it never queues behind anything else.
    private static let findLuna = BackgroundModel()
    private static var findWarming: Task<Void, Never>?
    /// Asks a fast model for a clearer name from the request, notes, recent chat and latest result, so the name follows
    /// where the task went rather than where it started. A manual rename meanwhile wins.
    func generateName(for task: FaciendaTask) {
        guard !demo, !namingTasks.contains(task.id) else { return }
        guard serviceModelReady else { error = "Connect \(ServiceModelChoice.current.provider.name) to name tasks automatically, or choose another model in Settings › Models."; return }
        namingTasks.insert(task.id)
        let executable = executable, luna = Self.nameLuna, before = task.displayName
        Task {
            defer { namingTasks.remove(task.id) }
            await loadConversation(for: task)
            let current = tasks.first { $0.id == task.id } ?? task
            let prompt = TaskNameWriter.prompt(for: current, latestResult: latestResults[task.id]?.excerpt, chat: await savedChatExcerpt(for: current, limit: 5000))
            do {
                try await luna.warm(executable: executable)
                let thread = try await luna.open(.name)
                defer { Task { await luna.close(thread) } }
                let name = try TaskNameWriter.read(try await luna.ask(thread, text: prompt, schema: TaskNameWriter.schema, effort: TaskNameWriter.reasoningEffort, timeout: .seconds(30)))
                refresh()
                guard tasks.first(where: { $0.id == task.id })?.displayName == before else { return }
                renameTask(task, name: name)
            } catch { self.error = "Couldn't name the task: " + error.localizedDescription }
        }
    }
    /// Splits "call the landlord tomorrow morning" into the step and its reminder time. Falls back to the text as typed.
    func readStep(_ text: String, for task: FaciendaTask) async -> (step: String, at: Date?) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo, serviceModelReady else { return (typed, nil) }
        let luna = Self.stepLuna, executable = executable
        do {
            try await luna.warm(executable: executable)
            let thread = try await luna.open(.ownStep)
            defer { Task { await luna.close(thread) } }
            let reply = try await luna.ask(thread, text: OwnStepReader.prompt(task: task.displayName, text: typed), schema: OwnStepReader.schema, effort: OwnStepReader.reasoningEffort, timeout: .seconds(20))
            return OwnStepReader.read(reply, typed: typed)
        } catch { return (typed, nil) }
    }

    /// Starts the finder while the text still reads like a lookup, so Return only waits for the answer.
    func warmFinder() {
        guard !demo, serviceModelReady, Self.findWarming == nil else { return }
        let luna = Self.findLuna, executable = executable
        Self.findWarming = Task { try? await luna.warm(executable: executable) }
    }

    /// Which earlier task the text means, judged by a fast model from the tasks matching its words and the most recent ones.
    /// Nil when the model cannot be asked or its reply cannot be used.
    func findEarlierTask(_ text: String) async -> TaskFinder.Answer? {
        guard !demo, serviceModelReady else { return nil }
        let matching = ((try? store.lookUpTasks(text, limit: 12)) ?? []).map(\.task)
        let recent = tasks.filter { $0.state != .dropped }.sorted { $0.updatedAt > $1.updatedAt }.prefix(40)
        var seen = Set<String>()
        let candidates = (matching + recent).filter { seen.insert($0.id).inserted }
        guard !candidates.isEmpty else { return nil }
        let luna = Self.findLuna, executable = executable
        await Self.findWarming?.value
        do {
            try await luna.warm(executable: executable)
            let thread = try await luna.open(.finder)
            defer { Task { await luna.close(thread) } }
            let reply = try await luna.ask(thread, text: TaskFinder.prompt(text: text, tasks: candidates), schema: TaskFinder.schema, effort: TaskFinder.reasoningEffort, timeout: .seconds(20))
            return TaskFinder.read(reply, tasks: candidates)
        } catch { return nil }
    }

    /// Writes missing headlines in the background with a fast model. The first sentence stands in meanwhile.
    /// Also prepares the wait composer's options once a chat's turn is done, so they are ready when it opens,
    /// and the recap a new row shows, freshest first.
    func writeHeadlines() {
        guard !demo, serviceModelReady, headlineTask == nil else { return }
        let recent = Date().addingTimeInterval(-3 * 86400)
        let open = Set(tasks.filter { $0.state.isOpen || ($0.state == .done && $0.updatedAt > recent) }.map(\.id))
        let parkable = Set(tasks.filter { task in
            task.state.isOpen && task.state != .running && wait(for: task) == nil && pendingDispatch(for: task.id) == nil
                && links(for: task.id).contains { $0.role == "work" }
        }.map(\.id))
        let needsHeadline = { (source: LatestResult) in self.headlines[source.taskId]?.eventId != source.eventId && !self.headlineAttempts.contains("h" + source.eventId) }
        let needsOptions = { (source: LatestResult) in
            parkable.contains(source.taskId) && self.waitOptions[source.taskId]?.eventId != source.eventId && !self.headlineAttempts.contains("o" + source.eventId)
        }
        // A finished result under review gets a ready continuation; a question already says what it needs.
        let reviewable = Set(tasks.filter { task in
            task.state == .needsMe && pendingDispatch(for: task.id) == nil && links(for: task.id).contains { $0.role == "work" }
        }.map(\.id))
        let needsSteps = { (source: LatestResult) in
            !source.isQuestion && reviewable.contains(source.taskId) && self.nextSteps[source.taskId]?.eventId != source.eventId && !self.headlineAttempts.contains("s" + source.eventId)
        }
        let due = latestResults.values.filter { open.contains($0.taskId) && (needsHeadline($0) || needsOptions($0) || needsSteps($0)) }
            .sorted { $0.at > $1.at }.prefix(6).map { (source: $0, headline: needsHeadline($0), options: needsOptions($0), steps: needsSteps($0)) }
        // A recap is written once work came back to a row and its chat has gone quiet, so it is ready while the row is new.
        // Work often comes back while the agent is still writing its last message, so a few tries follow it.
        let now = Date()
        let recapsDue = tasks.compactMap { task -> (id: String, key: String, at: Date)? in
            guard isUnread(task), let link = resultLink(for: task), ["idle", "notLoaded"].contains(link.lastKnownStatus),
                  let back = cameBack(task), (recaps[task.id]?.at ?? .distantPast) < back else { return nil }
            let key = task.id + back.timeIntervalSinceReferenceDate.description
            if let tried = recapTries[key], tried.count >= 4 || now.timeIntervalSince(tried.last) < 20 { return nil }
            return (task.id, key, back)
        }.sorted { $0.at > $1.at }.prefix(6)
        guard !due.isEmpty || !recapsDue.isEmpty else { return }
        for job in recapsDue { recapTries[job.key] = ((recapTries[job.key]?.count ?? 0) + 1, now) }
        for job in due {
            if job.headline { headlineAttempts.insert("h" + job.source.eventId) }
            if job.options { headlineAttempts.insert("o" + job.source.eventId) }
            if job.steps { headlineAttempts.insert("s" + job.source.eventId) }
        }
        let names = Dictionary(tasks.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let store = store, executable = executable, luna = Self.headlineLuna
        headlineTask = Task { [weak self] in
            defer { self?.headlineTask = nil; self?.refresh() }
            do { try await luna.warm(executable: executable) } catch { return }
            let tiers = (try? await luna.options().tiers) ?? []
            let tier = tiers.first { $0 == "priority" } ?? tiers.first { $0.localizedCaseInsensitiveContains("fast") }
            for job in recapsDue { await self?.prepareRecap(job.id, luna: luna, tier: tier) }
            for job in due {
                if job.steps { await self?.prepareNextSteps(job.source, luna: luna, tier: tier) }
                if job.options { await self?.prepareWaitOptions(job.source, luna: luna, tier: tier) }
                guard job.headline else { continue }
                let result = job.source
                guard let thread = try? await luna.open(.headline) else { return }
                let reply = try? await luna.ask(thread, text: HeadlineWriter.prompt(taskName: names[result.taskId] ?? "", result: result.excerpt, at: result.at, question: result.isQuestion),
                                                schema: HeadlineWriter.schema, effort: HeadlineWriter.reasoningEffort, serviceTier: tier, timeout: .seconds(30))
                var line = reply.flatMap { try? HeadlineWriter.read($0) }
                if let long = line, long.count > HeadlineWriter.targetLength,
                   let shorter = try? await luna.ask(thread, text: HeadlineWriter.shorten(long), schema: HeadlineWriter.schema, effort: HeadlineWriter.reasoningEffort, serviceTier: tier, timeout: .seconds(30)),
                   let retry = try? HeadlineWriter.read(shorter), retry.count < long.count { line = retry }
                await luna.close(thread)
                if let line { try? store.saveHeadline(taskId: result.taskId, eventId: result.eventId, text: line) }
            }
        }
    }

    /// Reads the task's newest finished turn for its recap: the path's next step, what is open now, the user's last words
    /// and the answer. Stored on top of the recap it follows, so the path keeps every earlier step.
    private func prepareRecap(_ taskID: String, luna: BackgroundModel, tier: String?) async {
        guard let task = tasks.first(where: { $0.id == taskID }), let link = resultLink(for: task) else { return }
        await loadConversation(for: task)
        let previous = recaps[taskID], previousTurn = previous?.turnId
        let store = store, dispatches = nativeDispatches, request = task.title, threadID = link.codexThreadId
        // Long chats run to many megabytes; reading one stays off the main thread.
        let source = await Task.detached(priority: .utility) {
            (try? store.conversationSnapshot(taskId: taskID, threadId: threadID))
                .flatMap { RecapSource($0.conversation, originalRequest: request, dispatches: dispatches, after: previousTurn) }
        }.value
        guard let source, source.turnId != previousTurn, let thread = try? await luna.open(.recap) else { return }
        let reply = try? await luna.ask(thread, text: RecapWriter.prompt(taskName: task.displayName, request: request, steps: previous?.steps ?? [], source: source),
                                        schema: RecapWriter.schema, effort: RecapWriter.reasoningEffort, serviceTier: tier, timeout: .seconds(40))
        await luna.close(thread)
        if let reply, let recap = try? RecapWriter.read(reply, taskId: taskID, taskName: task.displayName, source: source, previous: previous) {
            try? store.saveRecap(recap, after: previousTurn)
        }
    }

    /// Reads the task's chat and memory for the continuation offered when its row is clicked, stored against the result it follows.
    private func prepareNextSteps(_ source: LatestResult, luna: BackgroundModel, tier: String?) async {
        guard let task = tasks.first(where: { $0.id == source.taskId }) else { return }
        await loadConversation(for: task)
        let chat = await savedChatExcerpt(for: task, limit: 5000)
        let space = try? store.memorySpace(forTask: task.id)
        let notes = space.flatMap { try? store.memory(spaceID: $0.id) } ?? []
        var learned: JSONValue?
        if let space, memorySettings?.enabled == true {
            learned = try? await WorkspaceMemoryService(store: store).context(query: task.title + "\n" + source.excerpt.prefix(500), spaceID: space.id, taskID: task.id)["learned"]
        }
        guard let thread = try? await luna.open(.nextSteps) else { return }
        let reply = try? await luna.ask(thread, text: NextStepWriter.prompt(task: task, latestResult: source.excerpt, chat: chat, memory: NextStepWriter.memoryExcerpt(notes: notes, learned: learned)),
                                        schema: NextStepWriter.schema, effort: NextStepWriter.reasoningEffort, serviceTier: tier, timeout: .seconds(40))
        await luna.close(thread)
        if let reply { try? store.saveNextSteps(NextStepWriter.read(reply, taskId: task.id, eventId: source.eventId)) }
    }

    /// Reads the task's chat and asks for ready-made waits, stored against the source they came from.
    private func prepareWaitOptions(_ source: LatestResult, luna: BackgroundModel, tier: String?) async {
        guard let task = tasks.first(where: { $0.id == source.taskId }) else { return }
        await loadConversation(for: task)
        let chat = await savedChatExcerpt(for: task, latestResult: source.isQuestion ? nil : source.excerpt)
        let candidates = WaitCompiler.candidates(for: task, among: tasks)
        guard let thread = try? await luna.open(.wait) else { return }
        let reply = try? await luna.ask(thread, text: WaitCompiler.context(task: task, candidates: candidates, hasChat: true, chat: chat) + "\n\n" + WaitCompiler.suggestionRequest,
                                        schema: WaitCompiler.suggestionSchema, effort: WaitCompiler.reasoningEffort, serviceTier: tier, timeout: .seconds(40))
        await luna.close(thread)
        if let reply { try? store.saveWaitOptions(taskId: task.id, eventId: source.eventId, options: WaitCompiler.options(reply, candidates: candidates, hasChat: true)) }
    }

    /// The task's saved chat, cut down for a prompt. Read and cut off the main thread: long chats run to many megabytes.
    func savedChatExcerpt(for task: FaciendaTask, latestResult: String? = nil, limit: Int = 7000) async -> String {
        let store = store, link = resultLink(for: task), dispatches = nativeDispatches, taskID = task.id, request = task.title
        return await Task.detached(priority: .userInitiated) {
            let conversation = link.flatMap { try? store.conversationSnapshot(taskId: taskID, threadId: $0.codexThreadId) }?.conversation
            return WaitCompiler.chatExcerpt(conversation, originalRequest: request, dispatches: dispatches, latestResult: latestResult, limit: limit)
        }.value
    }
}
