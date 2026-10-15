import Foundation

/// The panes of the Settings sheet, in the order of its side list.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, runners, connections, memory, library, storage, models

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .runners: "Runners"
        case .connections: "Connections"
        case .memory: "Memory"
        case .library: "Library"
        case .storage: "Storage"
        case .models: "Models"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .runners: "play.circle"
        case .connections: "arrow.left.arrow.right"
        case .memory: "book.closed"
        case .library: "folder"
        case .storage: "internaldrive"
        case .models: "cpu"
        }
    }
}
