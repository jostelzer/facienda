import SwiftUI
import FaciendaCore

/// The waits for a task: what its chat suggests, two plain reminders, and a field for anything else.
struct WaitChoices: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    let parked: (FaciendaTask, String) -> Void
    let dismiss: () -> Void
    /// Only times: no waits read from the chat. Used when the user just wants to be reminded later.
    var remindersOnly = false
    @State private var assistant: WaitAssistant
    @State private var text = ""
    @State private var mic = Dictation()
    @FocusState private var focused: Bool

    init(model: AppModel, task: FaciendaTask, remindersOnly: Bool = false, parked: @escaping (FaciendaTask, String) -> Void, dismiss: @escaping () -> Void) {
        self.model = model; self.task = task; self.remindersOnly = remindersOnly; self.parked = parked; self.dismiss = dismiss
        _assistant = State(initialValue: WaitAssistant(task: task, model: model))
    }

    static func when(_ date: Date) -> String {
        let calendar = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today " + time }
        if calendar.isDateInTomorrow(date) { return "tomorrow " + time }
        if date.timeIntervalSinceNow < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Two plain reminders that are always there, unless the chat already offered the same time.
    private var reminders: [WaitCompiler.Option] {
        let calendar = Calendar.current, now = Date(), today = calendar.startOfDay(for: now)
        func at(_ day: Date, _ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day }
        let first = calendar.component(.hour, from: now) < 15 ? at(today, 18) : at(calendar.date(byAdding: .day, value: 1, to: today)!, 8)
        let second = calendar.nextDate(after: now.addingTimeInterval(2 * 86400), matching: DateComponents(hour: 8, weekday: 2), matchingPolicy: .nextTime)
            ?? at(calendar.date(byAdding: .day, value: 3, to: today)!, 8)
        let taken = Set(assistant.options.compactMap(\.plan.wakeTime))
        return [first, second].filter { !taken.contains($0) }.map { WaitCompiler.reminder($0, label: "Until " + Self.when($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let typed = assistant.typed { option(typed, highlighted: true) }
            if !remindersOnly { ForEach(assistant.options) { option($0) } }
            if !remindersOnly && assistant.suggesting && assistant.options.isEmpty {
                ChoiceProgress(text: "Reading the chat…")
            }
            ForEach(reminders) { option($0) }
            HStack(spacing: 6) {
                TextField("Or say when…", text: $text).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { mic.finishing(submit) }
                    .accessibilityLabel("Say what to wait for")
                if assistant.thinking { ProgressView().controlSize(.mini) }
                MicButton(dictation: mic, size: 11) { focused = true; mic.toggle(into: $text, vocabulary: model.dictationVocabulary) }
            }.choiceField(focused: focused)
                .padding(.horizontal, 4).padding(.top, 6)
            if let question = assistant.question { note(question, Palette.ink) }
            if let error = assistant.error { note(error, Palette.accent) }
        }
        .onAppear { assistant.prepare(executable: model.executable, suggest: !remindersOnly) }
        .onDisappear { assistant.close(); mic.cancel() }
    }

    private func option(_ option: WaitCompiler.Option, highlighted: Bool = false) -> some View {
        ChoiceRow(title: option.label, symbol: symbol(option.plan), highlighted: highlighted) { park(option) }
            .help(WaitCompiler.summary(option.plan, taskName: { id in model.tasks.first { $0.id == id }?.displayName }))
    }

    private func symbol(_ plan: WaitPlan) -> String {
        if plan.conditions.contains(where: { $0.kind == .observed }) { return "envelope" }
        if plan.conditions.contains(where: { $0.kind == .task }) { return "checkmark.circle" }
        return "clock"
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.top, 4)
    }

    private func park(_ option: WaitCompiler.Option) {
        guard !model.demo else { return }
        if model.park(task, plan: WaitCompiler.settled(option.plan, task: task, hasChat: assistant.hasChat)) { parked(task, option.label); dismiss() }
    }

    /// Enter on what was just understood parks it; otherwise the sentence is read.
    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { if let typed = assistant.typed { park(typed) }; return }
        text = ""
        Task { await assistant.send(message) }
    }
}
