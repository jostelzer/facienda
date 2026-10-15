import SwiftUI
import FaciendaCore

/// Where a task runs and on which model, so Codex and Claude work can sit side by side.
struct TaskAgentLabel: View {
    let model: AppModel
    let task: FaciendaTask

    var body: some View {
        let agent = model.agent(for: task)
        let chosen = task.workerModel.map { TaskModelChoice(model: $0, effort: task.workerReasoningEffort ?? "high", fast: task.workerServiceTier != nil) }
        let detail = [chosen.map(\.name), task.workerReasoningEffort.map(TaskModelChoice.effortName), task.workerServiceTier != nil ? "Fast" : nil].compactMap { $0 }
        Label { Text(([agent.name] + detail).joined(separator: " · ")) } icon: { ProviderMark(provider: agent, size: 11) }
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
            .help(note(agent))
    }

    private func note(_ agent: AgentProvider) -> String {
        guard agent == .claude, let thread = model.resultLink(for: task)?.threadId, let session = model.claudeSessions[thread] else {
            return "Runs in \(agent.name)"
        }
        switch session.configureState {
        case "done": return "Runs in Claude. The runner applied this model."
        case "failed": return "Runs in Claude with the Claude app’s own model: " + (session.configureNote ?? "the runner could not apply this one.")
        case "skipped": return "Runs in Claude with the Claude app’s own model: no runner was awake when it started."
        default: return "Runs in Claude. The runner is applying this model."
        }
    }
}

/// A Claude start that has not begun: it waits for the runner, or sits in the Claude app's composer because the
/// user chose to send it there. Facienda never opens the composer on its own.
struct ClaudeHandoff: View {
    let model: AppModel
    let item: NativeDispatch

    private var awake: Bool { model.claudeRunner?.isAwake() == true }
    private var held: Bool { model.claudeStartsHeld.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.awaitsClaudeSend {
                Label("Ready in Claude — press Send there", systemImage: "paperplane").font(.system(size: 13, weight: .medium))
                Text("The request is waiting in a new Claude session. Once you send it, the session links itself here\(awake ? " and the Claude runner applies your model" : "").")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Label(held ? "Claude did not pick this up" : "Waiting for the Claude runner", systemImage: held ? "exclamationmark.circle" : "moon.zzz")
                    .font(.system(size: 13, weight: .medium))
                Text(held ? "Facienda handed Claude the session but it did not appear. Try again, or send the request yourself in Claude."
                     : model.claudeConnected ? "The runner is asleep. Wake it and this task starts on its own, with nothing to send."
                     : "Connect Claude once and this task starts on its own, with nothing to send.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if item.awaitsClaudeSend {
                    Button("Show in Claude again") { model.openInClaude(item) }.buttonStyle(QuietButton()).disabled(model.demo)
                } else {
                    if held && awake {
                        Button("Try again") { Task { await model.retryClaudeStart(item) } }.buttonStyle(QuietButton(prominent: true)).disabled(model.demo)
                    } else if !awake {
                        Button(model.connectingClaude ? "Opening Claude…" : model.claudeConnected ? "Wake runner" : "Connect Claude") {
                            model.requestClaudeConnection(repair: model.claudeConnected)
                        }.buttonStyle(QuietButton(prominent: true)).disabled(model.connectingClaude || model.demo)
                    }
                    Button("Send it myself in Claude") { model.openInClaude(item) }.buttonStyle(QuietButton()).disabled(model.demo)
                        .help("Opens the request in a new Claude session for you to send")
                }
                Button("Cancel") { model.cancelStart(item.id) }.buttonStyle(QuietButton()).disabled(model.demo)
            }
        }.calloutCard()
    }
}

/// A delivery the runner could not confirm. Facienda looks for the chat that received it; the user
/// decides only what that search cannot prove. Chats appear by title, never by contents.
struct DeliveryRecovery: View {
    let model: AppModel
    let item: NativeDispatch
    private var search: DeliverySearch? { model.deliverySearches[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delivery needs recovery").font(.system(size: 13, weight: .medium))
            HStack(spacing: 6) {
                if search?.searching == true { ProgressView().controlSize(.small) }
                Text(model.deliverySummary(item)).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if let chats = search?.chats, chats.count > 1 {
                ForEach(chats) { chat in
                    HStack {
                        Text(chat.title.isEmpty ? "Untitled chat" : chat.title).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Button("Use this chat") { model.useDeliveryChat(item, chat) }.buttonStyle(QuietButton(compact: true)).disabled(model.demo)
                    }
                }
            }
            HStack {
                if item.kind != "check" {
                    Button(search?.provedMissing == true ? "Send again" : "Send again…") { model.sendAgain(item) }
                        .buttonStyle(QuietButton(prominent: search?.provedMissing == true)).disabled(model.demo || search?.searching == true)
                }
                Button("Drop delivery") { model.cancelStart(item.id) }.buttonStyle(QuietButton()).disabled(model.demo || search?.searching == true)
                if model.connected, search != nil, search?.searching != true {
                    Button("Search again") { Task { await model.findDelivery(item) } }.buttonStyle(QuietButton())
                }
            }
        }
        .task(id: "\(item.id):\(model.connected)") { if search == nil { await model.findDelivery(item) } }
    }
}

/// The same recovery as context-menu items, for a task's row on a board.
struct DeliveryRecoveryMenu: View {
    let model: AppModel
    let item: NativeDispatch
    private var search: DeliverySearch? { model.deliverySearches[item.id] }
    private var searching: Bool { search?.searching == true }

    var body: some View {
        if let chats = search?.chats, chats.count > 1 {
            ForEach(chats) { chat in
                Button("Use “\(chat.title.isEmpty ? "Untitled chat" : chat.title)”", systemImage: "link") { model.useDeliveryChat(item, chat) }.disabled(model.demo)
            }
        }
        if item.kind != "check" {
            Button(search?.provedMissing == true ? "Send again" : "Send again…", systemImage: "arrow.clockwise") { model.sendAgain(item) }
                .disabled(model.demo || searching)
        }
        if model.connected, !searching {
            Button("Search again", systemImage: "magnifyingglass") { Task { await model.findDelivery(item) } }
        }
        Button("Drop delivery", systemImage: "xmark") { model.cancelStart(item.id) }.disabled(model.demo || searching)
    }
}

struct DecisionCard: View {
    @Bindable var model: AppModel
    let decision: Decision
    @State private var answer = ""
    @State private var editing = false
    private var neutralOptions: [String] {
        var seen = Set<String>()
        return (decision.options + [decision.recommendation]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if decision.kind == "permission" {
                Label("Asks your permission", systemImage: "hand.raised.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.review)
            }
            Text(decision.question).font(.system(size: 14, weight: .semibold))
            if !decision.context.isEmpty { ResultText(model: model, text: decision.context) }
            if decision.kind == "permission" {
                // The agent asks for itself, so its own pick gets no emphasis: every option looks alike, in the order given.
                WrapLayout(spacing: 6) {
                    ForEach(neutralOptions, id: \.self) { option in
                        Button(CodexApproval.visible(option)) { model.answer(decision, text: option) }.buttonStyle(QuietButton())
                    }
                    Button("Write an answer…") { editing = true }.buttonStyle(QuietButton())
                }
            } else {
                HStack {
                    Button(decision.recommendation) { model.answer(decision, text: decision.recommendation) }.buttonStyle(QuietButton(prominent: true))
                    Menu("Other answer") {
                        ForEach(decision.options.filter { $0 != decision.recommendation }, id: \.self) { option in Button(option) { model.answer(decision, text: option) } }
                        Button("Write an answer…") { editing = true }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            if editing {
                HStack {
                    TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder)
                    Button("Send") { model.answer(decision, text: answer) }.disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.calloutCard()
    }
}

/// What a running Codex turn asks before it goes on. While Facienda's turn runs, Codex shows the chat read-only,
/// so the answer is given here.
struct CodexApprovalCard: View {
    @Bindable var model: AppModel
    let approval: CodexApproval
    @State private var answers: [String: String] = [:]

    var body: some View {
        // Everything here comes from the agent's request: shown in full, with hidden characters spelled out.
        let shown = approval.display
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.kind == .question ? "Codex asks" : "Codex asks your permission", systemImage: "hand.raised.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.review)
            Text(shown.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let command = shown.command { code(command) }
            if !shown.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.files.enumerated()), id: \.offset) { _, file in
                        Text(file.change + " · " + file.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let diff = file.diff, !diff.isEmpty {
                            DisclosureGroup("Diff") { ScrollView { code(diff) }.frame(maxHeight: 240) }.font(.system(size: 11))
                        }
                    }
                }
            }
            if let root = shown.grantRoot { detail("Also asks to write anywhere in", root) }
            ForEach(Array(shown.permissions.enumerated()), id: \.offset) { _, line in code(line) }
            if let cwd = shown.cwd { detail("In", cwd) }
            if let reason = shown.reason { detail("The agent's reason", reason) }
            if let gap = shown.gap, approval.kind != .question { Text(gap).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            if approval.kind == .question { questions } else { choices(shown) }
        }.calloutCard()
    }

    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ label: String, _ text: String) -> some View {
        Text("\(Text(label).foregroundStyle(Palette.muted)) \(Text(text).font(.system(size: 12, design: .monospaced)))")
            .font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// Allow is offered only when the card shows exactly what it would permit. No choice is emphasised.
    @ViewBuilder private func choices(_ shown: CodexApproval.Display) -> some View {
        if approval.choices.isEmpty {
            Text("Facienda can't answer this kind of request. The turn waits until it ends or you stop it in Codex.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        } else {
            HStack {
                ForEach(approval.choices, id: \.self) { choice in
                    Button(title(choice)) { model.answer(approval, choice) }.buttonStyle(QuietButton())
                        .disabled(choice != .decline && !shown.canAllow)
                }
            }
        }
    }

    private func title(_ choice: CodexApproval.Choice) -> String {
        switch choice {
        case .allow: approval.kind == .permissions ? "Allow for this turn" : "Allow"
        case .allowForChat: "Allow for this chat"
        case .decline: "Decline"
        }
    }

    @ViewBuilder private var questions: some View {
        let items = approval.request["questions"].array ?? []
        ForEach(Array(items.enumerated()), id: \.offset) { _, question in
            let id = question["id"].string ?? ""
            VStack(alignment: .leading, spacing: 6) {
                if items.count > 1 { Text(CodexApproval.visible(question["question"].string ?? "")).font(.system(size: 12, weight: .medium)) }
                let options = (question["options"].array ?? []).compactMap { $0["label"].string }
                if !options.isEmpty {
                    Picker("", selection: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })) {
                        ForEach(options, id: \.self) { Text(CodexApproval.visible($0)).tag($0) }
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                if options.isEmpty || question["isOther"].bool == true {
                    if question["isSecret"].bool == true {
                        SecureField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        Button("Send answer") { model.answer(approval, answers: answers) }
            .buttonStyle(QuietButton(prominent: true))
            .disabled(items.contains { (answers[$0["id"].string ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

extension View {
    /// The soft panel for something in a task that waits on the user: a check, a handoff to Claude, a question.
    func calloutCard() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.selected.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
