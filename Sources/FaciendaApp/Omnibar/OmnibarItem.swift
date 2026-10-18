import SwiftUI
import FaciendaCore
import FaciendaBridge

/// A chat found from the top bar, through the private index or Codex's title search.
struct ChatResult: Identifiable, Equatable {
    let threadId: String
    let title: String
    let cwd: String
    let updatedAt: Date
    var matches: [ChatMatch] = []
    var provider: AgentProvider = .codex
    /// A Claude session's Claude Code ID, which names its transcript.
    var cliSessionId: String?
    var id: String { threadId }
    var thread: CodexThread { CodexThread(id: threadId, title: title, cwd: cwd, updatedAt: updatedAt) }
    var candidate: ChatCandidate { ChatCandidate(threadId: threadId, provider: provider, title: title, cwd: cwd.isEmpty ? nil : cwd, cliSessionId: cliSessionId) }
}

enum OmnibarCommand: String, CaseIterable {
    case forYou, processing, waiting, scheduled, done, memory, settings, switchWorkspace, newWorkspace, newGroup, composer

    var title: String {
        switch self {
        case .forYou: "Go to For review"
        case .processing: "Go to In progress"
        case .waiting: "Go to Waiting"
        case .scheduled: "Go to Scheduled"
        case .done: "Go to Done"
        case .memory: "Open Memory"
        case .settings: "Open Settings"
        case .switchWorkspace: "Switch workspace"
        case .newWorkspace: "New workspace"
        case .newGroup: "New group"
        case .composer: "Write a longer request, with files"
        }
    }
    var symbol: String {
        switch self {
        case .forYou: Destination.forYou.symbol
        case .processing: Destination.processing.symbol
        case .waiting: Destination.waiting.symbol
        case .scheduled: Destination.scheduled.symbol
        case .done: Destination.done.symbol
        case .memory: SettingsPane.memory.symbol
        case .settings: "gearshape"
        case .switchWorkspace: "square.stack.3d.up"
        case .newWorkspace: "plus.square.on.square"
        case .newGroup: "rectangle.stack.badge.plus"
        case .composer: "paperclip"
        }
    }
    var keywords: [String] {
        switch self {
        case .forYou: ["review", "for review", "inbox"]
        case .processing: ["progress", "in progress", "running"]
        case .waiting: ["waiting", "parked"]
        case .scheduled: ["scheduled", "later"]
        case .done: ["done", "finished", "archive"]
        case .memory: ["memory", "notes"]
        case .settings: ["settings", "preferences"]
        case .switchWorkspace: ["switch", "workspace", "workspaces"]
        case .newWorkspace: ["new workspace"]
        case .newGroup: ["new group", "group", "add group"]
        case .composer: ["new task", "compose", "attach", "files", "longer"]
        }
    }
}

struct OmnibarItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case start, remember(String), command(OmnibarCommand), task(FaciendaTask), chat(ChatResult), note(MemoryFact)
        /// A question answered from what Facienda holds, with what it came from.
        case answer(BarReader.Reading)
        /// A place new work could go, when Facienda was not sure which.
        case place(BarPlace)
    }
    let id: String
    let kind: Kind
}

struct OmnibarSection: Identifiable {
    let id: String
    let title: String?
    var items: [OmnibarItem]
    var footnote: String?
}
