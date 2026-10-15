import Foundation
import Testing
import FaciendaExceptions
@testable import FaciendaCore

/// Each test here is a way undo used to, or could, end the app. None of them may crash.
@MainActor private final class Probe: UndoAction {
    let manager: UndoManager
    let inside: (UndoManager) -> Void
    var runs = 0
    init(_ manager: UndoManager, inside: @escaping (UndoManager) -> Void = { _ in }) { self.manager = manager; self.inside = inside }
    override func run() {
        runs += 1
        inside(manager)
        // The opposite step, as the app registers it: a fresh entry nothing else holds.
        SafeUndo.register(Probe(manager, inside: inside), named: "Probe", on: manager)
    }
}

@MainActor private func stack() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
}

@MainActor @Test func redoOfAnEntryNothingElseHoldsDoesNotCrash() {
    // The first version used the closure form, which does not retain its target: the redo called into freed memory.
    let manager = stack()
    SafeUndo.register(Probe(manager), named: "Probe", on: manager)
    for _ in 0..<50 {
        #expect(SafeUndo.undo(manager))
        #expect(SafeUndo.redo(manager))
    }
}

@MainActor @Test func undoOrRedoFromInsideAnUndoIsRefused() {
    let manager = stack()
    var refused: [Bool] = []
    SafeUndo.register(Probe(manager) { inner in refused += [SafeUndo.undo(inner), SafeUndo.redo(inner)] }, named: "Probe", on: manager)
    #expect(SafeUndo.undo(manager))
    #expect(refused == [false, false])
    #expect(SafeUndo.redo(manager))
}

@MainActor @Test func clearingInTheMiddleOfAnUndoWaitsForItToFinish() async {
    let manager = stack()
    SafeUndo.register(Probe(manager) { inner in SafeUndo.clear(inner) }, named: "Probe", on: manager)
    #expect(SafeUndo.undo(manager))
    await Task.yield(); try? await Task.sleep(for: .milliseconds(50))
    #expect(!manager.canUndo && !manager.canRedo)
}

@MainActor @Test func openGroupsMakeUndoWaitInsteadOfRaise() {
    let manager = stack()
    SafeUndo.register(Probe(manager), named: "Probe", on: manager)
    manager.beginUndoGrouping()
    #expect(!SafeUndo.undo(manager))
    manager.endUndoGrouping()
    #expect(SafeUndo.undo(manager))
}

@Test func objectiveCExceptionsAreCaught() {
    let exception = FaciendaCatchException { NSException(name: .internalInconsistencyException, reason: "test", userInfo: nil).raise() }
    #expect(exception?.reason == "test")
    #expect(FaciendaCatchException {} == nil)
}

@MainActor @Test func aStackFoundationRefusesIsEmptiedAndReported() async {
    // Code that empties the stack in the middle of an undo, without going through SafeUndo, leaves Foundation unable
    // to take the opposite step or to finish the undo. Both raise; neither may end the app.
    let manager = stack()
    var reported: [String] = []
    SafeUndo.failed = { reported.append($0) }
    defer { SafeUndo.failed = nil }
    SafeUndo.register(Probe(manager) { inner in inner.removeAllActions() }, named: "Probe", on: manager)
    #expect(!SafeUndo.undo(manager))
    #expect(!reported.isEmpty)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!manager.isUndoing || !SafeUndo.canUndo(manager))
    // Whatever state Foundation was left in, asking again is answered without raising.
    _ = SafeUndo.undo(manager); _ = SafeUndo.redo(manager)
}

/// The app's own loop against a real library: random changes, undos and redos, then everything undone.
@MainActor @Test func randomUndoAndRedoNeverCrashAndUndoingEverythingRestoresTheLibrary() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/safe-undo.sqlite"))
    let manager = stack()
    final class Change: UndoAction {
        let store: FaciendaStore, step: UndoStep, manager: UndoManager
        var failed = false
        init(_ store: FaciendaStore, _ step: UndoStep, _ manager: UndoManager) { self.store = store; self.step = step; self.manager = manager }
        override func run() {
            guard let reverse = try? store.replay(step) else { failed = true; return }
            SafeUndo.register(Change(store, reverse, manager), named: "Change", on: manager)
        }
    }
    let seed = try store.create(FaciendaTask(title: "Seed"))
    func snapshot() throws -> [String] {
        try store.tasks().map { "\($0.id) \($0.title) \($0.state) \($0.displayTitle ?? "")" }.sorted()
            + store.groups().map { "\($0.id) \($0.name)" }.sorted()
            + store.groupMembers().map { "\($0.taskId) \($0.groupId)" }.sorted()
            + store.planLines().map { "\($0.id) \($0.text) \($0.position) \($0.parentId ?? "")" }.sorted()
    }
    let start = try snapshot()
    var generator = SplitMix(seed: 20261009)
    for round in 0..<300 {
        switch Int.random(in: 0..<10, using: &generator) {
        case 0..<5:
            let step = UndoStep.recording {
                let tasks = (try? store.tasks()) ?? [], groups = (try? store.groups()) ?? []
                switch Int.random(in: 0..<7, using: &generator) {
                case 0: _ = try? store.create(FaciendaTask(title: "Task \(round)"))
                case 1: if let task = tasks.randomElement() { try? store.deleteTask(task.id) }
                case 2: if let task = tasks.randomElement() { _ = try? store.update(task.id) { $0.displayTitle = "Named \(round)" } }
                case 3: _ = try? store.createGroup(name: "Group \(round)")
                case 4: if let group = groups.randomElement() { try? store.deleteGroup(group.id) }
                case 5: if let task = tasks.randomElement(), let group = groups.randomElement() { try? store.assignGroup(taskId: task.id, groupId: group.id) }
                default: if let group = groups.randomElement() { _ = try? store.addPlanLine(groupId: group.id, text: "Line \(round)") }
                }
            }
            if !step.isEmpty { SafeUndo.register(Change(store, step, manager), named: "Change", on: manager) }
        case 5..<8: SafeUndo.undo(manager)
        default: SafeUndo.redo(manager)
        }
    }
    while SafeUndo.undo(manager) {}
    #expect(try snapshot() == start)
    #expect(try store.task(seed.id).title == "Seed")
}

/// A fixed sequence, so a failure can be replayed.
private struct SplitMix: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
