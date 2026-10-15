import Foundation
import GRDB
import Testing
@testable import FaciendaCore

@Test func setupRequiresRunnerResponseAndReusesPendingConnection() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/workspace.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    #expect(setup.projectPath == folder.path)
    #expect(setup.projectName == "facienda")
    #expect(try store.prepareWorkspaceSetup().challenge == setup.challenge)
    #expect(!setup.isReady(runner: nil))
    try store.bindRunner(threadId: "runner", automationId: "heartbeat")
    try store.runnerHeartbeat("runner")
    #expect(try store.workspaceSetup()?.isReady(runner: store.runnerState()) == false)
    #expect(throws: StoreError.self) {
        try store.verifyWorkspaceSetup(challenge: "stale", projectId: "project", runnerId: "runner", automationId: "heartbeat")
    }
    #expect(throws: StoreError.self) {
        try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "wrong", automationId: "heartbeat")
    }
    try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "runner", automationId: "heartbeat")
    let reopened = try FaciendaStore(url: store.url)
    #expect(try reopened.workspaceSetup()?.isReady(runner: reopened.runnerState()) == true)
    let repair = try reopened.prepareWorkspaceSetup(repair: true)
    #expect(repair.projectId == "project")
    #expect(repair.challenge != setup.challenge)
    #expect(!repair.isReady(runner: try reopened.runnerState()))
    #expect(throws: StoreError.self) {
        try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "runner", automationId: "heartbeat")
    }
}

@Test func selectedWorkspaceFolderIsTheProjectRootAndDeterminesItsName() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    #expect(store.nativeProjectDirectory.path == folder.path)
    #expect(store.nativeProjectName == "facienda")
    #expect(setup.projectPath == folder.path)
    #expect(setup.projectName == "facienda")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "facienda-WORKSPACE").path))
}

@Test func projectNameConfirmationUsesExactRootAndCurrentChallenge() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    for (challenge, name, directory) in [
        ("stale", "facienda", folder),
        (setup.challenge, "org", folder),
        (setup.challenge, "facienda", folder.appending(path: "facienda-WORKSPACE"))
    ] {
        #expect(throws: StoreError.self) {
            try store.confirmWorkspaceProject(challenge: challenge, id: "server-project", name: name, directory: directory)
        }
    }
    try store.confirmWorkspaceProject(challenge: setup.challenge, id: "server-project", name: "facienda", directory: folder)
    let reopened = try FaciendaStore(url: store.url)
    let confirmed = try #require(try reopened.workspaceSetup())
    #expect(confirmed.confirmedProjectName == "facienda")
    #expect(confirmed.codexProjectId == "server-project")
    #expect(confirmed.projectId == nil)
    #expect(try #require(confirmed.projectNameVerifiedAt) >= confirmed.requestedAt)
    #expect(try reopened.prepareWorkspaceSetup().codexProjectId == "server-project")
    let repair = try reopened.prepareWorkspaceSetup(repair: true)
    #expect(repair.codexProjectId == nil && repair.confirmedProjectName == nil && repair.projectNameVerifiedAt == nil)
}

@Test func reopeningLegacyProjectCorrectsRootAndInvalidatesOnlyItsVerification() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "runner", automationId: "heartbeat")
    try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "legacy-project", runnerId: "runner", automationId: "heartbeat")
    let cwd = folder.appending(path: "facienda-WORKSPACE/Work/task").path
    let task = try store.create(FaciendaTask(title: "Existing task", cwd: cwd))
    try store.db.write { db in
        try db.execute(sql: "UPDATE workspaceSetup SET projectPath = ?", arguments: [folder.appending(path: "facienda-WORKSPACE").path])
    }
    let reopened = try FaciendaStore(url: store.url)
    let corrected = try #require(try reopened.workspaceSetup())
    #expect(corrected.projectPath == folder.path)
    #expect(corrected.projectId == nil && corrected.verifiedAt == nil)
    #expect(corrected.challenge != setup.challenge)
    #expect(try reopened.runnerState()?.threadId == "runner")
    #expect(try reopened.task(task.id).cwd == cwd)
    #expect(reopened.isAutomaticWorkingDirectory(reopened.taskFolder(task.id).path, taskID: task.id))
    #expect(!corrected.isReady(runner: try reopened.runnerState()))
    #expect(try reopened.prepareWorkspaceSetup(repair: true).projectPath == folder.path)
}

@Test func automaticWorkingFoldersRemainRecognizedAfterCreation() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)/org")
    // The runner reconstructs the database URL from its --database path.
    let store = try FaciendaStore(url: URL(fileURLWithPath: folder.appending(path: ".facienda/facienda.sqlite").path))
    let taskID = UUID().uuidString
    // Task folders sit in the data folder beside the hidden library folder.
    #expect(!store.isAutomaticWorkingDirectory(folder.appending(path: "Work/\(taskID)").path, taskID: taskID))
    do {
        let working = folder.appending(path: taskID)
        #expect(store.isAutomaticWorkingDirectory(working.path, taskID: taskID))
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        #expect(store.isAutomaticWorkingDirectory(working.path, taskID: taskID))
        #expect(store.isAutomaticWorkingDirectory(working.path + "/", taskID: taskID))
        #expect(!store.isAutomaticWorkingDirectory(working.path, taskID: "other-task"))
        #expect(!store.isAutomaticWorkingDirectory(working.appending(path: "child").path, taskID: taskID))
    }
    #expect(!store.isAutomaticWorkingDirectory(folder.appending(path: "Chosen project").path, taskID: taskID))
}

@Test func newRunnerRetiresTheBoundRunner() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    let setup = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "old-runner", automationId: "old-heartbeat")
    try store.verifyWorkspaceSetup(challenge: setup.challenge, projectId: "project", runnerId: "old-runner", automationId: "old-heartbeat")
    let task = try store.create(FaciendaTask(title: "Waiting to be delivered"))
    let item = try store.enqueueDispatch(taskId: task.id)
    #expect(try store.claimDispatch(runnerId: "old-runner")?.id == item.id)

    let fresh = try store.prepareWorkspaceSetup(newRunner: true)
    #expect(try store.runnerState() == nil)
    #expect(fresh.challenge != setup.challenge)
    #expect(fresh.retiredRunnerId == "old-runner" && fresh.retiredAutomationId == "old-heartbeat")
    // The old runner can no longer claim; its undelivered claim waits for the new one.
    #expect(try store.dispatches().first { $0.id == item.id }?.state == "queued")
    #expect(throws: StoreError.self) { try store.claimDispatch(runnerId: "old-runner") }

    try store.bindRunner(threadId: "new-runner", automationId: "new-heartbeat")
    #expect(try store.claimDispatch(runnerId: "new-runner")?.id == item.id)
}

@Test func aRunnerChatMustBeRetiredBeforeAScheduledRunnerBinds() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)/org")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    _ = try store.prepareWorkspaceSetup()
    try store.bindRunner(threadId: "old-runner", automationId: "old-heartbeat")
    #expect(throws: StoreError.self) { try store.bindScheduledRunner(id: "runner-new") }
    let fresh = try store.prepareWorkspaceSetup(newRunner: true)
    #expect(try store.bindScheduledRunner(id: "runner-new") == "runner-new")
    #expect(fresh.retiredAutomationId == "old-heartbeat")
}

@Test func cleanlyFinishedRunsAreArchivedOnceAndTheRunnerItselfNever() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaSetupTests/\(UUID().uuidString)")
    let store = try FaciendaStore(url: folder.appending(path: ".facienda/facienda.sqlite"))
    try store.bindRunner(threadId: "runner", automationId: "automation")
    let start = Date()
    try store.recordFinishedRun("run-1", now: start)
    try store.recordFinishedRun("run-1", now: start)
    try store.recordFinishedRun("runner", now: start)
    try store.recordFinishedRun("unknown", now: start)
    // A minute's grace before archiving, so the run's last turn can close.
    #expect(try store.runnerRunsToArchive(now: start).isEmpty)
    #expect(try store.runnerRunsToArchive(now: start.addingTimeInterval(61)) == ["run-1"])
    try store.recordFinishedRun("run-2", now: start)
    for _ in 0..<3 { try store.markRunnerRun("run-2", archived: false, now: start) }
    try store.markRunnerRun("run-1", archived: true, now: start)
    #expect(try store.runnerRunsToArchive(now: start.addingTimeInterval(61)).isEmpty)
}
