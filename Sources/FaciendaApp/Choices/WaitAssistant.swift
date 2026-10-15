import SwiftUI
import FaciendaCore
import FaciendaBridge

/// One warm background model serves every "Wait until…" conversation.
private let waitLuna = BackgroundModel()

/// Reads the task's chat for ready-made waits and turns a typed sentence into one more. Plain dates never reach the model.
@MainActor @Observable final class WaitAssistant {
    /// What the user typed, understood as one wait to tap.
    var typed: WaitCompiler.Option?
    var question: String?
    var thinking = false
    var error: String?
    /// Ready-made waits read from the task's chat.
    var options: [WaitCompiler.Option] = []
    var suggesting = false
    let task: FaciendaTask
    let candidates: [WaitCompiler.Candidate]
    let hasChat: Bool
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var chat = ""
    @ObservationIgnored private var suggestion: Task<Void, Never>?
    @ObservationIgnored private var thread: Task<String, any Error>?
    @ObservationIgnored private var threadID: String?
    @ObservationIgnored private var introduced = false
    @ObservationIgnored private var serviceTier: String?
    @ObservationIgnored private var executable: String?

    init(task: FaciendaTask, model: AppModel) {
        self.task = task; self.model = model
        candidates = WaitCompiler.candidates(for: task, among: model.tasks)
        hasChat = model.links.contains { $0.taskId == task.id && $0.role == "work" }
        if let stored = model.waitOptions[task.id], stored.eventId == model.latestResults[task.id]?.eventId {
            // Read from the chat when its turn finished, so they show at once.
            options = stored.current()
        }
    }

    /// Opens the hidden thread straight away; reads the chat for options when none were prepared.
    func prepare(executable: String, suggest: Bool = true) {
        self.executable = executable
        guard thread == nil else { return }
        introduced = false; threadID = nil
        thread = Task {
            try await waitLuna.warm(executable: executable)
            // The priority tier answers in about half the time when the account offers it.
            let tiers = (try? await waitLuna.options().tiers) ?? []
            serviceTier = tiers.first { $0 == "priority" } ?? tiers.first { $0.localizedCaseInsensitiveContains("fast") }
            let id = try await waitLuna.open(.wait)
            threadID = id
            return id
        }
        guard suggest, options.isEmpty, hasChat, model.wait(for: task) == nil else { return }
        suggesting = true
        suggestion = Task {
            defer { suggesting = false }
            guard let id = try? await thread?.value else { return }
            await loadChat()
            guard let reply = try? await waitLuna.ask(id, text: introduction() + WaitCompiler.suggestionRequest, schema: WaitCompiler.suggestionSchema,
                                                      effort: WaitCompiler.reasoningEffort, serviceTier: serviceTier) else { return }
            introduced = true
            options = WaitCompiler.options(reply, candidates: candidates, hasChat: hasChat)
        }
    }

    /// The task's latest conversation, refreshed from Codex when connected.
    private func loadChat() async {
        guard chat.isEmpty else { return }
        await model.loadConversation(for: task)
        chat = await model.savedChatExcerpt(for: task, latestResult: model.latestResults[task.id]?.excerpt)
    }

    private func introduction() -> String {
        introduced ? "" : WaitCompiler.context(task: task, candidates: candidates, hasChat: hasChat, chat: chat) + "\n\n"
    }

    func close() {
        suggestion?.cancel(); thread?.cancel()
        if let threadID { Task { await waitLuna.close(threadID) } }
    }

    /// "tomorrow 8am" or "Friday 14:30": a whole message that is just a time with a clock reading.
    static func plainTime(_ text: String, now: Date = Date()) -> Date? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["until ", "at ", "on "] where text.lowercased().hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        guard text.range(of: #"\d{1,2}(:\d{2}|\s?(am|pm))"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = detector.matches(in: text, range: whole).first, match.range == whole, let date = match.date, date > now else { return nil }
        return date
    }

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        error = nil; question = nil
        if let date = Self.plainTime(text) { typed = WaitCompiler.reminder(date, label: "Until " + WaitChoices.when(date)); return }
        if thread == nil, let executable { prepare(executable: executable) }
        guard let thread else { error = "Codex isn't available. Pick an option above."; return }
        thinking = true; defer { thinking = false }
        do {
            let id = try await thread.value
            // One turn at a time on the hidden thread: let the options finish first.
            await suggestion?.value
            await loadChat()
            let reply = try await waitLuna.ask(id, text: introduction() + "USER: " + text, schema: WaitCompiler.schema, effort: WaitCompiler.reasoningEffort, serviceTier: serviceTier)
            introduced = true
            switch try WaitCompiler.resolve(reply, candidates: candidates, hasChat: hasChat) {
            case .question(let text): question = text; typed = nil
            case .plan(let plan): typed = WaitCompiler.Option(label: plan.summary, plan: plan)
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            // A session that never opened, or died, is replaced on the next message.
            if threadID == nil { self.thread = nil } else if case BridgeError.disconnected = error { self.thread = nil }
        }
    }
}
