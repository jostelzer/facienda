import SwiftUI
import FaciendaCore
import FaciendaBridge

extension AppDelegate {
    /// `--snapshot PATH`: draws one screen with the demo library into a PNG and quits, without a window on screen.
    /// Further flags pick the screen, such as `--plan`, `--settings` or `--task-choices`, `--dark` the palette, and
    /// `--usage` adds sample plan limits to the sidebar.
    func snapshot(path: String) {
        do {
            // `--library-folder DIR`: a throwaway copy of that library, seen from `--workspace NAME`. The copy keeps every
            // change the snapshot makes away from the library itself.
            var model: AppModel
            if let folder = Self.values("--library-folder").first {
                let copy = FileManager.default.temporaryDirectory.appending(path: "FaciendaSnapshot/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: folder), to: copy.appending(path: ".facienda"))
                let store = try FaciendaStore(url: copy.appending(path: ".facienda/facienda.sqlite"))
                var target = try store.defaultWorkspace()
                if let name = Self.values("--workspace").first, let named = try store.workspaces().first(where: { $0.name == name }) { target = named }
                model = try AppModel(demo: true, seed: false, store: store.scoped(to: target.id), codex: CodexConnection(demo: true), startDispatcher: { _ in })
                try videoStory(model)
                model.loadCovers()
            } else { model = try AppModel(demo: true) }
            if CommandLine.arguments.contains("--usage") {
                model.snapshotUsage = [
                    PlanUsage(agent: "Codex", plan: "Pro", windows: [.init(minutes: 10080, usedPercent: 16, resetsAt: nil)], limitReached: false),
                    PlanUsage(agent: "Claude", plan: "Max", windows: [.init(minutes: 300, usedPercent: 23, resetsAt: nil), .init(minutes: 10080, usedPercent: 8, resetsAt: nil)], limitReached: false)
                ]
            }
            if let index = CommandLine.arguments.firstIndex(of: "--conversation-fixture"), CommandLine.arguments.indices.contains(index + 1) {
                let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let data = try Data(contentsOf: fixture)
                let conversation = try JSONDecoder().decode(CodexConversation.self, from: data)
                let context = try JSONDecoder().decode(JSONValue.self, from: data)
                let request = context["originalRequest"].string ?? conversation.turns.flatMap {
                    $0.messages(originalRequest: "", dispatches: [])
                }.first(where: { $0.role == .user })?.text ?? conversation.title
                let task = try model.store.importThread(originalRequest: request, title: conversation.title, cwd: "", conversation: conversation)
                model.select(task.id)
                if context["dispatches"] != .null {
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    var dispatches = try decoder.decode([NativeDispatch].self, from: JSONEncoder().encode(context["dispatches"]))
                    for index in dispatches.indices { dispatches[index].taskId = task.id }
                    model.nativeDispatches = dispatches
                }
            }
            let workspaces = WorkspaceController(demo: true, load: false)
            workspaces.install(model)
            if let title = Self.values("--select").first { model.select(model.tasks.first { $0.title == title }?.id) }
            if let name = Self.values("--sheet").first { model.omnibarGroup = model.groups.first { $0.name == name }?.id }
            // `--islands`: a few more workspaces with work running and work that came back, to see the sidebar's island
            // with several planets.
            if CommandLine.arguments.contains("--islands") {
                let library = model.store.library
                for (name, fresh, running) in [("Studio", 3, 1), ("Garden", 0, 2), ("Travel", 1, 0), ("Lab", 2, 1)] {
                    let workspace = try library.createWorkspace(name: name)
                    for index in 0..<fresh {
                        _ = try library.scoped(to: workspace.id).create(FaciendaTask(title: "Came back \(index + 1)", state: .needsMe, nextAction: "Review"))
                    }
                    for index in 0..<running {
                        _ = try library.scoped(to: workspace.id).create(FaciendaTask(title: "Working \(index + 1)", state: .running, nextAction: "Wait"))
                    }
                }
                workspaces.reload()
            }
            if let index = CommandLine.arguments.firstIndex(of: "--section"), CommandLine.arguments.indices.contains(index + 1),
               let section = Destination(rawValue: CommandLine.arguments[index + 1]) {
                if TaskDot.Kind.legend(for: section).isEmpty { model.destination = section }
                else {
                    // A task list is the board with its chip on, and its first task in the panel.
                    model.showBoard(section)
                    model.select(model.tasks.first { model.belongs($0, to: section) }?.id)
                }
            }
            let scheme: ColorScheme = CommandLine.arguments.contains("--dark") ? .dark : .light
            let setup = OnboardingModel()
            if CommandLine.arguments.contains("--setup-codex") {
                model.connected = true; model.accountReady = true
                setup.model = model; setup.dataFolder = model.store.workFolder; setup.step = 1
            }
            if CommandLine.arguments.contains("--setup-claude") || CommandLine.arguments.contains("--setup-claude-waiting") {
                model.connected = true; model.accountReady = true
                model.claudeSetupOpened = CommandLine.arguments.contains("--setup-claude-waiting")
                setup.model = model; setup.dataFolder = model.store.workFolder; setup.step = 2
            }
            if CommandLine.arguments.contains("--setup-models") {
                model.connected = true; model.accountReady = true; model.loadServiceModel()
                setup.model = model; setup.dataFolder = model.store.workFolder; setup.step = 3
            }
            if CommandLine.arguments.contains("--setup-hooks") {
                // Codex is connected; only the hooks wait for the user's trust.
                _ = try model.store.prepareWorkspaceSetup()
                try model.store.bindCodexDispatcher()
                try model.store.verifyDispatcherSetup(projectId: "project")
                model.connected = true; model.accountReady = true; model.codexHooksTrusted = false
                model.refresh()
                setup.model = model; setup.dataFolder = model.store.workFolder; setup.step = 1
            }
            if CommandLine.arguments.contains("--plan"),
               let group = model.groups.first(where: { group in model.tasks.contains { model.groupMembers[$0.id] == group.id } }) {
                // A goal with steps, one of them already started, and a loose line still to start.
                let goal = try model.store.addPlanLine(groupId: group.id, text: "Make the studio a calm place to work")
                let started = try model.store.addPlanLine(groupId: group.id, parentId: goal.id, text: "Choose a desk")
                if let task = model.tasks.first(where: { model.groupMembers[$0.id] == group.id }) { try model.store.linkPlanLine(started.id, taskId: task.id) }
                _ = try model.store.addPlanLine(groupId: group.id, parentId: goal.id, text: "Find a warm desk lamp that doesn't glare on the screen")
                _ = try model.store.addPlanLine(groupId: group.id, parentId: goal.id, text: "Hang the acoustic panels")
                _ = try model.store.addPlanLine(groupId: group.id, text: "Sort out the cable mess behind the shelf")
                UserDefaults.standard.register(defaults: ["dashboardMode": DashboardMode.plan.rawValue, "planGroup:" + model.storageKey: group.id])
                model.refresh()
            }
            // `--sources`: a group with a work folder, linked documents and an agent's proposal; `--sources-popover` draws its popover.
            var sourcesGroup: TaskGroup?
            if CommandLine.arguments.contains("--sources"),
               let group = model.groups.first(where: { group in model.tasks.contains { model.groupMembers[$0.id] == group.id } }),
               let task = model.tasks.first(where: { model.groupMembers[$0.id] == group.id }) {
                let folder = FileManager.default.temporaryDirectory.appending(path: "facienda-demo/studio-plans")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try model.store.linkFolder(folder.path, groupId: group.id)
                try model.store.linkSource("https://drive.google.com/drive/folders/demo-quotes", title: "Furniture quotes", groupId: group.id)
                try model.store.linkSource("https://docs.google.com/spreadsheets/d/demo-budget/edit", title: "Studio budget", groupId: group.id)
                try model.store.linkSource("https://docs.google.com/document/d/demo-brief/edit", title: "Room brief", groupId: group.id)
                try model.store.linkSource("https://www.ikea.com/pt/en/cat/desks-20649/", title: "Desk shortlist", groupId: group.id)
                try model.store.proposeSource("https://docs.google.com/spreadsheets/d/demo-lighting/edit", title: "Lighting quotes", note: "Every lamp task asks for these prices.", taskId: task.id)
                model.refresh()
                sourcesGroup = model.groups.first { $0.id == group.id }
            }
            // `--memory`: the Memory page with a source the user described, a proposed source and a proposed rule from an agent.
            if CommandLine.arguments.contains("--memory"), let loose = model.tasks.first(where: { model.groupMembers[$0.id] == nil }) {
                #if DEBUG
                try model.store.seedMemoryDemo(spaceID: model.store.memorySpace(forTask: loose.id).id, taskID: loose.id)
                #endif
                let budget = try model.store.linkWorkspaceSource("https://docs.google.com/spreadsheets/d/demo-household/edit", title: "Household budget")
                try model.store.setSourceAbout(budget.id, "Monthly totals and what is already committed. Read it before quoting a price.")
                try model.store.linkWorkspaceSource("https://docs.google.com/document/d/demo-addresses/edit", title: "Addresses and opening hours")
                try model.store.proposeSource("https://docs.google.com/document/d/demo-travel/edit", title: "Travel notes", note: "Every trip task reads these.", taskId: loose.id)
                try model.store.remember(MemoryFact(kind: FaciendaStore.ruleKind, text: "Compare at least two shops before recommending one.", taskId: loose.id, source: "Demo proposal — illustrative data"))
                // Set rather than registered: a board mode saved by an earlier run would otherwise win.
                UserDefaults.standard.set(DashboardMode.memory.rawValue, forKey: "dashboardMode")
                model.settingsPane = .memory
                model.refresh()
            }
            var content = CommandLine.arguments.contains("--setup")
                ? AnyView(OnboardingView(setup: setup, onComplete: { _ in })) : AnyView(DashboardView(model: model, workspaces: workspaces, query: Self.values("--query").first ?? "", sheetDraft: Self.values("--sheet").isEmpty ? nil : Self.values("--query").first ?? ""))
            if CommandLine.arguments.contains("--claude-runner") {
                let setup = try model.store.prepareClaudeSetup()
                try model.store.bindClaudeRunner(sessionId: "local_demo-runner", challenge: setup.challenge, canStartSessions: false)
                model.refresh()
            }
            if CommandLine.arguments.contains("--claude-task") {
                var draft = FaciendaTask(title: "Draft the venue email for the autumn workshop", state: .inbox, nextAction: "Write the draft")
                draft.workerModel = "claude-opus-5-5"; draft.workerReasoningEffort = "high"; draft.workerProvider = .claude
                let task = try model.store.create(draft)
                try model.store.handOffToClaudeComposer(try model.store.enqueueDispatch(taskId: task.id).id)
                model.select(task.id)
            }
            if CommandLine.arguments.contains("--model-chooser") {
                model.composerModel = CommandLine.arguments.contains("--codex") ? TaskModelChoice(model: "gpt-6.1-sol", effort: "xhigh", fast: true) : .claudeStandard
                content = AnyView(ModelChoicePanel(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--omnibar-attachments") {
                // A screenshot pasted through the same path as ⌘V, beside a document picked with the paperclip.
                let omnibar = OmnibarModel(model: model, workspaces: workspaces)
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("facienda-demo-paste"))
                pasteboard.clearContents()
                pasteboard.setData(NSImage(named: "BrandIcon")?.tiffRepresentation, forType: .tiff)
                _ = omnibar.pasteAttachments(from: pasteboard)
                let document = FileManager.default.temporaryDirectory.appending(path: "facienda-demo/Studio brief.pdf")
                try FileManager.default.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("%PDF-1.4".utf8).write(to: document)
                omnibar.attach([document])
                omnibar.query = "Make the board look like this"
                content = AnyView(OmnibarField(omnibar: omnibar, spare: 400, reach: 600)
                    .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Palette.paper))
            }
            // `--window`: the whole window with its island; `--island x,y,w,h` gives the island's width as the third fraction of the window.
            if CommandLine.arguments.contains("--window") {
                let index = CommandLine.arguments.firstIndex(of: "--island")
                let island = index.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
                // `--feed` opens what came in over the island and the board.
                if CommandLine.arguments.contains("--feed") { workspaces.feed.open() }
                content = AnyView(WorkspaceWindow(model: model, workspaces: workspaces, fixedIsland: island))
            }
            if CommandLine.arguments.contains("--settings") { content = AnyView(SettingsView(model: model)) }
            if CommandLine.arguments.contains("--sources-popover"), let group = sourcesGroup {
                content = AnyView(SourcesPopover(model: model, group: group, folders: model.groupFolders[group.id] ?? [], sources: model.groupSources[group.id] ?? [])
                    .background(Palette.card).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 20).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--claude-settings") {
                content = AnyView(RunnersPane(model: model).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--runner-guide") {
                let kind: RunnerKind = CommandLine.arguments.contains("--codex") ? .codex : .claude
                content = AnyView(ScrollView { RunnerSetupGuide(model: model, kind: kind, back: {}).padding(32) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--task-choices") {
                // A reviewed task with a chat, its suggested continuation, and optionally a step the user took on.
                let task = try model.store.create(FaciendaTask(title: "A quieter home office", state: .running, nextAction: "Choose a desk"))
                try model.store.link(ThreadLink(taskId: task.id, codexThreadId: "demo-desk", title: task.title))
                try model.store.saveResult(taskId: task.id, text: "The oak desk fits the room and has cable management. Nothing ordered yet.")
                #if DEBUG
                if CommandLine.arguments.contains("--moves") { try model.store.seedMemoryDemo(spaceID: model.store.memorySpace(forTask: task.id).id, taskID: task.id) }
                #endif
                if let source = try model.store.latestResults().first(where: { $0.taskId == task.id }) {
                    try model.store.saveNextSteps(StoredNextSteps(taskId: task.id, eventId: source.eventId, label: "Compare oak desk delivery dates", instruction: "Compare delivery dates for the oak desk at the three shops and tell me which is fastest.", yourStep: "Measure the alcove before ordering", at: Date()))
                }
                if CommandLine.arguments.contains("--own-step") { try model.store.takeOn(task.id, step: "Call the landlord", remindAt: Date().addingTimeInterval(86400)) }
                if CommandLine.arguments.contains("--watch"), let source = try model.store.latestResults().first(where: { $0.taskId == task.id }) {
                    let watch = WaitPlan(conditions: [.observed("Robin", source: "Gmail, thread 'Lighting quote'", criterion: "Robin replied in that thread")], summary: "Robin replies in Gmail")
                    try model.store.saveWaitOptions(taskId: task.id, eventId: source.eventId, options: [WaitCompiler.Option(label: watch.summary, plan: watch)])
                }
                model.refresh()
                let shown = try model.store.task(task.id)
                content = CommandLine.arguments.contains("--watch")
                    ? AnyView(WatchComposer(model: model, task: shown, parked: { _, _ in }, dismiss: {}).padding(6).frame(width: 300).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper))
                    : AnyView(TaskChoicesPopover(model: model, task: shown, done: {}, parked: { _, _ in }, dismiss: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--chat-choice") {
                // A Claude session found from the top bar, to start a task from or to continue a task in.
                let omnibar = OmnibarModel(model: model, workspaces: workspaces)
                let chat = ChatResult(threadId: "local_0b5e1f5a-2c1d-4a4e-9b55-6d1f3c2a9e10", title: "Venue email for the autumn workshop",
                                      cwd: "/Users/me/Projects/workshop", updatedAt: Date(), provider: .claude, cliSessionId: UUID().uuidString)
                content = AnyView(ChatChoice(omnibar: omnibar, chat: chat).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--linked-chat") {
                // An answer that found the chat this task should carry on in.
                let task = try model.store.create(FaciendaTask(title: "Find the thread where we drafted the venue email", state: .needsMe, nextAction: "Review the answer"))
                try model.store.link(ThreadLink(taskId: task.id, codexThreadId: "demo-finder", title: task.title))
                try model.store.saveResult(taskId: task.id, text: "Found it: “Venue email for the autumn workshop” (codex://threads/demo-venue-email), from 2 October. It holds the draft and the venue's last reply.")
                model.refresh()
                model.linkedChatTitles["demo-venue-email"] = "Venue email for the autumn workshop"
                content = AnyView(TaskChoicesPopover(model: model, task: try model.store.task(task.id), done: {}, parked: { _, _ in }, dismiss: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper))
            }
            if CommandLine.arguments.contains("--wait-composer"), let task = model.tasks.first(where: { model.wait(for: $0) != nil }) {
                content = AnyView(VStack(spacing: 24) {
                    TaskActionsPopover(model: model, task: task, done: {}, parked: { _, _ in }, dismiss: {})
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper))
            }
            if let title = Self.values("--choices").first, let task = model.tasks.first(where: { $0.title == title }) {
                content = AnyView(TaskChoicesPopover(model: model, task: task, done: {}, parked: { _, _ in }, dismiss: {}).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper))
            }
            if let title = Self.values("--watch").first, let task = model.tasks.first(where: { $0.title == title }) {
                content = AnyView(WatchComposer(model: model, task: task, parked: { _, _ in }, dismiss: {}).padding(6).frame(width: 300).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper))
            }
            func render(_ content: AnyView) throws {
                let root = content.environment(\.colorScheme, scheme)
                let view = NSHostingView(rootView: root)
                // `--size WxH` draws any screen at a size of its own, for pages taller than the window.
                let size = CommandLine.arguments.firstIndex(of: "--size").flatMap { index -> NSRect? in
                    guard CommandLine.arguments.indices.contains(index + 1) else { return nil }
                    let parts = CommandLine.arguments[index + 1].split(separator: "x").compactMap { Double($0) }
                    return parts.count == 2 ? NSRect(x: 0, y: 0, width: parts[0], height: parts[1]) : nil
                }
                view.frame = size ?? (CommandLine.arguments.contains("--model-chooser") ? NSRect(x: 0, y: 0, width: 400, height: 640)
                    : CommandLine.arguments.contains("--settings") ? NSRect(x: 0, y: 0, width: 820, height: 640)
                    : CommandLine.arguments.contains("--claude-settings") ? NSRect(x: 0, y: 0, width: 700, height: 640)
                    : CommandLine.arguments.contains("--runner-guide") ? NSRect(x: 0, y: 0, width: 700, height: 760)
                    : CommandLine.arguments.contains("--task-choices") || !Self.values("--choices").isEmpty || !Self.values("--watch").isEmpty ? NSRect(x: 0, y: 0, width: 360, height: 420)
                    : CommandLine.arguments.contains("--chat-choice") ? NSRect(x: 0, y: 0, width: 460, height: 560)
                    : CommandLine.arguments.contains("--linked-chat") ? NSRect(x: 0, y: 0, width: 360, height: 420)
                    : CommandLine.arguments.contains("--sources-popover") ? NSRect(x: 0, y: 0, width: 340, height: 420) : NSRect(x: 0, y: 0, width: 1040, height: 740))
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                if let size { view.frame = size; window.setContentSize(size.size) }
                view.layoutSubtreeIfNeeded()
                let capture = {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "Snapshot", code: 1) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Snapshot", code: 2) }
                    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                    NSApp.terminate(nil)
                }
                // `--settle`: let animations that start on screen (a group's sheet opening) finish first, in a window far off screen.
                if CommandLine.arguments.contains("--settle") {
                    window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderFrontRegardless()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        do { try capture() } catch { fputs("Snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
                    }
                } else { try capture() }
            }
            // `--window --bar TEXT` types into the window's bar and lets its reading land; `--return` then presses Return
            // once, and `--feed` shows the Feed afterwards.
            if CommandLine.arguments.contains("--window"), let index = CommandLine.arguments.firstIndex(of: "--bar"), CommandLine.arguments.indices.contains(index + 1) {
                let omnibar = OmnibarModel(model: model, workspaces: workspaces)
                omnibar.query = CommandLine.arguments[index + 1]
                UserDefaults.standard.set(DashboardMode.board.rawValue, forKey: "dashboardMode")
                Task { @MainActor in
                    await omnibar.refresh()
                    // `--quick` presses Return before the reading came back, as fast typing does.
                    if CommandLine.arguments.contains("--quick") { omnibar.submit() }
                    try? await Task.sleep(for: .seconds(1.6))
                    if CommandLine.arguments.contains("--return") {
                        omnibar.submit()
                        try? await Task.sleep(for: .seconds(0.6))
                        model.refresh()
                    }
                    if CommandLine.arguments.contains("--feed") { workspaces.feed.open() }
                    do { try render(AnyView(WorkspaceWindow(model: model, workspaces: workspaces, bar: omnibar).environment(\.colorScheme, scheme))) }
                    catch { fputs("Snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
                }
                return
            }
            try render(content)
        } catch { fputs("Snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }

    /// Every value given after `flag`, for flags that may repeat.
    static func values(_ flag: String) -> [String] {
        let arguments = CommandLine.arguments
        return arguments.indices.filter { arguments[$0] == flag && arguments.indices.contains($0 + 1) }.map { arguments[$0 + 1] }
    }

    /// The launch video's story on a copy of a real library: a task added to a group, what it answered,
    /// the next step and watch it offers, the watch it is parked on, and later answers.
    ///   --add "Title|state|Group"    --recap "Title|said|answer|ask" (repeatable, in order)
    ///   --next "Title|label|instruction"    --watch-option "Title|who|source|criterion|summary"    --watching Title
    private func videoStory(_ model: AppModel) throws {
        let store = model.store
        func parts(_ spec: String) -> [String] { spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        func task(_ title: String) throws -> FaciendaTask? { try store.tasks().first { $0.title == title } }
        for spec in Self.values("--add") {
            let p = parts(spec), state = p.count > 1 ? TaskState(rawValue: p[1]) ?? .running : .running
            let created = try store.create(FaciendaTask(title: p[0], state: state, nextAction: "Work on it"))
            if state == .running {
                try store.link(ThreadLink(taskId: created.id, codexThreadId: "video-" + created.id, title: created.title))
                try store.observe(threadId: "video-" + created.id, status: "active", source: .appServer, verified: true)
            }
            if p.count > 2, let group = try store.groups().first(where: { $0.name == p[2] }) { try store.assignGroup(taskId: created.id, groupId: group.id) }
        }
        // `--calm`: a quieter board for the video. Each group keeps its featured task (named by --chat or --keep), one question,
        // one waiting or scheduled task and one new idea, with one running task in every other group; the rest is dropped.
        if CommandLine.arguments.contains("--calm") {
            model.refresh()
            let featured = Set(Self.values("--chat") + Self.values("--keep"))
            var byGroup: [String: [FaciendaTask]] = [:]
            for t in try store.tasks() where t.state != .dropped { byGroup[model.groupMembers[t.id] ?? "", default: []].append(t) }
            for (index, entry) in byGroup.sorted(by: { $0.key < $1.key }).enumerated() {
                let tasks = entry.value
                var kept = Set(tasks.filter { featured.contains($0.title) }.map(\.id))
                func pick(_ match: (FaciendaTask) -> Bool) { if let t = tasks.first(where: { !kept.contains($0.id) && match($0) }) { kept.insert(t.id) } }
                if entry.key.isEmpty { pick { $0.state == .inbox } }
                else {
                    if !tasks.contains(where: { kept.contains($0.id) && $0.state == .needsMe }) {
                        pick { $0.state == .needsMe && !((try? store.decisions(taskId: $0.id)) ?? []).isEmpty }
                    }
                    if index % 2 == 0 { pick { $0.state == .running } }
                    pick { $0.state == .waiting || $0.state == .scheduled }
                    pick { $0.state == .inbox }
                }
                for t in tasks where !kept.contains(t.id) { try store.update(t.id) { $0.state = .dropped } }
            }
        }
        // `--sent "Title|message"`: the suggestion clicked, its message queued for the agent (the row says Queued).
        for spec in Self.values("--sent") {
            let p = parts(spec); guard p.count == 2, let found = try task(p[0]) else { continue }
            if (try store.links(taskId: found.id)).isEmpty { try store.link(ThreadLink(taskId: found.id, codexThreadId: "video-" + found.id, title: found.title)) }
            _ = try store.enqueueDispatch(taskId: found.id, message: p[1])
        }
        // `--chat Title`: the task's agent chat, so its choices offer to carry on in it.
        for title in Self.values("--chat") {
            if let found = try task(title), (try store.links(taskId: found.id)).isEmpty {
                try store.link(ThreadLink(taskId: found.id, codexThreadId: "video-" + found.id, title: found.title))
            }
        }
        // `--set-state "Title|state"`: a task moved on, such as one that runs again once its question is answered.
        for spec in Self.values("--set-state") {
            let p = parts(spec); guard p.count == 2, let found = try task(p[0]), let state = TaskState(rawValue: p[1]) else { continue }
            if state == .running {
                for decision in try store.decisions(taskId: found.id) { try store.answerDecision(decision.id, answer: decision.recommendation) }
                if (try store.links(taskId: found.id)).isEmpty { try store.link(ThreadLink(taskId: found.id, codexThreadId: "video-" + found.id, title: found.title)) }
                try store.observe(threadId: "video-" + found.id, status: "active", source: .appServer, verified: true)
            }
            try store.update(found.id) { $0.state = state }
        }
        var turns: [String: String] = [:]
        for (index, spec) in Self.values("--recap").enumerated() {
            let p = parts(spec); guard p.count >= 3, let found = try task(p[0]) else { continue }
            let turn = "video-\(index)"
            // The result first: a card shows a recap only when it is at least as new as the task's latest answer.
            if (try store.links(taskId: found.id)).isEmpty { try store.link(ThreadLink(taskId: found.id, codexThreadId: "video-" + found.id, title: found.title)) }
            try store.saveResult(taskId: found.id, text: p[2])
            try store.saveRecap(TaskRecap(taskId: found.id, turnId: turn, steps: [], tip: "", said: p[1].isEmpty ? nil : p[1], saidAt: Date().addingTimeInterval(-1800),
                                          answer: p[2], ask: p.count > 3 && !p[3].isEmpty ? p[3] : nil, answeredAt: Date().addingTimeInterval(-60),
                                          // A parked task shows its watch, not its last answer: that recap is older than the result.
                                          at: Date().addingTimeInterval(Self.values("--watching").contains(p[0]) ? -10 : 1)), after: turns[found.id])
            turns[found.id] = turn
            try store.update(found.id) { $0.state = .needsMe }
        }
        for spec in Self.values("--next") {
            let p = parts(spec); guard p.count >= 3, let found = try task(p[0]),
                  let source = try store.latestResults().first(where: { $0.taskId == found.id }) else { continue }
            try store.saveNextSteps(StoredNextSteps(taskId: found.id, eventId: source.eventId, label: p[1], instruction: p[2]))
        }
        for spec in Self.values("--watch-option") {
            let p = parts(spec); guard p.count >= 5, let found = try task(p[0]),
                  let source = try store.latestResults().first(where: { $0.taskId == found.id }) else { continue }
            let plan = WaitPlan(conditions: [.observed(p[1], source: p[2], criterion: p[3])], summary: p[4])
            try store.saveWaitOptions(taskId: found.id, eventId: source.eventId, options: [WaitCompiler.Option(label: p[4], plan: plan)])
            if Self.values("--watching").contains(p[0]) {
                try store.park(found.id, plan: plan)
                // The watch's first look has already happened; nothing is queued for an agent.
                for pending in try store.dispatches() where pending.taskId == found.id { try store.cancelDispatch(pending.id) }
            }
        }
        model.refresh()
    }
}
