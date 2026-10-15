import SwiftUI
import FaciendaCore

/// Pressing a card's glyph: Done, then the waits to choose from. One tap parks.
struct TaskActionsPopover: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    let done: () -> Void
    let parked: (FaciendaTask, String) -> Void
    let dismiss: () -> Void

    var body: some View {
        let wait = model.wait(for: task), dependents = model.dependents(of: task)
        VStack(alignment: .leading, spacing: 2) {
            if !task.state.isOpen {
                ChoiceRow(title: "Reopen", symbol: "arrow.uturn.backward") { model.reopen(task); dismiss() }
            } else {
                ChoiceRow(title: "Done", symbol: "checkmark") { done(); dismiss() }
                if let wait {
                    ChoiceRow(title: "Wake now", detail: model.waitSubtitle(wait), symbol: "sun.max") { model.wake(task); dismiss() }
                }
                if !dependents.isEmpty {
                    // Done would release the tasks waiting on this one; this brings them back to the user instead.
                    ChoiceRow(title: "Not happening", detail: dependents.count == 1 ? "“\(dependents[0].displayName)” waits on this" : "\(dependents.count) tasks wait on this", symbol: "xmark") {
                        model.archive(task, reveal: false); dismiss()
                    }
                }
                Divider().padding(.vertical, 4)
                WaitChoices(model: model, task: task, parked: parked, dismiss: dismiss)
            }
        }.padding(6).frame(width: 290).background(Palette.paper)
    }
}
