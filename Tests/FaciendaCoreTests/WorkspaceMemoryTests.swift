import Foundation
import Testing
@testable import FaciendaCore

/// The library's first workspace, as the app sees it.
private func memoryStore() throws -> FaciendaStore {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaMemoryTests/\(UUID().uuidString)/test.sqlite"))
    return library.scoped(to: try library.defaultWorkspace().id)
}

private func spaceID(_ store: FaciendaStore) throws -> String { try store.resolvedMemorySpace(nil).id }

@Test func memorySettingsHaveNoServerEndpoint() throws {
    let db = try memoryStore(), settings = try db.memorySettings()
    #expect(!settings.enabled)
    try db.saveMemorySettings(enabled: true, workerModel: " gpt-6-luna ")
    #expect(try db.memorySettings().workerModel == "gpt-6-luna")
    let json = try JSONValue.encoded(db.memorySettings())
    #expect(json["endpoint"] == .null && json["engine"] == .null)
}

@Test func memoryOutboxRecoversLeaseAndIgnoresStaleAcknowledgement() throws {
    let db = try memoryStore(), now = Date().addingTimeInterval(5), space = try spaceID(db)
    try db.enqueueMemoryDocument(id: "source", content: "First", source: "test", at: now, spaceID: space)
    let first = try #require(try db.claimMemoryDocument(now: now))
    #expect(try db.claimMemoryDocument(now: now) == nil)
    try db.enqueueMemoryDocument(id: "source", content: "First", source: "test", at: now, spaceID: space)
    let reopened = try FaciendaStore(url: db.url)
    let retry = try #require(try reopened.claimMemoryDocument(now: now.addingTimeInterval(91)))
    #expect(first.operationId == retry.operationId)
    try db.enqueueMemoryDocument(id: "source", content: "Correction", source: "test", at: now, spaceID: space)
    try db.finishMemoryAttempt(first, state: "completed")
    #expect(try db.workspaceMemoryStatus().pending == 1)
    let corrected = try #require(try db.claimMemoryDocument(now: now.addingTimeInterval(92)))
    #expect(corrected.operationId != first.operationId)
    #expect(corrected.content == "Correction")
}

@Test func userSourceCaptureIsIdempotent() throws {
    let db = try memoryStore()
    _ = try db.create(FaciendaTask(title: "Use blue tiles"))
    try db.captureWorkspaceMemory()
    #expect(try db.workspaceMemoryStatus().pending == 0)
    try db.saveMemorySettings(enabled: true, workerModel: nil)
    try db.captureWorkspaceMemory(); try db.captureWorkspaceMemory()
    #expect(try db.workspaceMemoryStatus().pending == 1)
}

@Test func recallKeepsConfirmedNotesAvailableWhenLearningIsOff() async throws {
    let db = try memoryStore()
    var note = MemoryFact(text: "Use blue tiles", source: "user")
    note.confirmedAt = Date()
    try db.remember(note, source: .user)
    let context = try await WorkspaceMemoryService(store: db).context(query: "tiles")
    #expect(context["userConfirmed"].array?.count == 1)
    #expect(context["learned"] == .null)
}

@Test func memoryCredentialsRejectSharedPermissionsAndModelDefaultsAreExplicit() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "memory-credentials-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "token")
    try String(repeating: "x", count: 48).write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: StoreError.self) { try MemoryServiceCredentials.readToken(at: file) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(try MemoryServiceCredentials.readToken(at: file).count == 48)
    let store = try memoryStore()
    #expect(try store.memorySettings().workerModel == "gpt-6-luna")
    #expect(try store.memorySettings().workerReasoningEffort == "high")
    try store.saveMemorySettings(enabled: true, workerModel: "gpt-6-luna", workerReasoningEffort: "medium")
    #expect(try store.memorySettings().workerReasoningEffort == "medium")
    #expect(throws: StoreError.self) { try store.saveMemorySettings(enabled: true, workerModel: "gpt-6-luna", workerReasoningEffort: "typo") }
}

@Test func credentialsRejectSymlinksAndDatabaseFilesStayPrivate() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "memory-file-security-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let token = folder.appending(path: "token")
    try String(repeating: "a", count: 48).write(to: token, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
    let link = folder.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: token)
    #expect(throws: StoreError.self) { try MemoryServiceCredentials.readToken(at: link) }
    let store = try FaciendaStore(url: folder.appending(path: "facienda.sqlite"))
    _ = try store.create(FaciendaTask(title: "Synthetic storage-permission test"))
    for suffix in ["", "-wal", "-shm"] {
        let path = store.url.path + suffix
        if FileManager.default.fileExists(atPath: path) {
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }
}
