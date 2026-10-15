import Foundation
import FaciendaCore

extension AppModel {
    static let newGroupName = "New group"
    func requestNewGroup() {
        search = ""; destination = .dashboard; selection = nil; newGroupRequested = true
    }
    /// The board's New group card becomes a real group where it stood, holding any tasks dropped on it.
    @discardableResult func createGroup(name: String, holding taskIDs: [String] = [], lane: Int? = nil, row: Int? = nil) -> TaskGroup? {
        var created: TaskGroup?
        perform(undo: "New Group") {
            let group = try store.createGroup(name: name)
            for taskID in taskIDs { try store.assignGroup(taskId: taskID, groupId: group.id) }
            if let lane, let row { try store.placeGroups([GroupPlacement(id: group.id, lane: lane, row: row)]) }
            created = group
            refresh()
        }
        return created
    }
    func renameGroup(_ group: TaskGroup, name: String) {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != group.name else { return }
        perform(undo: "Rename Group") { try store.renameGroup(group.id, name: name); refresh() }
    }
    func placeGroups(_ placements: [GroupPlacement]) { perform(undo: "Move Group") { try store.placeGroups(placements); refresh() } }
    /// Sends a group with its tasks and chats to another workspace. Undo brings it back to the same place on this board.
    func moveGroup(_ group: TaskGroup, to target: Workspace) {
        perform(undo: "Move Group", offering: "Moved “\(group.name)” to \(target.name)") {
            try store.moveGroup(group.id, toWorkspace: target.id)
            if omnibarGroup == group.id { omnibarGroup = nil }
            refresh()
        }
    }
    func deleteGroup(_ group: TaskGroup) {
        perform(undo: "Delete Group", offering: "Deleted “\(group.name)”") { try store.deleteGroup(group.id); refresh() }
    }
    /// A task dropped on another card arrives at its top, like a new one.
    func move(taskID: String, to groupID: String?) {
        guard groupMembers[taskID] != groupID else { return }
        place(taskID: taskID, in: groupID, at: .top)
    }

    enum TaskSpot: Equatable { case top, bottom, above(String), below(String) }

    /// Puts a task where the user wants it in a card, joining that card's group if it came from another.
    /// Only the user's moves change the order; the rest of the card stays as it was.
    func place(taskID: String, in groupID: String?, at spot: TaskSpot) {
        let current = cardOrder(groupID)
        var order = current.filter { $0 != taskID }
        let index: Int
        switch spot {
        case .top: index = 0
        case .bottom: index = order.count
        case .above(let other): guard let found = order.firstIndex(of: other) else { return }; index = found
        case .below(let other): guard let found = order.firstIndex(of: other) else { return }; index = found + 1
        }
        order.insert(taskID, at: index)
        let joining = groupMembers[taskID] != groupID
        guard joining || order != current else { return }
        perform(undo: "Move Task") {
            if joining { try store.assignGroup(taskId: taskID, groupId: groupID) }
            try store.placeTasks(order)
            refresh()
        }
    }

    /// Every task in a card, shown or not, in board order. Ordering against all of them keeps hidden and filtered-out tasks where they were.
    private func cardOrder(_ groupID: String?) -> [String] {
        let known = Set(groups.map(\.id))
        let card = tasks.filter { task in
            let group: String? = groupMembers[task.id].flatMap { known.contains($0) ? $0 : nil }
            return group == groupID
        }
        let keyed: [(id: String, key: Double)] = card.map { ($0.id, boardKey($0)) }
        return keyed.sorted { $0.key != $1.key ? $0.key < $1.key : $0.id < $1.id }.map(\.id)
    }
}
