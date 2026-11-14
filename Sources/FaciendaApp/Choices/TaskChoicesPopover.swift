import SwiftUI
import FaciendaCore

/// What to do next with a task, in three sections:
/// Continue (the agent keeps going), Pause (until the agent sees something, or until I've done something), and Done.
/// Once the user has taken a step on, the Pause section asks whether it is done.
/// A popover on a plan line or in Goals; on the board it is the dock of the opened task, under what the agent said.
struct TaskChoicesPopover: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    /// Under the opened task's conversation: a field to answer in, one suggestion at most, and pausing and finishing
    /// kept small. Sending an answer goes back to the board; after any other choice the dock stays and says what
    /// became of the task.
    var dock = false
    /// The dock shows the ways to pause only once asked.
    @State private var pausing = false
    let done: () -> Void
    let parked: (FaciendaTask, String) -> Void
    let dismiss: () -> Void
    /// What the dock does once an answer is on its way.
    var afterSend: () -> Void = {}
    /// The suggestion that filled the field, as it was put there. Sent unchanged it counts as a suggestion taken; once
    /// the user edits it, the words are theirs.
    @State private var filled: String?
    /// What was last sent from here, for the dock's line on what became of it.
    @State private var sent: String?
    /// The Pause choice whose field is open.
    @State private var opened: Opened?
    @State private var message = ""
    /// Pictures and files that go with the answer: pasted, dropped or picked in the dock.
    @State private var files: [URL] = []
    @State private var dropping = false
    @State private var picking = false
    /// The files are being copied into the task's folder; nothing else is sent meanwhile.
    @State private var sending = false
    @State private var stepText = ""
    @State private var suggestedStep = ""
    @State private var reading = false
    @State private var moves: [MemoryMove] = []
    @State private var situation = ""
    @State private var routine: MemoryRoutine?
    @State private var routineIndex = 0
    @State private var availableRoutines: [MemoryRoutine] = []
    @State private var reviewingRoutineStep = false
    @State private var sentMove: MemoryMove?
    @State private var checkingSentMove = false
    /// What the typed step was read as, and the text it was read from.
    @State private var readBack: (step: String, at: Date?, from: String)?
    @State private var note = ""
    /// One mic per field, so only the field being dictated into shows it listening.
    @State private var messageMic = Dictation()
    @State private var stepMic = Dictation()
    @State private var noteMic = Dictation()
    /// Where the caret is in each field, so Shift-Return breaks the line there.
    @State private var carets: [Field: TextSelection] = [:]
    /// How tall each field's text is. The popover follows an explicit height, but not text wrapping inside a field.
    @State private var heights: [Field: CGFloat] = [:]
    @FocusState private var focus: Field?
    private enum Field { case message, step, note }
    private enum Opened { case watch, need, notYet }

    init(model: AppModel, task: FaciendaTask, dock: Bool = false, done: @escaping () -> Void, parked: @escaping (FaciendaTask, String) -> Void, dismiss: @escaping () -> Void,
         afterSend: @escaping () -> Void = {}) {
        self.model = model; self.task = task; self.dock = dock; self.done = done; self.parked = parked; self.dismiss = dismiss; self.afterSend = afterSend
        if model.demo {
            if dock { _files = State(initialValue: AppDelegate.demoReplyFiles) }
            let suggestions = (try? model.store.suggestedMoves(taskID: task.id)) ?? []
            _moves = State(initialValue: suggestions)
            _situation = State(initialValue: suggestions.first.flatMap { try? model.store.situationName($0.situationId) } ?? "")
        }
    }

    private var agent: String { model.agent(for: task).name }
    private var hasChat: Bool { model.resultLink(for: task) != nil }
    /// A message already on its way; the chat takes one at a time.
    private var queued: Bool { model.pendingDispatch(for: task.id) != nil }
    /// Running, or a message on its way: the board's In progress.
    private var running: Bool { model.belongs(task, to: .processing) }
    /// Enter belongs to the highlighted row only while nothing else has the keyboard.
    private var enterFree: Bool { focus == nil && opened == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: dock ? 10 : 4) {
            if dock { standing }
            if let move = sentMove {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Reply sent. Keep it as a move?").font(.system(size: 12, weight: .medium))
                    Text(move.text).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    HStack {
                        Button("Keep") { if let space = try? model.store.memorySpace(forTask: task.id).id { model.perform { try model.store.acceptMove(move.id, spaceID: space) } }; sentMove = nil; dismiss() }
                        Button("Not now") { sentMove = nil; dismiss() }
                    }.buttonStyle(QuietButton())
                }.padding(10)
            } else if checkingSentMove { Text("Reply sent").font(.caption).foregroundStyle(Palette.muted).padding(10) }
            if !task.state.isOpen {
                if hasChat, !dock { openRow(tint: nil) }
                ChoiceRow(title: "Reopen", symbol: "arrow.uturn.backward") { model.reopen(task); dismiss() }
                if dock, model.canOpen(task) { HStack { openButton; Spacer(minLength: 0) }.buttonStyle(DockChip()) }
            } else if let recovery = model.recoveryDispatch(for: task.id) {
                // Nothing reached the agent for certain, so there is nothing to carry on or pause yet.
                panel("Needs recovery", Palette.accent) { recoveryChoices(recovery) }
                if dock { foot(pause: false) } else { donePanel }
            } else if let step = model.ownStep(for: task) {
                if hasChat, !dock { openRow(tint: nil) }
                panel("I need to", Palette.amber) { stepChoices(step) }
                if dock { foot(pause: false) } else { donePanel }
            } else {
                // Kept while its agent was down, or its start was cancelled: it starts from here, with nothing to write again.
                if model.neverStarted(task) { panel("Start", Palette.green) { startChoices } }
                // While the agent is at it, the dock still takes the user's words: they steer the work under way.
                // The popover is too small for that and only offers the chat.
                if hasChat && running { if dock { continueChoices } else { openRow(tint: nil) } }
                // Opening the chat is one way of carrying on, so it leads the Continue section.
                else if hasChat { panel(dock ? nil : "Continue", Palette.green) { if !dock { openRow(tint: Palette.green) }; continueChoices } }
                else if model.canOpen(task), !dock { ChoiceRow(title: "Open", symbol: "arrow.up.right") { model.open(task); dismiss() } }
                if !hasChat && !running && !model.linkedChats(for: task).isEmpty { panel("Continue", Palette.green) { linkedChatRows } }
                // With a chat, the dock's actions sit inside the field's box; only a task without one needs a foot.
                if dock { if !hasChat { foot(pause: task.state != .running) } } else {
                    if task.state != .running { panel("Pause", Palette.amber) { pauseChoices } }
                    donePanel
                }
            }
        }.padding(dock ? 0 : 6).frame(width: dock ? nil : 300).background(dock ? Color.clear : Palette.paper)
            .task { await model.lookUpLinkedChatTitles(for: task) }
            .task(id: model.learnedStatus) {
                // The dock offers no moves, so there are none to look up.
                guard !dock else { return }
                // A result that arrived since the last sweep is read now, rather than showing moves for the one before.
                if !model.demo, model.memorySettings?.enabled == true { try? await MemoryMoveLearner(store: model.store).offerLatest(taskID: task.id) }
                moves = (try? model.store.suggestedMoves(taskID: task.id)) ?? []
                situation = moves.first.flatMap { try? model.store.situationName($0.situationId) } ?? ""
            }
            .task { if !dock { loadRoutine() } }
            // The opened task is there to be answered, so the caret waits in the field.
            .task { if dock, hasChat, !running, model.ownStep(for: task) == nil { focus = .message } }
            .onDisappear { messageMic.cancel(); stepMic.cancel(); noteMic.cancel() }
    }

    private func openRow(tint: Color?) -> some View {
        ChoiceRow(title: "Open in \(agent)", symbol: "arrow.up.right", tint: tint) { model.open(task); dismiss() }
    }

    // MARK: Continue: the agent keeps going

    /// The popover's ways to carry on: a kept routine, the user's own moves, and the line Facienda's model wrote.
    @ViewBuilder private var popoverSuggestions: some View {
        if let routine, routine.steps.indices.contains(routineIndex) {
            let step = routine.steps[routineIndex]
            Text("\(routine.name) · step \(routineIndex + 1) of \(routine.steps.count)").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 10)
            ChoiceRow(title: step.text, detail: step.mode == .ask ? "Review this step" : "Your kept routine", symbol: step.action == .yourStep ? "person" : "arrow.right") {
                if step.mode == .ask && !reviewingRoutineStep { reviewingRoutineStep = true }
                else { runRoutineStep(step) }
            }.disabled(queued || model.demo)
            if reviewingRoutineStep {
                Button(step.action == .message ? "Send these words" : "Confirm step") { runRoutineStep(step) }.buttonStyle(QuietButton()).padding(.horizontal, 10)
            }
        } else if !availableRoutines.isEmpty {
            Menu("Start a routine") {
                ForEach(availableRoutines) { item in Button(item.name) { model.perform { try model.store.startMemoryRoutine(item.id, taskID: task.id) }; loadRoutine() } }
            }.menuStyle(.borderlessButton).padding(.horizontal, 10)
        }
        if !moves.isEmpty {
            Text("Your next move · \(situation)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.horizontal, 10)
            ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
                ChoiceRow(title: shown(move.text), detail: move.stage == .accepted ? "\(move.seen) times · \(move.used) used" : "Keep this as a move? · seen \(move.seen) times", symbol: move.isYourStep ? "person" : "arrow.turn.down.right", tint: Palette.green) {
                    if move.stage != .accepted {
                        if let space = try? model.store.memorySpace(forTask: task.id).id {
                            model.perform { try model.store.acceptMove(move.id, spaceID: space, isYourStep: move.isYourStep) }
                            moves = (try? model.store.suggestedMoves(taskID: task.id)) ?? []
                        }
                    } else if move.isYourStep {
                        suggestedStep = move.text; stepText = move.text; opened = .need
                    } else if model.tell(task, move.text) {
                        try? model.store.recordMoveUse(move.id, taskID: task.id); dismiss()
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .option)
                .disabled(queued || model.demo)
                .help(move.stage == .accepted ? move.isYourStep ? "Your part; opens the step for you to confirm" : "Send your exact words" : "Keep this as a move; this click does not send it")
            }
            Text("Other suggestion").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 10)
        }
        // The label says what the agent will do; the whole message waits under the pointer, as it read like a page in the popover.
        // A model wrote it, so it is sent only by a click on it, never by Enter.
        if let next = model.continuation(for: task), let label = next.label, let instruction = next.instruction {
            ChoiceRow(title: CodexApproval.visible(label), symbol: "arrow.turn.down.right", tint: Palette.green, accent: Palette.green) {
                if model.reply(to: task, text: instruction, reveal: false, userAuthored: false) { dismiss() }
            }
            // A demo snapshot draws it as the real app does; the demo itself never sends.
            .disabled(queued || (model.demo && !CommandLine.arguments.contains("--snapshot")))
            .help(queued ? "A message is already on its way to \(agent)." : "Sends \(agent) this:\n" + CodexApproval.visible(instruction))
        } else if model.writingContinuation(for: task) {
            ChoiceProgress(text: "Reading the chat…")
        }
    }

    @ViewBuilder private var continueChoices: some View {
        // A suggestion belongs to a finished turn; while the agent works it would answer a question no longer asked.
        if dock { if !running { dockSuggestion } } else { popoverSuggestions }
        linkedChatRows
        if dock, !files.isEmpty { AttachmentChips(urls: files) { url in files.removeAll { $0 == url } }.disabled(sending) }
        if dock {
            let pause = task.state != .running
            if pause, pausing { pauseChoices }
            composer(pause: pause)
        } else {
            field(messagePrompt, text: $message, focus: .message, submit: send).disabled(queued || model.demo || sending)
        }
    }

    /// The dock's answer and its actions in one round box, as in a chat composer: the words on top, finishing and
    /// pausing at its lower left, the whole chat and sending at its lower right. Loose buttons under the field looked
    /// unarranged to the user, with Done not first.
    private func composer(pause: Bool) -> some View {
        let busy = queued || model.demo || sending
        let shape = RoundedRectangle(cornerRadius: 20)
        let box = VStack(alignment: .leading, spacing: 8) {
            input(messagePrompt, text: $message, focus: .message, mic: messageMic, submit: send)
                .padding(.leading, 5).padding(.trailing, 4).disabled(busy)
            HStack(spacing: 4) {
                footActions(pause: pause)
                Spacer(minLength: 8)
                if model.canOpen(task) { openButton.disabled(model.demo) }
                ChatModelMenu(model: model, task: task)
                Group {
                    MicButton(dictation: messageMic, size: 12) { focus = .message; messageMic.toggle(into: $message, vocabulary: model.dictationVocabulary) }
                    paperclip
                    sendButton
                }
                .disabled(busy)
            }
            .buttonStyle(DockChip())
        }
        .padding(.leading, 9).padding(.trailing, 8).padding(.top, 11).padding(.bottom, 8)
        .background(Palette.card, in: shape)
        .overlay(shape.strokeBorder(focus == .message || dropping ? Palette.blue.opacity(0.6) : Palette.line, lineWidth: 1))
        // The whole box is the field: a click in its empty part puts the caret in the words.
        .contentShape(shape)
        .onTapGesture { if !busy { focus = .message } }
        return takingFiles(box)
    }

    /// What the field takes depends on where the agent is. Claude reads a message while it works; Codex keeps it in
    /// its queue and starts it once the turn under way ends, so the field says so rather than promise a steer.
    private var messagePrompt: String {
        guard dock else { return "Or tell the agent…" }
        if queued { return "Your last message is on its way…" }
        if running { return model.agent(for: task) == .claude ? "Steer \(agent)…" : "Tell \(agent), for after this turn…" }
        return "Answer \(agent)…"
    }

    /// Send is a round arrow in the field. A word button beside it, as before, looked out of place under the chat.
    private var sendButton: some View {
        Button { messageMic.finishing(send) } label: {
            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(canSend ? Palette.paper : Palette.muted)
                .frame(width: 22, height: 22).background(Circle().fill(canSend ? Palette.blue : Palette.line)).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!canSend).help("Send to \(agent) (Return)").accessibilityLabel("Send")
    }

    /// The way into the whole chat, on the row with Pause and Done: in the task's bar the user found it too far off.
    private var openButton: some View {
        Button { model.open(task) } label: {
            HStack(spacing: 5) {
                ProviderMark(provider: model.agent(for: task), size: 12)
                Text("Open in \(agent)")
            }
        }
        .keyboardShortcut("o", modifiers: .command).help("Open the whole chat in \(agent) (⌘O)")
    }

    /// An answer can be words, files or both.
    private var canSend: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }

    /// The dock's answer takes pasted or dropped pictures and files, as the top bar does for a new task. A popover is
    /// too small to hold them.
    @ViewBuilder private func takingFiles(_ row: some View) -> some View {
        if dock {
            let focus = $focus
            row.takesAttachments(focused: { focus.wrappedValue == .message }, dropping: $dropping) { urls, dropped in
                attach(urls)
                if dropped { focus.wrappedValue = .message }
            }
        } else { row }
    }

    /// Adds files to the answer, once each. Folders are left out: an answer attaches files.
    private func attach(_ urls: [URL]) {
        for url in urls where url.isFileURL && !files.contains(url) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
            files.append(url)
        }
    }

    /// The paperclip in the dock's field, as beside the top bar's mic.
    private var paperclip: some View {
        Button { picking = true } label: {
            Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(files.isEmpty ? Palette.muted : Palette.blue)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Attach images, video, audio or documents · or paste or drop them here")
        .accessibilityLabel("Attach files")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): attach(urls); focus = .message
            case let .failure(error): model.error = error.localizedDescription
            }
        }
    }

    /// A question the agent put with its own answers, or a permission it waits for. Those are answered on the question
    /// itself, above the dock, so the dock suggests nothing beside them.
    private var asked: Bool {
        !(model.codexApprovals[task.id] ?? []).isEmpty || model.decisions(for: task.id).contains { $0.kind != "completion" }
    }

    /// One suggestion at most: the agent's own recommendation for this turn, or none. Facienda's model once filled in
    /// when the agent recommended nothing, but it reads the last saved answer, which can be turns older than the chat
    /// above, so it suggested reviewing the issues while the agent was asking to have a service started.
    /// It shows the very words a click sends, on one line; what the agent recommends and why wait under the pointer.
    @ViewBuilder private var dockSuggestion: some View {
        if !asked, let handover = model.handover(for: task), let recommendation = handover.recommendation {
            let reply = CodexApproval.visible(handover.reply ?? recommendation)
            // Words the user is writing, or files they added, are their answer; a click must not send something else.
            let own = canSend && !isFilled(reply)
            Suggestion(provider: model.agent(for: task), words: reply,
                       about: [recommendation == reply ? nil : recommendation, handover.why, handover.memory.map { "From memory: " + $0 }].compactMap { $0 },
                       on: isFilled(reply), send: { sendSuggestion(reply) }, edit: { toggle(reply) })
                .disabled(own || queued || model.demo || sending)
                .opacity(own ? 0.45 : 1)
                .animation(Motion.fade, value: own)
        }
    }

    /// The agent's own words, sent with one click as they show: a suggestion taken, never the user's words to learn from.
    private func sendSuggestion(_ words: String) {
        guard !sending, !queued else { return }
        if model.reply(to: task, text: words, reveal: false, userAuthored: false) { wasSent(words, own: false) }
    }

    /// A task without a chat to answer has no field, so its actions stand on their own: Done first, the chat last.
    @ViewBuilder private func foot(pause: Bool) -> some View {
        if pause, pausing { pauseChoices }
        HStack(spacing: 4) {
            footActions(pause: pause)
            Spacer(minLength: 8)
            if model.canOpen(task) { openButton.disabled(model.demo) }
        }
        .buttonStyle(DockChip())
    }

    /// Finishing first, then pausing. Each keeps the colour it has everywhere else: blue for the tick, amber for waiting.
    @ViewBuilder private func footActions(pause: Bool) -> some View {
        let dependents = model.dependents(of: task)
        Group {
            Button { done() } label: { footLabel("Done", "checkmark", Palette.blue) }
            if pause {
                Button { withAnimation(Motion.fade) { pausing.toggle(); if !pausing { opened = nil } } } label: {
                    footLabel(model.wait(for: task) == nil ? "Pause…" : "Change the wait…", "arrow.triangle.2.circlepath", Palette.amber)
                }
                .help("Let the agent watch for something, or note what you need to do first")
            }
            if !dependents.isEmpty {
                // Done would release the tasks waiting on this one; this brings them back to the user instead.
                Button("Not happening") { model.archive(task, reveal: false) }
                    .help(dependents.count == 1 ? "“\(dependents[0].displayName)” waits on this" : "\(dependents.count) tasks wait on this")
            }
        }
        .disabled(model.demo)
    }

    private func footLabel(_ title: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            Text(title)
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty, !sending else { return }
        // Words an agent wrote, sent as they stood, are a suggestion taken and not the user's own: memory learns from
        // what the user says, and must not learn an agent's wording as theirs.
        let own = text != filled?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !files.isEmpty else {
            if model.reply(to: task, text: text, reveal: false, userAuthored: own) { wasSent(text, own: own) }
            return
        }
        // Copying a long video takes a moment, so the files go off the main thread and the dock waits for them.
        let going = files
        sending = true
        Task {
            let arrived = await model.reply(to: task, text: text, files: going, userAuthored: own)
            sending = false
            guard arrived else { return }
            // The task holds its own copies now; a pasted picture's temporary file has done its work.
            OmnibarModel.discardPasted(going)
            files = []
            wasSent(text, own: own)
        }
    }

    private func wasSent(_ text: String, own: Bool) {
        sent = text.isEmpty ? nil : text; filled = nil
        // The answer is on its way and the dock has no moves to keep, so the user is back on the board for the next task.
        if dock { message = ""; afterSend() }
        // The popover asks whether a reply made before is worth keeping as a move.
        else if own { lookForRepeatedReply(text) } else { dismiss() }
    }

    /// Edit puts the suggestion in the field to change before sending, every character spelled out as it was shown.
    private func fill(_ text: String) {
        let shown = CodexApproval.visible(text)
        message = shown; filled = shown; focus = .message
    }
    private func isFilled(_ text: String) -> Bool { filled != nil && message == filled && filled == CodexApproval.visible(text) }
    /// A second click takes the suggestion out of the field again.
    private func toggle(_ text: String) {
        if isFilled(text) { message = ""; filled = nil } else { fill(text) }
    }

    // MARK: The dock: what became of the task

    /// While the task waits on the user the conversation above says what it wants. Once they have answered, the dock
    /// says what became of it. It once led on to the task that had waited longest; the user wanted it gone, as the
    /// board is where the next task is picked.
    @ViewBuilder private var standing: some View {
        let dot = TaskDot.Kind(model: model, task: task)
        if !dot.waitsOnUser {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TaskDot(kind: dot)
                Text(standingLine(dot)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let sent { Text("Sent “\(shown(sent))”").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1) }
                Spacer(minLength: 8)
            }
        }
    }

    private func standingLine(_ dot: TaskDot.Kind) -> String {
        switch dot {
        case .running: return queued ? "On its way to \(agent)" : "\(agent) is working"
        case .done: return "Done"
        case .watching, .waiting: return model.wait(for: task).map(model.waitLine) ?? dot.label
        case .onYou: return model.ownStep(for: task)?.text ?? dot.label
        default: return dot.label
        }
    }

    /// A move is sent exactly as written; the row shows it on one line, cut short.
    private func shown(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }

    private func lookForRepeatedReply(_ text: String) {
        guard model.memorySettings?.enabled == true else { dismiss(); return }
        checkingSentMove = true
        Task {
            defer { checkingSentMove = false }
            do {
                try model.store.captureWorkspaceMemory()
                try await MemoryMoveLearner(store: model.store).learnPending()
                let space = try model.store.memorySpace(forTask: task.id).id
                sentMove = try model.store.memoryMoves(spaceID: space).first { $0.text == text && $0.stage == .offered }
                if sentMove == nil { dismiss() }
            } catch { model.memoryError = error.localizedDescription; dismiss() }
        }
    }

    private func loadRoutine() {
        guard let space = try? model.store.memorySpace(forTask: task.id).id else { return }
        availableRoutines = ((try? model.store.memoryRoutines(spaceID: space)) ?? []).filter { $0.state == .live }
        routine = nil
        for _ in 0..<12 {
            guard let (item, index) = try? model.store.memoryRoutineStep(taskID: task.id) else { return }
            let step = item.steps[index]
            if step.mode == .automatic && step.canBeAutomatic {
                model.perform { model.notice = try model.store.advanceMemoryRoutine(taskID: task.id, expectedStep: index, userConfirmed: false) }
            } else { routine = item; routineIndex = index; return }
        }
    }

    private func runRoutineStep(_ step: MemoryRoutine.Step) {
        let confirmed: Bool
        switch step.action {
        case .message: confirmed = model.tell(task, step.text)
        case .yourStep: confirmed = model.takeOn(task, step: step.text, at: nil)
        case .reminder: confirmed = true
        }
        guard confirmed else { return }
        model.perform { if let text = try model.store.advanceMemoryRoutine(taskID: task.id, expectedStep: routineIndex, userConfirmed: true) { model.notice = text } }
        reviewingRoutineStep = false; loadRoutine()
        if step.action != .reminder { dismiss() }
    }

    /// Chats the request or the answer links to: the task can carry on there, in place of its own chat.
    @ViewBuilder private var linkedChatRows: some View {
        ForEach(model.linkedChats(for: task), id: \.threadId) { chat in
            ChoiceRow(title: chat.title.isEmpty ? "Continue in the linked \(chat.provider.name) chat" : "Continue in “\(chat.title)”",
                      detail: "\(chat.provider.name) chat · becomes this task's chat", symbol: "arrow.triangle.swap", tint: Palette.green) {
                if model.handOver(chat, taskID: task.id) { dismiss() }
            }
            .disabled(queued || model.demo)
            .help(queued ? "A message is on its way to the current chat. Switch once it has arrived." : "Your replies and checks go to that chat from now on")
        }
    }

    // MARK: Start: a task that never reached its agent

    /// Start stays greyed with the reason while the agent is down; Claude's runner can be woken from here.
    @ViewBuilder private var startChoices: some View {
        let provider = model.agent(for: task), down = model.whyDown(provider)
        let ready = down == nil && !model.dispatching && enterFree && !model.demo
        ChoiceRow(title: "Start in \(agent)", detail: down, symbol: "play", highlighted: ready, tint: Palette.green, accent: Palette.green) {
            Task { await model.dispatch(task, reveal: false) }; dismiss()
        }
        .keyboardShortcut(ready ? .defaultAction : nil)
        .disabled(down != nil || model.dispatching || model.demo)
        if provider == .claude, down != nil, model.claudeInstalled {
            ChoiceRow(title: model.connectingClaude ? "Opening Claude…" : model.claudeConnected ? "Wake runner" : "Connect Claude",
                      symbol: "moon.zzz", tint: Palette.green) { model.requestClaudeConnection(repair: model.claudeConnected); dismiss() }
                .disabled(model.connectingClaude || model.demo)
        }
    }

    // MARK: Recovery: a delivery the runner could not confirm

    @ViewBuilder private func recoveryChoices(_ item: NativeDispatch) -> some View {
        let search = model.deliverySearches[item.id]
        let searching = search?.searching == true, proved = search?.provedMissing == true
        HStack(alignment: .top, spacing: 6) {
            if searching { ProgressView().controlSize(.mini) }
            Text(model.deliverySummary(item)).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 10).padding(.bottom, 3)
        if let chats = search?.chats, chats.count > 1 {
            ForEach(chats) { chat in
                ChoiceRow(title: "Use “\(chat.title.isEmpty ? "Untitled chat" : chat.title)”", symbol: "link", tint: Palette.accent) { model.useDeliveryChat(item, chat); dismiss() }
                    .disabled(model.demo)
            }
        }
        if item.kind != "check" {
            let ready = proved && enterFree && !model.demo
            ChoiceRow(title: proved ? "Send again" : "Send again…", detail: proved ? nil : "Asks first: it may have arrived",
                      symbol: "arrow.clockwise", highlighted: ready, tint: Palette.accent, accent: Palette.accent) { model.sendAgain(item); dismiss() }
                .keyboardShortcut(ready ? .defaultAction : nil)
                .disabled(searching || model.demo)
        }
        if model.connected, search != nil, !searching {
            ChoiceRow(title: "Search again", symbol: "magnifyingglass", tint: Palette.accent) { Task { await model.findDelivery(item) } }
        }
        ChoiceRow(title: "Drop delivery", symbol: "xmark", tint: Palette.accent) { model.cancelStart(item.id); dismiss() }
            .disabled(searching || model.demo)
            .task(id: "\(item.id):\(model.connected)") { if model.deliverySearches[item.id] == nil { await model.findDelivery(item) } }
    }

    // MARK: Pause: until the agent sees something, or until I've done something

    @ViewBuilder private var pauseChoices: some View {
        if let wait = model.wait(for: task) {
            // Already paused: say on what, and offer to end it.
            ChoiceRow(title: wait.plan.hasObservedConditions ? "Agent is watching" : "Paused", detail: model.waitLine(wait),
                      symbol: "arrow.triangle.2.circlepath", tint: Palette.amber) { opened = opened == .watch ? nil : .watch }
            ChoiceRow(title: "Stop waiting", symbol: "sun.max", tint: Palette.amber) { model.wake(task); dismiss() }
        } else {
            ChoiceRow(title: "Agent watches for…", symbol: "arrow.triangle.2.circlepath", tint: Palette.amber) { opened = opened == .watch ? nil : .watch }
        }
        if opened == .watch { WatchComposer(model: model, task: task, parked: parked, dismiss: dismiss) }
        ChoiceRow(title: "I need to…", symbol: "touchid", tint: Palette.purple) { beginNeed() }
        if opened == .need { stepComposer }
    }

    @ViewBuilder private var stepComposer: some View {
        field("What do you need to do? Add a time for a reminder", text: $stepText, focus: .step, submit: submitStep)
        if reading { ChoiceProgress(text: "Reading…") }
        if let readBack, readBack.from == stepText {
            ChoiceRow(title: readBack.step, detail: readBack.at.map { "Reminds you " + WaitChoices.when($0) } ?? "No reminder",
                      symbol: readBack.at == nil ? "touchid" : "bell", highlighted: true) { save(readBack.step, at: readBack.at) }
        }
    }

    private func beginNeed() {
        if opened == .need { opened = nil; return }
        suggestedStep = model.continuation(for: task)?.yourStep ?? ""
        stepText = suggestedStep; readBack = nil; opened = .need
        Task { try? await Task.sleep(for: .milliseconds(60)); focus = .step }
    }

    /// The suggested step goes straight in. Anything typed is read once, shown back, and Enter again saves it.
    private func submitStep() {
        let text = stepText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !reading else { return }
        if let readBack, readBack.from == stepText { save(readBack.step, at: readBack.at); return }
        if text == suggestedStep.trimmingCharacters(in: .whitespacesAndNewlines) { save(text, at: nil); return }
        reading = true
        let typed = stepText
        Task {
            let read = await model.readStep(typed, for: task)
            reading = false
            if stepText == typed { readBack = (read.step, read.at, typed) }
        }
    }

    private func save(_ step: String, at: Date?) {
        if model.takeOn(task, step: step, at: at) {
            if let move = moves.first(where: { $0.isYourStep && $0.text == step && $0.stage == .accepted }) { try? model.store.recordMoveUse(move.id, taskID: task.id) }
            dismiss()
        }
    }

    // MARK: After the user took a step on

    @ViewBuilder private func stepChoices(_ step: OwnStep) -> some View {
        let reminder = model.wait(for: task)?.plan.wakeTime.map { "Reminds you " + WaitChoices.when($0) }
        ChoiceRow(title: "Did it: " + step.text, detail: reminder, symbol: "checkmark", highlighted: enterFree) { finish() }
            .keyboardShortcut(enterFree ? .defaultAction : nil)
        if hasChat { field("Anything for the agent? (optional)", text: $note, focus: .note, submit: finish) }
        ChoiceRow(title: "Not yet, remind me…", symbol: "clock", tint: Palette.amber) { opened = opened == .notYet ? nil : .notYet }
        if opened == .notYet { WaitChoices(model: model, task: task, remindersOnly: true, parked: parked, dismiss: dismiss) }
        ChoiceRow(title: "Not doing it after all", symbol: "xmark", tint: Palette.amber) { model.dropStep(task); dismiss() }
    }

    /// Without a note the task comes back for review; with one the agent hears how it went and carries on.
    private func finish() { model.didStep(task, note: note); dismiss() }

    // MARK: Done

    private var donePanel: some View {
        let dependents = model.dependents(of: task)
        // Blue, like done on the board: apart from carrying on (green) and pausing (amber).
        return panel(nil, Palette.blue) {
            ChoiceRow(title: "Done", symbol: "checkmark", tint: Palette.blue) { done(); dismiss() }
            if !dependents.isEmpty {
                // Done would release the tasks waiting on this one; this brings them back to the user instead.
                ChoiceRow(title: "Not happening", detail: dependents.count == 1 ? "“\(dependents[0].displayName)” waits on this" : "\(dependents.count) tasks wait on this",
                          symbol: "xmark", tint: Palette.blue) { model.archive(task, reveal: false); dismiss() }
            }
        }
    }

    // MARK: Pieces

    /// One section: a faint wash of its colour, with an optional heading in that colour.
    @ViewBuilder private func panel<Content: View>(_ title: String?, _ color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        // The dock has the room to set its sections apart by place alone, so they need no wash there.
        if dock {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).padding(.bottom, 2).accessibilityAddTraits(.isHeader) }
                content()
            }
        } else { washed(title, color, content) }
    }

    private func washed<Content: View>(_ title: String?, _ color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(color)
                    .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 1).accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(.bottom, title == nil ? 0 : 3)
        // Sage green is quieter than amber, so it gets a slightly stronger wash to read as its own section.
        .background(color.opacity(color == Palette.green ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A field with a mic; Enter waits for the last spoken words before it acts, Shift-Enter starts a new line.
    private func field(_ prompt: String, text: Binding<String>, focus field: Field, submit: @escaping () -> Void) -> some View {
        let mic = microphone(field)
        return HStack(spacing: 4) {
            input(prompt, text: text, focus: field, mic: mic, submit: submit)
            MicButton(dictation: mic, size: dock ? 12 : 11) { focus = field; mic.toggle(into: text, vocabulary: model.dictationVocabulary) }
        }
            .choiceField(focused: focus == field)
            .padding(.horizontal, dock ? 0 : 4).padding(.vertical, 3)
    }

    /// The words of a field, growing to eight lines.
    private func input(_ prompt: String, text: Binding<String>, focus field: Field, mic: Dictation, submit: @escaping () -> Void) -> some View {
        let caret = Binding<TextSelection?>(get: { carets[field] }, set: { carets[field] = $0 })
        return TextField(prompt, text: text, selection: caret, axis: .vertical).textFieldStyle(.plain).font(.system(size: dock ? 13 : 12))
            .lineLimit(1...8).frame(height: heights[field])
            .background(alignment: .topLeading) {
                // A trailing line break still needs its empty line.
                Text(text.wrappedValue.isEmpty || text.wrappedValue.hasSuffix("\n") ? text.wrappedValue + " " : text.wrappedValue)
                    .font(.system(size: dock ? 13 : 12)).lineLimit(8).fixedSize(horizontal: false, vertical: true).hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[field] = $0 }
            }
            .focused($focus, equals: field)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift), !mic.isActive else { return .ignored }
                var selection = caret.wrappedValue
                text.wrappedValue.breakLine(at: &selection)
                caret.wrappedValue = selection
                return .handled
            }
            .onSubmit { mic.finishing(submit) }
            .accessibilityLabel(prompt)
    }

    private func microphone(_ field: Field) -> Dictation {
        switch field {
        case .message: messageMic
        case .step: stepMic
        case .note: noteMic
        }
    }
}

/// The one suggested reply in the opened task's dock, on one line: the agent's mark and the words a click sends. The
/// pencil puts them in the field to change first, and they are ringed while they are there. What the agent recommends,
/// why, and what in memory it rests on show under the pointer, so the dock stays short.
private struct Suggestion: View {
    let provider: AgentProvider
    let words: String
    let about: [String]
    let on: Bool
    let send: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: send) {
                HStack(spacing: 8) {
                    ProviderMark(provider: provider, size: 12).frame(width: 14)
                    Text(words).font(.system(size: 12.5, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.paper)
                        .frame(width: 18, height: 18).background(Circle().fill(Palette.green))
                }
                .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 5).contentShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .help((["Send this to \(provider.name)"] + about).joined(separator: "\n\n"))
            .accessibilityLabel("Send to \(provider.name): " + words)
            Button(action: edit) {
                Image(systemName: on ? "xmark" : "pencil").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(.plain).padding(.trailing, 4)
            .help(on ? "Take it out of the field" : "Put it in the field to change first")
            .accessibilityLabel(on ? "Take the suggestion out of the field" : "Edit the suggestion first")
        }
        .foregroundStyle(Palette.ink)
        // The sage wash of carrying on, as on the popover's Continue section.
        // Round as a capsule on one line; a longer reply keeps the same soft corners.
        .background(Palette.green.opacity(hovering ? 0.24 : 0.14), in: RoundedRectangle(cornerRadius: 13))
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(on ? Palette.green : Palette.green.opacity(0.35), lineWidth: on ? 1.5 : 1))
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: on)
        .animation(Motion.fade, value: hovering)
    }
}

/// The dock's actions: soft round chips, the same round family as the field around them.
private struct DockChip: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.ink)
            .padding(.leading, 9).padding(.trailing, 11).frame(height: 26)
            .background(Palette.ink.opacity(configuration.isPressed ? 0.1 : 0.05), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}
