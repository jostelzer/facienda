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
            let kept = Set(attachments + parked.attachments + drafts.values.flatMap(\.attachments))
            Self.discardPasted(oldValue.filter { !kept.contains($0) })
        }
    }
    private var submitting = false
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

    var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// While a group is lit, typing writes its next task: no results hang over the lit card.
    var isOpen: Bool { !dismissed && !trimmed.isEmpty && model.spotlitGroup == nil }
    var items: [OmnibarItem] { sections.flatMap(\.items) }
    var canStart: Bool { !trimmed.isEmpty && !model.demo && !model.dispatching && !model.capturing && !submitting }
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
            sections = []; chats = []; chatsQuery = ""; highlighted = Self.startID; autoPick = nil
            model.search = ""
            return
        }
        if offered?.text != text { offered = nil }
        if TaskLookup.asksForEarlier(text) { model.warmFinder() }
        // Narrowing the board could hide the lit card the task is written for.
        guard model.spotlitGroup == nil else { sections = []; model.search = ""; return }
        let hits = wraps ? [] : ((try? model.store.lookUpTasks(text, limit: 6)) ?? [])
        filterBoard(text, matched: hits.contains(where: \.complete))
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
        var actions = [OmnibarItem(id: Self.startID, kind: .start)]
        if let note = Self.rememberText(text) { actions.insert(OmnibarItem(id: "remember", kind: .remember(note)), at: 1) }
        guard !wraps else {
            sections = [OmnibarSection(id: "actions", title: nil, items: actions)]
            if !items.contains(where: { $0.id == highlighted }) { highlighted = Self.startID }
            return
        }
        actions += commands(matching: text).map { OmnibarItem(id: "command:" + $0.rawValue, kind: .command($0)) }
        var result = [OmnibarSection(id: "actions", title: nil, items: actions)]
        // A chat that belongs to a task is found as that task, which opens straight away.
        var tasks = hits.map(\.task)
        if let offered, !tasks.contains(where: { $0.id == offered.task.id }) { tasks.insert(offered.task, at: 0) }
        var chatItems: [OmnibarItem] = []
        for chat in chats {
            guard let task = linkedTask(chat.threadId) else { chatItems.append(OmnibarItem(id: "chat:" + chat.threadId, kind: .chat(chat))); continue }
            if !tasks.contains(where: { $0.id == task.id }) { tasks.append(task) }
        }
        if !tasks.isEmpty {
            result.append(OmnibarSection(id: "tasks", title: "Tasks", items: tasks.map { OmnibarItem(id: "task:" + $0.id, kind: .task($0)) }))
        }
        if model.chatSearchEnabled == nil && !model.demo { chatItems.append(OmnibarItem(id: "enable-chat-search", kind: .enableChatSearch)) }
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
            let pick = TaskLookup.looksBack(text) ? hits.first.flatMap { $0.complete ? "task:" + $0.task.id : nil } : nil
            if let pick, highlighted == Self.startID || highlighted == autoPick { highlighted = pick }
            else if pick == nil, highlighted == autoPick { highlighted = Self.startID }
            autoPick = pick
        }
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
        if !model.connected { return "Connect Codex in Settings to search your chats." }
        if model.chatSearchEnabled == false { return "Searching chat titles only. Turn on chat search in Settings to search what was said." }
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
        guard !finding else { return }
        if model.spotlitGroup == AppModel.newGroupSheet { startInNewGroup(); return }
        if isOpen, let item = items.first(where: { $0.id == highlighted }) { run(item) } else { findOrStart() }
    }

    func run(_ item: OmnibarItem) {
        switch item.kind {
        case .start: findOrStart()
        case let .remember(text): remember(text)
        case let .command(command): perform(command)
        case let .task(task): bringBack(task, message: offered?.task.id == task.id ? offered?.message ?? "" : "")
        case let .chat(chat): chosenChat = chat
        case .note: finish(); model.openSettings(.memory)
        case .enableChatSearch: model.setChatSearch(true); Task { await refresh() }
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
        if let offered, offered.text == text { bringBack(offered.task, message: offered.message); return }
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

    /// The task comes back onto the board, into the group whose sheet is up if there is one.
    private func bringBack(_ task: FaciendaTask, message: String) {
        let group = model.omnibarGroup
        finish()
        model.bringBack(task, into: group, message: message)
        confirm(message.isEmpty ? "Brought back" : "Brought back and sent on")
    }

    func start() {
        if model.spotlitGroup == AppModel.newGroupSheet { startInNewGroup(); return }
        start(in: model.omnibarGroup)
    }

    private func start(in groupID: String?) {
        guard canStart else { return }
        if let threadId = Self.codexThreadID(trimmed) { addChat(threadId, in: groupID); return }
        if let sessionId = ClaudeDesktop.sessionID(inLink: trimmed) { addClaudeSession(sessionId, in: groupID); return }
        var request = trimmed
        if let followUp { request += "\n\nContinue from the Codex chat “\(followUp.title)”: codex://threads/\(followUp.threadId)" }
        submitting = true
        // On the dashboard the new task appears on the board; elsewhere Facienda shows it.
        let reveal = model.destination != .dashboard
        Task {
            defer { submitting = false }
            if await model.capture(title: request, intention: "", area: "Personal", date: Date(), startNow: true, attachments: attachments,
                                   groupID: groupID, reveal: reveal, model: model.composerModel) { finish() }
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
        model.releaseSpotlight()
        query = ""; followUp = nil; dismissed = false; offered = nil; attachments = []
        sections = []; highlighted = Self.startID; autoPick = nil
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

    /// While a group's sheet is up the text belongs to it; the bar's own text and follow-up wait here.
    @ObservationIgnored private var parked: (text: String, followUp: ChatResult?, attachments: [URL]) = ("", nil, [])
    /// What a sheet held when it was let go without starting, so opening that group again picks up there.
    @ObservationIgnored private var drafts: [String: (text: String, attachments: [URL])] = [:]

    func sheetOpened(_ group: String) {
        parked = (query, followUp, attachments)
        let draft = drafts.removeValue(forKey: group)
        query = draft?.text ?? ""; attachments = draft?.attachments ?? []; followUp = nil
    }

    /// Esc, a click outside or leaving the board keeps the sheet's text for that group and gives the bar back its own.
    func sheetClosed(_ group: String) {
        if dictation.isActive { dictation.cancel() }
        if !trimmed.isEmpty || !attachments.isEmpty { drafts[group] = (query, attachments) }
        // Its name stays for next time; a group it made for a start that failed is simply there on the board now.
        if group == AppModel.newGroupSheet { madeGroup = nil }
        query = parked.text; followUp = parked.followUp; attachments = parked.attachments; parked = ("", nil, [])
        dismissed = true
    }

    /// Shift-Return: a line break where the caret is.
    func breakLine(at selection: inout TextSelection?) { query.breakLine(at: &selection) }

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
        dictationBase = query; dictated = query; placedBefore = [query]; dismissed = false
        // The workspace's name is one more word the recognizer would otherwise guess at.
        let vocabulary = [workspaces?.current?.name].compactMap { $0 } + model.dictationVocabulary
        Task { await dictation.start(language: Dictation.language, vocabulary: vocabulary) }
    }

    /// Stops listening and puts back what the bar held before.
    func cancelDictation() {
        guard dictation.isActive else { return }
        dictation.cancel()
        query = dictationBase
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
        query = Dictation.join(dictationBase, words)
        dictated = query
        placedBefore.insert(query)
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
