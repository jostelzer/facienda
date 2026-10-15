import AppKit
import FaciendaCore

/// One change on the window's undo stack. Each is its own entry, so a toast can take back exactly its change.
final class UndoEntry: UndoAction {
    let name: String
    let step: UndoStep
    weak var model: AppModel?
    init(name: String, step: UndoStep, model: AppModel) { self.name = name; self.step = step; self.model = model }
    override func run() { model?.replay(self, redoable: true) }
}

/// A toast at the foot of the window saying what just happened, with Undo.
struct UndoOffer: Identifiable {
    let id = UUID()
    var message: String
    let entry: UndoEntry
}

/// ⌘Z and ⇧⌘Z: changes made through `perform(undo:)` go on the window's undo stack, alongside typing in text fields.
/// Undo puts back exactly the rows the change touched, so work the agents did meanwhile stays.
extension AppModel {
    /// Runs a change the user can take back. The name stays with it through undo and redo;
    /// a message also offers Undo in a toast for a few seconds.
    func perform(undo name: String, offering message: String? = nil, _ action: () throws -> Void) {
        let step = UndoStep.recording { perform(action) }
        guard let entry = register(step, named: name) else { return }
        latestUndo = entry
        if let message { offerUndo(message) }
    }

    /// Offers the latest change in a toast, for views that only know what to call it once it is made.
    func offerUndo(_ message: String) {
        guard let latestUndo else { return }
        undoOffer = UndoOffer(message: message, entry: latestUndo)
    }

    /// The toast's Undo takes back its own change, even if others came after it. It is not redone with ⇧⌘Z.
    func takeBack(_ offer: UndoOffer) {
        if let undoManager { SafeUndo.remove(offer.entry, from: undoManager) }
        replay(offer.entry, redoable: false)
    }

    @discardableResult private func register(_ step: UndoStep, named name: String) -> UndoEntry? {
        guard !step.isEmpty, let undoManager else { return nil }
        let entry = UndoEntry(name: name, step: step, model: self)
        return SafeUndo.register(entry, named: name, on: undoManager) ? entry : nil
    }

    /// Undoing records its own reverse, which goes on the redo stack, and redoing puts it back on the undo stack.
    fileprivate func replay(_ entry: UndoEntry, redoable: Bool) {
        if undoOffer?.entry === entry { undoOffer = nil }
        if latestUndo === entry { latestUndo = nil }
        do {
            let reverse = try store.replay(entry.step)
            if redoable { register(reverse, named: entry.name) }
        } catch {
            self.error = "“\(entry.name)” can’t be undone: the library changed since. \(error.localizedDescription)"
        }
        refresh()
    }
}

/// Edit ▸ Undo and Redo. A text field keeps its own history while it is being typed in, and on its own the menu
/// stops there; here typing is taken back first, then the changes before it, so a line removed with Backspace
/// comes back even though the cursor moved on to the line above.
@MainActor enum EditHistory {
    static func undo(_ model: AppModel?) { step(model, redo: false) }
    static func redo(_ model: AppModel?) { step(model, redo: true) }

    private static func step(_ model: AppModel?, redo: Bool) {
        let typing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager
        for manager in [typing, model?.undoManager].compactMap({ $0 }) where redo ? SafeUndo.canRedo(manager) : SafeUndo.canUndo(manager) {
            _ = redo ? SafeUndo.redo(manager) : SafeUndo.undo(manager)
            return
        }
    }
}
