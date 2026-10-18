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
    private static let readerLuna = BackgroundModel()
    private static var readerWarming: Task<Void, Never>?
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
    /// Names a group made on the board's + without a name, from its first task, as the user's other groups are named.
    /// It keeps its stand-in name if no model can be asked, and a name the user typed meanwhile wins.
    func nameGroup(_ group: TaskGroup, from task: String) {
        guard !demo, serviceModelReady, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let executable = executable, luna = Self.nameLuna, before = group.name
        let prompt = GroupNameWriter.prompt(task: task, groups: groups.map(\.name).filter { $0 != before })
        Task {
            do {
                try await luna.warm(executable: executable)
                let thread = try await luna.open(.groupName)
                defer { Task { await luna.close(thread) } }
                let name = try GroupNameWriter.read(try await luna.ask(thread, text: prompt, schema: GroupNameWriter.schema, effort: GroupNameWriter.reasoningEffort, timeout: .seconds(30)))
                guard let current = groups.first(where: { $0.id == group.id }), current.name == before else { return }
                renameGroup(current, name: name)
            } catch {}
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
        // The task asked for may live in any workspace.
        let matching = ((try? store.library.lookUpTasks(text, limit: 12)) ?? []).map(\.task)
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

    /// Starts the reading model before the first pause in typing, so the first reading comes back sooner.
    func warmReader() {
        guard !demo, serviceModelReady, Self.readerWarming == nil else { return }
        let luna = Self.readerLuna, executable = executable
        Self.readerWarming = Task { try? await luna.warm(executable: executable) }
    }

    /// What the top bar's text asks for, read by a fast model against the tasks it could be about: those matching its
    /// words, those that asked something, those parked, and the most recent, with the workspace's notes that match.
    /// New work is also given its place: the workspace and group across the library it belongs in, learning from where
    /// the person put earlier work. Nil when there is nothing to read against, the model cannot be asked, or its reply
    /// cannot be used: Return then starts the text as a task here, as it always did.
    func readBar(_ text: String) async -> BarReader.Reading? {
        let candidates = barCandidates(for: text)
        let words = Set(TaskLookup.terms(text))
        let notes = Array(memories.filter { fact in
            fact.supersededBy == nil && !words.isDisjoint(with: TaskLookup.terms(fact.text))
        }.prefix(8))
        let places = barPlaces(matching: text)
        guard !candidates.isEmpty || !notes.isEmpty || places.count > 1 else { return nil }
        if demo { return DemoReader.read(text, candidates: candidates, notes: notes, places: places, here: workspaceID).map { Self.keepNamed($0, text, places) } }
        guard serviceModelReady else { return nil }
        let luna = Self.readerLuna, executable = executable
        await Self.readerWarming?.value
        do {
            try await luna.warm(executable: executable)
            let thread = try await luna.open(.reader)
            defer { Task { await luna.close(thread) } }
            let moved = (try? store.routeCorrections()) ?? []
            let prompt = BarReader.prompt(text: text, candidates: candidates, notes: notes, places: places, here: workspaceID, moved: moved)
            let reply = try await luna.ask(thread, text: prompt, schema: BarReader.schema, effort: BarReader.reasoningEffort, timeout: .seconds(20))
            return BarReader.read(reply, candidates: candidates, notes: notes, places: places, here: workspaceID).map { Self.keepNamed($0, text, places) }
        } catch { return nil }
    }

    /// A workspace named in the text decides where new work goes, whatever the reader made of the rest: a place it chose
    /// there stands, and otherwise the work goes to that workspace without a group.
    static func keepNamed(_ reading: BarReader.Reading, _ text: String, _ places: [BarPlace]) -> BarReader.Reading {
        guard reading.kind == .new, let named = FaciendaStore.namedWorkspace(in: text, among: places) else { return reading }
        var kept = reading
        if reading.place?.workspaceID != named { kept.place = places.first { $0.workspaceID == named && $0.groupID == nil } }
        kept.sure = true; kept.alternative = nil
        return kept
    }

    /// Every place new work could go, across the library. One place means there is nothing to choose.
    func barPlaces(matching text: String = "") -> [BarPlace] { (try? store.library.barPlaces(matching: text)) ?? [] }

    /// Keeps where the person put a task made in the bar, so the reader puts similar work there next time.
    func learnPlace(of taskID: String, workspaceID: String, groupID: String?) {
        guard let text = try? store.barText(forTask: taskID) else { return }
        try? store.recordRouteCorrection(text: text, workspaceID: workspaceID, groupID: groupID)
    }

    /// The tasks a line in the bar could be about, at most 24: matching its words first, then those that asked something,
    /// then parked ones, then the most recent. Each with its group, how the board describes it, its open question and the
    /// start of its latest result.
    func barCandidates(for text: String) -> [BarReader.Candidate] {
        let matching = ((try? store.lookUpTasks(text, limit: 8)) ?? []).map(\.task)
        let open = tasks.filter { $0.state.isOpen }
        let asking = open.filter { pendingQuestion(for: $0) != nil }
        let parked = open.filter { $0.state == .waiting || $0.state == .scheduled }
        let recent = open.sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        let picked = (matching + asking + parked + recent).filter { seen.insert($0.id).inserted }.prefix(24)
        return picked.map { task in
            let group = groupMembers[task.id].flatMap { id in groups.first { $0.id == id }?.name }
            // The result itself, not its headline: questions about a task are answered from what it found.
            let latest = latestResults[task.id]?.excerpt.replacingOccurrences(of: "\n", with: " ") ?? ""
            return BarReader.Candidate(task: task, group: group, status: task.state.isOpen ? taskStatus(task) : "Done",
                                       question: pendingQuestion(for: task), latest: String(latest.prefix(300)))
        }
    }

    /// The question a task is waiting on you to answer, if it asked one the bar may answer. Permission to act is never
    /// given from the bar: that stays a deliberate click on the task.
    func pendingQuestion(for task: FaciendaTask) -> Decision? {
        decisions(for: task.id).last { $0.state == "pending" && ($0.kind == "decision" || $0.kind == "completion") }
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
        var memory = NextStepWriter.memoryExcerpt(notes: notes)
        if let space, memorySettings?.enabled == true {
            let question = "What understanding of this workspace's subjects, processes and user preferences should guide the next move? Task: " + String(task.title.prefix(1000)) + "\nLatest result (context, not user evidence): " + String(source.excerpt.prefix(2000))
            if let context = try? await WorkspaceMemoryService(store: store).context(query: question, spaceID: space.id, taskID: task.id) {
                memory += "\nCURRENT MEMORY (inferences are advisory):\n" + String(context.json.prefix(9000))
            }
            if let reflection = try? await MemoryReflector(store: store, inference: memoryLuna).reflect(question, spaceID: space.id, rounds: 3, priority: .background) {
                memory += "\n" + String(reflection.context.prefix(7000))
            }
        }
        guard let thread = try? await luna.open(.nextSteps) else { return }
        let reply = try? await luna.ask(thread, text: NextStepWriter.prompt(task: task, latestResult: source.excerpt, chat: chat, memory: memory),
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
