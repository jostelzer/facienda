import Foundation

/// One thing a parked task waits for. All of a wait's conditions must hold.
public struct WaitCondition: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case time, task, observed }
    public var id: String
    public var kind: Kind
    public var at: Date?
    public var taskId: String?
    /// Observed conditions: who or what, where to look, and what counts as ready.
    public var what: String
    public var source: String
    public var criterion: String
    /// The saved prerequisite tracking this condition, and whether parking created it.
    public var blockerId: String?
    public var ownsBlocker: Bool

    public init(id: String = UUID().uuidString, kind: Kind, at: Date? = nil, taskId: String? = nil, what: String = "", source: String = "", criterion: String = "") {
        self.id = id; self.kind = kind; self.at = at; self.taskId = taskId
        self.what = what; self.source = source; self.criterion = criterion; self.ownsBlocker = false
    }
    public static func time(_ date: Date) -> Self { .init(kind: .time, at: date) }
    public static func task(_ id: String) -> Self { .init(kind: .task, taskId: id) }
    public static func observed(_ what: String, source: String, criterion: String) -> Self { .init(kind: .observed, what: what, source: source, criterion: criterion) }
}

/// What happens when the wait is over.
public enum WaitAction: String, Codable, Sendable, CaseIterable {
    case surface, work, tell
    public var label: String {
        switch self {
        case .surface: "Bring it to me"
        case .work: "Start the work"
        case .tell: "Tell the chat"
        }
    }
}

public struct WaitPlan: Codable, Equatable, Sendable {
    public var conditions: [WaitCondition]
    public var giveUpAt: Date?
    public var then: WaitAction
    /// The reminder text, or the message for the chat.
    public var note: String
    /// One sentence read back to the user.
    public var summary: String
    /// How often observed conditions are looked at. Nil means the default for the give-up window.
    public var checkEvery: TimeInterval?

    public init(conditions: [WaitCondition], giveUpAt: Date? = nil, then: WaitAction = .surface, note: String = "", summary: String = "", checkEvery: TimeInterval? = nil) {
        self.conditions = conditions; self.giveUpAt = giveUpAt; self.then = then; self.note = note; self.summary = summary; self.checkEvery = checkEvery
    }

    public static let cadences: [(label: String, seconds: TimeInterval)] = [("hourly", 3600), ("every 4 hours", 4 * 3600), ("daily", 86400), ("weekly", 7 * 86400), ("monthly", 30 * 86400)]
    public static func cadenceLabel(_ seconds: TimeInterval) -> String {
        cadences.first { $0.seconds == seconds }?.label ?? (seconds < 86400 ? "every \(Int((seconds / 3600).rounded())) hours" : "every \(Int((seconds / 86400).rounded())) days")
    }
    /// Short windows deserve frequent looks; open-ended waits are checked a few times a day.
    public var checkInterval: TimeInterval {
        if let checkEvery { return checkEvery }
        guard let giveUpAt else { return 4 * 3600 }
        let window = giveUpAt.timeIntervalSinceNow
        return window <= 86400 ? 3600 : window <= 7 * 86400 ? 4 * 3600 : 86400
    }
    public var hasObservedConditions: Bool { conditions.contains { $0.kind == .observed } }

    public func validate(now: Date = Date()) throws {
        guard !conditions.isEmpty else { throw StoreError.invalid("Say what this task is waiting for.") }
        for condition in conditions {
            switch condition.kind {
            case .time: guard let at = condition.at, at > now else { throw StoreError.invalid("Choose a time in the future.") }
            case .task: guard condition.taskId?.isEmpty == false else { throw StoreError.invalid("Choose the task to wait for.") }
            case .observed:
                guard [condition.what, condition.source, condition.criterion].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw StoreError.invalid("Say who or what to watch, where to look, and what counts as ready.")
                }
            }
        }
        if let giveUpAt {
            guard giveUpAt > now else { throw StoreError.invalid("Choose a give-up time in the future.") }
            guard conditions.contains(where: { $0.kind != .time }) else { throw StoreError.invalid("A plain reminder needs no give-up time.") }
            guard conditions.allSatisfy({ $0.at.map { $0 < giveUpAt } ?? true }) else { throw StoreError.invalid("The give-up time must come after the wake time.") }
        }
        if then == .tell && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StoreError.invalid("Write what to tell the chat.") }
        if let checkEvery, checkEvery < 3600 || checkEvery > 30 * 86400 { throw StoreError.invalid("Check between once an hour and once a month.") }
    }

    /// The latest time condition; with "all of", earlier ones add nothing.
    public var wakeTime: Date? { conditions.compactMap(\.at).max() }
}
