import AppKit
import Observation
import FaciendaCore
import FaciendaBridge

/// One workspace of the library: its tasks, groups and memory. Other workspaces have their own models.
/// The model's behaviour lives in the `AppModel+…` extensions next to this file, one concern each.
@MainActor @Observable final class AppModel {
    // MARK: Workspace

    /// Scoped to this model's workspace. `store.library` sees every workspace.
    let store: FaciendaStore
    var workspaceID: String { store.workspaceID ?? "" }
    var workspace: Workspace?
    /// Names this workspace's preferences on this Mac. Workspaces combined from separate folders keep their earlier key.
    let storageKey: String
    let demo: Bool
    /// Workspaces a group or task can move to.
    var otherWorkspaces: [Workspace] = []
    /// Every task in the library, for prerequisites and waits that name a task in another workspace.
    var libraryTasks: [FaciendaTask] = [] { didSet { derived = Derived() } }
    /// The last change, while the toast offering to undo it is up.
    var undoOffer: UndoOffer?
    /// The window's undo stack, shared with its text fields. Set by the dashboard.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The newest change on the undo stack, for a toast offered once a view knows what to call it.
    @ObservationIgnored var latestUndo: UndoEntry?
    var error: String?
    var notice: String?

    // MARK: Navigation

    var destination: Destination = .dashboard { didSet { derived = Derived() } }
    var selection: String?
    /// A task list asked for (⌘2, Go to Done…), until the board has turned on its chips.
    var requestedList: Destination?
    var search = "" { didSet { derived = Derived() } }
    var showCapture = false
    var showSettings = false
    /// The pane Settings opens on; back to General once it closes.
    var settingsPane: SettingsPane = .general
    var showShortcuts = false
    /// How many task composers are on screen. The mic shortcut goes to one of them before the top bar.
    var composersOnScreen = 0
    /// Set by the voice hotkey: the New task sheet starts listening as soon as it opens.
    var listenOnCompose = false
    var composerFocusRequest = 0
    /// Bumped to move the keyboard to the top bar.
    var omnibarFocusRequest = 0
    /// Bumped to start or stop dictating into the top bar.
    var dictationRequest = 0
    /// The group a task started from the top bar joins, set by a card's + and lit up on the board until let go.
    /// Nil lets the runner file it; `unsortedGroup` keeps it in "Unsorted".
    var omnibarGroup: String?
    static let unsortedGroup = ""
    /// The group in the spotlight. It only shows on the board.
    var spotlitGroup: String? { destination == .dashboard ? omnibarGroup : nil }
    /// Set by the menu, shortcut and command bar; the board opens its New group card and clears it.
    var newGroupRequested = false
    /// A task the board should scroll to and open, as when its row is clicked. Set when the top bar brings one back.
    var boardOpenRequest: String?

    // MARK: Tasks and what hangs off them

    var tasks: [FaciendaTask] = [] { didSet { derived = Derived() } }
    var links: [ThreadLink] = [] { didSet { derived = Derived() } }
    var decisions: [Decision] = [] { didSet { derived = Derived() } }
    var nativeDispatches: [NativeDispatch] = [] { didSet { derived = Derived() } }
    /// The model for Facienda's background work, in Codex or Claude.
    var serviceModel: ServiceModelChoice = .luna
    /// What running Codex turns ask, by task, for the user to answer here.
    var codexApprovals: [String: [CodexApproval]] = [:]
    var checkPlans: [CheckPlan] = [] { didSet { derived = Derived() } }
    var blockers: [TaskBlocker] = [] { didSet { derived = Derived() } }
    var readinessPlans: [TaskReadiness] = []
    /// The latest wait of each task, keyed by task ID.
    var waits: [String: TaskWait] = [:]
    /// Each task's latest result and the one-line headline written from it, keyed by task ID.
    var latestResults: [String: LatestResult] = [:]
    var headlines: [String: TaskHeadline] = [:]
    /// What a new row shows under its name: the path to what is open now, the user's last words and the answer.
    var recaps: [String: TaskRecap] = [:]
    /// Waits to offer in the composer, read from each task's chat when its turn finished.
    var waitOptions: [String: StoredWaitOptions] = [:]
    /// What a reviewed task offers when its row is clicked: a continuation for the agent and a guess at the user's own step.
    var nextSteps: [String: StoredNextSteps] = [:]
    /// Steps the user took on themselves, keyed by task ID.
    var ownSteps: [String: OwnStep] = [:]
    private var readMarks: [String: TaskReadMark] = [:]
    var replyDrafts: [String: String] = [:]
    /// Tasks whose new name is being written right now.
    var namingTasks: Set<String> = []
    @ObservationIgnored var headlineTask: Task<Void, Never>?
    @ObservationIgnored var headlineAttempts: Set<String> = []
    /// Tries at a recap since a task's work came back, keyed by task and that moment.
    @ObservationIgnored var recapTries: [String: (count: Int, last: Date)] = [:]

    // MARK: The selected task

    var timeline: [TaskEvent] = []
    var taskContext: DispatchContext?
    var result: String?
    var resultReportedAt: Date?
    var resultErrors: [String: String] = [:]
    var loadingResults: Set<String> = []
    @ObservationIgnored var snapshotCache: (key: String, snapshot: CodexConversationSnapshot?)?
    /// Titles of chats that answers link to, as their app names them, by chat ID.
    var linkedChatTitles: [String: String] = [:]
    /// Tasks the user already moved to another chat, which offer no more chats to continue in.
    var handedOver: Set<String> = []
    @ObservationIgnored var linkedChatsCache: [String: (key: String, chats: [ChatLinks.Found])] = [:]
    @ObservationIgnored var claudeSessionLookups: [String: ClaudeDesktop.Session?] = [:]

    // MARK: Groups

    var groups: [TaskGroup] = [] { didSet { derived = Derived() } }
    /// Task ID to group ID. Tasks without an entry are ungrouped.
    var groupMembers: [String: String] = [:] { didSet { derived = Derived() } }
    /// Where the user put each task on the board. Tasks without an entry sort by when they were made, newest first.
    var taskPlaces: [String: Double] = [:] { didSet { derived = Derived() } }
    /// Each group's linked folders, primary first. Groups without links are absent.
    var groupFolders: [String: [String]] = [:]
    /// Each group's linked and proposed sources, in order. Groups without any are absent.
    var groupSources: [String: [GroupSource]] = [:]
    /// Every line of this workspace's group plans. The Plan view shows one group's lines as an outline.
    var planLines: [PlanLine] = []
    /// Folders of the user's Codex projects, most recently active first, offered when linking a folder.
    var codexProjectFolders: [String] = []
    /// Paints group covers through Codex. nil until the running app installs it, so tests and the demo never reach Codex.
    @ObservationIgnored var coverPainter: (any CoverPainting)?
    /// What a cover looked like before its last change, so the change can be undone.
    var coverUndo: [String: CoverSnapshot] = [:]
    /// Painted covers by group ID.
    var coverImages: [String: NSImage] = [:]
    /// Groups whose cover is being painted right now.
    var paintingCovers: Set<String> = []
    @ObservationIgnored var coverStamps: [String: Date] = [:]
    /// Groups whose automatic painting failed since launch; they wait for the user to ask again.
    @ObservationIgnored var coverFailures: Set<String> = []
    var coversEnabled: Bool { UserDefaults.standard.object(forKey: "groupCovers") as? Bool ?? true }

    // MARK: Memory

    /// The memory this workspace learns into and recalls from.
    var memorySpace: MemorySpace?
    var memorySpaces: [MemorySpace] = []
    /// The memory the Memory view shows. Nil is this workspace's own.
    var viewedSpaceID: String?
    var viewedMemories: [MemoryFact] = []
    var memories: [MemoryFact] = []
    var memoryStatus: WorkspaceMemoryStatus?
    /// Built-in memory progress for the memory being viewed.
    var learnedStatus: NativeMemoryStatus?
    var memorySettings: WorkspaceMemorySettings?
    var memoryError: String?
    var memorySyncing = false
    @ObservationIgnored var memoryCursor = 0
    @ObservationIgnored var memoryTask: Task<Void, Never>?

    // MARK: Composer

    var capturing = false
    var dispatching = false
    var startingTaskID: String?
    var composerRequest = ""
    var composerAttachments: [URL] = []
    /// The model for the next task. The last choice is remembered across launches.
    var composerModel = AppModel.savedComposerModel() {
        didSet {
            modelSettings[composerModel.model] = composerModel
            guard !demo else { return }
            if let data = try? JSONEncoder().encode(composerModel) { UserDefaults.standard.set(data, forKey: "composerModel") }
            if let data = try? JSONEncoder().encode(modelSettings) { UserDefaults.standard.set(data, forKey: "composerModelSettings") }
        }
    }
    /// The reasoning and Fast each model last had, so switching back to a model brings them back.
    @ObservationIgnored var modelSettings = AppModel.savedModelSettings()

    func chooseComposerModel(_ id: String) { composerModel = composerModel.choosing(id, remembered: modelSettings) }

    // MARK: Codex

    /// The Codex connection every workspace shares.
    let codex: CodexConnection
    var bridge: CodexBridge { codex.bridge }
    let installer = ConnectionInstaller()
    /// Starts Facienda's Codex dispatcher once the library is connected. Tests pass one that does nothing.
    @ObservationIgnored let startDispatcher: @MainActor (AppModel) -> Void
    var connection: String { get { codex.connection } set { codex.connection = newValue } }
    var connected: Bool { get { codex.connected } set { codex.connected = newValue } }
    var accountReady: Bool { get { codex.accountReady } set { codex.accountReady = newValue } }
    var executable: String { get { codex.executable } set { codex.executable = newValue } }
    /// Plan limits for each signed-in agent, shown at the foot of the sidebar.
    var usage: [PlanUsage] { snapshotUsage ?? codex.usage + (demo ? [] : [ClaudeUsage.shared.usage].compactMap { $0 }) }
    /// Sample limits for `--snapshot --usage`, so a picture of the sidebar shows its meters.
    var snapshotUsage: [PlanUsage]?
    var signInID: String? { codex.signInID }
    var signingIn: Bool { codex.signingIn }
    var signInError: String? { codex.signInError }
    var connecting: Bool { codex.connecting }
    var connectionPlan: ConnectionPlan?
    var nativeRunner: NativeRunnerState?
    var workspaceSetup: WorkspaceSetup?
    var connectingWorkspace = false
    var workspaceSetupError: String?
    var threads: [CodexThread] = []
    var nextCursor: String?
    var importingThreadID: String?
    /// Codex chat update times from the last poll and the last read, by thread ID, and chats
    /// already read during their current burst of activity.
    @ObservationIgnored var threadStamps: [String: Double] = [:]
    @ObservationIgnored var settledThreadStamps: [String: Double] = [:]
    @ObservationIgnored var quietlyHeldThreads: Set<String> = []
    /// What Facienda found when it looked for a parked delivery's chat, keyed by dispatch ID.
    var deliverySearches: [String: DeliverySearch] = [:]
    /// A parked delivery the user asked to send again before Facienda proved it never arrived.
    var resendConfirmation: NativeDispatch?
    @ObservationIgnored var deliveryTask: Task<Void, Never>?

    // MARK: Claude

    var claudeRunner: ClaudeRunnerState?
    /// Claude sessions carrying this workspace's tasks, by session ID.
    var claudeSessions: [String: ClaudeSession] = [:]
    var connectingClaude = false
    var claudeSetupOpened = false
    var claudeSetupError: String?
    /// Starts the Claude app did not pick up. They wait for the user instead of being handed over again.
    var claudeStartsHeld: Set<String> = []
    @ObservationIgnored var startingWaitingClaude = false
    /// The one question Facienda asks before adding its permission hook to the Claude settings, once for all sessions.
    var askingClaudeAccess = false
    @ObservationIgnored var claudeAccessNext: (connect: Bool, repair: Bool) = (true, false)
    /// Transcript modification dates already read, and whether a turn ran then, by session ID.
    @ObservationIgnored var transcriptStamps: [String: (modified: Date, running: Bool)] = [:]
    /// Opens Claude links. Tests replace it so they never launch the Claude app.
    @ObservationIgnored var openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Whether the Claude app adopted a session Facienda handed it, waiting briefly for it to appear.
    @ObservationIgnored var claudeSessionAdopted: @MainActor (String) async -> Bool = { await ClaudeDesktop.waitForSession(cliSessionId: $0, seconds: 12) }
    @ObservationIgnored var claudeAppAvailable: @MainActor () -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppModel.claudeBundleID) != nil }
    /// Where the Codex runner lives instead of the user's choice. Tests set it so they never write into ~/facienda.
    var claudeInstalled: Bool { claudeAppAvailable() }

    // MARK: Chat search

    /// Whether every Codex chat on this Mac is indexed for search. Nil until the user decides.
    var chatSearchEnabled = UserDefaults.standard.object(forKey: "chatSearchEnabled") as? Bool
    var chatIndexProgress: ChatIndexProgress?
    var chatIndexError: String?
    @ObservationIgnored var openedChatIndex: ChatIndex?
    @ObservationIgnored var indexTask: Task<Void, Never>?

    // MARK: Background services

    var notificationEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    /// Free space where tasks work. Below `DiskUsage.lowSpaceThreshold` the runner holds new work and the board says why.
    var freeDiskSpace: Int64?
    /// The day the library was last copied outside the data folder, so the copy runs once a day while the app stays open.
    @ObservationIgnored var backedUpDay: Int?
    /// Set once setup registered Facienda's MCP server and hooks in Codex this session.
    var codexToolsConnected = false
    var codexToolsError: String?
    /// Whether Codex trusts Facienda's hooks, as `hooks/list` reports; nil until read.
    var codexHooksTrusted: Bool?
    var diskNearlyFull: Bool { freeDiskSpace.map { $0 < DiskUsage.lowSpaceThreshold } ?? false }
    var mobileSyncStatus = "iPhone companion is off"
    var mobileSyncEnabled: Bool {
        UserDefaults.standard.string(forKey: "mobileSyncWorkspace") == workspaceID
    }
    var mobileCloudBuild: Bool { MobileCompanion.isCloudBuild }
    @ObservationIgnored var mobileCompanion: MobileCompanion?
    @ObservationIgnored var mobileTask: Task<Void, Never>?
    @ObservationIgnored var started = false
    @ObservationIgnored var serviceTask: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored var derived = Derived()
    @ObservationIgnored var folderLookups = FolderLookups()

    init(demo: Bool = false, store: FaciendaStore? = nil, codex: CodexConnection? = nil,
         startDispatcher: @escaping @MainActor (AppModel) -> Void = { DispatcherHost.shared.start(for: $0) }) throws {
        self.demo = demo
        self.codex = codex ?? CodexConnection(demo: demo)
        self.startDispatcher = startDispatcher
        let opened = try store ?? (demo ? FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaDemo/\(UUID().uuidString)/Library/facienda.sqlite")) : LibraryHome.open())
        // A whole-library store shows its first workspace.
        let scoped = try opened.workspaceID == nil ? opened.scoped(to: opened.defaultWorkspace().id) : opened
        let workspace = try scoped.workspace(scoped.workspaceID ?? "")
        self.store = scoped
        storageKey = scoped.url.path + "#" + workspace.id
        if demo { try seedDemo() }
        refresh()
    }

    static func savedComposerModel() -> TaskModelChoice {
        guard let data = UserDefaults.standard.data(forKey: "composerModel"),
              let choice = try? JSONDecoder().decode(TaskModelChoice.self, from: data), choice.details != nil else { return .standard }
        return choice
    }

    static func savedModelSettings() -> [String: TaskModelChoice] {
        guard let data = UserDefaults.standard.data(forKey: "composerModelSettings"),
              let settings = try? JSONDecoder().decode([String: TaskModelChoice].self, from: data) else { return [:] }
        return settings
    }

    var selectedTask: FaciendaTask? { selection.flatMap { tasksByID[$0] } }
    var areas: [String] { Array(Set(tasks.filter(\.state.isOpen).map(\.area))).sorted() }
    /// Search and answers only use chats that belong here.
    var chatScope: ChatScope {
        ChatScope(threadIds: Set(links.map(\.codexThreadId)), directories: tasks.map { store.taskFolder($0.id).path })
    }
    var attentionCount: Int { tasks.filter { $0.state == .needsMe }.count }
    var newCount: Int { tasks.filter(isUnread).count }
    var runningCount: Int { tasks.filter { $0.state == .running }.count }
    var violations: [FaciendaTask] { tasks.filter { !$0.ruleViolations.isEmpty } }

    func refresh() {
        snapshotCache = nil; folderLookups = FolderLookups()
        perform {
            workspace = try store.workspace(workspaceID)
            let all = try store.library.workspaces()
            otherWorkspaces = all.filter { $0.id != workspaceID }
            memorySpaces = try store.memorySpaces()
            memorySpace = memorySpaces.first { $0.id == workspace?.memorySpaceId }
            // The library holds every workspace's work; this model keeps its own.
            tasks = try store.tasks(); libraryTasks = try store.library.tasks()
            let ids = Set(tasks.map(\.id))
            let dispatches = try store.dispatches()
            nativeRunner = try store.runnerState(); nativeDispatches = dispatches.filter { ids.contains($0.taskId) }; workspaceSetup = try store.workspaceSetup()
            loadServiceModel()
            codexApprovals = Dictionary(grouping: try store.openCodexApprovals().filter { $0.taskId.map(ids.contains) == true }, by: { $0.taskId ?? "" })
            claudeRunner = try store.claudeRunner()
            if claudeRunner?.isAwake() == true, !startingWaitingClaude, !waitingClaudeStarts(in: dispatches, tasks: libraryTasks, workspaces: all).isEmpty {
                Task { await startWaitingClaudeTasks() }
            }
            claudeSessions = Dictionary(try store.claudeSessions().filter { ids.contains($0.taskId) }.map { ($0.threadId, $0) }, uniquingKeysWith: { _, last in last })
            memoryStatus = try store.workspaceMemoryStatus()
            learnedStatus = try? store.nativeMemoryStatus(spaceID: viewedSpaceID ?? store.resolvedMemorySpace(nil).id)
            memorySettings = try store.memorySettings()
            checkPlans = try store.checkPlans().filter { ids.contains($0.taskId) }
            blockers = try store.blockers().filter { ids.contains($0.taskId) }; readinessPlans = try store.readinessPlans().filter { ids.contains($0.taskId) }
            waits = Self.byTask(try store.waits(), \.taskId, in: ids)
            latestResults = Self.byTask(try store.latestResults(), \.taskId, in: ids)
            headlines = Self.byTask(try store.headlines(), \.taskId, in: ids)
            recaps = Self.byTask(try store.recaps(), \.taskId, in: ids)
            waitOptions = Self.byTask(try store.waitOptions(), \.taskId, in: ids)
            nextSteps = Self.byTask(try store.nextSteps(), \.taskId, in: ids)
            ownSteps = Self.byTask(try store.ownSteps(), \.taskId, in: ids)
            handedOver = try store.handedOverTasks().intersection(ids)
            links = try store.links().filter { ids.contains($0.taskId) }; decisions = try store.decisions().filter { ids.contains($0.taskId) }
            memories = try store.allMemory()
            if let viewed = viewedSpaceID, !memorySpaces.contains(where: { $0.id == viewed }) { viewedSpaceID = nil }
            viewedMemories = try viewedSpaceID.map { try store.allMemory(spaceID: $0) } ?? memories
            groups = try store.groups()
            groupMembers = Dictionary(try store.groupMembers().map { ($0.taskId, $0.groupId) }, uniquingKeysWith: { first, _ in first })
            taskPlaces = try store.boardPlaces()
            groupFolders = try store.groupFolders()
            groupSources = try store.groupSources()
            planLines = try store.planLines()
            readMarks = try store.readMarks()

            taskContext = try selection.flatMap { try store.latestDispatchContext(taskId: $0) }
            timeline = try selection.map { try store.events(taskId: $0) } ?? []
            let report = try selection.flatMap { try store.latestEvent(taskId: $0, kind: "codex.result") }
            result = report?.payload; resultReportedAt = report?.at
        }
        writeHeadlines()
        loadCovers(); paintMissingCovers()
    }
    /// One record per task of this workspace, the first one each task has.
    private static func byTask<Record>(_ records: [Record], _ taskID: KeyPath<Record, String>, in ids: Set<String>) -> [String: Record] {
        Dictionary(records.filter { ids.contains($0[keyPath: taskID]) }.map { ($0[keyPath: taskID], $0) }, uniquingKeysWith: { first, _ in first })
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    /// Every write posts a notification, so a poll or another process's burst of writes arrives as many at once.
    /// They are read in one go, a moment later, instead of reloading everything for each.
    func refreshSoon() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    func select(_ id: String?, reviewed: Bool = false) {
        selection = id
        if reviewed, let id { markReviewed(id) }
        refresh()
    }
    func markReviewed(_ id: String) {
        let now = Date()
        readMarks[id, default: TaskReadMark()].seenAt = now
        perform { try store.markSeen([id: now]) }
    }
    /// Only work coming back finished makes a task new again; renames, moves and other edits do not.
    func hasReviewed(_ task: FaciendaTask) -> Bool { readMarks[task.id]?.isNew != true }
    /// New means finished since the user last opened it. Work underway and closed tasks never count.
    func isUnread(_ task: FaciendaTask) -> Bool {
        task.state.isOpen && !hasReviewed(task) && !belongs(task, to: .processing)
    }
    /// When the task's work last came back finished.
    func cameBack(_ task: FaciendaTask) -> Date? { readMarks[task.id]?.finishedAt }
    /// Steps to the next (+1) or previous (-1) task that has a decision waiting, wrapping around.
    func stepDecision(_ step: Int) {
        guard !decisions.isEmpty else { return }
        let ids = decisions.map(\.taskId)
        let index = ids.firstIndex(of: selection ?? "") ?? (step > 0 ? -1 : 0)
        guard let task = tasksByID[ids[((index + step) % ids.count + ids.count) % ids.count]] else { return }
        showTask(task)
    }
    /// ⇧⌘↩: the decision card the open task panel shows, only when it is the one thing there to answer. A permission is
    /// always answered by hand, and with several cards or a Codex request beside it the shortcut could answer one the user is not reading.
    var acceptableDecision: Decision? {
        guard destination != .inbox, let task = selectedTask, codexApprovals[task.id]?.isEmpty != false else { return nil }
        return Self.acceptable(decisions(for: task.id))
    }
    static func acceptable(_ decisions: [Decision]) -> Decision? {
        let cards = decisions.filter { $0.kind != "completion" }
        guard cards.count == 1, let card = cards.first, card.kind != "permission",
              !card.recommendation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return card
    }
    func acceptRecommendation() {
        guard let decision = acceptableDecision else { return }
        answer(decision, text: decision.recommendation)
    }
    /// ⇧⌘E: finishes the selected task, if it is open.
    func completeSelection() {
        guard let task = tasks.first(where: { $0.id == selection }), task.state.isOpen else { return }
        complete(task)
    }
    func compose() {
        search = ""; destination = .inbox; selection = nil; composerFocusRequest += 1
    }
    /// The task lists are the board with only their state's chip on; the board turns them on and clears the request.
    /// The dashboard itself keeps the chips as they are.
    func showBoard(_ list: Destination) {
        search = ""; destination = .dashboard; selection = nil
        if list != .dashboard { requestedList = list }
    }
    /// Settings on one pane, such as Memory, which lives there rather than on a page of its own.
    func openSettings(_ pane: SettingsPane = .general) {
        settingsPane = pane; showSettings = true
    }
    /// A task opens in its panel beside the board.
    func showTask(_ task: FaciendaTask) {
        search = ""; destination = .dashboard
        select(task.id)
    }
    /// Ends the spotlight; the group's sheet folds back into its card.
    func releaseSpotlight() { omnibarGroup = nil }
}
