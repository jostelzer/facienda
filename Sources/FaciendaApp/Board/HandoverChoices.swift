import SwiftUI
import FaciendaCore

/// A task's choices for carrying on in a new chat on another model, Codex or Claude: the old chat leaves the task,
/// and its last answer and conversation go to the new one in a handover note.
struct HandoverChoices: View {
    let model: AppModel
    let task: FaciendaTask

    var body: some View {
        let current = task.workerModel.map(TaskModelChoice.current)
        ForEach(AgentProvider.allCases, id: \.self) { provider in
            Section(provider.name) {
                ForEach(TaskModelChoice.models(for: provider), id: \.id) { option in
                    Button { Task { await model.continueInNewChat(task, model: option.id) } } label: {
                        if option.id == current { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                    }
                    .disabled(!model.canStart(provider))
                }
            }
        }
    }

    /// Only a task that has a chat can hand it over; one without picks its model when it starts.
    static func offered(_ task: FaciendaTask, in model: AppModel) -> Bool {
        task.state.isOpen && model.links(for: task.id).contains { $0.role == "work" }
    }
}
