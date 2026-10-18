import OSLog
import SwiftUI
import FaciendaCore
import FaciendaBridge

/// One input for starting tasks, finding tasks, chats and notes, and running commands. A question is a task too:
/// its chat researches memory, tasks and chats and answers it.
/// Enter starts a task unless you moved to a result, so a result that arrives late never takes over Enter.
/// The exception is asking for an earlier task, as in "where was the omnibar task": the best match found as you type is picked
/// for you, and otherwise Enter asks a fast model which task you mean and offers that one, for one more Enter to bring it back.
@MainActor @Observable final class OmnibarModel {
    static let startID = "start"

    let model: AppModel
    @ObservationIgnored weak var workspaces: WorkspaceController?
    var query = ""
    var dismissed = false
    var sections: [OmnibarSection] = []
    var highlighted = OmnibarModel.startID
    /// The chat the next task continues from.
    var followUp: ChatResult?
    /// A chat waiting for you to spawn a task from it or attach it to one.
    var chosenChat: ChatResult?
    /// A short confirmation shown in the bar, such as "Remembered".
    var confirmation: String?
    /// Enter is finding the earlier task the text asks for.
    var finding = false
    /// A task the finder was not sure about, waiting for Enter to bring it back, with what else was asked and the text it was found for.
    var offered: (task: FaciendaTask, message: String, text: String)?
    /// The text is longer than the widest bar and wraps. That is a task or a question, not a search.
    var wraps = false
    /// Files, images and media pasted, dropped or picked into the bar. They go with the next task.
    /// A pasted picture's temporary copy is deleted once nothing holds it: the task copied it, or the draft was cleared.
    var attachments: [URL] = [] {
        didSet {
            let kept = Set(attachments + parked.attachments + drafts.values.flatMap(\.attachments) + launching)
            Self.discardPasted(oldValue.filter { !kept.contains($0) })
        }
    }
    private var submitting = false
    /// Files going with tasks that left the bar and are still being placed or made.
    @ObservationIgnored private var launching: [URL] = []
    /// The reading of a text the model is working on, shared by the bar's reading and a task waiting for its place.
    @ObservationIgnored private var inFlight: (text: String, task: Task<BarReader.Reading?, Never>)?
    @ObservationIgnored private var chats: [ChatResult] = []
    @ObservationIgnored private var chatsQuery = ""
    /// The task picked for you because the text asks for an earlier one. Moving away from it keeps your choice.
    @ObservationIgnored private var autoPick: String?
    let dictation = Dictation()
    /// What was in the bar when dictation began, and the text dictation last put there.
    @ObservationIgnored private var dictationBase = ""
    @ObservationIgnored private var dictated = ""
    /// Everything dictation has put in the bar this time, so the field handing an older one back is not mistaken for typing.
    @ObservationIgnored private var placedBefore: Set<String> = []

    init(model: AppModel, workspaces: WorkspaceController? = nil) {
        self.model = model; self.workspaces = workspaces
        dictation.onText = { [weak self] in self?.place($0) }
        Self.discardStalePasted()
    }

    /// The name typed on the new group's sheet. Left empty, Facienda names the group from its first task.
    var newGroupName = ""
    /// The group the new group's sheet already made, so trying again after a failed start never makes a second one.
    @ObservationIgnored private var madeGroup: String?

    /// A group's sheet is only for writing a task in that group. Its text is its own: the bar keeps showing what was
    /// typed there, and nothing in the sheet is read, searched or found.
    var sheetText = ""
    /// The text being worked on: the sheet's while one is up, otherwise the bar's.
    var text: String {
        get { model.spotlitGroup != nil ? sheetText : query }
        set { if model.spotlitGroup != nil { sheetText = newValue } else { query = newValue } }
    }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// An open task whose name is the text, nearly word for word. Return opens it rather than making a second one.
    private(set) var duplicate: String?
    /// That task, while the bar holds nothing that changes what Return does with it.
    var typedAgain: FaciendaTask? {
        guard let duplicate, followUp == nil, attachments.isEmpty else { return nil }
        return model.tasksByID[duplicate] ?? lastHits.first { $0.task.id == duplicate }?.task
    }
    /// A task that lives in another workspace than the open one.
    func isElsewhere(_ task: FaciendaTask) -> Bool { task.workspaceId != nil && task.workspaceId != model.workspaceID }
    /// A task's name, with its workspace when that is not the open one.
    func name(_ task: FaciendaTask) -> String {
        guard isElsewhere(task), let place = taskPlaces[task.id] else { return task.displayName }
        return task.displayName + " · " + place.label
    }

    /// What the reading model made of a text, and when it came back. It counts only while the bar still holds that text.
    private(set) var modelRead: (text: String, reading: BarReader.Reading, at: Date)?
    /// The text the model is reading now, or will once typing pauses.
    private(set) var readingText: String?
    /// Return is waiting for the model's reading before it does anything.
    private(set) var awaitingRead = false
    /// The model is reading the text right now.
    private(set) var readingNow = false
    /// Bumped when Return is held because a reading only just appeared, so the reading line can show itself.
    private(set) var readingNudge = 0
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var lastHits: [TaskHit] = []
    /// Where each task found lives, such as "Facienda · facienda coding".
    private(set) var taskPlaces: [String: BarPlace] = [:]
    /// The answer or option the model's reading picked for Return.
    @ObservationIgnored private var modelPick: String?
    /// A reading the model made only now may not have been seen: Return waits this long before acting on one.
    static let readingSettle: TimeInterval = 0.8

    /// The model's reading of the text in the bar, when it has one beyond starting new work.
    var modelReading: BarReader.Reading? {
        guard let modelRead, modelRead.text == trimmed, modelRead.reading.kind != .new else { return nil }
        return modelRead.reading
    }
    /// The text could be about several tasks; the results ask which.
    var asking: BarReader.Reading? { modelReading.flatMap { $0.kind == .unclear ? $0 : nil } }
    /// Where the reader put the text as new work, while the bar still holds that text.
    var route: BarReader.Reading? {
        guard let modelRead, modelRead.text == trimmed, modelRead.reading.kind == .new,
              modelRead.reading.place != nil || !modelRead.reading.sure else { return nil }
        return modelRead.reading
    }
    /// New work has more than one place to go, so every request is read for where it belongs.
    var routes: Bool { (workspaces?.workspaces.count ?? 1) > 1 || !model.groups.isEmpty }
    static let placePrefix = "place:"

    /// What Return will do, when that is anything but starting the text as a new task. It follows the highlighted
    /// result while they show, so moving through them reads out each one's action. A group's sheet speaks for itself.
    var reading: BarReading? {
        let text = trimmed
        guard !text.isEmpty, model.spotlitGroup == nil, !finding else { return nil }
        let reading: BarReading
        if let offered, offered.text == text { reading = .task(offered.task, message: offered.message) }
        else if isOpen, let item = items.first(where: { $0.id == highlighted }) { reading = self.reading(of: item, text) }
        else { reading = defaultReading }
        return reading.isWorthShowing ? reading : nil
    }

    private func reading(of item: OmnibarItem, _ text: String) -> BarReading {
        switch item.kind {
        case .start: return defaultReading
        case let .remember(note): return BarReading(.remember, target: note)
        case let .command(command): return BarReading(.command, target: command.title)
        case let .task(task):
            if item.id.hasPrefix(Self.askPrefix), let asking, let chosen = BarReading(asking.choosing(task)) { return chosen }
            if task.id == duplicate { return BarReading(.already, target: name(task), taskID: task.id) }
            let said = BarReading.task(task, message: offered?.task.id == task.id ? offered?.message ?? "" : "")
            return BarReading(said.verb, target: name(task), taskID: said.taskID, message: said.message)
        case let .chat(chat): return BarReading(.chat, target: chat.title.isEmpty ? "Untitled chat" : chat.title)
        case .note: return BarReading(.note)
        case .answer: return BarReading(.answered, read: true)
        case let .place(place): return .start(at: place)
        }
    }

    /// Return with nothing picked, which is also what the first result does: a pasted chat link is added as a task, an
    /// open task typed again is opened, "remember …" is remembered, what the model read is done, a request for an
    /// earlier task is looked up first, and anything else starts as a new task. ⌘↵ always starts a new task.
    var defaultReading: BarReading {
        let text = trimmed
        if Self.codexThreadID(text) != nil || ClaudeDesktop.sessionID(inLink: text) != nil { return BarReading(.trackChat) }
        if let task = typedAgain { return BarReading(.already, target: name(task), taskID: task.id) }
        if followUp == nil, attachments.isEmpty, let note = Self.rememberText(text) { return BarReading(.remember, target: note) }
        if let read = modelReading, let said = BarReading(read) { return said }
        if followUp == nil, attachments.isEmpty, TaskLookup.asksForEarlier(text) { return BarReading(.find) }
        if let route { return .start(route) }
        return BarReading(.start)
    }
    static let askPrefix = "ask:"
    static let sourcePrefix = "source:"
    /// While a group is lit, typing writes its next task: no results hang over the lit card.
    var isOpen: Bool { !dismissed && !trimmed.isEmpty && model.spotlitGroup == nil }
    var items: [OmnibarItem] { sections.flatMap(\.items) }
    /// A demo snapshot draws Start as it looks with text in the field.
    var canStart: Bool { !trimmed.isEmpty && (!model.demo || CommandLine.arguments.contains("--snapshot")) && !model.dispatching && !model.capturing && !submitting }
    /// A group's sheet can keep the task in the group's plan instead. Unsorted has no plan, and a plan line holds text only.
    var canPlan: Bool {
        !trimmed.isEmpty && !model.demo && !submitting && attachments.isEmpty && followUp == nil
            && (model.groups.contains { $0.id == model.spotlitGroup } || model.spotlitGroup == AppModel.newGroupSheet)
    }
    /// The new group's sheet with a name and no task: Start just makes the group.
    var makesGroupOnly: Bool { model.spotlitGroup == AppModel.newGroupSheet && trimmed.isEmpty && attachments.isEmpty }
    var canMakeGroup: Bool { makesGroupOnly && !newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.demo && !submitting }

    // MARK: Results

    /// Recomputes results for the current text. Local results are immediate; chats follow after a short pause.
    func refresh() async {
        let text = trimmed
        guard !text.isEmpty else {
            sections = []; chats = []; chatsQuery = ""; highlighted = Self.startID; autoPick = nil; duplicate = nil
            model.search = ""; stopReading()
            return
        }
        if offered?.text != text { offered = nil }
        if TaskLookup.asksForEarlier(text) { model.warmFinder() }
        // Narrowing the board could hide the lit card the task is written for.
        guard model.spotlitGroup == nil else { sections = []; model.search = ""; return }
        // Every workspace's tasks are found, by their words, as you type.
        let hits = wraps ? [] : ((try? model.store.library.lookUpTasks(text, limit: 8)) ?? [])
        lastHits = hits
        let shown = hits.map(\.task.id) + (offered.map { [$0.task.id] } ?? [])
        taskPlaces = (try? model.store.library.taskPlaces(ofTasks: shown)) ?? [:]
        let here = hits.filter { !isElsewhere($0.task) }
        filterBoard(text, matched: here.contains(where: \.complete))
        scheduleRead(text, matched: !here.isEmpty)
        // Refining a search keeps the chats already shown until fresher ones arrive.
        if !text.hasPrefix(chatsQuery) || chatsQuery.isEmpty { chats = [] }
        rebuild(text, hits: hits, picking: true)
        guard !wraps else { return }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let found = await chatResults(text)
        guard !Task.isCancelled, trimmed == text else { return }
        chats = found; chatsQuery = text
        rebuild(text, hits: hits, picking: false)
    }

    /// The board narrows while you type, but only when something matches,
    /// so typing a new request never empties the screen.
    private func filterBoard(_ text: String, matched: Bool) {
        let search = model.destination == .dashboard && matched ? text : ""
        if model.search != search { model.search = search }
    }

    /// `picking` is set only for the results found as you type, never for chats arriving later.
    private func rebuild(_ text: String, hits: [TaskHit], picking: Bool) {
        // With files or a chat to continue from, the text is a new request, not the old task's name. Text long
        // enough to wrap finds no tasks, so it is never one either.
        let same = attachments.isEmpty && followUp == nil ? BarReading.sameTask(as: text, among: hits.map(\.task)) : nil
        if duplicate != same?.id { duplicate = same?.id }
        let actions = [OmnibarItem(id: Self.startID, kind: .start)]
        guard !wraps else {
            sections = [OmnibarSection(id: "actions", title: nil, items: actions)]
            if !items.contains(where: { $0.id == highlighted }) { highlighted = Self.startID }
            return
        }
        var result = [OmnibarSection(id: "actions", title: nil, items: actions + commands(matching: text).map { OmnibarItem(id: "command:" + $0.rawValue, kind: .command($0)) })]
        // What the model read comes first: its answer with what it came from, or the tasks it could mean.
        var shown = Set<String>()
        if let read = modelReading {
            if read.kind == .question {
                result.insert(OmnibarSection(id: "answer", title: nil, items: [OmnibarItem(id: "answer", kind: .answer(read))]), at: 0)
                if !read.sources.isEmpty {
                    result.insert(OmnibarSection(id: "sources", title: "From", items: read.sources.map { OmnibarItem(id: Self.sourcePrefix + $0.id, kind: .task($0)) }), at: 1)
                }
                shown.formUnion(read.sources.map(\.id))
            } else if read.kind == .unclear {
                result.insert(OmnibarSection(id: "ask", title: BarReading.question(for: read), items: read.options.map { OmnibarItem(id: Self.askPrefix + $0.id, kind: .task($0)) }), at: 0)
                shown.formUnion(read.options.map(\.id))
            }
        }
        // Not sure where new work goes: the places it could, best first, and here without a group. Starting is one
        // of them, so the plain start row steps aside.
        if let route, let place = route.place, let other = route.alternative {
            var places = [place, other]
            if let home = model.barPlaces().first(where: { $0.workspaceID == model.workspaceID && $0.groupID == nil }), !places.contains(home) { places.append(home) }
            result[0].items.removeAll { $0.id == Self.startID }
            if result[0].items.isEmpty { result.removeFirst() }
            result.insert(OmnibarSection(id: "place", title: "Where does it go?",
                                         items: places.map { OmnibarItem(id: Self.placePrefix + $0.workspaceID + "/" + ($0.groupID ?? ""), kind: .place($0)) }), at: 0)
        }
        // A chat that belongs to a task is found as that task, which opens straight away.
        var tasks = hits.map(\.task).filter { !shown.contains($0.id) }
        if let offered, !tasks.contains(where: { $0.id == offered.task.id }) { tasks.insert(offered.task, at: 0) }
        var chatItems: [OmnibarItem] = []
        for chat in chats {
            guard let task = linkedTask(chat.threadId) else { chatItems.append(OmnibarItem(id: "chat:" + chat.threadId, kind: .chat(chat))); continue }
            if !tasks.contains(where: { $0.id == task.id }) { tasks.append(task) }
        }
        if !tasks.isEmpty {
            result.append(OmnibarSection(id: "tasks", title: "Existing tasks", items: tasks.map { OmnibarItem(id: "task:" + $0.id, kind: .task($0)) }))
        }
        let footnote = chatFootnote
        if !chatItems.isEmpty || footnote != nil {
            let claude = chats.contains { $0.provider == .claude }
            result.append(OmnibarSection(id: "chats", title: claude ? "Chats" : "Codex chats", items: chatItems, footnote: footnote))
        }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        let notes = model.memories.filter { fact in
            fact.supersededBy == nil && words.allSatisfy { fact.text.lowercased().contains($0) }
        }.prefix(3)
        if !notes.isEmpty {
            result.append(OmnibarSection(id: "notes", title: "Memory", items: notes.map { OmnibarItem(id: "note:" + $0.id, kind: .note($0)) }))
        }
        sections = result
        if picking {
            // A task typed again is picked, as an earlier one asked for by name is, so Return opens it.
            let pick = same.map { "task:" + $0.id } ?? (TaskLookup.looksBack(text) ? hits.first.flatMap { $0.complete ? "task:" + $0.task.id : nil } : nil)
            if let pick, highlighted == Self.startID || highlighted == autoPick, modelReading?.kind != .question, asking == nil { highlighted = pick }
            else if pick == nil, highlighted == autoPick { highlighted = Self.startID }
            autoPick = pick
        }
        // A fresh answer or question takes Return, as the first row would, until you move to something else.
        let modelFirst = result.first.flatMap { ["answer", "ask"].contains($0.id) ? $0.items.first?.id : nil }
        if let modelFirst, highlighted == Self.startID || highlighted == modelPick { highlighted = modelFirst }
        else if modelFirst == nil, let modelPick, highlighted == modelPick { highlighted = Self.startID }
        modelPick = modelFirst
        if !items.contains(where: { $0.id == highlighted }) { highlighted = Self.startID }
    }

    private func linkedTask(_ threadId: String) -> FaciendaTask? {
        model.links.first { $0.codexThreadId == threadId }.flatMap { model.tasksByID[$0.taskId] }.flatMap { $0.state == .dropped ? nil : $0 }
    }

    private var chatFootnote: String? {
        if model.demo { return nil }
        if model.chatSearchEnabled == true {
            if let progress = model.chatIndexProgress, progress.building {
                return "Indexing \(progress.indexed) of \(max(progress.known, progress.indexed)) chats. Titles are searched in the meantime."
            }
            return nil
        }
        // Chat search is a setting, not something the bar asks about.
        return nil
    }

    private func chatResults(_ text: String) async -> [ChatResult] {
        // "where was the chat about the omnibar" searches for "omnibar".
        let text = TaskLookup.terms(text).joined(separator: " ")
        guard !text.isEmpty else { return [] }
        var results: [ChatResult] = []
        let scope = model.chatScope
        if let index = model.chatIndex {
            let hits = await Task.detached { (try? index.search(text, limit: 6, in: scope)) ?? [] }.value
            results = hits.map { ChatResult(threadId: $0.threadId, title: $0.title, cwd: $0.cwd, updatedAt: $0.updatedAt, matches: $0.matches) }
        }
        // Until every chat is indexed, or with chat search off, Codex's own title search fills in.
        let indexComplete = model.chatSearchEnabled == true && model.chatIndexProgress?.building == false
        if model.connected, !model.demo, !indexComplete, results.count < 6,
           let page = try? await model.bridge.listThreads(search: text) {
            let known = Set(results.map(\.threadId))
            results += page.data.filter { !known.contains($0.id) && scope.contains(threadId: $0.id, cwd: $0.cwd) }.prefix(6 - results.count).map {
                ChatResult(threadId: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: Date(timeIntervalSince1970: $0.updatedAt))
            }
        }
        // Claude app sessions are found by title, among those working where this workspace's tasks do.
        if !model.demo {
            let places = model.tasks.flatMap { [$0.cwd].compactMap { $0 } + ($0.folders ?? []) }
            let claudeScope = ChatScope(threadIds: scope.threadIds, directories: scope.directories + places)
            let words = text.lowercased().split(whereSeparator: \.isWhitespace)
            let sessions = await recentClaudeSessions().filter { session in
                claudeScope.contains(threadId: session.id, cwd: session.cwd) && words.allSatisfy { session.title.lowercased().contains($0) }
            }.prefix(4)
            results += sessions.map { ChatResult(threadId: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: $0.lastActivityAt, provider: .claude, cliSessionId: $0.cliSessionId) }
        }
        return results
    }

    @ObservationIgnored private var claudeSessions: (read: Date, sessions: [ClaudeDesktop.Session])?
    /// Read at most every half minute while typing.
    private func recentClaudeSessions() async -> [ClaudeDesktop.Session] {
        if let claudeSessions, claudeSessions.read > Date().addingTimeInterval(-30) { return claudeSessions.sessions }
        let sessions = await model.claudeAppSessions()
        claudeSessions = (Date(), sessions)
        return sessions
    }

    private func commands(matching text: String) -> [OmnibarCommand] {
        let lower = text.lowercased()
        guard lower.count >= 2 else { return [] }
        return OmnibarCommand.allCases.filter { command in
            if command == .switchWorkspace || command == .newWorkspace, workspaces == nil || model.demo { return false }
            if command == .newGroup, model.demo { return false }
            return command.keywords.contains { $0.hasPrefix(lower) } || command.title.lowercased().hasPrefix(lower)
        }.prefix(3).map { $0 }
    }

    static func rememberText(_ text: String) -> String? {
        for prefix in ["remember that ", "remember: ", "remember "] where text.lowercased().hasPrefix(prefix) {
            let note = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : note
        }
        return nil
    }

    // MARK: Keyboard

    func move(_ offset: Int) {
        let all = items
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == highlighted } ?? 0
        highlighted = all[min(max(current + offset, 0), all.count - 1)].id
    }

    func handle(_ press: KeyPress) -> KeyPress.Result { handle(press.key, press.modifiers) }

    func handle(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyPress.Result {
        if dictation.isActive {
            switch key {
            case .escape:
                cancelDictation()
                return .handled
            // Return acts on what was said, once the last words are in.
            case .return where !modifiers.contains(.shift):
                Task { await dictation.finish(); _ = handle(key, modifiers) }
                return .handled
            default: break
            }
        }
        switch key {
        // In wrapped text the arrows move between its lines.
        case .upArrow, .downArrow:
            guard isOpen, !wraps else { return .ignored }
            move(key == .upArrow ? -1 : 1)
            return .handled
        case .escape:
            // Backing out of a group's sheet keeps what was typed there for next time.
            if model.spotlitGroup != nil { model.releaseSpotlight() }
            else if isOpen { dismissed = true }
            else if !query.isEmpty || followUp != nil || !attachments.isEmpty { query = ""; followUp = nil; attachments = [] }
            else { return .ignored }
            return .handled
        case .return:
            if modifiers.contains(.shift) { return .ignored }
            if modifiers.contains(.command) { start(); return .handled }
            if modifiers.contains(.option) {
                // A group's sheet has no list to act on, so Option-Return plans the task there instead.
                if model.spotlitGroup != nil { plan(); return .handled }
                if isOpen, let item = items.first(where: { $0.id == highlighted }) { runSecondary(item) }
                return .handled
            }
            submit()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Actions

    /// Return: the highlighted result, or start the task.
    func submit() {
        guard !finding, !awaitingRead else { return }
        if model.spotlitGroup == AppModel.newGroupSheet { startInNewGroup(); return }
        // A group's sheet makes a task in that group: no readings, no finding earlier tasks.
        if model.spotlitGroup != nil { start(); return }
        if isOpen, let item = items.first(where: { $0.id == highlighted }) {
            // An answer or a choice the model only just offered may not have been seen yet.
            if item.id == "answer" || item.id.hasPrefix(Self.askPrefix), !readingSettled { nudgeReading(); return }
            run(item)
        } else { findOrStart() }
    }

    /// The model's reading has been on screen long enough to have been read.
    private var readingSettled: Bool { modelRead.map { Date().timeIntervalSince($0.at) >= Self.readingSettle } ?? true }
    private func nudgeReading() { readingNudge += 1; dismissed = false }

    func run(_ item: OmnibarItem) {
        switch item.kind {
        // Under Facienda's own question or answer, the first row is the way out: a new task.
        case .start: if modelReading?.kind == .unclear || modelReading?.kind == .question { start() } else { findOrStart() }
        case let .remember(text): remember(text)
        case let .command(command): perform(command)
        case let .task(task):
            if item.id.hasPrefix(Self.askPrefix), let asking { act(on: asking.choosing(task), by: .you); return }
            let decider: IntakeEntry.Decider = offered?.task.id == task.id ? .model : item.id == autoPick ? .rule : .you
            bringBack(task, message: offered?.task.id == task.id ? offered?.message ?? "" : "", by: decider)
        case let .chat(chat): chosenChat = chat
        case .note: finish(); model.openSettings(.memory)
        case let .answer(read): act(on: read, by: .model)
        case let .place(place):
            // Where the person put it is what the reader learns from.
            try? model.store.recordRouteCorrection(text: trimmed, workspaceID: place.workspaceID, groupID: place.groupID)
            launch(at: place, said: .start(at: place), by: .you)
        }
    }

    /// The second action: open a task or chat in Codex.
    func runSecondary(_ item: OmnibarItem) {
        switch item.kind {
        case let .task(task): if model.canOpen(task) { finish(); model.open(task) }
        case let .chat(chat): model.openThread(chat.threadId)
        default: run(item)
        }
    }

    /// Text asking for an earlier task brings that task back instead of starting a new one. A fast model reads which
    /// task is meant and the task is offered for one more Enter, with what would be sent to it; when none fits the text
    /// starts as a task after all, whose chat can search further.
    private func findOrStart() {
        let text = trimmed
        if let offered, offered.text == text { bringBack(offered.task, message: offered.message, by: .model); return }
        // An open task typed again opens, with the results closed too. ⌘↵ still starts a second one.
        if let task = typedAgain { bringBack(task, message: "", by: .rule); return }
        if followUp == nil, attachments.isEmpty, let note = Self.rememberText(text) { remember(note); return }
        if let read = modelReading {
            guard readingSettled else { nudgeReading(); return }
            act(on: read, by: .model); return
        }
        // Words that point back at a task wait for the reading rather than start one by mistake.
        if readingText == text, BarReader.pointsBack(text) { awaitReading(text); return }
        guard canStart, followUp == nil, attachments.isEmpty, Self.codexThreadID(text) == nil, Self.rememberText(text) == nil,
              TaskLookup.asksForEarlier(text) else { start(); return }
        finding = true
        Task {
            let answer = await model.findEarlierTask(text)
            finding = false
            // Typing on while it looked makes the answer stale.
            guard trimmed == text else { return }
            if let answer, answer.intent == .new { start(); return }
            guard let task = answer?.task ?? localPick(text) else { start(); return }
            // Even a sure answer waits for one more Enter: a model chose the task and wrote what goes to it.
            offered = (task, answer?.message ?? "", text)
            dismissed = false
            await refresh()
            highlighted = "task:" + task.id
        }
    }

    /// Without the model: the best task matching every word that counts, if the words found one.
    private func localPick(_ text: String) -> FaciendaTask? {
        ((try? model.store.lookUpTasks(text, limit: 1)) ?? []).first.flatMap { $0.complete ? $0.task : nil }
    }

    // MARK: Reading

    /// Reads the text once typing pauses, when it could be about the board at all. Plain new work never waits on a model.
    private func scheduleRead(_ text: String, matched: Bool) {
        if modelRead?.text == text { return }
        readTask?.cancel()
        let answersQuestion = model.tasks.contains { task in
            model.pendingQuestion(for: task).map { question in
                let words = Set(TaskLookup.terms(question.question + " " + question.options.joined(separator: " ")))
                return !words.isDisjoint(with: TaskLookup.terms(text))
            } ?? false
        }
        guard text.count <= 500, followUp == nil, attachments.isEmpty, typedAgain == nil, Self.rememberText(text) == nil,
              Self.codexThreadID(text) == nil, ClaudeDesktop.sessionID(inLink: text) == nil, !TaskLookup.asksForEarlier(text),
              BarReader.worthReading(text, matchesTasks: matched, matchesQuestion: answersQuestion, routes: routes) else { readingText = nil; return }
        readingText = text
        model.warmReader()
        readTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            await self?.read(text)
        }
    }

    private func read(_ text: String) async {
        guard trimmed == text else { return }
        readingNow = true
        let result = await reading(of: text).value
        readingNow = false
        guard !Task.isCancelled, trimmed == text else { return }
        readingText = nil
        modelRead = (text, result ?? BarReader.Reading(kind: .new), Date())
        rebuild(text, hits: lastHits, picking: false)
    }

    /// The model's reading of a text: the one under way for it, or a new one.
    private func reading(of text: String) -> Task<BarReader.Reading?, Never> {
        if let inFlight, inFlight.text == text { return inFlight.task }
        let task = Task { [model] in await model.readBar(text) }
        inFlight = (text, task)
        return task
    }

    /// The reading, or nil once it has taken longer than a task should wait for its place.
    private func placed(_ text: String) async -> BarReader.Reading? {
        let reading = reading(of: text)
        return await withTaskGroup(of: BarReader.Reading?.self) { group in
            group.addTask { await reading.value }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Return on words that point back at a task, before the reading came: it waits for the reading and shows it, so a
    /// second Return does it. Nothing to read starts the text as a task after all.
    private func awaitReading(_ text: String) {
        readTask?.cancel()
        awaitingRead = true
        Task {
            await read(text)
            awaitingRead = false
            guard trimmed == text else { return }
            if modelReading == nil { start() } else { dismissed = false }
        }
    }

    private func stopReading() {
        readTask?.cancel(); readTask = nil; readingText = nil; awaitingRead = false; readingNow = false
    }

    /// Does what a reading says, and keeps the request with it for the Feed.
    private func act(on read: BarReader.Reading, by decider: IntakeEntry.Decider) {
        let text = trimmed
        guard let said = BarReading(read) else { start(); return }
        switch read.kind {
        case .new: start()
        case .open:
            guard let task = read.task else { return }
            bringBack(task, message: "", by: decider)
        case .reply:
            guard let task = read.task else { return }
            if !task.state.isOpen { bringBack(task, message: read.message, by: decider); return }
            record(said, by: decider, taskID: task.id)
            finish()
            if model.tell(task, read.message) { confirm("Sent to “\(task.displayName)”") }
        case .answer:
            guard let task = read.task else { return }
            record(said, by: decider, taskID: task.id)
            finish()
            if let question = model.pendingQuestion(for: task) {
                model.answer(question, text: read.message); confirm("Answered “\(task.displayName)”")
            } else if model.tell(task, read.message) { confirm("Sent to “\(task.displayName)”") }
        case .done:
            guard let task = read.task else { return }
            record(said, by: decider, taskID: task.id)
            finish()
            // Done offers its own undo.
            model.complete(task)
        case .park:
            guard let task = read.task, let until = read.until else { return }
            record(said, by: decider, taskID: task.id)
            finish()
            var plan = WaitPlan(conditions: [.time(until)], note: text)
            plan.summary = WaitCompiler.summary(plan, taskName: { _ in nil })
            if model.park(task, plan: plan) { confirm("Parked until " + BarReading.when(until)) }
        case .question:
            record(BarReading(.answered, target: String(read.answer.prefix(200)), read: true), by: decider, taskID: read.sources.first?.id)
            finish()
        case .unclear:
            // The choices are in the results; Return there picks one.
            nudgeReading()
        }
    }

    /// Keeps what was typed beside what Return did with it. A request that could not be kept never stops the action.
    private func record(_ reading: BarReading, by decider: IntakeEntry.Decider, taskID: String?) {
        guard model.spotlitGroup == nil else { return }
        try? model.store.recordIntake(text: trimmed, reading: reading.label, decidedBy: decider, taskId: taskID)
    }

    /// The task comes back onto the board, into the group whose sheet is up if there is one.
    private func bringBack(_ task: FaciendaTask, message: String, by decider: IntakeEntry.Decider) {
        let group = model.omnibarGroup
        record(.task(task, message: message), by: decider, taskID: task.id)
        // A task in another workspace is shown where it lives: that workspace comes forward with the task open.
        if isElsewhere(task), let workspaces, let home = workspaces.workspaces.first(where: { $0.id == task.workspaceId }) {
            finish()
            guard workspaces.open(home), let there = workspaces.model else { return }
            there.bringBack(there.tasksByID[task.id] ?? task, into: nil, message: message)
            return
        }
        finish()
        model.bringBack(task, into: group, message: message)
        // A task that was never closed is only opened.
        let open = task.state.isOpen
        confirm(message.isEmpty ? (open ? "Opened" : "Brought back") : (open ? "Sent on" : "Brought back and sent on"))
    }

    /// Starts the text as a task where it belongs: in the group whose sheet is up, or where the reader put it, in any
    /// workspace. When the reader showed it could not tell between two places, Return asks which first. Otherwise the
    /// bar is free at once: a task still being placed starts as soon as its place is known.
    func start() {
        if model.spotlitGroup == AppModel.newGroupSheet { startInNewGroup(); return }
        let text = trimmed
        // A group's sheet makes its task right there, and a pasted chat link is added as it is.
        if model.spotlitGroup != nil || Self.codexThreadID(text) != nil || ClaudeDesktop.sessionID(inLink: text) != nil {
            start(in: model.omnibarGroup); return
        }
        if let route {
            if route.alternative != nil {
                // ⌘↵ on a place starts it there; otherwise Return asks which place first.
                if let item = items.first(where: { $0.id == highlighted }), case .place = item.kind { run(item); return }
                if let first = items.first(where: { $0.id.hasPrefix(Self.placePrefix) }) { highlighted = first.id }
                nudgeReading(); return
            }
            launch(at: route.place, said: .start(route), by: .model); return
        }
        // Anything more than a word goes where it belongs, read now if it was not read while typing.
        if routes, readingText == text || inFlight?.text == text || TaskLookup.terms(text).count >= 2 { launch(placing: text); return }
        launch(at: nil, said: BarReading(.start), by: .rule)
    }

    /// The text as the task asks it, with the chat it continues from.
    private var request: String {
        guard let followUp else { return trimmed }
        return trimmed + "\n\nContinue from the Codex chat “\(followUp.title)”: codex://threads/\(followUp.threadId)"
    }

    /// What Return took out of the bar to start, so the bar is free for the next thing at once.
    private struct Launch {
        let typed: String, request: String, files: [URL], choice: TaskModelChoice?, group: String?, reveal: Bool
    }

    private func takeLaunch() -> Launch? {
        guard canStart else { return nil }
        let taken = Launch(typed: trimmed, request: request, files: attachments, choice: model.composerModel, group: model.omnibarGroup,
                           reveal: model.destination != .dashboard)
        launching += taken.files
        finish()
        return taken
    }

    /// Starts the task where it was placed, or here when it has no place.
    private func launch(at place: BarPlace?, said: BarReading, by decider: IntakeEntry.Decider) {
        guard let taken = takeLaunch() else { return }
        Task { await start(taken, at: place, said: said, by: decider) }
    }

    /// Frees the bar and starts the task once the reader has placed it. A request that turned out to be about a task
    /// still starts as new work: Return was pressed before anything else was shown.
    private func launch(placing text: String) {
        guard let taken = takeLaunch() else { return }
        confirmation = "Finding where it goes…"
        Task {
            let read = await placed(text).flatMap { $0.kind == .new ? $0 : nil }
            var said = read.map(BarReading.start) ?? BarReading(.start)
            // Return came before the reading, so its best guess is taken, said as not sure.
            if said.alternative != nil { said.alternative = nil; said.sure = false }
            await start(taken, at: read?.place, said: said, by: read == nil ? .rule : .model)
        }
    }

    private func start(_ taken: Launch, at place: BarPlace?, said: BarReading, by decider: IntakeEntry.Decider) async {
        defer {
            launching.removeAll { taken.files.contains($0) }
            Self.discardPasted(taken.files)
        }
        let elsewhere = place.map { $0.workspaceID != model.workspaceID } ?? false
        let home = elsewhere ? place.flatMap { workspaces?.model(for: $0.workspaceID) } ?? model : model
        // A group only counts in its own workspace; without a place the task goes where the bar was pointing.
        let group = place.map { $0.workspaceID == home.workspaceID ? $0.groupID : nil } ?? taken.group
        if await home.capture(title: taken.request, intention: "", area: "Personal", date: Date(), startNow: true, attachments: taken.files,
                              groupID: group, reveal: home === model && taken.reveal, model: taken.choice) {
            try? home.store.recordIntake(text: taken.typed, reading: said.label, decidedBy: decider, taskId: home.lastCaptured)
            if home !== model { workspaces?.reload() }
            confirm(place.map { "Started in \($0.label)" } ?? "Started")
        } else {
            if home !== model, let error = home.error { model.error = error; home.error = nil }
            if confirmation == "Finding where it goes…" { confirmation = nil }
            // Nothing typed is lost: the words come back to the bar if it is empty.
            if query.isEmpty { query = taken.typed }
        }
    }

    /// A group's sheet's task, made right in that group, or a pasted chat link added as a task.
    private func start(in groupID: String?) {
        guard canStart else { return }
        if let threadId = Self.codexThreadID(trimmed) { addChat(threadId, in: groupID); return }
        if let sessionId = ClaudeDesktop.sessionID(inLink: trimmed) { addClaudeSession(sessionId, in: groupID); return }
        let request = request
        submitting = true
        // On the dashboard the new task appears on the board; elsewhere Facienda shows it.
        let reveal = model.destination != .dashboard
        Task {
            defer { submitting = false }
            if await model.capture(title: request, intention: "", area: "Personal", date: Date(), startNow: true, attachments: attachments,
                                   groupID: groupID, reveal: reveal, model: model.composerModel) {
                finish()
            }
        }
    }

    /// The board's +: the group, named or left for Facienda to name, and its first task, started or planned.
    /// Without a task it is simply a new group. Either way the sheet folds into the new card.
    func startInNewGroup(plan planning: Bool = false) {
        if makesGroupOnly { guard canMakeGroup else { return } }
        else { guard planning ? canPlan : canStart else { return } }
        let text = trimmed
        let group: TaskGroup
        if let made = madeGroup, let existing = model.groups.first(where: { $0.id == made }) { group = existing; model.sheetLanding = made }
        else {
            guard let made = model.makeGroup(named: newGroupName, firstTask: text) else { return }
            group = made; madeGroup = made.id
        }
        if makesGroupOnly { finish(); return }
        if planning {
            if model.planTask(text, in: group.id) { finish() }
            return
        }
        start(in: group.id)
    }

    /// A pasted Codex link becomes a task that tracks that chat, in the lit group if there is one. You stay where you are.
    private func addChat(_ threadId: String, in groupID: String?) {
        submitting = true
        Task {
            defer { submitting = false }
            if await model.importThread(CodexThread(id: threadId, title: "", cwd: "", updatedAt: Date()), groupID: groupID, reveal: false) {
                record(BarReading(.trackChat), by: .rule, taskID: nil)
                finish(); confirm("Chat added as a task")
            }
        }
    }

    /// A pasted Claude session link or `local_…` ID becomes a task that tracks that session.
    private func addClaudeSession(_ sessionId: String, in groupID: String?) {
        submitting = true
        Task {
            defer { submitting = false }
            if await model.importClaudeSession(sessionId, groupID: groupID, reveal: false) {
                record(BarReading(.trackChat), by: .rule, taskID: nil)
                finish(); confirm("Claude session added as a task")
            }
        }
    }

    /// The chat a Codex deep link such as `codex://threads/<id>` points to, when the text is only that link.
    static func codexThreadID(_ text: String) -> String? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), url.scheme?.lowercased() == "codex",
              ["threads", "thread"].contains(url.host()?.lowercased()) else { return nil }
        let id = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty || id.contains("/") ? nil : id
    }

    func remember(_ text: String) {
        model.perform {
            var fact = MemoryFact(text: text, source: "Added from the top bar")
            fact.confirmedAt = Date()
            try model.store.remember(fact, source: .user)
            model.refresh()
            record(BarReading(.remember, target: text), by: .rule, taskID: nil)
            finish()
            confirm("Remembered")
        }
    }

    func perform(_ command: OmnibarCommand) {
        let text = trimmed
        finish()
        switch command {
        case .forYou: model.showBoard(.forYou)
        case .processing: model.showBoard(.processing)
        case .waiting: model.showBoard(.waiting)
        case .scheduled: model.showBoard(.scheduled)
        case .done: model.showBoard(.done)
        case .memory: model.openSettings(.memory)
        case .settings: model.showSettings = true
        case .switchWorkspace: workspaces?.reload(); workspaces?.sheet = .manage
        case .newWorkspace: workspaces?.error = nil; workspaces?.sheet = .create
        case .newGroup: model.requestNewGroup()
        case .composer:
            // Keywords like "new task" are not the request itself.
            if !command.keywords.contains(text.lowercased()) && !text.isEmpty { model.composerRequest = text }
            model.compose()
        }
    }

    func continueFrom(_ chat: ChatResult) {
        followUp = chat; chosenChat = nil
        model.omnibarFocusRequest += 1
    }

    /// Clears the bar after an action. The board filter and the spotlight go with it:
    /// a group's sheet folds straight back into its card, where the new row is already in place.
    /// Option-Return or the sheet's Plan button: the task waits at the end of its group's plan, not started.
    func plan() {
        guard canPlan, let group = model.spotlitGroup else { return }
        if group == AppModel.newGroupSheet { startInNewGroup(plan: true); return }
        guard model.planTask(trimmed, in: group) else { return }
        finish()
    }

    func finish() {
        if dictation.isActive { dictation.cancel() }
        stopReading(); modelRead = nil; modelPick = nil
        // A task started from a group's sheet leaves the bar's own text where it was.
        if model.spotlitGroup != nil { sheetText = "" } else { query = "" }
        model.releaseSpotlight()
        followUp = nil; dismissed = false; offered = nil; attachments = []
        sections = []; highlighted = Self.startID; autoPick = nil; duplicate = nil
        newGroupName = ""; madeGroup = nil
        model.search = ""
    }

    private func confirm(_ text: String) {
        confirmation = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if confirmation == text { confirmation = nil }
        }
    }

    // MARK: Group sheet

    /// While a group's sheet is up, files and a follow-up belong to it; the bar's own wait here. Its text never moves.
    @ObservationIgnored private var parked: (followUp: ChatResult?, attachments: [URL]) = (nil, [])
    /// What a sheet held when it was let go without starting, so opening that group again picks up there.
    @ObservationIgnored private var drafts: [String: (text: String, attachments: [URL])] = [:]

    /// Text waiting in a group's sheet for when it opens; the demo snapshots use it.
    func seedDraft(_ text: String, for group: String) { drafts[group] = (text, []) }

    func sheetOpened(_ group: String) {
        parked = (followUp, attachments)
        let draft = drafts.removeValue(forKey: group)
        sheetText = draft?.text ?? ""; attachments = draft?.attachments ?? []; followUp = nil
    }

    /// Esc, a click outside or leaving the board keeps the sheet's text for that group and gives the bar back its files.
    func sheetClosed(_ group: String) {
        if dictation.isActive { dictation.cancel() }
        if !sheetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty { drafts[group] = (sheetText, attachments) }
        // Its name stays for next time; a group it made for a start that failed is simply there on the board now.
        if group == AppModel.newGroupSheet { madeGroup = nil }
        sheetText = ""; followUp = parked.followUp; attachments = parked.attachments; parked = (nil, [])
        dismissed = true
    }

    /// Shift-Return: a line break where the caret is.
    func breakLine(at selection: inout TextSelection?) { text.breakLine(at: &selection) }

    // MARK: Attachments

    /// Adds files to the next task, once each. Folders are left out: a task attaches files.
    func attach(_ urls: [URL]) {
        for url in urls where url.isFileURL && !attachments.contains(url) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
            attachments.append(url)
        }
        dismissed = false
    }

    /// ⌘V with files or a picture on the pasteboard attaches them. Text that comes with a picture pastes as text,
    /// unless it is only the picture's link, as a browser's Copy Image adds.
    func pasteAttachments(from pasteboard: NSPasteboard = .general) -> Bool {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            attach(files)
            return true
        }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let onlyLink = !text.contains(where: \.isWhitespace) && URL(string: text)?.scheme.map { ["http", "https"].contains($0.lowercased()) } == true
        guard text.isEmpty || onlyLink, let image = Self.pastedImage(pasteboard) else { return false }
        attach([image])
        return true
    }

    /// Where pasted pictures wait, one folder each, until a task copies them.
    static var pastedFolder: URL { FileManager.default.temporaryDirectory.appending(path: "Facienda Pasted", directoryHint: .isDirectory) }

    /// Deletes the temporary folders of pasted pictures; files the user picked or dropped are theirs and left alone.
    static func discardPasted(_ urls: [URL]) {
        let root = pastedFolder.standardizedFileURL.path + "/"
        for url in urls where url.isFileURL {
            let folder = url.deletingLastPathComponent().standardizedFileURL
            guard folder.path.hasPrefix(root), !folder.path.dropFirst(root.count).contains("/") else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Pictures pasted in an earlier session that never became a task.
    private static func discardStalePasted() {
        let old = Date().addingTimeInterval(-86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(at: pastedFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where ((try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < old {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A picture on the pasteboard, such as a screenshot, saved as a PNG the task can copy.
    private static func pastedImage(_ pasteboard: NSPasteboard) -> URL? {
        let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        } ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        let folder = pastedFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = folder.appending(path: "Pasted image \(stamp.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            return file
        } catch { return nil }
    }

    // MARK: Dictation

    func toggleDictation() {
        if dictation.isActive { Task { await dictation.finish() } } else { startDictation() }
    }

    func startDictation() {
        guard !dictation.isActive else { return }
        dictationBase = text; dictated = text; placedBefore = [text]; dismissed = false
        // The workspace's name is one more word the recognizer would otherwise guess at.
        let vocabulary = [workspaces?.current?.name].compactMap { $0 } + model.dictationVocabulary
        Task { await dictation.start(language: Dictation.language, vocabulary: vocabulary) }
    }

    /// Stops listening and puts back what the bar held before.
    func cancelDictation() {
        guard dictation.isActive else { return }
        dictation.cancel()
        text = dictationBase
    }

    /// Typing while dictating keeps what is there and stops listening.
    func edited(_ text: String) {
        guard dictation.isActive, text != dictated else { return }
        // A field redrawing can hand back what it showed a moment ago; only new text is typing.
        if placedBefore.contains(text) {
            Self.dictationLog.info("The bar handed back earlier dictated text (\(text.count) characters); still listening")
            return
        }
        Self.dictationLog.info("Typing stopped dictation (\(text.count) characters, dictated \(self.dictated.count))")
        dictation.cancel()
    }

    private static let dictationLog = Logger(subsystem: "org.facienda.mac", category: "Dictation")

    /// Spoken words follow whatever was typed before dictation began.
    private func place(_ words: String) {
        text = Dictation.join(dictationBase, words)
        dictated = text
        placedBefore.insert(text)
    }
}

extension String {
    /// Shift-Return in a text field: a line break in place of the selection, with the caret after it.
    mutating func breakLine(at selection: inout TextSelection?) {
        var text = self
        var range = text.endIndex..<text.endIndex
        if case let .selection(picked)? = selection?.indices, picked.upperBound <= text.endIndex { range = picked }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: "\n")
        self = text
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset + 1))
    }
}
