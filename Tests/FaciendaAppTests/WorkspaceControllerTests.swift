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
    #expect(controller.create(name: "Work"))
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

@MainActor @Test func archivingAWorkspaceStopsItsModelAndRestoreBringsItsWorkBack() async throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model)
    home.composerRequest = "Keep my draft"
    #expect(controller.create(name: "Work"))
    let workModel = try #require(controller.model)
    let work = try #require(controller.current)
    let task = try workModel.store.create(FaciendaTask(title: "Still open"))
    #expect(await controller.archive(work))
    #expect(controller.model === home)
    #expect(home.composerRequest == "Keep my draft")
    #expect(controller.workspaces.map(\.name) == ["Home"] && controller.archived.map(\.name) == ["Work"])
    #expect(try home.store.library.task(task.id).state == .dropped)
    #expect(!(await controller.archive(try #require(controller.current))))
    #expect(controller.restore(work))
    #expect(controller.workspaces.map(\.name) == ["Home", "Work"] && controller.archived.isEmpty)
    #expect(try home.store.library.task(task.id).state == .inbox)
}

@MainActor @Test func workspacesOwnTheirMemoryAndMovesCarryTasksAcross() throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model), homeWorkspace = try #require(controller.current)
    #expect(controller.create(name: "Office"))
    let office = try #require(controller.current)
    // A new workspace's memory is its own, named after it, and follows a rename.
    #expect(office.memorySpaceId != homeWorkspace.memorySpaceId)
    #expect(controller.model?.memorySpace?.name == "Office")
    #expect(controller.rename(office, to: "Studio"))
    #expect(controller.model?.memorySpace?.name == "Studio")
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
    #expect(controller.model?.memorySpace?.id == office.memorySpaceId)
}

@MainActor @Test func oneTaskMovesToAnotherWorkspaceAndComesBackOnUndo() throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model), homeWorkspace = try #require(controller.current)
    #expect(controller.create(name: "Office"))
    let office = try #require(controller.current), officeModel = try #require(controller.model)
    let desk = try #require(officeModel.createGroup(name: "Desk"))
    #expect(controller.open(homeWorkspace))
    let taxes = try #require(home.createGroup(name: "Taxes"))
    let task = try home.store.create(FaciendaTask(title: "Receipts")), other = try home.store.create(FaciendaTask(title: "Return"))
    for each in [task, other] { home.move(taskID: each.id, to: taxes.id) }
    home.refresh(); home.select(task.id)
    // The menu offers the other workspace with its groups.
    #expect(home.otherWorkspaces.map(\.id) == [office.id])
    #expect(home.otherGroups[office.id]?.map(\.id) == [desk.id])
    let undo = UndoManager()
    undo.groupsByEvent = false
    home.undoManager = undo
    home.moveTask(task, to: office, group: desk)
    #expect(home.tasks.map(\.id) == [other.id] && home.groups.map(\.id) == [taxes.id])
    #expect(home.selection == nil)
    let offer = try #require(home.undoOffer)
    #expect(offer.message == "Moved “Receipts” to Office · Desk")
    home.takeBack(offer)
    #expect(home.error == nil)
    #expect(Set(home.tasks.map(\.id)) == [task.id, other.id])
    #expect(home.groupMembers[task.id] == taxes.id)
    home.moveTask(task, to: office)
    #expect(controller.open(office))
    #expect(controller.model?.tasks.map(\.id) == [task.id])
    #expect(controller.model?.groupMembers[task.id] == nil)
}

@MainActor @Test func sidebarKeepsTheDraggedOrderAndCountsEveryWorkspace() throws {
    let defaults = scratchDefaults("WorkspaceOrder")
    let (controller, library) = try controller(defaults)
    try controller.rename(#require(controller.current), to: "A")
    for name in ["B", "C", "D"] { #expect(controller.create(name: name)) }
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
    #expect(controller.create(name: "Garden"))
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

@MainActor @Test func workspacesKeepTheirSpacesOnTheIslandAndADropSwapsTwo() throws {
    let defaults = scratchDefaults("WorkspaceSlots")
    let (controller, library) = try controller(defaults)
    for name in ["B", "C"] { #expect(controller.create(name: name)) }
    let named = { (name: String) in try #require(controller.workspaces.first { $0.name == name }) }
    let home = try named("Home"), b = try named("B"), c = try named("C")
    // Each takes the first free space, in the order they came.
    #expect([home, b, c].map(controller.slot(of:)) == [0, 1, 2])
    // Dropped into an empty space, a workspace leaves a gap; a new one fills it and shifts nobody.
    controller.setSlot(home, to: 6)
    #expect(controller.slot(of: home) == 6 && controller.hasGaps)
    #expect(controller.create(name: "D"))
    let d = try named("D")
    #expect([home, b, c, d].map(controller.slot(of:)) == [6, 1, 2, 0])
    // Dropped onto another, the two swap.
    controller.setSlot(c, to: 1)
    #expect(controller.slot(of: c) == 1 && controller.slot(of: b) == 2)
    // Spaces outlast a restart; closing the gaps moves everyone up, in the order they stand.
    let reopened = WorkspaceController(libraryURL: library, defaults: defaults)
    #expect(reopened.slot(of: home) == 6)
    reopened.closeGaps()
    #expect([d, c, b, home].map(reopened.slot(of:)) == [0, 1, 2, 3] && !reopened.hasGaps)
}

@MainActor @Test func theFirstGridKeepsTheOrderThePlanetsStoodIn() throws {
    let defaults = scratchDefaults("WorkspacePlanets")
    let (controller, library) = try controller(defaults)
    for name in ["B", "C"] { #expect(controller.create(name: name)) }
    let ids = Dictionary(uniqueKeysWithValues: controller.workspaces.map { ($0.name, $0.id) })
    let home = try #require(ids["Home"]), b = try #require(ids["B"]), c = try #require(ids["C"])
    // C stood highest, then Home, then B, lowest; the old island kept places as fractions of its width and height.
    defaults.set([home: [0.7, 0.4], b: [0.3, 0.8], c: [0.5, 0.1]], forKey: "workspacePlaces")
    defaults.removeObject(forKey: "workspaceSlots")
    let reopened = WorkspaceController(libraryURL: library, defaults: defaults)
    #expect(["C", "Home", "B"].map { name in reopened.workspaces.first { $0.name == name }.map(reopened.slot(of:)) } == [0, 1, 2])
}

@Test func theIslandIsAGridOfSpacesThatWrapsWithItsWidth() {
    // Four columns on a usual island, two on the narrowest; a tile about three fifths of its column.
    let wide = IslandGrid(area: CGSize(width: 360, height: 700), lastTaken: 5)
    #expect(wide.columns == 4 && wide.tile == 54 && wide.corner == 13)
    let narrow = IslandGrid(area: CGSize(width: 190, height: 700), lastTaken: 5)
    #expect(narrow.columns == 2)
    // The same space wraps to another row and column, so the order holds.
    #expect(wide.centre(of: 5) == CGPoint(x: IslandGrid.side + 27 + wide.pitch, y: IslandGrid.top + wide.row + 27))
    #expect(narrow.centre(of: 5).x == 147.5 && narrow.centre(of: 5).y == IslandGrid.top + narrow.row * 2 + narrow.tile / 2)
    // The outer tiles stand as far in from the island's sides as the cards from the board's, and their names stay inside.
    #expect(wide.centre(of: 0).x - wide.tile / 2 == IslandFrame.inset)
    #expect(abs(wide.centre(of: 3).x + wide.tile / 2 - (360 - IslandFrame.inset)) < 0.001)
    // Names stay centred under their tiles: an outer name gets only the room that keeps it inside the island.
    let first = wide.centre(of: 0).x, inner = wide.centre(of: 1).x, last = wide.centre(of: 3).x
    #expect(first - wide.name(at: first) / 2 >= 3 && last + wide.name(at: last) / 2 <= 357.001)
    #expect(wide.name(at: inner) == wide.pitch - 4 && wide.name(at: inner) <= wide.pitch)
    // A carried tile lands in the space nearest it, and a point between tiles is under none.
    #expect(wide.space(nearest: CGPoint(x: 140, y: 120)) == 5)
    #expect(wide.space(nearest: CGPoint(x: -40, y: 9000)) == wide.spaces - wide.columns)
    #expect(wide.space(under: wide.centre(of: 2)) == 2)
    #expect(wide.space(under: CGPoint(x: 90, y: wide.centre(of: 0).y + wide.row / 2)) == nil)
    // Spaces fill the island; a tile further down than that adds rows, and the tiles shrink until they fit.
    #expect(wide.spaces == Int((700 - IslandGrid.top) / wide.row) * 4)
    let crowded = IslandGrid(area: CGSize(width: 360, height: 300), lastTaken: 15)
    #expect(crowded.spaces == 16 && crowded.tile < wide.tile && crowded.centre(of: 15).y + crowded.tile / 2 <= 300)
}

@Test func aLongNameUnderATileTightensThenHyphenatesBeforeItIsCut() {
    // A name that fits is left as it is.
    let short = TileName("Garden", width: 66)
    #expect(short.text == "Garden" && short.tracking == 0 && !short.cut)
    // A word a little too wide keeps its size and draws its letters closer, no closer than the tightest.
    let snug = TileName("Correspondence", width: 90)
    #expect(snug.tracking < 0 && snug.tracking >= TileName.tightest && !snug.text.contains("\u{AD}") && !snug.cut)
    // A word too wide even so then breaks at a syllable.
    let long = TileName("Correspondence", width: 66)
    #expect(long.tracking >= TileName.tightest)
    #expect(long.text.contains("\u{AD}") && long.text.replacingOccurrences(of: "\u{AD}", with: "") == "Correspondence" && !long.cut)
    // Only the words too wide are hyphenated, and nothing else of the name changes, emoji included.
    let mixed = TileName("Tea 🍵 Correspondence", width: 66)
    #expect(mixed.text.hasPrefix("Tea 🍵 ") && mixed.text.replacingOccurrences(of: "\u{AD}", with: "") == "Tea 🍵 Correspondence")
    // A name that needs a third line even so is cut, and shows whole on hover.
    #expect(TileName("Photographs of the summer house by the lake", width: 66).cut)
}

@Test func theIslandRunsFromTheBarDownAndOnlyItsWidthChanges() {
    let window = CGSize(width: 1200, height: 800)
    // A first island takes the old sidebar's place: a quarter of the width, from under the bar all the way down the left.
    let first = IslandFrame.frame(width: IslandFrame.width(share: 0, in: window), in: window)
    #expect(first == CGRect(x: 10, y: 56, width: 280, height: 734))
    // A width the user chose is kept as a share, so it grows and shrinks with the window but always fills its height.
    let wider = CGSize(width: 1600, height: 900)
    #expect(IslandFrame.width(share: 0.25, in: wider) == 400)
    #expect(IslandFrame.frame(width: 400, in: wider).height == 834)
    // Dragged too narrow it still holds its planets; dragged too wide the board keeps its room.
    #expect(IslandFrame.clamped(40, in: window) == IslandFrame.narrowest)
    #expect(IslandFrame.clamped(1100, in: window) == 1200 - IslandFrame.board.width - 30)
    // An island saved before it was always full height keeps its width; anything unreadable is the first one.
    #expect(IslandFrame.share(fromSavedFrame: "0.5,0.2,0.3,0.4") == 0.3)
    #expect(IslandFrame.share(fromSavedFrame: "0.5,nan,2,0.3") == nil)
    #expect(IslandFrame.width(share: .nan, in: window) == 280)
}

@MainActor @Test func aGoalLineKeepsBoardWorkAndTakesDetailInTheBar() async throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model), library = home.store.library, goals = controller.goals
    let goal = try library.addGoal("A calmer home"), sub = try library.addGoal("A quieter home office", parentId: goal.id)
    let line = try library.addGoalLine("Better light at the desk", to: sub.id)
    let found = try home.store.create(FaciendaTask(title: "Compare desk lighting options"))
    goals.open()
    // Board work that fits the line is only offered. It is under the line once the user keeps it.
    let guess = try #require(goals.guesses(line: line.id).first)
    #expect(guess.task.id == found.id && goals.entries(of: sub.id).first?.isPlanned == true)
    goals.keep(guess)
    #expect(goals.guesses.isEmpty && goals.entries(of: sub.id).first?.work.map(\.task?.id) == [found.id])
    // The line goes to the bar, and what is typed there starts one more task under it. The line stays as written.
    let item = try #require(goals.items.first { $0.line.id == line.id })
    let place = BarPlace(workspaceID: home.workspaceID, workspaceName: "Home")
    goals.detail(item, at: place)
    let aim = try #require(goals.aim)
    #expect(aim.lineID == line.id && aim.text == "Better light at the desk" && aim.place == place)
    #expect(await goals.start(toward: aim, detail: "Compare two warm lamps", files: [], choice: nil))
    let made = try #require(try home.store.tasks().first { $0.title.hasPrefix("Better light at the desk\n") })
    #expect(made.title == "Better light at the desk\n\nCompare two warm lamps")
    #expect(made.intention == "Part of the goal: A calmer home › A quieter home office")
    #expect(try library.servedLine(taskId: made.id) == line.id)
    let entry = try #require(goals.entries(of: sub.id).first)
    #expect(entry.line.task == nil && entry.work.count == 2)
    // Work moves out of its box to the subgoal alone, which has a box of its own.
    goals.file(task: found.id, under: nil, subgoal: sub.id)
    #expect(try library.servedLine(taskId: found.id) == nil)
    #expect(goals.boxes(of: sub.id).loose.map(\.task?.id) == [found.id])
    // A minigoal with nothing under it, started as it is, holds a task named like it rather than becoming one.
    let rug = try library.addGoalLine("Find a rug", to: sub.id)
    goals.load()
    #expect(await goals.start(toward: GoalsModel.Aim(lineID: rug.id, text: "Find a rug", place: place), detail: "", files: [], choice: nil))
    let named = try #require(try home.store.tasks().first { $0.title == "Find a rug" })
    #expect(try library.servedLine(taskId: named.id) == rug.id)
    #expect(goals.boxes(of: sub.id).open.map(\.id) == [line.id, rug.id])
    // Minigoals move past each other, never past the box without one, and work moves between boxes.
    goals.moveLine(try #require(goals.items.first { $0.line.id == line.id }), by: 1)
    #expect(goals.boxes(of: sub.id).open.map(\.id) == [rug.id, line.id])
    goals.file(task: found.id, under: rug.id, subgoal: sub.id)
    #expect(goals.boxes(of: sub.id).open.first?.work.map(\.task?.id) == [named.id, found.id])
    #expect(goals.boxes(of: sub.id).loose.isEmpty)
    // Leaving Goals lets the line go, so the bar is the board's again.
    goals.aim = aim
    goals.close()
    #expect(goals.aim == nil)
}

@MainActor @Test func goalsOpenOnTheMapAndFoldOneStepAtATime() throws {
    let (controller, _) = try controller()
    let home = try #require(controller.model), library = home.store.library, goals = controller.goals
    let goal = try library.addGoal("A calmer home")
    let sub = try library.addGoal("A quieter home office", parentId: goal.id), other = try library.addGoal("Plants on the balcony", parentId: goal.id)
    let rug = try library.addGoalLine("Find a rug", to: sub.id), quiet = try library.addGoalLine("Soften the sound", to: sub.id)
    let curtains = try home.store.create(FaciendaTask(title: "Hang heavier curtains", state: .done))
    try library.serve(taskId: curtains.id, lineId: quiet.id)
    let loose = try home.store.create(FaciendaTask(title: "Call about the window seals"))
    try library.serve(taskId: loose.id, subgoalId: sub.id)
    goals.open()
    goals.setToday(false, reduceMotion: true)
    // Open minigoals first, then the work on none, then the finished ones, which show only while Reached is on.
    goals.setShowReached(true, reduceMotion: true)
    #expect(goals.leaves(of: sub.id).map(\.id) == [rug.id, "loose:" + sub.id, quiet.id])
    goals.setShowReached(false, reduceMotion: true)
    #expect(goals.leaves(of: sub.id).map(\.id) == [rug.id, "loose:" + sub.id])
    #expect(goals.leaves(of: other.id).isEmpty)
    // A goal starts folded; a click sends its subgoals out, and folding it again folds their minigoals with them.
    #expect(!goals.spreads(goal.id))
    goals.toggle(goal: goal.id, reduceMotion: true)
    #expect(goals.spreads(goal.id) && goals.opened.isEmpty)
    goals.toggle(subgoal: sub.id, reduceMotion: true)
    goals.toggle(subgoal: other.id, reduceMotion: true)
    #expect(goals.opened == [sub.id, other.id])
    goals.toggle(goal: goal.id, reduceMotion: true)
    #expect(!goals.spreads(goal.id) && goals.opened.isEmpty)
    // Opening a subgoal's minigoals unfolds its goal too.
    goals.toggle(subgoal: other.id, reduceMotion: true)
    #expect(goals.spreads(goal.id) && goals.opened == [other.id])
    // A box opens beside its line, and a second click closes it.
    let box = GoalsModel.OpenBox(subgoalID: sub.id, lineID: rug.id)
    goals.toggle(box: box, reduceMotion: true)
    #expect(goals.openBox == box)
    goals.toggle(box: box, reduceMotion: true)
    #expect(goals.openBox == nil)
    // Esc folds the box, then every open subgoal, then every goal, then leaves Goals.
    goals.toggle(box: box, reduceMotion: true)
    goals.back(reduceMotion: true)
    #expect(goals.openBox == nil && goals.opened.count == 2 && goals.isOpen)
    goals.back(reduceMotion: true)
    #expect(goals.opened.isEmpty && goals.spreads(goal.id) && goals.isOpen)
    goals.back(reduceMotion: true)
    #expect(!goals.spreads(goal.id) && goals.isOpen)
    goals.back(reduceMotion: true)
    #expect(!goals.isOpen)
    // A box closes when the work it showed moves away, and a subgoal folds once it is reached.
    goals.open()
    goals.toggle(box: GoalsModel.OpenBox(subgoalID: sub.id, lineID: nil), reduceMotion: true)
    goals.file(task: loose.id, under: rug.id, subgoal: sub.id)
    #expect(goals.openBox == nil && goals.opened == [sub.id])
    goals.reach(sub.id)
    #expect(goals.opened.isEmpty)
    // With Today open everything starts out for picking, and folds the same way, apart from the map's own folds.
    goals.setToday(true, reduceMotion: true)
    defer { goals.setToday(false, reduceMotion: true) }
    #expect(goals.spreads(goal.id) && goals.hangs(other.id))
    goals.toggle(subgoal: other.id, reduceMotion: true)
    #expect(!goals.hangs(other.id) && goals.opened.isEmpty)
    goals.toggle(goal: goal.id, reduceMotion: true)
    #expect(!goals.spreads(goal.id))
    // Out again, its subgoals' minigoals come out with it.
    goals.toggle(goal: goal.id, reduceMotion: true)
    #expect(goals.spreads(goal.id) && goals.hangs(other.id))
}

/// Every picture tints the open island at the same lightness, keeping its hue, so a dark one shows as clearly as a bright
/// one. A muted picture gets more of its colour; a vivid one keeps what the screen can show at that lightness.
@Test func theIslandTintKeepsAPicturesHueAtOneLightness() {
    let lab = { (colour: NSColor) -> Oklab in
        let rgb = colour.usingColorSpace(.sRGB)!
        return Oklab(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
    for mean in [NSColor(srgbRed: 0.25, green: 0.37, blue: 0.37, alpha: 1), NSColor(srgbRed: 0.77, green: 0.39, blue: 0.23, alpha: 1),
                 NSColor(srgbRed: 0.31, green: 0.29, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.1, green: 0.2, blue: 0.95, alpha: 1)] {
        let before = lab(mean), after = lab(WorkspaceController.islandTint(of: mean))
        #expect(abs(after.l - 0.62) < 0.01)
        #expect(abs(atan2(after.b, after.a) - atan2(before.b, before.a)) < 0.05)
        if hypot(before.a, before.b) < 0.1 { #expect(hypot(after.a, after.b) > hypot(before.a, before.b) * 1.3) }
    }
}
