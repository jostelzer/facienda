import Foundation

/// What Return in the top bar will do, in a few words: a verb and what it acts on, such as "Reply · Deed transfer".
/// The bar shows it only when Return will do something other than start the text as a new task, which is what people
/// expect of the bar and needs no saying. The board rings the task a reading acts on, so the place is seen, not read.
public struct BarReading: Equatable, Sendable {
    public enum Verb: String, Sendable {
        /// Start the text as a task, in the group the bar names.
        case start
        /// The text asks for an earlier task: a fast model reads which one, and offers it for one more Return.
        case find
        /// Open a task that is still open; its choices come up on the board.
        case open
        /// Bring a finished task back onto the board.
        case bringBack
        /// Bring a task back and send it a message: a steer, so the message is shown before Return sends it.
        case reply
        /// The text is already an open task, nearly word for word. Return opens that one rather than making a second.
        case already
        /// Keep the text as a note in the workspace's memory.
        case remember
        /// Add a pasted chat link as a task that follows that chat.
        case trackChat
        /// One of the bar's commands, such as going to Waiting.
        case command
        /// A chat found by the search, to start from or continue in.
        case chat
        /// A memory note found by the search.
        case note
        /// Answer the question a task asked, with the option or words shown.
        case decide
        /// Mark a task done.
        case done
        /// Park a task until a time.
        case park
        /// The text could be about several tasks: Return asks which one.
        case ask
        /// A question Facienda answered from what it already holds; the answer is under the bar.
        case answered
    }

    public let verb: Verb
    /// What the verb acts on: a task's or chat's name, a command's own words. Empty when the verb says it all.
    public let target: String
    /// The task the board rings, if the reading acts on one.
    public let taskID: String?
    /// What will be sent with a reply, or the answer to a task's question, word for word.
    public let message: String
    /// When a parked task comes back.
    public let until: Date?
    /// Read by the model rather than by a fixed rule, so it is shown before Return does it.
    public let read: Bool
    /// Where new work goes, when the reader chose a place for it.
    public var place: BarPlace?
    /// Whether the reader was sure of that place.
    public var sure = true
    /// Another place that fits nearly as well. Return asks which.
    public var alternative: BarPlace?

    public init(_ verb: Verb, target: String = "", taskID: String? = nil, message: String = "", until: Date? = nil, read: Bool = false) {
        self.verb = verb; self.target = target; self.taskID = taskID; self.message = message; self.until = until; self.read = read
    }

    /// The bar's reading of what the model read: the same verbs, said the same way.
    public init?(_ reading: BarReader.Reading) {
        let name = reading.task?.displayName ?? ""
        switch reading.kind {
        case .new: return nil
        case .open, .reply:
            guard let task = reading.task else { return nil }
            let said = BarReading.task(task, message: reading.message)
            self.init(said.verb, target: said.target, taskID: said.taskID, message: said.message, read: true)
        case .answer: self.init(.decide, target: name, taskID: reading.task?.id, message: reading.message, read: true)
        case .done: self.init(.done, target: name, taskID: reading.task?.id, read: true)
        case .park: self.init(.park, target: name, taskID: reading.task?.id, until: reading.until, read: true)
        case .question: self.init(.answered, read: true)
        case .unclear: self.init(.ask, read: true)
        }
    }

    /// The verb as the bar says it.
    public var verbLabel: String {
        switch verb {
        case .start: "New task"
        case .find: "Find the earlier task"
        case .open: "Open"
        case .bringBack: "Bring back"
        case .reply: "Reply"
        case .already: "Already a task"
        case .remember: "Remember"
        case .trackChat: "Add the chat as a task"
        case .command: target
        case .chat: "Chat"
        case .note: "Open in Memory"
        case .decide: "Answer"
        case .done: "Mark done"
        case .park: "Park"
        case .ask: "Which one?"
        case .answered: target.isEmpty ? "Answered below" : "Answered"
        }
    }

    /// The second line, for what a reading would say or set: the words a reply sends, the answer chosen, the time a
    /// parked task comes back.
    public func detail(timeZone: TimeZone = .current) -> String {
        switch verb {
        case .reply: return message.isEmpty ? "" : "Sends “\(message)”"
        case .decide: return message.isEmpty ? "" : "Answers “\(message)”"
        case .park: return until.map { "Until " + Self.when($0, timeZone: timeZone) } ?? ""
        default: return ""
        }
    }

    /// A time as the bar says it: "Fri 23 Oct, 09:00".
    public static func when(_ date: Date, timeZone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB"); format.timeZone = timeZone; format.dateFormat = "EEE d MMM, HH:mm"
        return format.string(from: date)
    }

    /// What to ask when the text could be about several tasks, by what it would do to the one chosen.
    public static func question(for reading: BarReader.Reading, timeZone: TimeZone = .current) -> String {
        switch reading.then {
        case .reply: "Which task should hear it?"
        case .answer: "Which task's question does it answer?"
        case .done: "Which one is done?"
        case .park: reading.until.map { "Park which one until \(when($0, timeZone: timeZone))?" } ?? "Park which one?"
        default: "Which one do you mean?"
        }
    }

    /// The whole line: the verb, then what it acts on. New work says where it goes, and when it is not sure.
    public var label: String {
        if verb == .start {
            guard let place else { return sure ? verbLabel : "New task here · not sure where it goes" }
            if let alternative { return "New task · \(place.label) or \(alternative.label)?" }
            return "New task in \(place.label)" + (sure ? "" : " · not sure")
        }
        return verb == .command || target.isEmpty ? verbLabel : verbLabel + " · " + target
    }

    /// Starting a new task is what the bar is for, so it is left unsaid unless the reader chose where it goes.
    public var isWorthShowing: Bool { verb != .start || place != nil || !sure }

    /// New work as the reader placed it.
    public static func start(_ reading: BarReader.Reading) -> BarReading {
        var said = BarReading(.start, read: true)
        said.place = reading.place; said.sure = reading.sure; said.alternative = reading.alternative
        return said
    }

    /// New work going where the person chose.
    public static func start(at place: BarPlace) -> BarReading {
        var said = BarReading(.start)
        said.place = place
        return said
    }

    /// Return on a task: open it, bring it back, or bring it back and tell it something.
    public static func task(_ task: FaciendaTask, message: String = "") -> BarReading {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb: Verb = !message.isEmpty ? .reply : task.state.isOpen ? .open : .bringBack
        return BarReading(verb, target: task.displayName, taskID: task.id, message: message)
    }

    /// An open task whose name is the text, nearly word for word: same words in the same order, ignoring case, accents
    /// and punctuation. Typing a task that is already on the board opens it rather than making a second one.
    public static func sameTask(as text: String, among tasks: [FaciendaTask]) -> FaciendaTask? {
        let typed = TaskLookup.words(text)
        guard !typed.isEmpty else { return nil }
        return tasks.first { task in
            task.state.isOpen && (TaskLookup.words(task.displayName) == typed || TaskLookup.words(task.title) == typed)
        }
    }
}
