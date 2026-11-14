import Foundation
import FaciendaCore

extension AppModel {
    /// When a row last moved, for a card sorted by date: its chat's last message, or when the task was made while it has no chat.
    func movedAt(_ task: FaciendaTask) -> Date { lastMessageAt(for: task) ?? task.createdAt }
}

/// How far back a row's last message lies, as the captions of a card sorted by date name it.
enum DayBand: Equatable {
    case today, yesterday, week, earlier

    var caption: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "This week"
        case .earlier: "Earlier"
        }
    }

    /// By calendar day, not by hours: a message from 23:50 is yesterday's at 00:10.
    static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DayBand {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2..<7: return .week
        default: return .earlier
        }
    }
}

enum DateOrder {
    /// Newest first. A tie falls back to the ID, so a card never shuffles between two redraws.
    static func sorted(_ tasks: [FaciendaTask], movedAt: (FaciendaTask) -> Date) -> [FaciendaTask] {
        tasks.map { ($0, movedAt($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }.map(\.0)
    }
}
