import SwiftUI
import FaciendaCore

/// The one popover a task row opens, in three sections:
/// Continue (the agent keeps going), Pause (until the agent sees something, or until I've done something), and Done.
/// Once the user has taken a step on, the Pause section asks whether it is done.
struct TaskChoicesPopover: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    let done: () -> Void
    let parked: (FaciendaTask, String) -> Void
    let dismiss: () -> Void
    /// The Pause choice whose field is open.
    @State private var opened: Opened?
    @State private var message = ""
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

    init(model: AppModel, task: FaciendaTask, done: @escaping () -> Void, parked: @escaping (FaciendaTask, String) -> Void, dismiss: @escaping () -> Void) {
        self.model = model; self.task = task; self.done = done; self.parked = parked; self.dismiss = dismiss
        if model.demo {
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
        VStack(alignment: .leading, spacing: 4) {
            if let move = sentMove {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Reply sent. Keep it as a move?").font(.system(size: 12, weight: .medium))
                    Text(move.text).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    HStack {
                        Button("Keep") { if let space = try? model.store.memorySpace(forTask: task.id).id { model.perform { try model.store.acceptMove(move.id, spaceID: space) } }; dismiss() }
                        Button("Not now") { dismiss() }
                    }.buttonStyle(QuietButton())
                }.padding(10)
            } else if checkingSentMove { Text("Reply sent").font(.caption).foregroundStyle(Palette.muted).padding(10) }
            if !task.state.isOpen {
                if hasChat { openRow(tint: nil) }
                ChoiceRow(title: "Reopen", symbol: "arrow.uturn.backward") { model.reopen(task); dismiss() }
            } else if let recovery = model.recoveryDispatch(for: task.id) {
                // Nothing reached the agent for certain, so there is nothing to carry on or pause yet.
                panel("Needs recovery", Palette.accent) { recoveryChoices(recovery) }
                donePanel
            } else if let step = model.ownStep(for: task) {
                if hasChat { openRow(tint: nil) }
                panel("I need to", Palette.amber) { stepChoices(step) }
                donePanel
            } else {
                // While the agent is at it there is nothing to send, only its chat to look in.
                if hasChat && running { openRow(tint: nil) }
                // Opening the chat is one way of carrying on, so it leads the Continue section.
                else if hasChat { panel("Continue", Palette.green) { openRow(tint: Palette.green); continueChoices } }
                else if model.canOpen(task) { ChoiceRow(title: "Open", symbol: "arrow.up.right") { model.open(task); dismiss() } }
                if !hasChat && !running && !model.linkedChats(for: task).isEmpty { panel("Continue", Palette.green) { linkedChatRows } }
                if task.state != .running { panel("Pause", Palette.amber) { pauseChoices } }
                donePanel
            }
        }.padding(6).frame(width: 300).background(Palette.paper)
            .task { await model.lookUpLinkedChatTitles(for: task) }
            .task(id: model.learnedStatus) {
                // A result that arrived since the last sweep is read now, rather than showing moves for the one before.
                if !model.demo, model.memorySettings?.enabled == true { try? await MemoryMoveLearner(store: model.store).offerLatest(taskID: task.id) }
                moves = (try? model.store.suggestedMoves(taskID: task.id)) ?? []
                situation = moves.first.flatMap { try? model.store.situationName($0.situationId) } ?? ""
            }
            .task { loadRoutine() }
            .onDisappear { messageMic.cancel(); stepMic.cancel(); noteMic.cancel() }
    }

    private func openRow(tint: Color?) -> some View {
        ChoiceRow(title: "Open in \(agent)", symbol: "arrow.up.right", tint: tint) { model.open(task); dismiss() }
    }

    // MARK: Continue: the agent keeps going

    @ViewBuilder private var continueChoices: some View {
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
        linkedChatRows
        field("Or tell the agent…", text: $message, focus: .message) {
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if model.tell(task, text) { lookForRepeatedReply(text) }
        }
        .disabled(queued || model.demo)
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
    private func panel<Content: View>(_ title: String?, _ color: Color, @ViewBuilder _ content: () -> Content) -> some View {
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
        let caret = Binding<TextSelection?>(get: { carets[field] }, set: { carets[field] = $0 })
        return HStack(spacing: 4) {
            TextField(prompt, text: text, selection: caret, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12))
                .lineLimit(1...8).frame(height: heights[field])
                .background(alignment: .topLeading) {
                    // A trailing line break still needs its empty line.
                    Text(text.wrappedValue.isEmpty || text.wrappedValue.hasSuffix("\n") ? text.wrappedValue + " " : text.wrappedValue)
                        .font(.system(size: 12)).lineLimit(8).fixedSize(horizontal: false, vertical: true).hidden()
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
            MicButton(dictation: mic, size: 11) { focus = field; mic.toggle(into: text, vocabulary: model.dictationVocabulary) }
        }
            .choiceField(focused: focus == field)
            .padding(.horizontal, 4).padding(.vertical, 3)
    }

    private func microphone(_ field: Field) -> Dictation {
        switch field {
        case .message: messageMic
        case .step: stepMic
        case .note: noteMic
        }
    }
}
