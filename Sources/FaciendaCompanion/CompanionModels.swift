import Foundation
import SwiftData

/// The phone owns the immutable request; only the Mac creates task summaries.
/// CloudKit models deliberately have defaults and no uniqueness constraints.
@Model public final class CompanionRequest {
    public var requestID: String = ""
    public var text: String = ""
    public var createdAt: Date = Date()
    public var receivedAt: Date?
    public var workspaceID: String = ""

    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(), workspaceID: String = "") {
        self.requestID = id; self.text = text; self.createdAt = createdAt
        self.workspaceID = workspaceID
    }
}

@Model public final class CompanionTask {
    public var taskID: String = ""
    public var title: String = ""
    public var detail: String = ""
    public var section: String = "waiting"
    public var status: String = "Waiting"
    public var revision: Int = 0
    public var updatedAt: Date = Date()
    public var workspaceID: String = ""

    public init(id: String, title: String, detail: String, section: String, status: String, revision: Int = 0, updatedAt: Date = Date(), workspaceID: String = "") {
        self.taskID = id; self.title = title; self.detail = detail; self.section = section
        self.status = status; self.revision = revision; self.updatedAt = updatedAt
        self.workspaceID = workspaceID
    }
}

@Model public final class CompanionWorkspace {
    public var workspaceID: String = ""
    public var name: String = ""
    public var nameUpdatedAt: Date = Date()
    public var createdAt: Date = Date()
    public var syncedAt: Date?
    public var ready: Bool = false
    public var isDefault: Bool = false

    public init(id: String = UUID().uuidString, name: String, updatedAt: Date = Date()) {
        workspaceID = id; self.name = name; nameUpdatedAt = updatedAt; createdAt = updatedAt
    }

    public static func unique(_ workspaces: [CompanionWorkspace]) -> [CompanionWorkspace] {
        var latest: [String: CompanionWorkspace] = [:]
        for workspace in workspaces {
            if let previous = latest[workspace.workspaceID], previous.nameUpdatedAt >= workspace.nameUpdatedAt { continue }
            latest[workspace.workspaceID] = workspace
        }
        return latest.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.workspaceID < $1.workspaceID
        }
    }
}

public enum CompanionSection: String, CaseIterable, Identifiable, Sendable {
    case processing, review, waiting, scheduled, done
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .processing: "In progress"
        case .review: "For review"
        case .waiting: "Waiting"
        case .scheduled: "Scheduled"
        case .done: "Done"
        }
    }
    public var symbol: String {
        switch self {
        case .processing: "circle.dotted"
        case .review: "eye"
        case .waiting: "hourglass"
        case .scheduled: "calendar"
        case .done: "checkmark.circle"
        }
    }
}

public struct CompanionItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var section: String
    public var status: String
    public var updatedAt: Date

    public var category: CompanionSection { CompanionSection(rawValue: section) ?? .waiting }

    /// Resolve duplicate CloudKit inserts by revision, then suppress acknowledged outbox items.
    @MainActor public static func merged(tasks: [CompanionTask], requests: [CompanionRequest], cloudEnabled: Bool, workspaceID: String? = nil, includeUnassigned: Bool = false) -> [Self] {
        let tasks = tasks.filter { workspaceID == nil || $0.workspaceID == workspaceID || (includeUnassigned && $0.workspaceID.isEmpty) }
        let requests = requests.filter { workspaceID == nil || $0.workspaceID == workspaceID || (includeUnassigned && $0.workspaceID.isEmpty) }
        var latest: [String: CompanionTask] = [:]
        for task in tasks {
            if let previous = latest[task.taskID],
               previous.revision > task.revision || (previous.revision == task.revision && previous.updatedAt >= task.updatedAt) { continue }
            latest[task.taskID] = task
        }
        var items = latest.values.map {
            Self(id: $0.taskID, title: $0.title, detail: $0.detail, section: $0.section, status: $0.status, updatedAt: $0.updatedAt)
        }
        for request in requests where latest[request.requestID] == nil {
            guard !items.contains(where: { $0.id == request.requestID }) else { continue }
            items.append(Self(id: request.requestID, title: request.text, detail: "", section: "processing",
                              status: request.receivedAt != nil ? "Received by Mac" : cloudEnabled ? "Waiting for Mac" : "Saved on this iPhone",
                              updatedAt: request.createdAt))
        }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }
}

public enum CompanionStorage {
    public static let containerID = "iCloud.org.facienda"

    @MainActor public static func makeContainer(cloudEnabled: Bool, inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([CompanionRequest.self, CompanionTask.self, CompanionWorkspace.self])
        let database: ModelConfiguration.CloudKitDatabase = cloudEnabled ? .private(containerID) : .none
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration("FaciendaCompanion", schema: schema, url: url, cloudKitDatabase: database)
        } else {
            configuration = ModelConfiguration("FaciendaCompanion", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: database)
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
