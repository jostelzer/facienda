import Foundation
import GRDB

public struct WorkspaceSetup: Codable, FetchableRecord, Equatable, Sendable {
    public var projectPath: String
    public var projectName: String { Self.projectName }
    public var projectId: String?
    public var challenge: String
    public var requestedAt: Date
    public var verifiedAt: Date?
    public var runnerId: String?
    public var automationId: String?
    /// App-server identity; native chat tools may use a different project identity.
    public var codexProjectId: String?
    public var confirmedProjectName: String?
    public var projectNameVerifiedAt: Date?
    /// The runner chat a new runner replaced, and its heartbeat, so the new runner can pause it.
    public var retiredRunnerId: String?
    public var retiredAutomationId: String?
    /// The Codex project that holds the runner chat and the task chats, whatever the library folder is called.
    public static let projectName = "facienda"
    public static let runnerName = "facienda-runner"
    public func isReady(runner: NativeRunnerState?) -> Bool {
        guard let runner, let verifiedAt, let projectId, !projectId.isEmpty else { return false }
        // The dispatcher needs no automation: setup itself confirmed the project.
        if runner.isDispatcher { return runnerId == runner.threadId && verifiedAt >= requestedAt }
        guard let automationId, !automationId.isEmpty else { return false }
        return runner.threadId == runnerId && runner.automationId == automationId &&
            verifiedAt >= requestedAt && (runner.lastSeen ?? .distantPast) >= requestedAt
    }
}

extension FaciendaStore {
    /// The Codex project: the data folder, which holds the library and every task's own folder.
    public var nativeProjectDirectory: URL { workFolder }
    public var nativeProjectName: String { WorkspaceSetup.projectName }

    static func registerRetiredRunner(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("retired_runner") { db in
            try db.execute(sql: "ALTER TABLE workspaceSetup ADD COLUMN retiredRunnerId TEXT")
            try db.execute(sql: "ALTER TABLE workspaceSetup ADD COLUMN retiredAutomationId TEXT")
        }
    }

    static func registerRunnerFolder(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("runner_folder") { db in
            try db.execute(sql: "ALTER TABLE workspaceSetup ADD COLUMN runnerPath TEXT")
        }
    }

    static func registerScheduledRunner(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("scheduled_runner") { db in
            try db.execute(sql: """
                ALTER TABLE runnerState ADD COLUMN scheduled INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE runnerState ADD COLUMN leaseHolder TEXT;
                ALTER TABLE runnerState ADD COLUMN leaseUntil DATETIME;
                ALTER TABLE runnerState ADD COLUMN unreportedSeenAt DATETIME;
                """)
        }
    }

    public func workspaceSetup() throws -> WorkspaceSetup? {
        try db.read { try WorkspaceSetup.fetchOne($0, sql: "SELECT * FROM workspaceSetup WHERE id = 1") }
    }

    /// Reopening unfinished setup reuses the same challenge and native project.
    /// A new runner retires the bound one: setup then makes a fresh runner chat, which pauses the old one's heartbeat.
    public func prepareWorkspaceSetup(repair: Bool = false, newRunner: Bool = false) throws -> WorkspaceSetup {
        try FileManager.default.createDirectory(at: nativeProjectDirectory, withIntermediateDirectories: true)
        return try write { db in
            if let existing = try WorkspaceSetup.fetchOne(db, sql: "SELECT * FROM workspaceSetup WHERE id = 1"),
               existing.projectPath == nativeProjectDirectory.path, !repair, !newRunner { return existing }
            if newRunner, let old = try NativeRunnerState.fetchOne(db, sql: "SELECT * FROM runnerState WHERE id = 1") {
                try db.execute(sql: "DELETE FROM runnerState WHERE id = 1")
                // Claimed but not yet delivered: the new runner takes them from the top. Deliveries already under way keep their record.
                try db.execute(sql: "UPDATE dispatches SET state = 'queued', runnerId = NULL WHERE state = 'claimed' AND runnerId = ?", arguments: [old.threadId])
                try db.execute(sql: "UPDATE workspaceSetup SET retiredRunnerId = ?, retiredAutomationId = ? WHERE id = 1", arguments: [old.threadId, old.automationId])
            }
            try db.execute(sql: """
                INSERT INTO workspaceSetup(id, projectPath, challenge, requestedAt) VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  projectId = CASE WHEN workspaceSetup.projectPath = excluded.projectPath THEN workspaceSetup.projectId ELSE NULL END,
                  codexProjectId = NULL, confirmedProjectName = NULL, projectNameVerifiedAt = NULL,
                  projectPath = excluded.projectPath, challenge = excluded.challenge,
                  requestedAt = excluded.requestedAt, verifiedAt = NULL
                """, arguments: [nativeProjectDirectory.path, UUID().uuidString, Date()])
            return try WorkspaceSetup.fetchOne(db, sql: "SELECT * FROM workspaceSetup WHERE id = 1")!
        }
    }

    /// Save the supported project API's confirmation separately from native chat identity.
    public func confirmWorkspaceProject(challenge: String, id: String, name: String, directory: URL) throws {
        try write { db in
            guard let setup = try WorkspaceSetup.fetchOne(db, sql: "SELECT * FROM workspaceSetup WHERE id = 1"),
                  setup.challenge == challenge, !id.isEmpty, name == setup.projectName,
                  directory.standardizedFileURL.resolvingSymlinksInPath() == nativeProjectDirectory.standardizedFileURL.resolvingSymlinksInPath()
            else { throw StoreError.conflict }
            try db.execute(sql: "UPDATE workspaceSetup SET codexProjectId = ?, confirmedProjectName = ?, projectNameVerifiedAt = ? WHERE id = 1", arguments: [id, name, Date()])
        }
    }

    /// A native runner reports the project/automation checks and answers the current challenge.
    public func verifyWorkspaceSetup(challenge: String, projectId: String, runnerId: String, automationId: String) throws {
        guard !projectId.isEmpty, !automationId.isEmpty else { throw StoreError.invalid("Verify the native project and heartbeat first.") }
        try write { db in
            guard let setup = try WorkspaceSetup.fetchOne(db, sql: "SELECT * FROM workspaceSetup WHERE id = 1"), setup.challenge == challenge,
                  let runner = try NativeRunnerState.fetchOne(db, sql: "SELECT * FROM runnerState WHERE id = 1"),
                  runner.threadId == runnerId, runner.automationId == automationId else { throw StoreError.conflict }
            let now = Date()
            try db.execute(sql: "UPDATE runnerState SET lastSeen = ? WHERE id = 1", arguments: [now])
            try db.execute(sql: "UPDATE workspaceSetup SET projectId = ?, runnerId = ?, automationId = ?, verifiedAt = ? WHERE id = 1", arguments: [projectId, runnerId, automationId, now])
        }
    }
}
