import Foundation
import GRDB

public enum TaskState: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case inbox, running, needsMe, waiting, scheduled, done, dropped
    public var isOpen: Bool { self != .done && self != .dropped }
    public var label: String {
        switch self {
        case .inbox: "Inbox"
        case .running: "Running"
        case .needsMe: "Needs me"
        case .waiting: "Waiting"
        case .scheduled: "Scheduled"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }
}

public enum AutomationScope: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case prepareOnly, askFirst, autonomous
    public var label: String {
        switch self {
        case .prepareOnly: "Prepare only"
        case .askFirst: "Ask first"
        case .autonomous: "Autonomous"
        }
    }
}

public enum EventSource: String, Codable, Sendable, DatabaseValueConvertible {
    case user, app, hook, mcp, appServer
    public var isVerified: Bool { self != .mcp }
}

public struct TaskAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String

    public init(name: String, path: String) { self.name = name; self.path = path }
}

/// The desktop agent app whose native chats carry a task's work.
public enum AgentProvider: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case codex, claude
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

/// What a new task chat runs on: model, reasoning effort and Fast mode. The model decides the agent app.
public struct TaskModelChoice: Codable, Equatable, Sendable {
    public struct Model: Equatable, Sendable {
        public let id: String
        public let name: String
        public let provider: AgentProvider
        public let offersFast: Bool
    }
    public static let catalog: [Model] = [
        Model(id: "gpt-6-astra", name: "GPT-6 Astra", provider: .codex, offersFast: true),
        Model(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", provider: .codex, offersFast: true),
        Model(id: "gpt-6-luna", name: "GPT-6 Luna", provider: .codex, offersFast: true),
        Model(id: "claude-fable-5-1", name: "Fable 5.1", provider: .claude, offersFast: false),
        Model(id: "claude-opus-5-5", name: "Opus 5.5", provider: .claude, offersFast: true),
        Model(id: "claude-sonnet-5-5", name: "Sonnet 5.5", provider: .claude, offersFast: false),
        Model(id: "claude-haiku-5-5", name: "Haiku 5.5", provider: .claude, offersFast: false)
    ]
    public static func models(for provider: AgentProvider) -> [Model] { catalog.filter { $0.provider == provider } }
    public static func efforts(for provider: AgentProvider) -> [String] {
        switch provider {
        case .codex: ["low", "medium", "high", "xhigh", "max", "ultra"]
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        }
    }
    public static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        default: effort.capitalized
        }
    }
    /// The service tier saved for Fast mode: Codex's priority tier, or Claude's fast mode.
    public static func fastTier(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: "priority"
        case .claude: "fast"
        }
    }
    public static let fastTier = fastTier(for: .codex)
    public static let standard = TaskModelChoice(model: "gpt-6.1-sol", effort: "high", fast: false)
    public static let claudeStandard = TaskModelChoice(model: "claude-opus-5-5", effort: "high", fast: false)
    public static func standard(for provider: AgentProvider) -> TaskModelChoice {
        provider == .claude ? claudeStandard : standard
    }

    public var model: String
    public var effort: String
    public var fast: Bool

    public init(model: String, effort: String, fast: Bool) {
        self.model = model; self.effort = effort; self.fast = fast
    }
    public var details: Model? { Self.catalog.first { $0.id == model } }
    public var provider: AgentProvider { Self.provider(ofModel: model) }
    public var name: String { details?.name ?? model }
    public var offersFast: Bool { details?.offersFast ?? false }
    public static func provider(ofModel model: String) -> AgentProvider {
        catalog.first { $0.id == model }?.provider ?? (model.hasPrefix("claude") ? .claude : .codex)
    }
    /// Switching models keeps the reasoning level when the new model's app offers it, and drops Fast where it is unavailable.
    public func choosing(_ model: String) -> TaskModelChoice {
        var next = TaskModelChoice(model: model, effort: effort, fast: fast)
        if !Self.efforts(for: next.provider).contains(effort) { next.effort = "high" }
        if !next.offersFast { next.fast = false }
        return next
    }
    /// Switching back to a model brings back the reasoning and Fast it last had, kept valid for that model.
    public func choosing(_ model: String, remembered: [String: TaskModelChoice]) -> TaskModelChoice {
        guard let last = remembered[model], last.model == model else { return choosing(model) }
        return last.choosing(model)
    }
    /// The saved service tier for this choice, or nil at standard speed.
    public var serviceTier: String? { fast && offersFast ? Self.fastTier(for: provider) : nil }
}

public struct FaciendaTask: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "tasks"
    public var id: String
    public var title: String
    public var displayTitle: String?
    public var displayTitleSource: String?
    public var displayName: String { displayTitle ?? title }
    public var intention: String
    public var attachments: [TaskAttachment]?
    public var definitionOfDone: String
    public var area: String
    public var state: TaskState
    public var nextAction: String
    public var returnAt: Date?
    public var waitingOn: String?
    public var checkAt: Date?
    public var automationScope: AutomationScope
    public var brief: String
    public var cwd: String?
    /// The folders linked to the task's group when it started, primary first. Nil when it started without any.
    public var folders: [String]?
    /// The model, reasoning effort and service tier chosen when the task launched. Nil means the workspace default.
    public var workerModel: String?
    public var workerReasoningEffort: String?
    public var workerServiceTier: String?
    /// The agent app that runs this task's chats. Nil means Codex, as for every task before Claude support.
    public var workerProvider: AgentProvider?
    public var provider: AgentProvider { workerProvider ?? workerModel.map(TaskModelChoice.provider(ofModel:)) ?? .codex }
    public var snoozeCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var completedBy: String?
    public var revision: Int
    /// The workspace showing this task. Nil until it is saved; a store scoped to a workspace fills it in.
    public var workspaceId: String?

    public init(id: String = UUID().uuidString, title: String, intention: String = "", definitionOfDone: String = "", area: String = "Personal", state: TaskState = .inbox, nextAction: String = "Clarify the next step", returnAt: Date? = Date(), automationScope: AutomationScope = .prepareOnly, brief: String = "", cwd: String? = nil) {
        self.id = id; self.title = title; self.intention = intention; self.definitionOfDone = definitionOfDone
        self.area = area; self.state = state; self.nextAction = nextAction; self.returnAt = returnAt
        self.automationScope = automationScope; self.brief = brief; self.cwd = cwd
        self.snoozeCount = 0; self.createdAt = Date(); self.updatedAt = Date(); self.revision = 0
    }

    public var ruleViolations: [String] {
        guard state.isOpen else { return [] }
        var problems: [String] = []
        if state == .inbox { problems.append("Choose a next state") }
        if nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Add a next action") }
        if state == .scheduled && returnAt == nil { problems.append("Set a return date") }
        if state == .waiting && (waitingOn?.isEmpty != false || checkAt == nil) { problems.append("Name who you are waiting on and when to check") }
        return problems
    }
}

public struct ThreadLink: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "threadLinks"
    public var id: String
    public var taskId: String
    public var codexThreadId: String
    public var role: String
    public var linkedBy: String
    public var title: String
    public var preview: String
    public var lastKnownStatus: String
    public var statusSource: EventSource
    public var statusVerified: Bool
    public var lastActivityAt: Date?
    /// The app holding this chat. `codexThreadId` is that app's own chat ID: a Codex thread or a Claude session.
    public var provider: AgentProvider
    public var threadId: String { codexThreadId }
    public init(taskId: String, codexThreadId: String, role: String = "work", linkedBy: String = "user", title: String = "", preview: String = "", provider: AgentProvider = .codex) {
        self.id = UUID().uuidString; self.taskId = taskId; self.codexThreadId = codexThreadId
        self.role = role; self.linkedBy = linkedBy; self.title = title; self.preview = preview
        self.lastKnownStatus = "unknown"; self.statusSource = .app; self.statusVerified = false
        self.provider = provider
    }
    private enum CodingKeys: String, CodingKey {
        case id, taskId, codexThreadId, role, linkedBy, title, preview, lastKnownStatus, statusSource, statusVerified, lastActivityAt, provider
    }
    /// Links saved before Claude support carry no provider; they are Codex chats.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id); taskId = try container.decode(String.self, forKey: .taskId)
        codexThreadId = try container.decode(String.self, forKey: .codexThreadId); role = try container.decode(String.self, forKey: .role)
        linkedBy = try container.decode(String.self, forKey: .linkedBy); title = try container.decode(String.self, forKey: .title)
        preview = try container.decode(String.self, forKey: .preview); lastKnownStatus = try container.decode(String.self, forKey: .lastKnownStatus)
        statusSource = try container.decode(EventSource.self, forKey: .statusSource); statusVerified = try container.decode(Bool.self, forKey: .statusVerified)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        provider = try container.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .codex
    }
}

public struct TaskEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "events"
    public var id: String
    public var taskId: String?
    public var threadId: String?
    public var source: EventSource
    public var kind: String
    public var payload: String
    public var verified: Bool
    public var at: Date
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id; container["taskId"] = taskId; container["threadId"] = threadId
        container["source"] = source; container["kind"] = kind
        container["payload"] = MemoryRedaction.payload(payload); container["verified"] = verified; container["at"] = at
    }
    public init(taskId: String? = nil, threadId: String? = nil, source: EventSource, kind: String, payload: String = "", verified: Bool? = nil, at: Date = Date()) {
        self.id = UUID().uuidString; self.taskId = taskId; self.threadId = threadId; self.source = source
        self.kind = kind; self.payload = payload; self.verified = verified ?? source.isVerified; self.at = at
    }
}

public struct Decision: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "decisions"
    public var id: String
    public var taskId: String
    public var question: String
    public var context: String
    public var recommendation: String
    public var options: [String]
    public var state: String
    public var kind: String
    public var answer: String?
    public var answeredAt: Date?
    public var createdAt: Date
    public init(taskId: String, question: String, context: String = "", recommendation: String, options: [String], kind: String = "decision") {
        self.id = UUID().uuidString; self.taskId = taskId; self.question = question; self.context = context
        self.recommendation = recommendation; self.options = options; self.state = "pending"; self.kind = kind; self.createdAt = Date()
    }
}

public struct MemoryFact: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "memoryFacts"
    public var id: String
    public var kind: String
    public var text: String
    /// Historical categorization retained as provenance, never an access boundary.
    public var originScope: String
    public var taskId: String?
    public var source: String
    public var confirmedAt: Date?
    public var supersededBy: String?
    public var createdAt: Date
    /// The memory this note belongs to. Notes never cross into another memory.
    public var spaceId: String?
    public var forgottenAt: Date? = nil
    public init(kind: String = "fact", text: String, taskId: String? = nil, source: String) {
        self.id = UUID().uuidString; self.kind = kind; self.text = text; self.originScope = "workspace"
        self.taskId = taskId; self.source = source; self.createdAt = Date()
    }
}

public enum StoreError: LocalizedError, Sendable {
    case invalid(String), notFound, userOnly, conflict
    /// The library file is gone. Nothing is made in its place.
    case libraryMissing(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .libraryMissing(let path): "Facienda’s library is missing at \(path). Nothing was created in its place. Open Facienda to set up a new library."
        case .notFound: "This item no longer exists."
        case .userOnly: "Only the user can complete, drop, or change the automation scope of a task."
        case .conflict: "This item changed while you were editing. Refresh and try again."
        }
    }
}
