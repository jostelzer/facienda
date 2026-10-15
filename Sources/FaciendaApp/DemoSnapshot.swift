import SwiftUI
import FaciendaCore
import FaciendaBridge

extension AppDelegate {
    /// `--snapshot PATH`: draws one screen with the demo library into a PNG and quits, without a window on screen.
    /// Further flags pick the screen, such as `--plan`, `--settings` or `--task-choices`, `--dark` the palette, and
    /// `--usage` adds sample plan limits to the sidebar.
    func snapshot(path: String) {
        do {
            let model = try AppModel(demo: true)
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
            var content = CommandLine.arguments.contains("--setup")
                ? AnyView(OnboardingView(setup: setup, onComplete: { _ in })) : AnyView(DashboardView(model: model, workspaces: workspaces))
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
                if let source = try model.store.latestResults().first(where: { $0.taskId == task.id }) {
                    try model.store.saveNextSteps(StoredNextSteps(taskId: task.id, eventId: source.eventId, label: "Compare delivery dates", instruction: "Compare delivery dates for the oak desk at the three shops and tell me which is fastest.", yourStep: "Measure the alcove before ordering", at: Date()))
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
            let root = content.environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: root)
            view.frame = CommandLine.arguments.contains("--model-chooser") ? NSRect(x: 0, y: 0, width: 400, height: 640)
                : CommandLine.arguments.contains("--settings") ? NSRect(x: 0, y: 0, width: 820, height: 640)
                : CommandLine.arguments.contains("--claude-settings") ? NSRect(x: 0, y: 0, width: 700, height: 640)
                : CommandLine.arguments.contains("--runner-guide") ? NSRect(x: 0, y: 0, width: 700, height: 760)
                : CommandLine.arguments.contains("--task-choices") ? NSRect(x: 0, y: 0, width: 360, height: 420)
                : CommandLine.arguments.contains("--chat-choice") ? NSRect(x: 0, y: 0, width: 460, height: 560)
                : CommandLine.arguments.contains("--linked-chat") ? NSRect(x: 0, y: 0, width: 360, height: 420)
                : CommandLine.arguments.contains("--sources-popover") ? NSRect(x: 0, y: 0, width: 340, height: 420) : NSRect(x: 0, y: 0, width: 1040, height: 740)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "Snapshot", code: 1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Snapshot", code: 2) }
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            NSApp.terminate(nil)
        } catch { fputs("Snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }
}
