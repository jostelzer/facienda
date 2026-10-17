import Foundation
import FaciendaCore

/// Plan lines, written, moved and started as tasks from the Plan view.
extension AppModel {
    @discardableResult func addPlanLine(in groupID: String, parent: String?, after: String?) -> PlanLine? {
        var line: PlanLine?
        perform(undo: "New Line") { line = try store.addPlanLine(groupId: groupID, parentId: parent, after: after); refresh() }
        return line
    }
    /// A task written down in its group without starting it: a new line at the end of the group's plan.
    func planTask(_ text: String, in groupID: String) -> Bool {
        var planned = false
        perform(undo: "Plan Task") { try store.addPlanLine(groupId: groupID, text: text); refresh(); planned = true }
        return planned
    }

    /// What a group's card shows from its plan: top-level lines not started yet. Goals with steps stay in the Plan view.
    func plannedLines(in groupID: String) -> [PlanLine] {
        let lines = planLines.filter { $0.groupId == groupID }
        let parents = Set(lines.compactMap(\.parentId))
        return lines.filter { $0.parentId == nil && $0.launchedTaskId == nil && !parents.contains($0.id)
            && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.position < $1.position }
    }
    func setPlanText(_ id: String, _ text: String) { perform(undo: "Typing") { try store.setPlanText(id, text: text); refresh() } }
    func deletePlanLine(_ id: String) { perform(undo: "Delete Line") { try store.deletePlanLine(id); refresh() } }
    func indentPlanLine(_ id: String) { perform(undo: "Indent") { try store.indentPlanLine(id); refresh() } }
    func outdentPlanLine(_ id: String) { perform(undo: "Outdent") { try store.outdentPlanLine(id); refresh() } }
    func movePlanLine(_ id: String, by offset: Int) { perform(undo: "Move Line") { try store.movePlanLine(id, by: offset); refresh() } }
    /// With `groupID` the line moves into that group's plan, as a planned row carried to another card does.
    func placePlanLine(_ id: String, in groupID: String? = nil, parentId: String?, before: String?) {
        perform(undo: "Move Line") { try store.placePlanLine(id, groupId: groupID, parentId: parentId, before: before); refresh() }
    }
    func adoptIntoPlan(_ taskID: String, group: String, parentId: String?, before: String?) {
        perform(undo: "Move Task") { try store.adoptIntoPlan(taskId: taskID, groupId: group, parentId: parentId, before: before); refresh() }
    }

    /// Starts a plan line as a task in its group. The goals above the line travel with it, so the agent sees the bigger picture.
    func launchPlanLine(_ line: PlanLine, text: String) async -> Bool {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, line.launchedTaskId == nil else { return false }
        let goals = PlanOutline(planLines.filter { $0.groupId == line.groupId }).ancestors(of: line.id)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let intention = goals.isEmpty ? "" : "Part of the goal: " + goals.joined(separator: " › ")
        do {
            try store.setPlanText(line.id, text: title)
            var draft = FaciendaTask(title: title, intention: intention, state: .inbox, nextAction: title, returnAt: Date())
            let choice = composerModel
            draft.workerModel = choice.model; draft.workerReasoningEffort = choice.effort
            draft.workerServiceTier = choice.serviceTier; draft.workerProvider = choice.provider
            let task = try store.create(draft)
            try store.assignGroup(taskId: task.id, groupId: line.groupId)
            try store.linkPlanLine(line.id, taskId: task.id)
            refresh()
            // One start at a time; a line started right after another waits its turn instead of being skipped.
            while dispatching { try? await Task.sleep(for: .milliseconds(150)) }
            await dispatch(task, reveal: false)
            return true
        } catch {
            self.error = error.localizedDescription
            refresh()
            return false
        }
    }
}
