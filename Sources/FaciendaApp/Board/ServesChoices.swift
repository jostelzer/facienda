import SwiftUI
import FaciendaCore

/// The goal a task serves, for its menu: each open goal, and inside it the subgoals to pick from. A subgoal with lines
/// still as written opens once more, so the task can go under the line it works toward. Goals live in the library, so
/// they are read as the menu opens. Choosing a subgoal gives the task a line in it, in place of any it had.
struct ServesChoices: View {
    let model: AppModel
    let taskID: String

    var body: some View {
        let library = model.store.library
        let goals = (try? library.goals()) ?? []
        let current = try? library.servedSubgoal(taskId: taskID), line = try? library.servedLine(taskId: taskID)
        // Only what the user wrote can hold work: a line that became a task is that task.
        let written = ((try? library.goalItems()) ?? []).filter { $0.task == nil && $0.line.parentLineId == nil }
        let open = goals.filter { $0.parentId == nil && $0.reachedAt == nil }
        if open.isEmpty { Text("No goals yet. Add them in Goals (⌘G).") }
        ForEach(open) { goal in
            let subs = goals.filter { $0.parentId == goal.id && $0.reachedAt == nil }
            Menu {
                if subs.isEmpty { Text("No subgoals yet") }
                ForEach(subs) { sub in
                    let lines = written.filter { $0.line.subgoalId == sub.id }
                    if lines.isEmpty {
                        Button { serve(sub.id) } label: { choice(sub.text, on: sub.id == current) }
                    } else {
                        Menu {
                            Button { serve(sub.id) } label: { choice("Just this subgoal", on: sub.id == current && line == nil) }
                            Divider()
                            ForEach(lines) { item in
                                Button { serve(line: item.line.id) } label: { choice(item.line.text, on: item.line.id == line) }
                            }
                        } label: { choice(sub.text, on: sub.id == current) }
                    }
                }
            } label: { choice(goal.text, on: subs.contains { $0.id == current }) }
        }
        if current != nil {
            Divider()
            Button("No goal") { serve(nil) }
        }
    }

    @ViewBuilder private func choice(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    private func serve(_ subgoal: String?) {
        do { try model.store.library.serve(taskId: taskID, subgoalId: subgoal) } catch { model.error = error.localizedDescription }
    }

    private func serve(line: String) {
        do { try model.store.library.serve(taskId: taskID, lineId: line) } catch { model.error = error.localizedDescription }
    }
}
