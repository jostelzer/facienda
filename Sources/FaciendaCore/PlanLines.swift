import Foundation
import GRDB

/// One line of a group's plan: something the user wants done, written in their own words.
/// Lines nest under a parent line, so a larger goal can hold the steps that reach it.
/// Launching a line makes it a task in the group; the line then shows that task.
public struct PlanLine: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "planLines"
    public var id: String
    public var groupId: String
    /// The line this one sits under. Nil for a top-level line.
    public var parentId: String?
    /// The line's place among its siblings, counted from the top.
    public var position: Int
    public var text: String
    /// The task this line became. Not called taskId, so deleting the task unlinks the line instead of removing what the user wrote.
    public var launchedTaskId: String?
    public var createdAt: Date
    public var updatedAt: Date
}

extension FaciendaStore {
    static func registerPlanLines(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("plan_lines") { db in
            // Beside groups and tasks: writing a plan never edits a task, and a group's plan goes with the group.
            try db.execute(sql: """
            CREATE TABLE planLines (
              id TEXT PRIMARY KEY NOT NULL,
              groupId TEXT NOT NULL REFERENCES taskGroups(id) ON DELETE CASCADE,
              parentId TEXT REFERENCES planLines(id) ON DELETE CASCADE,
              position INTEGER NOT NULL,
              text TEXT NOT NULL,
              launchedTaskId TEXT REFERENCES tasks(id) ON DELETE SET NULL,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL
            );
            CREATE INDEX plan_lines_group ON planLines(groupId, parentId, position);
            """)
        }
    }

    public static let planLineLimit = 2000

    /// The scoped workspace's plan lines, or every line in the library, in reading order within each group.
    public func planLines() throws -> [PlanLine] {
        try db.read { db in
            guard let workspaceID else { return try PlanLine.fetchAll(db, sql: "SELECT * FROM planLines ORDER BY groupId, position") }
            return try PlanLine.fetchAll(db, sql: "SELECT p.* FROM planLines p JOIN taskGroups g ON g.id = p.groupId WHERE g.workspaceId = ? ORDER BY p.groupId, p.position", arguments: [workspaceID])
        }
    }

    /// Adds a line to a group's plan: under `parentId`, right after `afterId`, or at the end of its siblings.
    @discardableResult public func addPlanLine(groupId: String, parentId: String? = nil, after afterId: String? = nil, text: String = "", now: Date = Date()) throws -> PlanLine {
        let text = try Self.planText(text, allowEmpty: true)
        return try write { db in
            guard try TaskGroup.fetchOne(db, key: groupId) != nil else { throw StoreError.notFound }
            if let workspaceID, try String.fetchOne(db, sql: "SELECT workspaceId FROM taskGroups WHERE id = ?", arguments: [groupId]) != workspaceID { throw StoreError.notFound }
            if let parentId { guard try PlanLine.fetchOne(db, key: parentId)?.groupId == groupId else { throw StoreError.notFound } }
            let siblings = try Self.siblings(db, groupId: groupId, parentId: parentId)
            let position: Int
            if let afterId, let index = siblings.firstIndex(where: { $0.id == afterId }) { position = index + 1 } else { position = siblings.count }
            let line = PlanLine(id: UUID().uuidString, groupId: groupId, parentId: parentId, position: position, text: text, launchedTaskId: nil, createdAt: now, updatedAt: now)
            var ordered = siblings
            ordered.insert(line, at: position)
            try line.insert(db)
            try Self.renumber(db, ordered)
            return line
        }
    }

    public func setPlanText(_ id: String, text: String, now: Date = Date()) throws {
        let text = try Self.planText(text, allowEmpty: true)
        try write { db in
            guard var line = try PlanLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard line.text != text else { return }
            line.text = text; line.updatedAt = now
            try line.update(db)
        }
    }

    /// Removes a line. The lines under it go with it; tasks it launched stay in their group.
    public func deletePlanLine(_ id: String) throws {
        try write { db in
            guard let line = try PlanLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            try line.delete(db)
            try Self.renumber(db, Self.siblings(db, groupId: line.groupId, parentId: line.parentId))
        }
    }

    /// Moves a line under the sibling above it, as that sibling's last line. The first line has nowhere to go.
    @discardableResult public func indentPlanLine(_ id: String, now: Date = Date()) throws -> Bool {
        try write { db in
            guard var line = try PlanLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            let siblings = try Self.siblings(db, groupId: line.groupId, parentId: line.parentId)
            guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0 else { return false }
            let newParent = siblings[index - 1]
            line.parentId = newParent.id
            line.position = try Self.siblings(db, groupId: line.groupId, parentId: newParent.id).count
            line.updatedAt = now
            try line.update(db)
            try Self.renumber(db, Self.siblings(db, groupId: line.groupId, parentId: siblings[index].parentId))
            return true
        }
    }

    /// Moves a line out from under its parent, to sit right after it. Top-level lines stay where they are.
    @discardableResult public func outdentPlanLine(_ id: String, now: Date = Date()) throws -> Bool {
        try write { db in
            guard var line = try PlanLine.fetchOne(db, key: id), let parentId = line.parentId,
                  let parent = try PlanLine.fetchOne(db, key: parentId) else { return false }
            let oldParent = line.parentId
            line.parentId = parent.parentId; line.updatedAt = now
            var siblings = try Self.siblings(db, groupId: line.groupId, parentId: parent.parentId)
            let index = (siblings.firstIndex { $0.id == parent.id } ?? siblings.count - 1) + 1
            siblings.insert(line, at: index)
            try line.update(db)
            try Self.renumber(db, siblings)
            try Self.renumber(db, Self.siblings(db, groupId: line.groupId, parentId: oldParent))
            return true
        }
    }

    /// Moves a line one place up or down among its siblings.
    @discardableResult public func movePlanLine(_ id: String, by offset: Int) throws -> Bool {
        try write { db in
            guard let line = try PlanLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            var siblings = try Self.siblings(db, groupId: line.groupId, parentId: line.parentId)
            guard let index = siblings.firstIndex(where: { $0.id == id }) else { return false }
            let target = index + offset
            guard siblings.indices.contains(target), target != index else { return false }
            siblings.swapAt(index, target)
            try Self.renumber(db, siblings)
            return true
        }
    }

    /// Puts a line, with everything under it, under `parentId` just before the sibling `beforeId`, or last when that is nil.
    /// With `groupId` the line moves into that group's plan, in the same workspace; tasks its lines started stay in their group.
    /// A line never goes under itself or one of its own lines.
    public func placePlanLine(_ id: String, groupId: String? = nil, parentId: String?, before beforeId: String?, now: Date = Date()) throws {
        try write { db in
            guard var line = try PlanLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            let oldGroup = line.groupId, group = groupId ?? oldGroup
            if group != oldGroup {
                guard let target = try TaskGroup.fetchOne(db, key: group), let source = try TaskGroup.fetchOne(db, key: oldGroup),
                      target.workspaceId == source.workspaceId, workspaceID.map({ $0 == target.workspaceId }) ?? true else { throw StoreError.notFound }
            }
            var ancestor = parentId
            while let current = ancestor {
                guard current != id, let above = try PlanLine.fetchOne(db, key: current), above.groupId == group else {
                    throw StoreError.invalid("A line can't go under itself.")
                }
                ancestor = above.parentId
            }
            let oldParent = line.parentId
            var siblings = try Self.siblings(db, groupId: group, parentId: parentId).filter { $0.id != id }
            let index: Int
            if let beforeId {
                guard let found = siblings.firstIndex(where: { $0.id == beforeId }) else { throw StoreError.notFound }
                index = found
            } else { index = siblings.count }
            if group != oldGroup {
                // The lines under it come along.
                let steps = PlanOutline(try PlanLine.fetchAll(db, sql: "SELECT * FROM planLines WHERE groupId = ?", arguments: [oldGroup])).descendants(of: id)
                for step in steps { try db.execute(sql: "UPDATE planLines SET groupId = ?, updatedAt = ? WHERE id = ?", arguments: [group, now, step.id]) }
            }
            line.groupId = group; line.parentId = parentId; line.updatedAt = now
            siblings.insert(line, at: index)
            try line.update(db)
            try Self.renumber(db, siblings)
            if oldGroup != group || oldParent != parentId { try Self.renumber(db, Self.siblings(db, groupId: oldGroup, parentId: oldParent)) }
        }
    }

    /// Brings a task that didn't come from the plan into it, as a line under `parentId` just before `beforeId` (or last).
    /// A task belongs to one line at most.
    @discardableResult public func adoptIntoPlan(taskId: String, groupId: String, parentId: String?, before beforeId: String?, now: Date = Date()) throws -> PlanLine {
        try write { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId), try TaskGroup.fetchOne(db, key: groupId) != nil else { throw StoreError.notFound }
            if let workspaceID, try String.fetchOne(db, sql: "SELECT workspaceId FROM taskGroups WHERE id = ?", arguments: [groupId]) != workspaceID { throw StoreError.notFound }
            guard try PlanLine.fetchOne(db, sql: "SELECT * FROM planLines WHERE launchedTaskId = ?", arguments: [taskId]) == nil else { throw StoreError.conflict }
            if let parentId { guard try PlanLine.fetchOne(db, key: parentId)?.groupId == groupId else { throw StoreError.notFound } }
            var siblings = try Self.siblings(db, groupId: groupId, parentId: parentId)
            let index: Int
            if let beforeId {
                guard let found = siblings.firstIndex(where: { $0.id == beforeId }) else { throw StoreError.notFound }
                index = found
            } else { index = siblings.count }
            let line = PlanLine(id: UUID().uuidString, groupId: groupId, parentId: parentId, position: index, text: try Self.planText(task.displayName, allowEmpty: false),
                                launchedTaskId: taskId, createdAt: now, updatedAt: now)
            siblings.insert(line, at: index)
            try line.insert(db)
            try Self.renumber(db, siblings)
            return line
        }
    }

    /// Records the task a line became. A line launches once.
    public func linkPlanLine(_ id: String, taskId: String, now: Date = Date()) throws {
        try write { db in
            guard var line = try PlanLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard line.launchedTaskId == nil else { throw StoreError.conflict }
            guard try FaciendaTask.fetchOne(db, key: taskId) != nil else { throw StoreError.notFound }
            line.launchedTaskId = taskId; line.updatedAt = now
            try line.update(db)
        }
    }

    private static func siblings(_ db: Database, groupId: String, parentId: String?) throws -> [PlanLine] {
        if let parentId {
            return try PlanLine.fetchAll(db, sql: "SELECT * FROM planLines WHERE groupId = ? AND parentId = ? ORDER BY position, createdAt", arguments: [groupId, parentId])
        }
        return try PlanLine.fetchAll(db, sql: "SELECT * FROM planLines WHERE groupId = ? AND parentId IS NULL ORDER BY position, createdAt", arguments: [groupId])
    }

    private static func renumber(_ db: Database, _ lines: [PlanLine]) throws {
        for (index, line) in lines.enumerated() where line.position != index {
            try db.execute(sql: "UPDATE planLines SET position = ? WHERE id = ?", arguments: [index, line.id])
        }
    }

    private static func planText(_ raw: String, allowEmpty: Bool) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !text.isEmpty else { throw StoreError.invalid("Write what you want done first.") }
        guard text.count <= planLineLimit else { throw StoreError.invalid("Keep a plan line under \(planLineLimit) characters.") }
        return text
    }
}

/// A group's plan as an outline: each line with how deep it sits, in reading order.
public struct PlanOutline: Sendable {
    public struct Entry: Equatable, Sendable {
        public var line: PlanLine
        public var depth: Int
        public var childIDs: [String]
    }
    public let entries: [Entry]

    public init(_ lines: [PlanLine]) {
        let byParent = Dictionary(grouping: lines) { $0.parentId ?? "" }
        let known = Set(lines.map(\.id))
        var entries: [Entry] = []
        func visit(_ parent: String, depth: Int) {
            for line in (byParent[parent] ?? []).sorted(by: { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }) {
                let children = (byParent[line.id] ?? []).map(\.id)
                entries.append(Entry(line: line, depth: depth, childIDs: children))
                visit(line.id, depth: depth + 1)
            }
        }
        visit("", depth: 0)
        // A line whose parent is missing would be unreachable; it shows at the top level instead of vanishing.
        for line in lines where line.parentId.map({ !known.contains($0) }) == true {
            entries.append(Entry(line: line, depth: 0, childIDs: (byParent[line.id] ?? []).map(\.id)))
            visit(line.id, depth: 1)
        }
        self.entries = entries
    }

    /// Where a dragged line lands among the lines that stay put (`others`, in reading order with their depths).
    /// `target` is how many of them sit above it. The depth is the one asked for, kept between the line below
    /// (it can't sit shallower than its new next neighbour) and one deeper than the line above.
    /// The parent is the nearest line above that sits one level shallower; `before` is the next sibling, if any.
    public static func drop(others: [(id: String, depth: Int)], target: Int, wantedDepth: Int) -> (depth: Int, parent: String?, before: String?) {
        let target = min(max(target, 0), others.count)
        let above = target > 0 ? others[target - 1] : nil
        let below = target < others.count ? others[target] : nil
        let deepest = above.map { $0.depth + 1 } ?? 0
        let shallowest = min(below?.depth ?? 0, deepest)
        let depth = min(max(wantedDepth, shallowest), deepest)
        let parent = depth == 0 ? nil : others.prefix(target).last { $0.depth == depth - 1 }?.id
        return (depth, parent, below.flatMap { $0.depth == depth ? $0.id : nil })
    }

    /// Every line below `id`, at any depth.
    public func descendants(of id: String) -> [PlanLine] {
        guard let start = entries.firstIndex(where: { $0.line.id == id }) else { return [] }
        let depth = entries[start].depth
        return entries[(start + 1)...].prefix { $0.depth > depth }.map(\.line)
    }

    /// The chain of lines above `id`, outermost first.
    public func ancestors(of id: String) -> [PlanLine] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.line.id, $0.line) })
        var chain: [PlanLine] = []
        var current = byID[id]?.parentId
        while let parent = current.flatMap({ byID[$0] }), !chain.contains(where: { $0.id == parent.id }) {
            chain.insert(parent, at: 0); current = parent.parentId
        }
        return chain
    }
}
