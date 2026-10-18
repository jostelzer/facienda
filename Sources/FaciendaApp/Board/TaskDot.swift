import SwiftUI
import FaciendaCore

/// One glyph per state, told apart by shape as well as colour.
struct TaskDot: View {
    enum Kind: String, Equatable {
        case review, onYou, running, watching, waiting, done, attention
        /// For review, told apart by what is asked of the user: an answer, a permission, or closing the task.
        case question, permission, finished
        /// A plan line that hasn't been started as a task yet.
        case notStarted

        static let legendOrder: [Kind] = [.notStarted, .running, .review, .onYou, .waiting, .done]
        /// The chips a task list stands for on the board.
        static func legend(for list: Destination) -> [Kind] {
            switch list {
            case .processing: [.running]
            case .forYou: [.review]
            case .waiting, .scheduled: [.waiting]
            case .done: [.done]
            case .dashboard, .inbox: []
            }
        }
        /// Questions, permissions, finished work and tasks needing attention are all for review, filtered together;
        /// the agent watching is one way of being parked.
        var legend: Kind {
            switch self {
            case .attention, .question, .permission, .finished: .review
            case .watching: .waiting
            default: self
            }
        }

        @MainActor init(model: AppModel, task: FaciendaTask) {
            let status = model.status(for: task)
            if status == .recovery || status == .prerequisiteChanged { self = .attention }
            else if model.belongs(task, to: .done) { self = .done }
            // A chat stopped at a permission prompt is still running, but nothing happens until the user allows it.
            else if status == .needsPermission { self = .permission }
            else if model.belongs(task, to: .processing) { self = .running }
            // The user said they will do the next step themselves, with or without a reminder.
            else if model.ownStep(for: task) != nil { self = .onYou }
            // Parked until something holds: the agent watching for it, or a time, a follow-up or another task.
            else if model.belongs(task, to: .waiting) || model.belongs(task, to: .scheduled) {
                self = model.wait(for: task)?.plan.hasObservedConditions == true ? .watching : .waiting
            }
            else if status == .needsInput { self = .question }
            else if status == .ready { self = .finished }
            else { self = .review }
        }

        var label: String {
            switch self {
            case .review: "For review"
            case .watching: "Agent watching"
            case .onYou: "On you"
            case .running: "Running"
            case .waiting: "Parked"
            case .done: "Done"
            case .attention: "Needs attention"
            case .question: "Has a question"
            case .permission: "Needs permission"
            case .finished: "Ready to close"
            case .notStarted: "Planned"
            }
        }
    }

    let kind: Kind
    var animated = true

    /// Driven by the clock rather than a repeatForever state animation, which stalls when the view is recycled.
    private var arc: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle().trim(from: 0, to: 0.3).stroke(Palette.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(animated ? turn * 360 : 0))
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .review: Image(systemName: "eye.fill").font(.system(size: 11)).foregroundStyle(Palette.review)
            case .question: Image(systemName: "questionmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.review)
            case .permission: Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Palette.review)
            // The agent says it is finished, in review ink; only the user's own close earns the green check.
            case .finished: Image(systemName: "hand.thumbsup.fill").font(.system(size: 11)).foregroundStyle(Palette.review)
            // A fingerprint: a step only a person can take, the agent's hands in the world.
            case .onYou: Image(systemName: "touchid").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.purple)
            case .running:
                // A progress indicator, so it keeps turning under Reduce Motion, like the system ProgressView.
                Circle().stroke(Palette.line, lineWidth: 2).frame(width: 11, height: 11)
                    .overlay(arc)
            case .watching: Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.amber)
            case .waiting: Image(systemName: "clock").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.amber)
            case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.green)
            case .attention: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.accent)
            case .notStarted: Circle().strokeBorder(Palette.firmLine, lineWidth: 1.5).frame(width: 11, height: 11)
            }
        }.frame(width: 16, height: 16).help(kind.label).accessibilityLabel(kind.label)
    }
}

extension TaskDot.Kind {
    /// A task's glyph from its state alone, for a task in a workspace that is not open, whose chats and waits are not
    /// loaded. Nil for a task let go.
    init?(state: TaskState) {
        switch state {
        case .running: self = .running
        case .needsMe: self = .review
        case .waiting, .scheduled: self = .waiting
        case .done: self = .done
        case .inbox: self = .notStarted
        case .dropped: return nil
        }
    }
}
