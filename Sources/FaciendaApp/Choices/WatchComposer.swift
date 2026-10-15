import SwiftUI
import FaciendaCore

/// "Agent watches for…": one line saying what to wait for, read into a watch the agent checks. Waits the chat suggests are offered first.
struct WatchComposer: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    let parked: (FaciendaTask, String) -> Void
    let dismiss: () -> Void
    @State private var assistant: WaitAssistant
    @State private var text = ""
    /// The user's choice in the two menus; nil keeps what they typed, or the defaults.
    @State private var cadence: TimeInterval?
    @State private var span: TimeInterval?
    @State private var mic = Dictation()
    @FocusState private var focused: Bool

    init(model: AppModel, task: FaciendaTask, parked: @escaping (FaciendaTask, String) -> Void, dismiss: @escaping () -> Void) {
        self.model = model; self.task = task; self.parked = parked; self.dismiss = dismiss
        _assistant = State(initialValue: WaitAssistant(task: task, model: model))
    }

    /// The watches on offer: what was typed, or what the chat suggests.
    private var candidates: [WaitCompiler.Option] {
        if let typed = assistant.typed { return [typed] }
        return Array(assistant.options.filter(\.plan.hasObservedConditions).prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                TextField("What should the agent watch for?", text: $text).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { mic.finishing(submit) }
                    .accessibilityLabel("What should the agent watch for")
                MicButton(dictation: mic, size: 11) { focused = true; mic.toggle(into: $text, vocabulary: model.dictationVocabulary) }
            }
                .choiceField(focused: focused)
                .padding(.horizontal, 4).padding(.vertical, 3)
            // Before anything is typed: what the chat says is worth watching for.
            ForEach(candidates) { watch($0, highlighted: assistant.typed != nil) }
            if assistant.typed == nil && assistant.suggesting && assistant.options.isEmpty { note("Reading the chat…", Palette.muted, spinning: true) }
            if let first = candidates.first, first.plan.hasObservedConditions { timing(first) }
            if assistant.thinking { note("Reading…", Palette.muted, spinning: true) }
            if let question = assistant.question { note(question, Palette.ink) }
            if let error = assistant.error { note(error, Palette.accent) }
        }
        .onAppear { assistant.prepare(executable: model.executable) }
        // The field only takes the keyboard once it is in the popover's window, a moment after it appears.
        .task { try? await Task.sleep(for: .milliseconds(60)); focused = true }
        .onDisappear { assistant.close(); mic.cancel() }
    }

    private func applied(_ option: WaitCompiler.Option) -> WaitPlan { WaitCompiler.watch(option.plan, cadence: cadence, span: span) }

    private func watch(_ option: WaitCompiler.Option, highlighted: Bool = false) -> some View {
        let plan = applied(option)
        // The menus below decide the timing, so the label keeps only what is watched for.
        let title = option.label.replacingOccurrences(of: #"\s*·\s*gives up.*$"#, with: "", options: .regularExpression)
        return ChoiceRow(title: title, symbol: "arrow.triangle.2.circlepath", highlighted: highlighted, tint: Palette.amber) { park(option) }
            .help(WaitCompiler.summary(plan, taskName: { id in model.tasks.first { $0.id == id }?.displayName }))
    }

    /// How often and for how long, defaulting to every 4 hours for a week; one click to change either.
    private func timing(_ option: WaitCompiler.Option) -> some View {
        let plan = applied(option)
        let often = WaitCompiler.watchCadences.first { $0.seconds == plan.checkInterval }?.label ?? WaitPlan.cadenceLabel(plan.checkInterval)
        // Named after the span it really has: a typed give-up ("or Friday"), or one stretched to fit a slow check, shows its date.
        let left = plan.giveUpAt.map { $0.timeIntervalSinceNow } ?? WaitCompiler.watchSpan
        let long = WaitCompiler.watchSpans.first { abs($0.seconds - left) < 120 }?.label
            ?? plan.giveUpAt.map { "until " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? ""
        return HStack(spacing: 4) {
            TimingChoice(label: often, accessibility: "How often the agent checks", choices: WaitCompiler.watchCadences) { cadence = $0 }
            TimingChoice(label: long, accessibility: "How long the agent keeps checking", choices: WaitCompiler.watchSpans) { span = $0 }
        }
        .padding(.leading, 32).padding(.bottom, 4)
    }

    private func note(_ text: String, _ color: Color, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.mini) }
            Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func park(_ option: WaitCompiler.Option) {
        guard !model.demo else { return }
        if model.park(task, plan: WaitCompiler.settled(applied(option), task: task, hasChat: assistant.hasChat)) { parked(task, option.label); dismiss() }
    }

    /// Enter on what was just understood starts the watch; otherwise the sentence is read.
    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { if let typed = assistant.typed { park(typed) }; return }
        text = ""
        Task { await assistant.send(message) }
    }
}

/// A small capsule showing one timing; clicking it lists the alternatives.
private struct TimingChoice: View {
    let label: String
    let accessibility: String
    let choices: [(label: String, seconds: TimeInterval)]
    let pick: (TimeInterval) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Palette.card, in: Capsule()).overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(accessibility).accessibilityValue(label)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(choices, id: \.seconds) { choice in
                    ChoiceRow(title: choice.label, symbol: choice.label == label ? "checkmark" : "circle.dotted") { pick(choice.seconds); open = false }
                }
            }.padding(4).frame(width: 170).background(Palette.paper)
        }
    }
}
