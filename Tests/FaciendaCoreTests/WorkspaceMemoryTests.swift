import Foundation
import Testing
@testable import FaciendaCore

/// The library's first workspace, as the app sees it.
private func memoryStore() throws -> FaciendaStore {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaMemoryTests/\(UUID().uuidString)/test.sqlite"))
    return library.scoped(to: try library.defaultWorkspace().id)
}

private func spaceID(_ store: FaciendaStore) throws -> String { try store.resolvedMemorySpace(nil).id }

@Test func memoryBankPersistsAndIsolatesWorkspaces() throws {
    let db = try memoryStore(), settings = try db.memorySettings()
    #expect(!settings.enabled)
    #expect(settings.workerModel == "gpt-6-luna")
    let bank = try db.resolvedMemorySpace(nil).bankId
    #expect(try FaciendaStore(url: db.url).memorySpaces().first?.bankId == bank)
    #expect(try memoryStore().resolvedMemorySpace(nil).bankId != bank)
    try db.saveMemorySettings(endpoint: settings.endpoint, enabled: true, workerModel: " gpt-6-luna ", engine: "hindsight")
    #expect(try db.memorySettings().workerModel == "gpt-6-luna")
    #expect(throws: StoreError.self) { try db.saveMemorySettings(endpoint: "https://example.com", enabled: true, workerModel: nil, engine: "hindsight") }
    #expect(throws: StoreError.self) { try db.saveMemorySettings(endpoint: "http://localhost@evil.example", enabled: true, workerModel: nil, engine: "hindsight") }
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

@Test func endpointChangeRequeuesSourcesAndCaptureIsIdempotent() throws {
    let db = try memoryStore(), settings = try db.memorySettings()
    _ = try db.create(FaciendaTask(title: "Remember my preference"))
    try db.captureWorkspaceMemory()
    #expect(try db.workspaceMemoryStatus().pending == 0)
    try db.saveMemorySettings(endpoint: settings.endpoint, enabled: true, workerModel: nil, engine: "hindsight")
    try db.captureWorkspaceMemory(); try db.captureWorkspaceMemory()
    #expect(try db.workspaceMemoryStatus().pending == 1)
    let doc = try #require(try db.claimMemoryDocument(now: Date().addingTimeInterval(1)))
    try db.finishMemoryAttempt(doc, state: "completed")
    try db.markSpaceConfigured(try spaceID(db), endpoint: settings.endpoint)
    try db.saveMemorySettings(endpoint: "https://127.0.0.1:8889", enabled: true, workerModel: nil, engine: "hindsight")
    try db.finishMemoryAttempt(doc, state: "completed")
    #expect(try db.workspaceMemoryStatus().pending == 1)
    // The bank was configured on the old service, so the new one configures it again.
    #expect(try db.resolvedMemorySpace(nil).configuredEndpoint != db.memorySettings().endpoint)
}

private final class HindsightFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let body: JSONValue
        if request.url!.path.hasSuffix("recall") {
            body = .object(["results": .array([.object(["text": .string("Use the workspace preference"), "type": .string("observation")])])])
        } else if request.url!.path.hasSuffix("/memories") {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let size = stream.read(&buffer, maxLength: buffer.count)
                    if size <= 0 { break }; data.append(contentsOf: buffer.prefix(size))
                }
            }
            let input = try! JSONDecoder().decode(JSONValue.self, from: data)
            body = .object(["success": .bool(true), "bank_id": .string(request.url!.pathComponents[4]), "operation_id": .string(input["operation_id"].string!.lowercased())])
        } else { body = .object([:]) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func recallSeparatesConfirmedNotesFromLearnedObservations() async throws {
    let db = try memoryStore(), settings = try db.memorySettings()
    var note = MemoryFact(text: "A confirmed preference", source: "user")
    note.confirmedAt = Date()
    try db.remember(note, source: .user)
    try db.saveMemorySettings(endpoint: settings.endpoint, enabled: true, workerModel: nil, engine: "hindsight")
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HindsightFixture.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let context = try await WorkspaceMemoryService(store: db, session: session, apiToken: "fixture-token").context(query: "preference")
    #expect(context["userConfirmed"].array?.count == 1)
    #expect(context["learned"]["results"].array?.first?["type"].string == "observation")
    try db.saveMemorySettings(endpoint: settings.endpoint, enabled: false, workerModel: nil)
    #expect(try await WorkspaceMemoryService(store: db, session: session, apiToken: "fixture-token").context(query: "test")["learned"] == .null)
}

@Test func retainAcceptsCanonicalizedUUIDAcknowledgements() async throws {
    let db = try memoryStore(), settings = try db.memorySettings()
    try db.saveMemorySettings(endpoint: settings.endpoint, enabled: true, workerModel: nil, engine: "hindsight")
    try db.enqueueMemoryDocument(id: "test", content: "A durable source", source: "fixture", at: Date(), spaceID: try spaceID(db))
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HindsightFixture.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    try await WorkspaceMemoryService(store: db, session: session, apiToken: "fixture-token").synchronize(limit: 1)
    #expect(try db.workspaceMemoryStatus().processing == 1)
    #expect(try db.workspaceMemoryStatus().error == nil)
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
    try store.saveMemorySettings(endpoint: "https://127.0.0.1:8888", enabled: true, workerModel: "gpt-6-luna", workerReasoningEffort: "medium")
    #expect(try store.memorySettings().workerReasoningEffort == "medium")
    #expect(throws: StoreError.self) { try store.saveMemorySettings(endpoint: "https://127.0.0.1:8888", enabled: true, workerModel: "gpt-6-luna", workerReasoningEffort: "typo") }
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
