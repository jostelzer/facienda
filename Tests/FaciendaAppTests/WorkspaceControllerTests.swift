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

@MainActor @Test func workspacesKeepTheirPlacesOnTheIslandAndNewOnesNeverShiftThem() throws {
    let defaults = scratchDefaults("WorkspacePlaces")
    let (controller, library) = try controller(defaults)
    let memory = try #require(controller.memorySpaces.first).id
    for name in ["B", "C"] { #expect(controller.create(name: name, memorySpaceID: memory)) }
    // Every workspace gets a place of its own, clear of the others.
    let first = Dictionary(uniqueKeysWithValues: controller.ordered.map { ($0.id, controller.place(of: $0)) })
    #expect(first.count == 3 && Set(first.values.map { "\($0)" }).count == 3)
    // A dragged place sticks, kept clear of the island's edge; a new workspace leaves everyone else where they are.
    let moved = try #require(controller.ordered.last)
    controller.setPlace(moved, to: CGPoint(x: 1.4, y: -0.2))
    #expect(controller.place(of: moved) == CGPoint(x: 0.88, y: 0.08))
    #expect(controller.create(name: "D", memorySpaceID: memory))
    for workspace in controller.ordered where workspace.id != moved.id && first[workspace.id] != nil {
        #expect(controller.place(of: workspace) == first[workspace.id])
    }
    // Places outlast a restart; tidying puts everyone back into the zigzag.
    let reopened = WorkspaceController(libraryURL: library, defaults: defaults)
    #expect(reopened.place(of: moved) == CGPoint(x: 0.88, y: 0.08))
    reopened.arrangePlaces()
    #expect(reopened.place(of: moved) != CGPoint(x: 0.88, y: 0.08))
    #expect(Set(reopened.ordered.map { "\(reopened.place(of: $0))" }).count == 4)
}

@Test func theIslandLeansOnAWallAndTheBoardMakesRoomForIt() {
    let window = CGSize(width: 1200, height: 800)
    // A first island takes the old sidebar's place: a quarter of the width, all the way down the left. Only its free
    // edge resizes it.
    let first = IslandFrame.snap(IslandFrame.decode("", share: 0.25, in: window), in: window)
    #expect(first == CGRect(x: 10, y: 10, width: 280, height: 780))
    #expect(IslandFrame.room(for: first, in: window).leading == 290)
    #expect(IslandFrame.freeEdges(first, in: window) == [.trailing])
    // Carried into the middle, the nearest wall takes it; it never leaves the window or gets too small to hold planets.
    let floating = IslandFrame.snap(CGRect(x: 820, y: 300, width: 300, height: 400), in: window)
    #expect(floating.maxX == 1190 && floating.minY == 300)
    #expect(IslandFrame.room(for: floating, in: window).trailing == 310)
    let squeezed = IslandFrame.snap(CGRect(x: -500, y: 900, width: 20, height: 20), in: window)
    #expect(squeezed.size == IslandFrame.smallest && squeezed.minX == 10 && squeezed.maxY == 790)
    // It can be set down on the bottom too, where it stays, and the board goes above it.
    let down = IslandFrame.snap(CGRect(x: 450, y: 520, width: 300, height: 300), in: window)
    #expect(down == CGRect(x: 450, y: 490, width: 300, height: 300))
    #expect(IslandFrame.room(for: down, in: window).bottom == 310)
    // Near a corner, both walls pull it on.
    let corner = IslandFrame.snap(CGRect(x: 35, y: 560, width: 300, height: 200), in: window)
    #expect(IslandFrame.touching(corner, in: window) == [.leading, .bottom])
    // A wide island along the bottom takes room from below.
    let shelf = IslandFrame.snap(CGRect(x: 100, y: 560, width: 900, height: 230), in: window)
    #expect(IslandFrame.touching(shelf, in: window) == [.bottom])
    #expect(IslandFrame.room(for: shelf, in: window).bottom == 240)
    // A dragged edge clicks onto its wall when it comes near.
    #expect(IslandFrame.resized(CGRect(x: 10, y: 10, width: 280, height: 760), moving: .bottom, in: window).height == 780)
    // A tall island let go against the top alone still leans on a side wall, so the board is never pushed off the window.
    let window2 = CGSize(width: 1497, height: 949)
    let topOnly = IslandFrame.snap(CGRect(x: 198, y: 0, width: 352, height: 928), in: window2)
    #expect(topOnly.minX == 10)
    #expect(IslandFrame.room(for: topOnly, in: window2).leading == 362)
    // Whatever the island does, the board keeps room of its own, and a broken saved place falls back to the first one.
    let huge = CGRect(x: 10, y: 10, width: 1100, height: 780)
    #expect(IslandFrame.room(for: huge, in: window).leading == 840)
    #expect(IslandFrame.decode("0.5,nan,2,0.3", share: 0.25, in: window) == IslandFrame.decode("", share: 0.25, in: window))
    // Saved as fractions, so it keeps its wall when the window changes size.
    let wider = CGSize(width: 1600, height: 900)
    let kept = IslandFrame.snap(IslandFrame.decode(IslandFrame.encode(floating, in: window), share: 0.25, in: wider), in: wider)
    #expect(kept.maxX == 1590)
}
