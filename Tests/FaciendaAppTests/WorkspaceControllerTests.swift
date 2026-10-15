import AppKit
import Foundation
import Testing
import FaciendaCore
import FaciendaBridge

/// Preferences for one test. Every suite made here is removed when the test run ends, so runs leave no files behind.
nonisolated(unsafe) private var scratchSuites: [String] = []
@MainActor private func scratchDefaults(_ label: String) -> UserDefaults {
    let name = "Facienda\(label)-\(UUID().uuidString)"
    if scratchSuites.isEmpty {
        atexit {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
            for name in scratchSuites {
                UserDefaults.standard.removePersistentDomain(forName: name)
                try? FileManager.default.removeItem(at: folder.appending(path: name + ".plist"))
            }
        }
    }
    scratchSuites.append(name)
    return UserDefaults(suiteName: name)!
}

/// A controller over a fresh library, with its own view preferences.
@MainActor private func controller(_ defaults: UserDefaults? = nil) throws -> (WorkspaceController, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "FaciendaWorkspaceControllerTests/\(UUID().uuidString)")
    let library = try LibraryHome.setUp(workspaceName: "Home", dataFolder: root.appending(path: "facienda"), pointer: nil).url
    let defaults = defaults ?? scratchDefaults("Workspaces")
    return (WorkspaceController(libraryURL: library, defaults: defaults), library)
}

@MainActor @Test func workspaceSwitchingPreservesDraftsSelectionAndNamedRegistry() throws {
    let (controller, library) = try controller()
    let home = try #require(controller.model)
    #expect(controller.name == "Home")
    let task = try home.store.create(FaciendaTask(title: "Home task"))
    home.refresh(); home.select(task.id)
    home.composerRequest = "Unsent intention"
    home.replyDrafts[task.id] = "Unsent reply"
    #expect(controller.create(name: "Work", memorySpaceID: try #require(controller.memorySpaces.first).id))
    #expect(controller.model?.tasks.isEmpty == true)
    #expect(controller.model?.composerRequest.isEmpty == true)
    // One library: the new workspace needs no Codex setup of its own.
    #expect(controller.model?.store.url == home.store.url)
    // Every workspace shares one Codex connection, so a switch never starts Codex again.
    #expect(controller.model?.codex === home.codex && home.codex === controller.codex)
    let saved = try #require(controller.workspaces.first { $0.name == "Home" })
    #expect(controller.rename(saved, to: "Personal"))
    #expect(controller.open(saved))
    #expect(controller.model === home)
    #expect(controller.name == "Personal")
    #expect(home.selection == task.id)
    #expect(home.composerRequest == "Unsent intention")
    #expect(home.replyDrafts[task.id] == "Unsent reply")
    #expect(library == home.store.url)
}

@MainActor @Test func deletingAWorkspaceStopsItsModelButNeverLosesOpenWork() async throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model)
    home.composerRequest = "Keep my draft"
    #expect(controller.create(name: "Work", memorySpaceID: try #require(controller.memorySpaces.first).id))
    let workModel = try #require(controller.model)
    let work = try #require(controller.current)
    _ = try workModel.store.create(FaciendaTask(title: "Still open"))
    #expect(!(await controller.remove(work)))
    #expect(controller.error != nil)
    _ = try workModel.store.update(try #require(workModel.store.tasks().first).id) { $0.state = .done }
    #expect(await controller.remove(work))
    #expect(controller.model === home)
    #expect(home.composerRequest == "Keep my draft")
    #expect(controller.workspaces.map(\.name) == ["Home"])
    #expect(!(await controller.remove(try #require(controller.current))))
}

@MainActor @Test func workspacesChooseTheirMemoryAndMovesCarryTasksAcross() throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model), homeWorkspace = try #require(controller.current)
    let work = try #require(controller.createMemory(name: "Work"))
    #expect(controller.createMemory(name: "work") == nil)
    controller.error = nil
    #expect(controller.create(name: "Office", memorySpaceID: work.id))
    let office = try #require(controller.current)
    #expect(controller.memoryName(for: office) == "Work")
    #expect(controller.open(homeWorkspace))
    let group = try #require(home.createGroup(name: "Taxes"))
    _ = try home.store.create(FaciendaTask(title: "Receipts"))
    let task = try #require(try home.store.tasks().first)
    // Moves go on the window's undo stack and offer Undo in a toast.
    let undo = UndoManager()
    undo.groupsByEvent = false
    home.undoManager = undo
    home.move(taskID: task.id, to: group.id)
    home.moveGroup(group, to: office)
    #expect(home.groups.isEmpty && home.tasks.isEmpty)
    let offer = try #require(home.undoOffer)
    #expect(offer.message == "Moved “Taxes” to Office")
    #expect(try home.store.library.task(task.id).workspaceId == office.id)
    home.takeBack(offer)
    #expect(home.groups.map(\.id) == [group.id] && home.tasks.map(\.id) == [task.id])
    #expect(home.undoOffer == nil)
    home.moveGroup(group, to: office)
    #expect(home.tasks.isEmpty)
    #expect(controller.open(office))
    #expect(controller.model?.tasks.map(\.id) == [task.id])
    #expect(controller.model?.memorySpace?.id == work.id)
    #expect(controller.setMemory(office, to: homeWorkspace.memorySpaceId))
    #expect(controller.model?.memorySpace?.id == homeWorkspace.memorySpaceId)
    #expect(controller.deleteMemory(work))
    #expect(controller.memorySpaces.count == 1)
}

@MainActor @Test func sidebarKeepsTheDraggedOrderAndCountsEveryWorkspace() throws {
    let defaults = scratchDefaults("WorkspaceOrder")
    let (controller, library) = try controller(defaults)
    let memory = try #require(controller.memorySpaces.first).id
    try controller.rename(#require(controller.current), to: "A")
    for name in ["B", "C", "D"] { #expect(controller.create(name: name, memorySpaceID: memory)) }
    let saved = Dictionary(uniqueKeysWithValues: controller.workspaces.map { ($0.name, $0) })
    let a = try #require(saved["A"]), b = try #require(saved["B"]), d = try #require(saved["D"])
    controller.move(d, to: a, after: false)
    #expect(controller.ordered.map(\.name) == ["D", "A", "B", "C"])
    controller.move(a, to: b, after: true)
    #expect(controller.ordered.map(\.name) == ["D", "B", "A", "C"])
    #expect(controller.open(b))
    _ = try #require(controller.model).store.create(FaciendaTask(title: "Finished in B", state: .needsMe))
    #expect(controller.open(d))
    controller.reload()
    // B is no longer on screen, yet its finished task still counts.
    #expect(controller.newCount(for: b) == 1)
    #expect(controller.newCount(for: d) == 0)
    let reopened = WorkspaceController(libraryURL: library, defaults: defaults)
    #expect(reopened.ordered.map(\.name) == ["D", "B", "A", "C"])
    // The library reopens on the workspace last shown.
    #expect(reopened.current?.name == "D")
}

@MainActor @Test func aMissingLibraryIsReportedInsteadOfStartingOver() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FaciendaWorkspaceControllerTests/\(UUID().uuidString)")
    let library = root.appending(path: "Library/facienda.sqlite")
    let controller = WorkspaceController(libraryURL: library, defaults: scratchDefaults("Missing"))
    #expect(controller.model == nil)
    #expect(throws: StoreError.self) { try controller.openLibrary() }
    #expect(!FileManager.default.fileExists(atPath: library.path))
}

private actor PictureLog {
    var calls: [(name: String, tasks: [String], style: String?, instruction: String?)] = []
    func add(_ name: String, _ tasks: [String], _ style: String?, _ instruction: String?) { calls.append((name, tasks, style, instruction)) }
}

private struct FakePicturePainter: CoverPainting {
    let log: PictureLog
    let pixel: Data
    func paint(executable: String, name: String, tasks: [String], style: String?, notes: [String]) async throws -> GroupCover {
        await log.add(name, tasks, style, nil); return GroupCover(image: pixel, style: "Fauvism")
    }
    func edit(executable: String, cover: URL, name: String, tasks: [String], instruction: String, style: String?, notes: [String]) async throws -> GroupCover {
        await log.add(name, [], style, instruction); return GroupCover(image: pixel, style: "Fauvism at night")
    }
}

@MainActor @Test func workspacesArePaintedOneAtATimeOnceCodexIsReadyAndCanBeAdjustedAndUndone() async throws {
    let (controller, _) = try controller()
    #expect(controller.create(name: "Garden", memorySpaceID: try #require(controller.memorySpaces.first).id))
    _ = try #require(controller.model).store.create(FaciendaTask(title: "Plant tulips"))
    let log = PictureLog()
    let pixel = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .jpeg, properties: [:]))
    controller.coverPainter = FakePicturePainter(log: log, pixel: pixel)
    // Nothing is painted until Codex is connected and signed in.
    controller.paintMissingCovers()
    #expect(controller.paintingCovers.isEmpty)
    controller.codex.connected = true; controller.codex.accountReady = true
    controller.paintMissingCovers()
    #expect(controller.paintingCovers.count == 1)
    for _ in 0..<300 where controller.coverImages.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    var calls = await log.calls
    #expect(calls.map(\.name) == ["Home", "Garden"] && calls[1].tasks == ["Plant tulips"])
    #expect(controller.workspaces.allSatisfy { $0.coverStyle == "Fauvism" } && controller.paintingCovers.isEmpty)
    let garden = try #require(controller.workspaces.first { $0.name == "Garden" })
    #expect(!controller.canUndoCover(garden))
    controller.adjustCover(garden, instruction: " at night ")
    for _ in 0..<300 where !controller.paintingCovers.isEmpty || controller.workspaces.first(where: { $0.id == garden.id })?.coverNotes == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    calls = await log.calls
    #expect(calls.last?.instruction == "at night" && calls.last?.style == "Fauvism")
    let adjusted = try #require(controller.workspaces.first { $0.id == garden.id })
    #expect(adjusted.coverNoteList == ["at night"] && adjusted.coverStyle == "Fauvism at night" && controller.canUndoCover(adjusted))
    controller.undoCover(adjusted)
    let restored = try #require(controller.workspaces.first { $0.id == garden.id })
    #expect(restored.coverStyle == "Fauvism" && restored.coverNotes == nil && !controller.canUndoCover(restored))
}
