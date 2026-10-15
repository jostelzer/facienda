import Foundation
import FaciendaExceptions

/// An entry on an undo stack. The stack keeps it alive for exactly as long as it can be undone or redone.
@MainActor open class UndoAction: NSObject {
    public override init() { super.init() }
    /// Called when the entry is undone or redone. Registering from here puts the opposite step on the other stack.
    open func run() {}
    /// Named apart from NSObject's `perform(_:)`, which is `performSelector:` and would be picked by `#selector` instead.
    @objc(faciendaRunUndoAction:) fileprivate func runUndoAction(_ object: Any?) {
        SafeUndo.running += 1
        defer { SafeUndo.running -= 1 }
        run()
    }
}

/// The only way Facienda touches an `UndoManager`, so that nothing an undo or redo does can bring the app down.
/// Foundation raises exceptions Swift cannot catch when a stack is used at the wrong moment: undoing or redoing
/// while an undo runs, undoing with groups left open, clearing the stack in the middle of an undo, which then fails
/// as it finishes. Each call checks for those first, and runs inside `FaciendaCatchException` in case Foundation
/// finds another reason. A stack that raised anyway is emptied, and `failed` says so.
@MainActor public enum SafeUndo {
    /// Told when the stack had to be emptied after Foundation refused it.
    public static var failed: ((String) -> Void)?
    /// How many entries are running their undo or redo right now.
    fileprivate static var running = 0

    /// Puts an action on the stack under a name, such as "Delete Task".
    /// The selector form retains the action. The closure form, `registerUndo(withTarget:handler:)`, does not:
    /// once nothing else holds the target, undo calls back into freed memory and the app crashes.
    @discardableResult public static func register(_ action: UndoAction, named name: String, on manager: UndoManager) -> Bool {
        // An entry running while its stack says it is not undoing means the stack was cleared mid-undo. Registering
        // now would put the step back on the stack being undone, which pops and runs it again, without end.
        if running > 0 && !busy(manager) {
            later { clear(manager) }
            failed?("Undo history was reset: it was cleared while an undo was running.")
            return false
        }
        return attempt(manager) {
            // A stack that does not group by event needs a group around the entry, except during an undo, which opens its own.
            let group = !manager.groupsByEvent && manager.groupingLevel == 0 && !busy(manager)
            if group { manager.beginUndoGrouping() }
            manager.registerUndo(withTarget: action, selector: #selector(UndoAction.runUndoAction(_:)), object: action)
            manager.setActionName(name)
            if group { manager.endUndoGrouping() }
        }
    }

    public static func canUndo(_ manager: UndoManager) -> Bool { ready(manager) && manager.canUndo }
    public static func canRedo(_ manager: UndoManager) -> Bool { ready(manager) && manager.canRedo }

    /// Takes the newest entry back. Does nothing, rather than raise, when the stack cannot undo right now.
    @discardableResult public static func undo(_ manager: UndoManager) -> Bool {
        canUndo(manager) && attempt(manager) { manager.undo() }
    }

    /// Puts the newest undone entry forward again. Does nothing, rather than raise, when the stack cannot redo right now.
    @discardableResult public static func redo(_ manager: UndoManager) -> Bool {
        canRedo(manager) && attempt(manager) { manager.redo() }
    }

    /// Takes one entry off the stack, as when its change was undone some other way.
    public static func remove(_ action: UndoAction, from manager: UndoManager) {
        guard !busy(manager) else { return later { remove(action, from: manager) } }
        attempt(manager) { manager.removeAllActions(withTarget: action) }
    }

    /// Empties the stack once any undo in progress has finished.
    public static func clear(_ manager: UndoManager) { clear(manager, tries: 3) }

    private static func clear(_ manager: UndoManager, tries: Int) {
        guard !busy(manager) else {
            if tries > 0 { later { clear(manager, tries: tries - 1) } }
            return
        }
        _ = FaciendaCatchException { manager.removeAllActions() }
    }

    private static func busy(_ manager: UndoManager) -> Bool { manager.isUndoing || manager.isRedoing }

    /// Undo closes a single group left open by event grouping itself, and raises on any deeper nesting.
    private static func ready(_ manager: UndoManager) -> Bool {
        !busy(manager) && manager.groupingLevel <= (manager.groupsByEvent ? 1 : 0)
    }

    @discardableResult private static func attempt(_ manager: UndoManager, _ body: () -> Void) -> Bool {
        guard let exception = FaciendaCatchException(body) else { return true }
        later { clear(manager) }
        failed?("Undo history was reset after an error: \(exception.reason ?? exception.name.rawValue)")
        return false
    }

    private static func later(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
