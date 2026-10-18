import Foundation
import Testing
@testable import FaciendaCore

private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.standardizedFileURL
}

private let sheet = "https://docs.google.com/spreadsheets/d/1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdEF/edit#gid=1923818370"
private let folder = "https://drive.google.com/drive/folders/1FaKeFoLdErIdAbCdEfGhIjKlMnOpQrSt"

@Test func sourcesKnowWhatTheyAreFromTheirAddress() throws {
    let root = try scratch()
    let notes = root.appending(path: "notes.md"), shelf = root.appending(path: "shelf")
    try Data("x".utf8).write(to: notes)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    #expect(SourceKind.of(sheet) == .sheet)
    #expect(SourceKind.of("https://docs.google.com/document/d/abc/edit") == .doc)
    #expect(SourceKind.of("https://docs.google.com/presentation/d/abc/edit") == .slides)
    #expect(SourceKind.of(folder) == .driveFolder)
    #expect(SourceKind.of("https://drive.google.com/file/d/abc/view") == .file)
    #expect(SourceKind.of("https://github.com/example/repo/issues") == .link)
    #expect(SourceKind.of(notes.path) == .file)
    #expect(SourceKind.of(shelf.path) == .folder)
    #expect(SourceKind.of("/Volumes/Drive/Candidates.gsheet") == .sheet)

    let drive = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage/GoogleDrive-someone@example.org/My Drive/Quotes").path
    #expect(LinkedSource.isCloudDrive(drive))
    #expect(LinkedSource.account(of: drive) == "someone@example.org")
    #expect(!LinkedSource.isCloudDrive(shelf.path) && LinkedSource.account(of: shelf.path) == nil)
    #expect(LinkedSource.title(of: "/Volumes/Drive/Candidates.gsheet", kind: .sheet) == "Candidates")
    #expect(LinkedSource.title(of: sheet, kind: .sheet) == "Google Sheet")
}

@Test func answersOfferTheirGoogleDocumentsAndFoldersButNotFilesOrOtherPages() throws {
    let root = try scratch()
    try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
    try Data("<html>".utf8).write(to: root.appending(path: "docs/mock.html"))
    try Data("{}".utf8).write(to: root.appending(path: "docs/Budget.gsheet"))
    let answer = """
    The order is tracked in [Storeroom Ordering](\(sheet)) and the CVs sit in \(folder).
    See the mock in [mock.html](docs/mock.html:12), the [missing file](docs/gone.md), [Apple](https://www.apple.com),
    the [mocks folder](docs) and [Budget](docs/Budget.gsheet).
    Again: [Storeroom Ordering](\(sheet)).
    """
    let found = LinkedSource.documents(in: answer, relativeTo: root.path)
    #expect(found.map(\.address) == [sheet, root.appending(path: "docs").path, root.appending(path: "docs/Budget.gsheet").path, folder])
    #expect(found.map(\.title) == ["Storeroom Ordering", "mocks folder", "Budget", nil])
    #expect(LinkedSource.documents(in: "[relative](docs)", relativeTo: nil).isEmpty)
}

@Test func agentsProposeAndTheUserDecides() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let group = try store.createGroup(name: "Hardware hiring"), other = try store.createGroup(name: "Errands")
    let task = try store.create(FaciendaTask(title: "Find the interview rating sheet"))
    try store.assignGroup(taskId: task.id, groupId: group.id)
    let loose = try store.create(FaciendaTask(title: "Book the dentist"))

    let proposal = try store.proposeSource(sheet, title: "Interview ratings", note: "Every hiring task asks for it.", taskId: task.id)
    #expect(proposal.state == .proposed && proposal.kind == .sheet && proposal.taskId == task.id)
    #expect(try store.groupSources()[group.id]?.map(\.title) == ["Interview ratings"])
    #expect(try store.linkedSources(forTask: task.id).isEmpty)
    // Proposing it again changes nothing.
    #expect(try store.proposeSource(sheet, title: "Other name", note: nil, taskId: task.id).id == proposal.id)
    // A task in no group proposes to its workspace, where every task is told about it once linked.
    let forAll = try store.proposeSource(sheet, title: "Ratings", note: nil, taskId: loose.id)
    #expect(forAll.groupId == nil && forAll.workspaceId == loose.workspaceId && forAll.state == .proposed)
    #expect(try store.linkedSources(forTask: loose.id).isEmpty)
    try store.setSourceState(forAll.id, .linked)
    try store.setSourceAbout(forAll.id, " How each candidate scored. ")
    #expect(try store.linkedSources(forTask: loose.id).map(\.about) == ["How each candidate scored."])
    #expect(try store.linkedSources(forTask: task.id).map(\.address) == [sheet])
    #expect(try store.groupSources()[group.id]?.map(\.title) == ["Interview ratings"])
    try store.setSourceState(forAll.id, .dismissed)
    #expect(throws: StoreError.self) { try store.proposeSource("not a link", title: "Ratings", note: nil, taskId: task.id) }

    try store.setSourceState(proposal.id, .linked)
    #expect(try store.linkedSources(forTask: task.id).map(\.address) == [sheet])
    // Dismissed stays dismissed, even when an agent proposes it again.
    try store.setSourceState(proposal.id, .dismissed)
    #expect(try store.groupSources()[group.id] == nil)
    #expect(try store.proposeSource(sheet, title: "Ratings", note: nil, taskId: task.id).state == .dismissed)
    // The user can always link it themselves.
    #expect(try store.linkSource(sheet, title: "Ratings summary", groupId: group.id).state == .linked)
    #expect(try store.linkedSources(forTask: task.id).map(\.title) == ["Ratings summary"])
    try store.renameSource(proposal.id, to: "Interview ratings")
    #expect(try store.sources(groupId: group.id).map(\.title) == ["Interview ratings"])
    #expect(try store.sources(groupId: other.id).isEmpty)

    try store.deleteGroup(group.id)
    #expect(try store.groupSources().isEmpty)
}

@Test func savedAnswersOfferTheirDocumentsToTheGroup() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let repo = root.appending(path: "repo"), notes = root.appending(path: "notes")
    try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appending(path: "docs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: notes.appending(path: "plan.md"))
    let group = try store.createGroup(name: "Launch")
    try store.linkFolder(repo.path, groupId: group.id)
    var task = try store.create(FaciendaTask(title: "Plan the launch"))
    try store.assignGroup(taskId: task.id, groupId: group.id)
    task = try store.update(task.id) { $0.cwd = repo.path }

    try store.saveResult(taskId: task.id, text: """
    Done. The plan is in [the launch plan](\(notes.appending(path: "plan.md").path)), next to [the notes](\(notes.path)); numbers in [Budget](\(sheet)).
    I also updated [the docs](docs), which are in the repository the group works in.
    """)
    let offered = try store.sources(groupId: group.id)
    #expect(offered.map(\.title) == ["the notes", "Budget"])
    #expect(offered.allSatisfy { $0.state == .proposed && $0.taskId == task.id })
    #expect(offered.first?.note?.contains("Plan the launch") == true)

    // A second answer offers only what is new; a dismissed document is not offered again.
    try store.setSourceState(offered[1].id, .dismissed)
    try store.saveResult(taskId: task.id, text: "Still in [Budget](\(sheet)) and \(folder).")
    #expect(try store.sources(groupId: group.id).map(\.address) == [notes.path, folder])

    // A task outside any group offers to its workspace, and its answer is still saved.
    let loose = try store.create(FaciendaTask(title: "Loose"))
    try store.saveResult(taskId: loose.id, text: "[Budget](\(sheet))")
    #expect(try store.latestEvent(taskId: loose.id, kind: "codex.result")?.payload == "[Budget](\(sheet))")
    #expect(try store.workspaceSources(workspaceID: try #require(loose.workspaceId)).map(\.address) == [sheet])
}

@Test func theProposeToolReachesTheTasksGroup() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let group = try store.createGroup(name: "Storeroom")
    let task = try store.create(FaciendaTask(title: "Order the lamps"))
    try store.assignGroup(taskId: task.id, groupId: group.id)
    let tools = ToolService(store: store)
    let result = try tools.call("propose_source", arguments: .object(["taskId": .string(try store.taskHandle(task.id)), "address": .string(folder), "title": .string("Storeroom - QUOTES"), "why": .string("Every order needs its quotes.")]))
    #expect(result["state"].string == "proposed" && result["kind"].string == "driveFolder")
    #expect(try store.sources(groupId: group.id).first?.note == "Every order needs its quotes.")
    // Files on this Mac are the user's to link.
    let quote = root.appending(path: "quote.pdf")
    try Data("x".utf8).write(to: quote)
    #expect(throws: StoreError.self) { try store.proposeSource(quote.path, title: "Quote", note: nil, taskId: task.id) }
    #expect(try store.proposeSource(root.path, title: "Quotes", note: nil, taskId: task.id).kind == .folder)
}

@Test func linkingARepositoryOffersNothingMore() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let app = root.appending(path: "app")
    try FileManager.default.createDirectory(at: app.appending(path: ".git"), withIntermediateDirectories: true)
    try Data("[remote \"origin\"]\n\turl = git@github.com:example/app.git\n".utf8).write(to: app.appending(path: ".git/config"))
    let group = try store.createGroup(name: "App")
    try store.linkFolder(app.path, groupId: group.id)
    #expect(try store.offerAutomaticSources() == 0)
    #expect(try store.sources(groupId: group.id).isEmpty)
}

@Test func driveFoldersOfferTheirDocumentsAndLinkFilesBecomeWebAddresses() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let drive = root.appending(path: "Storeroom")
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
    try Data(#"{"": "WARNING!", "doc_id": "1aBcDeFgHiJk", "resource_key": "", "email": "someone@example.org"}"#.utf8).write(to: drive.appending(path: "Storeroom Ordering.gsheet"))
    try Data(#"{"url": "https://docs.google.com/document/d/abc/edit", "doc_id": "abc"}"#.utf8).write(to: drive.appending(path: "Procedure.gdoc"))
    try Data("not json".utf8).write(to: drive.appending(path: "Broken.gslides"))
    try Data("x".utf8).write(to: drive.appending(path: "quote.pdf"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: drive.appending(path: "Broken.gslides").path)

    #expect(LinkedSource.webAddress(ofStub: drive.appending(path: "Storeroom Ordering.gsheet").path) == "https://docs.google.com/spreadsheets/d/1aBcDeFgHiJk/edit")
    #expect(LinkedSource.webAddress(ofStub: drive.appending(path: "Procedure.gdoc").path) == "https://docs.google.com/document/d/abc/edit")
    #expect(LinkedSource.webAddress(ofStub: drive.appending(path: "Broken.gslides").path) == nil)
    #expect(Set(LinkedSource.driveDocuments(in: drive.path).map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["Storeroom Ordering.gsheet", "Procedure.gdoc", "Broken.gslides"])

    let group = try store.createGroup(name: "Storeroom")
    // Linking a link file keeps the document's web address.
    let ordering = try store.linkSource(drive.appending(path: "Storeroom Ordering.gsheet").path, groupId: group.id)
    #expect(ordering.address == "https://docs.google.com/spreadsheets/d/1aBcDeFgHiJk/edit" && ordering.title == "Storeroom Ordering" && ordering.kind == .sheet)
    // A Drive folder offers the documents directly inside it, except those the group already has.
    var folder = try store.linkSource(drive.path, groupId: group.id)
    folder.kind = .driveFolder; folder.account = "someone@example.org"
    #expect(store.offerDriveDocuments(in: folder, limit: 5) == 2)
    let offered = try store.sources(groupId: group.id).filter { $0.state == .proposed }
    #expect(Set(offered.map(\.title)) == ["Procedure", "Broken"])
    #expect(offered.allSatisfy { $0.account == "someone@example.org" && $0.note == "In the Drive folder “Storeroom”." })
    // Later passes only offer what changed since the folder was linked.
    #expect(store.offerDriveDocuments(in: folder, limit: 3, changedSince: Date()) == 0)
}

@Test func filesInTheTasksOwnFolderAreNotOfferedButAttachmentsAre() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "library/tasks.sqlite"))
    let group = try store.createGroup(name: "Hiring")
    let source = root.appending(path: "cv.pdf")
    try Data("x".utf8).write(to: source)
    var task = try store.prepareWorkingFolder(taskId: try store.create(FaciendaTask(title: "Compare the candidates")).id)
    let own = URL(fileURLWithPath: try #require(task.cwd))
    let attached = own.appending(path: "Attachments/1/cv.pdf")
    try FileManager.default.createDirectory(at: attached.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: attached)
    try FileManager.default.createDirectory(at: own.appending(path: "clone"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: own.appending(path: "comparison.pdf"))
    task = try store.update(task.id) { $0.attachments = [TaskAttachment(name: "cv.pdf", path: attached.path)] }

    // Filing the task offers what the user attached.
    try store.assignGroup(taskId: task.id, groupId: group.id)
    #expect(try store.sources(groupId: group.id).map(\.title) == ["cv.pdf"])
    #expect(try store.sources(groupId: group.id).first?.note == "Attached to “Compare the candidates”.")
    // What the agent made or cloned in its own folder stays there.
    try store.saveResult(taskId: task.id, text: "The comparison is in [comparison.pdf](comparison.pdf), from [the clone](clone).")
    #expect(try store.sources(groupId: group.id).count == 1)
}

@Test func earlierFileProposalsArePutAway() throws {
    let root = try scratch(), url = root.appending(path: "library/tasks.sqlite")
    var store = try FaciendaStore(url: url)
    let group = try store.createGroup(name: "Delta")
    try store.write { db in
        for (kind, address, task, note) in [("file", "/x/Work/1/mock.html", "t", "Made by “x”."), ("file", "/x/Work/1/Attachments/2/cv.pdf", "t", nil),
                                            ("link", "https://github.com/a/b", nil, "Where “b” is hosted: its issues."), ("sheet", sheet, "t", nil)] {
            try db.execute(sql: "INSERT INTO groupSources (id, groupId, kind, address, title, state, taskId, note, position, createdAt) VALUES (?, ?, ?, ?, 'x', 'proposed', ?, ?, 0, ?)",
                           arguments: [UUID().uuidString, group.id, kind, address, task, note, Date()])
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'group_sources_narrowed'")
    }
    store = try FaciendaStore(url: url)
    #expect(Set(try store.sources(groupId: group.id).map(\.address)) == ["/x/Work/1/Attachments/2/cv.pdf", sheet])
}

@Test func agentsCannotPointTheUserAtAppsOrFoldersElsewhere() throws {
    let root = try scratch(), store = try FaciendaStore(url: root.appending(path: "data/library/tasks.sqlite"))
    let group = try store.createGroup(name: "Tools")
    let elsewhere = root.appending(path: "elsewhere"), project = root.appending(path: "project/docs"), app = root.appending(path: "data/Tool.app")
    for folder in [elsewhere, project, app.appending(path: "Contents")] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let task = try store.update(try store.create(FaciendaTask(title: "Sort the tools")).id) { $0.cwd = root.appending(path: "project").path }
    try store.assignGroup(taskId: task.id, groupId: group.id)
    #expect(SourceKind.of(app.path) == .file)
    #expect(throws: StoreError.self) { try store.proposeSource(app.path, title: "Tool", note: nil, taskId: task.id) }
    #expect(throws: StoreError.self) { try store.proposeSource(elsewhere.path, title: "Elsewhere", note: nil, taskId: task.id) }
    #expect(try store.proposeSource(project.path, title: "Docs", note: nil, taskId: task.id).kind == .folder)
    #expect(try store.proposeSource(root.appending(path: "data").path, title: "Data", note: nil, taskId: task.id).kind == .folder)
    // A home-wide working folder does not open the whole disk.
    let wide = try store.update(task.id) { $0.cwd = "/" }
    #expect(throws: StoreError.self) { try store.proposeSource(elsewhere.path, title: "Elsewhere", note: nil, taskId: wide.id) }

    #expect(GroupSource(id: "s", groupId: group.id, kind: .link, address: "https://example.org", title: "x", state: .proposed, position: 0, createdAt: Date()).isWeb)
    for address in ["httpx://example.org", "http:/nohost", "javascript:alert(1)", "/Applications/Tool.app"] {
        #expect(!GroupSource(id: "s", groupId: group.id, kind: .link, address: address, title: "x", state: .proposed, position: 0, createdAt: Date()).isWeb)
    }
    #expect(SourceKind.of("httpx://docs.google.com/spreadsheets/d/x") != .sheet)
}
