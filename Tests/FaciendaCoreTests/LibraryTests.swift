import Foundation
import Testing
import GRDB
@testable import FaciendaCore

private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "FaciendaLibraryTests/\(UUID().uuidString)") }

private func library() throws -> FaciendaStore { try FaciendaStore(url: folder().appending(path: "facienda.sqlite")) }

/// Synchronous reads, so async tests do not pick GRDB's async overloads.
private func value<T: DatabaseValueConvertible>(_ db: FaciendaStore, _ sql: String, _ arguments: StatementArguments = []) throws -> T? {
    try db.db.read { try T.fetchOne($0, sql: sql, arguments: arguments) }
}

private func documentSpaces(_ db: FaciendaStore) throws -> [String: String] {
    try db.db.read { try Row.fetchAll($0, sql: "SELECT id, spaceId FROM memoryDocuments") }.reduce(into: [:]) { $0[$1["id"] as String] = $1["spaceId"] as String }
}

@Test func workspacesShowOnlyTheirOwnTasksAndGroups() throws {
    let db = try library(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: home.memorySpaceId)
    let personal = db.scoped(to: home.id), office = db.scoped(to: work.id)
    let errand = try personal.create(FaciendaTask(title: "Buy a lamp"))
    let report = try office.create(FaciendaTask(title: "Quarterly report"))
    #expect(errand.workspaceId == home.id && report.workspaceId == work.id)
    #expect(try personal.tasks().map(\.id) == [errand.id])
    #expect(try office.tasks(search: "lamp").isEmpty)
    #expect(try db.tasks().count == 2)
    let shopping = try personal.createGroup(name: "Shopping"), planning = try office.createGroup(name: "Planning")
    #expect(try personal.groups().map(\.id) == [shopping.id])
    #expect(try office.groups().map(\.id) == [planning.id])
    #expect(planning.position == 0)
    try personal.assignGroup(taskId: errand.id, groupId: shopping.id)
    #expect(throws: StoreError.self) { try office.assignGroup(taskId: report.id, groupId: shopping.id) }
    #expect(try office.groupMembers().isEmpty)
    // Editing a task never moves it.
    var edited = try personal.task(errand.id); edited.workspaceId = work.id
    try personal.update(errand.id) { $0 = edited }
    #expect(try db.task(errand.id).workspaceId == home.id)
    #expect(try db.newCounts().isEmpty)
    _ = try office.update(report.id) { $0.state = .running }
    try office.saveResult(taskId: report.id, text: "Drafted")
    #expect(try db.newCounts() == [work.id: 1])
}

@Test func runnerFilesNewTasksInsideTheirOwnWorkspace() throws {
    let db = try library(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: home.memorySpaceId)
    try db.bindRunner(threadId: "runner", automationId: "beat")
    _ = try db.scoped(to: home.id).createGroup(name: "Travel")
    let trip = try db.scoped(to: work.id).create(FaciendaTask(title: "Conference trip"))
    let group = try #require(try db.proposeGroup(taskId: trip.id, runnerID: "runner", name: "travel"))
    #expect(group.workspaceId == work.id)
    #expect(try db.scoped(to: home.id).groups().count == 1)
    // Work saved without a workspace, such as by an older helper, still lands somewhere visible.
    try db.db.write { try $0.execute(sql: "INSERT INTO tasks(id, title, intention, definitionOfDone, area, state, nextAction, automationScope, brief, snoozeCount, createdAt, updatedAt, revision) VALUES ('orphan', 'Orphan', '', '', '', 'inbox', 'x', 'prepareOnly', '', 0, 0, 0, 0)") }
    #expect(try db.task("orphan").workspaceId == home.id)
}

@Test func groupsMoveBetweenWorkspacesWithTheirHistory() throws {
    let db = try library(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: try db.createMemorySpace(name: "Work").id)
    let personal = db.scoped(to: home.id), office = db.scoped(to: work.id)
    _ = try office.createGroup(name: "Existing")
    let group = try personal.createGroup(name: "Taxes")
    try personal.placeGroups([GroupPlacement(id: group.id, lane: 1, row: 2)])
    let a = try personal.create(FaciendaTask(title: "Collect receipts")), b = try personal.create(FaciendaTask(title: "File the return"))
    let loose = try personal.create(FaciendaTask(title: "Unrelated"))
    for task in [a, b] { try personal.assignGroup(taskId: task.id, groupId: group.id) }
    try db.link(ThreadLink(taskId: a.id, codexThreadId: "chat-a"))
    try db.moveGroup(group.id, toWorkspace: work.id)
    let moved = try #require(try office.groups().first { $0.id == group.id })
    #expect(moved.lane == nil && moved.row == nil && moved.position == 1)
    #expect(Set(try office.tasks().map(\.id)) == [a.id, b.id])
    #expect(try personal.tasks().map(\.id) == [loose.id])
    #expect(try office.groupMembers().count == 2)
    // Chats, revisions and history travel unchanged.
    #expect(try db.links(taskId: a.id).first?.codexThreadId == "chat-a")
    #expect(try db.task(a.id).revision == a.revision)
    #expect(try db.latestEvent(taskId: a.id, kind: "task.moved")?.payload == "Work")
    #expect(try db.memorySpace(forTask: b.id).id == work.memorySpaceId)
    let archive = try db.createWorkspace(name: "Archive", memorySpaceID: home.memorySpaceId)
    try db.removeWorkspace(archive.id)
    #expect(throws: StoreError.self) { try db.moveGroup(group.id, toWorkspace: archive.id) }
}

@Test func removingAWorkspaceKeepsItsHistoryButNeverOpenWork() throws {
    let db = try library(), home = try db.defaultWorkspace()
    #expect(throws: StoreError.self) { try db.removeWorkspace(home.id) }
    let side = try db.createWorkspace(name: "Side project", memorySpaceID: home.memorySpaceId)
    let task = try db.scoped(to: side.id).create(FaciendaTask(title: "Sketch"))
    #expect(throws: StoreError.self) { try db.removeWorkspace(side.id) }
    _ = try db.update(task.id) { $0.state = .done }
    try db.removeWorkspace(side.id)
    #expect(try db.workspaces().map(\.id) == [home.id])
    #expect(try db.workspaces(includeRemoved: true).count == 2)
    #expect(try db.task(task.id).state == .done)
}

@Test func memoriesStaySeparateFromCaptureToHindsight() async throws {
    let db = try library(), home = try db.defaultWorkspace()
    let workMemory = try db.createMemorySpace(name: "Work")
    #expect(throws: StoreError.self) { try db.createMemorySpace(name: "work") }
    let work = try db.createWorkspace(name: "Office", memorySpaceID: workMemory.id)
    let personal = db.scoped(to: home.id), office = db.scoped(to: work.id)
    let errand = try personal.create(FaciendaTask(title: "Book the dentist"))
    let report = try office.create(FaciendaTask(title: "Quarterly report"))
    var note = MemoryFact(text: "Dentist is Dr. Silva", source: "User"); note.confirmedAt = Date()
    try personal.remember(note, source: .user)
    try office.remember(MemoryFact(text: "Reports go to Ana", taskId: report.id, source: "User"), source: .user)
    #expect(try personal.memory().map(\.text) == ["Dentist is Dr. Silva"])
    #expect(try office.memory().map(\.text) == ["Reports go to Ana"])
    let settings = try db.memorySettings()
    try db.saveMemorySettings(endpoint: settings.endpoint, enabled: true, workerModel: nil, engine: "hindsight")
    try db.captureWorkspaceMemory()
    let spaces = try documentSpaces(db)
    #expect(spaces["task-\(errand.id)"] == home.memorySpaceId)
    #expect(spaces["task-\(report.id)"] == workMemory.id)
    #expect(spaces["curated-notes-\(home.memorySpaceId)"] == home.memorySpaceId)
    #expect(spaces["curated-notes-\(workMemory.id)"] == workMemory.id)
    #expect(try personal.workspaceMemoryStatus().pending == 2)

    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BankRecorder.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    BankRecorder.reset()
    try await WorkspaceMemoryService(store: db, session: session, apiToken: "fixture-token").synchronize(limit: 10)
    let banks = BankRecorder.retained()
    let personalBank = try db.memorySpace(home.memorySpaceId).bankId
    #expect(banks["task-\(errand.id)"] == personalBank)
    #expect(banks["task-\(report.id)"] == workMemory.bankId)
    #expect(banks.values.allSatisfy { $0 == personalBank || $0 == workMemory.bankId })
    // Each bank is configured once, on its own.
    #expect(try db.memorySpaces().allSatisfy { $0.configuredEndpoint == settings.endpoint })
    let context = try await WorkspaceMemoryService(store: office, session: session, apiToken: "fixture-token").context(query: "")
    #expect(context["memory"].string == "Work")
    #expect(context["bankId"].string == workMemory.bankId)
    #expect(context["userConfirmed"].array?.isEmpty == true)
    #expect(BankRecorder.recalled() == [workMemory.bankId])

    // A note saved in the wrong memory can move; its old memory's notes are resent without it.
    try db.moveMemory(note.id, toSpace: workMemory.id)
    #expect(try personal.memory().isEmpty)
    try db.captureWorkspaceMemory()
    let curated: String? = try value(db, "SELECT content FROM memoryDocuments WHERE id = ?", ["curated-notes-\(home.memorySpaceId)"])
    #expect(curated?.contains("no user-confirmed notes") == true)
    // A workspace that switches memory learns into the new one; what it learned before stays.
    try db.setMemorySpace(workspaceID: home.id, spaceID: workMemory.id)
    #expect(try db.memorySpace(forTask: errand.id).id == workMemory.id)
    try db.captureWorkspaceMemory()
    #expect(try documentSpaces(db)["task-\(errand.id)"] == home.memorySpaceId)
    #expect(throws: StoreError.self) { try db.deleteMemorySpace(workMemory.id) }
    try db.deleteMemorySpace(home.memorySpaceId)
    #expect(try db.memorySpaces().map(\.id) == [workMemory.id])
    let left: Int? = try value(db, "SELECT count(*) FROM memoryDocuments WHERE spaceId = ?", [home.memorySpaceId])
    #expect(left == 0)
}

private final class BankRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var documents: [String: String] = [:]
    nonisolated(unsafe) private static var recalls: [String] = []
    private static let lock = NSLock()
    static func reset() { lock.withLock { documents = [:]; recalls = [] } }
    static func retained() -> [String: String] { lock.withLock { documents } }
    static func recalled() -> [String] { lock.withLock { recalls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let bank = request.url!.pathComponents.count > 4 ? request.url!.pathComponents[4] : ""
        var body: JSONValue = .object([:])
        if request.url!.path.hasSuffix("/memories") {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; data.append(contentsOf: buffer.prefix(size)) }
            }
            let input = try! JSONDecoder().decode(JSONValue.self, from: data)
            Self.lock.withLock { Self.documents[input["items"].array![0]["document_id"].string!] = bank }
            body = .object(["success": .bool(true), "bank_id": .string(bank), "operation_id": .string(input["operation_id"].string!)])
        } else if request.url!.path.hasSuffix("recall") {
            Self.lock.withLock { Self.recalls.append(bank) }
            body = .object(["results": .array([])])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func workspacePicturesSitWithTheCoversAndKeepTheirPreviousOneUntilTheWorkspaceGoes() throws {
    let db = try library(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: home.memorySpaceId)
    #expect(try db.workspace(work.id).coverPaintedAt == nil)
    try db.saveCover(workspaceId: work.id, image: Data([1]), style: "Precisionism")
    try db.saveCover(workspaceId: work.id, image: Data([2]), style: "Precisionism at dusk", note: " at dusk\n")
    var saved = try db.workspace(work.id)
    #expect(saved.coverStyle == "Precisionism at dusk" && saved.coverPaintedAt != nil && saved.coverNoteList == ["at dusk"])
    let file = db.coverURL(workspaceId: work.id)
    #expect(file.deletingLastPathComponent() == db.coverURL(groupId: "any").deletingLastPathComponent())
    #expect(try Data(contentsOf: file) == Data([2]))
    #expect(try Data(contentsOf: db.previousCoverURL(workspaceId: work.id)) == Data([1]))
    // A scoped store reaches the same picture as the library.
    #expect(db.scoped(to: work.id).coverURL(workspaceId: work.id) == file)
    try db.restorePreviousCover(workspaceId: work.id, style: "Precisionism", notes: [])
    saved = try db.workspace(work.id)
    #expect(saved.coverStyle == "Precisionism" && saved.coverNotes == nil)
    #expect(try Data(contentsOf: file) == Data([1]))
    try db.setCoverNotes(workspaceId: work.id, notes: ["no people"])
    #expect(try db.workspace(work.id).coverNoteList == ["no people"])
    #expect(throws: StoreError.self) { try db.saveCover(workspaceId: "missing", image: Data([1]), style: "") }
    #expect(!FileManager.default.fileExists(atPath: db.coverURL(workspaceId: "missing").path))
    try db.removeWorkspace(work.id)
    #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: db.previousCoverURL(workspaceId: work.id).path))
}

@Test func reviewCountsLeaveOutClosedAndRunningWork() throws {
    let db = try library(), home = try db.defaultWorkspace()
    let work = try db.createWorkspace(name: "Work", memorySpaceID: home.memorySpaceId)
    let scoped = db.scoped(to: work.id)
    _ = try scoped.create(FaciendaTask(title: "Open"))
    _ = try scoped.update(try scoped.create(FaciendaTask(title: "Asks")).id) { $0.state = .needsMe }
    for state in [TaskState.done, .dropped, .running] {
        _ = try scoped.update(try scoped.create(FaciendaTask(title: state.label)).id) { $0.state = state }
    }
    _ = try db.scoped(to: home.id).create(FaciendaTask(title: "At home"))
    #expect(try db.reviewCounts() == [work.id: 2, home.id: 1])
}
