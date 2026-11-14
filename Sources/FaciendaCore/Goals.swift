import Foundation
import GRDB

/// A goal the user holds for months, or one of its subgoals. Goals belong to the library rather than a workspace, since
/// one goal often draws on work in several. Only two levels: a goal, and its subgoals; a subgoal holds lines of work.
public struct Goal: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "goals"
    public var id: String
    /// The goal this subgoal serves. Nil for a goal.
    public var parentId: String?
    public var text: String
    /// The goal's order among its siblings, for anything that lists them.
    public var position: Int
    /// Where the user put it on the map. A goal's place is a fraction of the map's width and height; a subgoal's is its
    /// offset in points from its goal's centre, so it travels with the goal. Nil until the user moves it.
    public var x: Double?
    public var y: Double?
    /// When the user said it was reached. Reached subgoals leave the board for the ledger, which keeps them.
    public var reachedAt: Date?
    /// No longer used: each line now has a place of its own. Kept so the column's meaning stays written down.
    public var homeWorkspaceId: String?
    public var homeGroupId: String?
    /// A goal's picture, painted as a workspace's is: its style, when it was painted, and the user's standing wishes.
    public var coverStyle: String?
    public var coverPaintedAt: Date?
    public var coverNotes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var isSubgoal: Bool { parentId != nil }
    public var coverNoteList: [String] { (coverNotes ?? "").split(whereSeparator: \.isNewline).map(String.init) }
}

/// One line of a subgoal: something to do, in the user's words. Started as it is, it becomes a task in a workspace and
/// group of the user's choosing, and the line then shows that task. More often a line is a small goal of its own, too
/// short to be a task: then it stays as written and holds the work toward it, each task a line under it. A task made
/// elsewhere can serve a subgoal too, under a line or with a line of its own. A task serves at most one subgoal.
public struct GoalLine: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "goalLines"
    public var id: String
    public var subgoalId: String
    public var position: Int
    public var text: String
    /// The task this line became. Deleting the task leaves the line, planned again, rather than what the user wrote.
    public var taskId: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Where a planned line will start: a workspace, and a group in it or none. Once started, the task's own place counts.
    public var workspaceId: String? = nil
    public var groupId: String? = nil
    /// With a group chosen, the planned line is also a line of that group's plan, so its card shows it as planned. The
    /// two are one thing: editing, moving, starting or deleting either one carries over to the other.
    public var planLineId: String? = nil
    /// The line this one's task works toward. Set only on a task's own line, one level deep; nil for what the user wrote.
    public var parentLineId: String? = nil
    /// When the user put it on today's list. Nil again once it is taken off, or the morning after it was done.
    public var pickedAt: Date? = nil
    /// When the user ticked it by hand, for what gets done away from Facienda. Its work, if it holds any, is left alone.
    public var tickedAt: Date? = nil
}

/// A line on today's list that serves no goal: an errand, written on the list and gone once it is done.
public struct TodayLine: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "todayLines"
    public var id: String
    public var text: String
    public var tickedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

/// A subgoal's line with the task it became, if any, and where that task lives.
public struct GoalItem: Equatable, Sendable, Identifiable {
    public var line: GoalLine
    public var task: FaciendaTask?
    public var groupName: String?
    public var mark: TaskReadMark
    public var id: String { line.id }
    /// New as the board counts it: open, not running, and back since it was last opened.
    public var isNew: Bool { task.map { [.needsMe, .waiting, .scheduled, .inbox].contains($0.state) && mark.isNew } ?? false }
}

/// Board work that looks as if it serves a subgoal: a task on no goal yet whose words fit one of the subgoal's lines, or
/// the subgoal itself. Only a guess, worked out on this Mac from words and places. Nothing is linked until the user
/// keeps it, and a guess sent away is not made again.
public struct GoalGuess: Equatable, Sendable, Identifiable {
    public var task: FaciendaTask
    public var groupName: String?
    public var groupId: String?
    public var subgoalId: String
    /// The line the task seems to work toward. Nil when it fits the subgoal but none of its lines.
    public var lineId: String?
    public var id: String { task.id }
    /// What the guess is for: the line, else the subgoal.
    public var targetId: String { lineId ?? subgoalId }
    /// The task as the line it would get, so a guess can be drawn like the subgoal's other rows.
    public var item: GoalItem {
        GoalItem(line: GoalLine(id: "guess:" + task.id, subgoalId: subgoalId, position: 0, text: task.displayName, taskId: task.id,
                                createdAt: task.createdAt, updatedAt: task.updatedAt, parentLineId: lineId),
                 task: task, groupName: groupName, mark: TaskReadMark())
    }
}

extension FaciendaStore {
    static func registerGoals(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("goals") { db in
            // Beside groups and tasks: a goal never edits the work that serves it, and deleting a group or a task only
            // unlinks it.
            try db.execute(sql: """
            CREATE TABLE goals (
              id TEXT PRIMARY KEY NOT NULL,
              parentId TEXT REFERENCES goals(id) ON DELETE CASCADE,
              text TEXT NOT NULL,
              position INTEGER NOT NULL,
              x DOUBLE, y DOUBLE,
              reachedAt DATETIME,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL
            );
            CREATE INDEX goals_parent ON goals(parentId, position);
            CREATE TABLE goalLinks (
              id TEXT PRIMARY KEY NOT NULL,
              subgoalId TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
              groupId TEXT UNIQUE REFERENCES taskGroups(id) ON DELETE CASCADE,
              taskId TEXT UNIQUE REFERENCES tasks(id) ON DELETE CASCADE,
              createdAt DATETIME NOT NULL,
              CHECK ((groupId IS NULL) != (taskId IS NULL))
            );
            CREATE INDEX goal_links_subgoal ON goalLinks(subgoalId);
            """)
        }
        migrator.registerMigration("goal_lines") { db in
            // Subgoals hold their own lines of work now, rather than whole groups: a task belongs to its workspace and
            // group, and serves a subgoal on its own. Links made the old way are let go.
            try db.execute(sql: """
            DROP TABLE goalLinks;
            CREATE TABLE goalLines (
              id TEXT PRIMARY KEY NOT NULL,
              subgoalId TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
              position INTEGER NOT NULL,
              text TEXT NOT NULL,
              taskId TEXT UNIQUE REFERENCES tasks(id) ON DELETE SET NULL,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL
            );
            CREATE INDEX goal_lines_subgoal ON goalLines(subgoalId, position);
            ALTER TABLE goals ADD COLUMN homeWorkspaceId TEXT;
            ALTER TABLE goals ADD COLUMN homeGroupId TEXT;
            ALTER TABLE goals ADD COLUMN coverStyle TEXT;
            ALTER TABLE goals ADD COLUMN coverPaintedAt DATETIME;
            ALTER TABLE goals ADD COLUMN coverNotes TEXT;
            """)
        }
        migrator.registerMigration("goal_line_places") { db in
            // A planned line knows where it will start, line by line, rather than one place for a whole subgoal.
            try db.execute(sql: """
            ALTER TABLE goalLines ADD COLUMN workspaceId TEXT;
            ALTER TABLE goalLines ADD COLUMN groupId TEXT;
            """)
        }
        migrator.registerMigration("goal_line_plans") { db in
            // A planned line placed in a group shows on that group's card. Changes made on the board come back here
            // through triggers, so every way of editing a plan (the board, undo, a helper) keeps the line in step.
            // A planned row deleted from the board leaves the subgoal too; a started one keeps its task.
            try db.execute(sql: """
            ALTER TABLE goalLines ADD COLUMN planLineId TEXT;
            CREATE UNIQUE INDEX goal_lines_plan ON goalLines(planLineId) WHERE planLineId IS NOT NULL;
            CREATE TRIGGER goal_line_plan_deleted AFTER DELETE ON planLines BEGIN
              DELETE FROM goalLines WHERE planLineId = OLD.id AND taskId IS NULL;
              UPDATE goalLines SET planLineId = NULL WHERE planLineId = OLD.id;
            END;
            CREATE TRIGGER goal_line_plan_text AFTER UPDATE OF text ON planLines WHEN NEW.text != '' BEGIN
              UPDATE goalLines SET text = NEW.text, updatedAt = NEW.updatedAt WHERE planLineId = NEW.id AND text != NEW.text;
            END;
            CREATE TRIGGER goal_line_plan_group AFTER UPDATE OF groupId ON planLines BEGIN
              UPDATE goalLines SET groupId = NEW.groupId, workspaceId = (SELECT workspaceId FROM taskGroups WHERE id = NEW.groupId)
              WHERE planLineId = NEW.id AND groupId IS NOT NEW.groupId;
            END;
            CREATE TRIGGER goal_line_plan_started AFTER UPDATE OF launchedTaskId ON planLines WHEN NEW.launchedTaskId IS NOT NULL BEGIN
              UPDATE goalLines SET taskId = NULL WHERE taskId = NEW.launchedTaskId AND planLineId IS NOT NEW.id;
              UPDATE goalLines SET taskId = NEW.launchedTaskId, updatedAt = NEW.updatedAt WHERE planLineId = NEW.id AND taskId IS NULL;
            END;
            """)
            // Lines already placed in a group join its plan now.
            let placed = try GoalLine.fetchAll(db, sql: """
                SELECT l.* FROM goalLines l JOIN taskGroups g ON g.id = l.groupId
                WHERE l.taskId IS NULL ORDER BY l.subgoalId, l.position
                """)
            for var line in placed { try FaciendaStore.planLine(db, for: &line, now: Date()) }
        }
        migrator.registerMigration("goal_line_work") { db in
            // A line can hold the work toward it: each task's own line points at the line it serves. Removing that line
            // only lets its work go back to the subgoal. A guess the user sent away is kept, so it is not made again.
            try db.execute(sql: """
            ALTER TABLE goalLines ADD COLUMN parentLineId TEXT REFERENCES goalLines(id) ON DELETE SET NULL;
            CREATE INDEX goal_lines_parent ON goalLines(parentLineId) WHERE parentLineId IS NOT NULL;
            CREATE TABLE goalGuessDismissals (
              taskId TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
              targetId TEXT NOT NULL,
              createdAt DATETIME NOT NULL,
              PRIMARY KEY (taskId, targetId)
            );
            """)
        }
        migrator.registerMigration("goal_line_minigoals") { db in
            // A line the user wrote is a minigoal and stays one: the task its planned row starts as, on the board or in
            // Goals, becomes work under it rather than taking its place. The row is used up, so the minigoal lets it go.
            try db.execute(sql: """
            DROP TRIGGER goal_line_plan_started;
            CREATE TRIGGER goal_line_plan_started AFTER UPDATE OF launchedTaskId ON planLines WHEN NEW.launchedTaskId IS NOT NULL BEGIN
              DELETE FROM goalLines WHERE taskId = NEW.launchedTaskId AND planLineId IS NOT NEW.id;
              INSERT INTO goalLines (id, subgoalId, position, text, taskId, createdAt, updatedAt, parentLineId)
                SELECT upper(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-' || hex(randomblob(2)) || '-' || hex(randomblob(2)) || '-' || hex(randomblob(6))),
                       l.subgoalId, (SELECT count(*) FROM goalLines w WHERE w.parentLineId = l.id), l.text, NEW.launchedTaskId, NEW.updatedAt, NEW.updatedAt, l.id
                FROM goalLines l WHERE l.planLineId = NEW.id AND l.taskId IS NULL AND l.parentLineId IS NULL;
              UPDATE goalLines SET planLineId = NULL WHERE planLineId = NEW.id AND taskId IS NULL;
            END;
            """)
        }
        migrator.registerMigration("goal_today") { db in
            // Today's list, beside the map: the minigoals the user picked for the day, and lines that serve no goal,
            // which live only there. Either can be ticked by hand, since not everything on a day's list is done by a task.
            try db.execute(sql: """
            ALTER TABLE goalLines ADD COLUMN pickedAt DATETIME;
            ALTER TABLE goalLines ADD COLUMN tickedAt DATETIME;
            CREATE TABLE todayLines (
              id TEXT PRIMARY KEY NOT NULL,
              text TEXT NOT NULL,
              tickedAt DATETIME,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL
            );
            """)
        }
    }

    public static let goalTextLimit = 300

    // MARK: Goals and subgoals

    /// Every goal and subgoal in the library, goals first, each set in its order.
    public func goals() throws -> [Goal] {
        try db.read { db in try Goal.fetchAll(db, sql: "SELECT * FROM goals ORDER BY parentId IS NOT NULL, position, createdAt") }
    }

    /// Adds a goal, or a subgoal under `parentId`, at the end of its siblings. A subgoal can't hold subgoals of its own.
    @discardableResult public func addGoal(_ text: String, parentId: String? = nil, now: Date = Date()) throws -> Goal {
        let text = try Self.goalText(text)
        return try write { db in
            if let parentId {
                guard let parent = try Goal.fetchOne(db, key: parentId) else { throw StoreError.notFound }
                guard parent.parentId == nil else { throw StoreError.invalid("A subgoal can't hold subgoals.") }
            }
            let position = try Int.fetchOne(db, sql: "SELECT count(*) FROM goals WHERE parentId IS ?", arguments: [parentId]) ?? 0
            let goal = Goal(id: UUID().uuidString, parentId: parentId, text: text, position: position, x: nil, y: nil, reachedAt: nil,
                            homeWorkspaceId: nil, homeGroupId: nil, coverStyle: nil, coverPaintedAt: nil, coverNotes: nil, createdAt: now, updatedAt: now)
            try goal.insert(db)
            return goal
        }
    }

    public func renameGoal(_ id: String, to text: String, now: Date = Date()) throws {
        let text = try Self.goalText(text)
        try write { db in
            guard var goal = try Goal.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard goal.text != text else { return }
            goal.text = text; goal.updatedAt = now
            try goal.update(db)
        }
    }

    /// Where the user put a goal on its island; see `Goal.x`.
    public func placeGoal(_ id: String, x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else { throw StoreError.invalid("That place is off the map.") }
        try write { db in
            guard try Goal.fetchOne(db, key: id) != nil else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE goals SET x = ?, y = ? WHERE id = ?", arguments: [x, y, id])
        }
    }

    /// Moves a subgoal to `index` among its siblings.
    public func moveSubgoal(_ id: String, to index: Int) throws {
        try write { db in
            guard let goal = try Goal.fetchOne(db, key: id), let parent = goal.parentId else { throw StoreError.notFound }
            var siblings = try Goal.fetchAll(db, sql: "SELECT * FROM goals WHERE parentId = ? ORDER BY position, createdAt", arguments: [parent])
            siblings.removeAll { $0.id == id }
            siblings.insert(goal, at: min(max(index, 0), siblings.count))
            for (position, sibling) in siblings.enumerated() {
                try db.execute(sql: "UPDATE goals SET position = ? WHERE id = ?", arguments: [position, sibling.id])
            }
        }
    }

    /// Marks a goal or subgoal reached, or open again with nil. Its lines stay, so the ledger keeps what served it.
    public func setGoalReached(_ id: String, at date: Date?, now: Date = Date()) throws {
        try write { db in
            guard var goal = try Goal.fetchOne(db, key: id) else { throw StoreError.notFound }
            goal.reachedAt = date; goal.updatedAt = now
            try goal.update(db)
        }
    }

    /// Deletes a goal with its subgoals, or one subgoal, with their lines. The tasks they started stay where they are.
    public func deleteGoal(_ id: String) throws {
        try write { db in
            guard try Goal.deleteOne(db, key: id) else { throw StoreError.notFound }
            let all = try Goal.fetchAll(db, sql: "SELECT * FROM goals ORDER BY position, createdAt")
            for siblings in Dictionary(grouping: all, by: \.parentId).values {
                for (index, goal) in siblings.enumerated() where goal.position != index {
                    try db.execute(sql: "UPDATE goals SET position = ? WHERE id = ?", arguments: [index, goal.id])
                }
            }
        }
        try? FileManager.default.removeItem(at: coverURL(goalId: id))
        try? FileManager.default.removeItem(at: previousCoverURL(goalId: id))
    }

    // MARK: Lines

    /// Every subgoal's lines, in order, with the tasks they became, each line followed by the work it holds. Lines whose
    /// task was let go read as planned again; work whose task was let go is no longer shown.
    public func goalItems() throws -> [GoalItem] {
        try db.read { db in
            let lines = try GoalLine.fetchAll(db, sql: "SELECT * FROM goalLines ORDER BY subgoalId, position, createdAt")
            let ids = lines.compactMap(\.taskId)
            guard !ids.isEmpty else { return lines.filter { $0.parentLineId == nil }.map { GoalItem(line: $0, task: nil, groupName: nil, mark: TaskReadMark()) } }
            let marks = ", ".join(repeating: "?", count: ids.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.*, g.name AS memberGroupName FROM tasks t
                LEFT JOIN taskGroupMembers m ON m.taskId = t.id LEFT JOIN taskGroups g ON g.id = m.groupId
                WHERE t.id IN (\(marks))
                """, arguments: StatementArguments(ids))
            var found: [String: (FaciendaTask, String?, TaskReadMark)] = [:]
            for row in rows {
                let task = try FaciendaTask(row: row)
                found[task.id] = (task, row["memberGroupName"], TaskReadMark(finishedAt: row["finishedAt"], seenAt: row["seenAt"]))
            }
            let items = lines.map { line in
                guard let id = line.taskId, let (task, group, mark) = found[id], task.state != .dropped else {
                    return GoalItem(line: line, task: nil, groupName: nil, mark: TaskReadMark())
                }
                return GoalItem(line: line, task: task, groupName: group, mark: mark)
            }
            let work = Dictionary(grouping: items.filter { $0.line.parentLineId != nil && $0.task != nil }, by: { $0.line.parentLineId ?? "" })
            return items.filter { $0.line.parentLineId == nil }.flatMap { [$0] + (work[$0.id] ?? []) }
        }
    }

    public func goalLine(_ id: String) throws -> GoalLine? { try db.read { try GoalLine.fetchOne($0, key: id) } }

    /// Adds a planned line to a subgoal, right after `afterId` or at the end.
    @discardableResult public func addGoalLine(_ text: String, to subgoalId: String, after afterId: String? = nil, now: Date = Date()) throws -> GoalLine {
        let text = try Self.lineText(text)
        return try write { db in
            try Self.requireSubgoal(db, subgoalId)
            return try Self.insertLine(db, GoalLine(id: UUID().uuidString, subgoalId: subgoalId, position: 0, text: text, taskId: nil, createdAt: now, updatedAt: now), after: afterId)
        }
    }

    public func setGoalLineText(_ id: String, text: String, now: Date = Date()) throws {
        let text = try Self.lineText(text)
        try write { db in
            guard var line = try GoalLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard line.text != text else { return }
            line.text = text; line.updatedAt = now
            try line.update(db)
            if let plan = line.planLineId {
                try db.execute(sql: "UPDATE planLines SET text = ?, updatedAt = ? WHERE id = ?", arguments: [String(text.prefix(Self.planLineLimit)), now, plan])
            }
        }
    }

    /// Removes a line. A task it started stays where it is and no longer serves the subgoal. Work the line held stays
    /// with the subgoal, as lines of its own.
    public func deleteGoalLine(_ id: String) throws {
        try write { db in
            guard let line = try GoalLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            try Self.removeLine(db, line)
            // Its planned row goes from the group's card with it; a row already started stays with its task.
            if let id = line.planLineId, let plan = try PlanLine.fetchOne(db, key: id), plan.launchedTaskId == nil { try Self.dropPlanLine(db, plan) }
        }
    }

    /// Moves a line to `index` in a subgoal, its own or another. The work it holds goes with it; work under a line has
    /// no place of its own to move to.
    public func moveGoalLine(_ id: String, to subgoalId: String, at index: Int, now: Date = Date()) throws {
        try write { db in
            guard var line = try GoalLine.fetchOne(db, key: id), line.parentLineId == nil else { throw StoreError.notFound }
            try Self.requireSubgoal(db, subgoalId)
            let from = line.subgoalId
            line.subgoalId = subgoalId; line.updatedAt = now
            try line.update(db)
            try db.execute(sql: "UPDATE goalLines SET subgoalId = ? WHERE parentLineId = ?", arguments: [subgoalId, id])
            var siblings = try GoalLine.fetchAll(db, sql: """
                SELECT * FROM goalLines WHERE subgoalId = ? AND id != ? AND parentLineId IS NULL ORDER BY position, createdAt
                """, arguments: [subgoalId, id])
            siblings.insert(line, at: min(max(index, 0), siblings.count))
            for (position, sibling) in siblings.enumerated() { try db.execute(sql: "UPDATE goalLines SET position = ? WHERE id = ?", arguments: [position, sibling.id]) }
            if from != subgoalId { try Self.renumberLines(db, subgoalId: from) }
        }
    }

    /// Where a planned line will start. Nil clears it, so it is suggested a place again.
    public func setGoalLinePlace(_ id: String, workspaceId: String?, groupId: String?, now: Date = Date()) throws {
        try write { db in
            guard var line = try GoalLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            if let workspaceId {
                _ = try Self.workspace(db, workspaceId)
                if let groupId, try String.fetchOne(db, sql: "SELECT workspaceId FROM taskGroups WHERE id = ?", arguments: [groupId]) != workspaceId { throw StoreError.notFound }
            }
            line.workspaceId = workspaceId; line.groupId = workspaceId == nil ? nil : groupId; line.updatedAt = now
            try line.update(db)
            try Self.planLine(db, for: &line, now: now)
        }
    }

    /// Where a planned line might start, best first: places its subgoal's other lines went, then groups whose work
    /// shares its words. A suggestion only; nothing starts anywhere until the user says so.
    public func suggestedPlaces(for lineId: String, limit: Int = 3) throws -> [BarPlace] {
        guard let line = try db.read({ try GoalLine.fetchOne($0, key: lineId) }) else { throw StoreError.notFound }
        let places = try barPlaces(matching: line.text, examples: 0)
        // Where the subgoal's other work lives, from what was started and what was placed.
        let siblings = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT coalesce(t.workspaceId, l.workspaceId) AS workspace, CASE WHEN l.taskId IS NULL THEN l.groupId ELSE m.groupId END AS grp
                FROM goalLines l LEFT JOIN tasks t ON t.id = l.taskId LEFT JOIN taskGroupMembers m ON m.taskId = l.taskId
                WHERE l.subgoalId = ? AND l.id != ?
                """, arguments: [line.subgoalId, lineId])
        }
        var near: [String: Int] = [:]
        for row in siblings { if let workspace: String = row["workspace"] { near[workspace + "|" + ((row["grp"] as String?) ?? ""), default: 0] += 1 } }
        let scored = places.map { place -> (BarPlace, Int) in
            (place, near[place.workspaceID + "|" + (place.groupID ?? ""), default: 0] * 3 + place.matches.count * 2)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The line now shows the task it was started as.
    public func linkGoalLine(_ id: String, taskId: String, now: Date = Date()) throws {
        try write { db in
            guard var line = try GoalLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard try FaciendaTask.fetchOne(db, key: taskId) != nil else { throw StoreError.notFound }
            // The task is this line now, not work under another.
            try db.execute(sql: "DELETE FROM goalLines WHERE taskId = ? AND parentLineId IS NOT NULL", arguments: [taskId])
            try db.execute(sql: "UPDATE goalLines SET taskId = NULL WHERE taskId = ?", arguments: [taskId])
            line.taskId = taskId; line.updatedAt = now
            try line.update(db)
            // Started some other way than from its planned row, the row now shows the same task.
            if let plan = line.planLineId { try db.execute(sql: "UPDATE planLines SET launchedTaskId = ?, updatedAt = ? WHERE id = ? AND launchedTaskId IS NULL", arguments: [taskId, now, plan]) }
        }
    }

    /// Lets a task made elsewhere serve a subgoal: it gets a line there, in place of any it had in another. Nil lets it
    /// serve none.
    public func serve(taskId: String, subgoalId: String?, now: Date = Date()) throws {
        try write { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId) else { throw StoreError.notFound }
            if let workspaceID, task.workspaceId != workspaceID { throw StoreError.notFound }
            if let old = try GoalLine.fetchOne(db, sql: "SELECT * FROM goalLines WHERE taskId = ?", arguments: [taskId]) {
                // Work under a line of the same subgoal comes out from under it, to a line of its own.
                if old.subgoalId == subgoalId, old.parentLineId == nil { return }
                try Self.removeLine(db, old)
            }
            guard let subgoalId else { return }
            try Self.requireSubgoal(db, subgoalId)
            _ = try Self.insertLine(db, GoalLine(id: UUID().uuidString, subgoalId: subgoalId, position: 0, text: String(task.displayName.prefix(Self.planLineLimit)),
                                                 taskId: taskId, createdAt: now, updatedAt: now), after: nil)
        }
    }

    /// Lets a task serve a subgoal as work toward one of its lines. The line stays as the user wrote it and holds the
    /// task, beside any others it holds, in place of any line the task had.
    public func serve(taskId: String, lineId: String, now: Date = Date()) throws {
        try write { db in
            guard let task = try FaciendaTask.fetchOne(db, key: taskId), let line = try GoalLine.fetchOne(db, key: lineId) else { throw StoreError.notFound }
            if let workspaceID, task.workspaceId != workspaceID { throw StoreError.notFound }
            // Work sits one level under a line, never under other work, and a line can't hold the task it became.
            guard line.parentLineId == nil, line.taskId != taskId else { throw StoreError.invalid("That line can't hold this task.") }
            if let old = try GoalLine.fetchOne(db, sql: "SELECT * FROM goalLines WHERE taskId = ?", arguments: [taskId]) {
                if old.parentLineId == lineId { return }
                try Self.removeLine(db, old)
            }
            let position = try Int.fetchOne(db, sql: "SELECT coalesce(max(position), -1) + 1 FROM goalLines WHERE parentLineId = ?", arguments: [lineId]) ?? 0
            try GoalLine(id: UUID().uuidString, subgoalId: line.subgoalId, position: position, text: String(task.displayName.prefix(Self.planLineLimit)),
                         taskId: taskId, createdAt: now, updatedAt: now, parentLineId: lineId).insert(db)
        }
    }

    /// The subgoal a task serves, if any.
    public func servedSubgoal(taskId: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT subgoalId FROM goalLines WHERE taskId = ?", arguments: [taskId]) }
    }

    /// The line a task works toward, if it serves its subgoal under one.
    public func servedLine(taskId: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT parentLineId FROM goalLines WHERE taskId = ?", arguments: [taskId]) }
    }

    // MARK: Today

    /// Puts a line the user wrote on today's list, or takes it off. Work under a line is on the board already, so it
    /// is never picked by itself. Picking is no change to the line: it does not count as the subgoal moving.
    public func setGoalLinePicked(_ id: String, _ picked: Bool, now: Date = Date()) throws {
        try write { db in
            guard var line = try GoalLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard line.parentLineId == nil else { throw StoreError.invalid("Only a minigoal can be picked for today.") }
            guard (line.pickedAt != nil) != picked else { return }
            line.pickedAt = picked ? now : nil
            try line.update(db)
        }
    }

    /// Ticks a line the user wrote by hand, or unticks it. The work it holds stays as it is.
    public func setGoalLineTicked(_ id: String, _ ticked: Bool, now: Date = Date()) throws {
        try write { db in
            guard var line = try GoalLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard line.parentLineId == nil else { throw StoreError.invalid("Only a minigoal can be ticked.") }
            guard (line.tickedAt != nil) != ticked else { return }
            line.tickedAt = ticked ? now : nil; line.updatedAt = now
            try line.update(db)
        }
    }

    /// The lines on today's list that serve no goal, in the order they were written.
    public func todayLines() throws -> [TodayLine] {
        try db.read { db in try TodayLine.fetchAll(db, sql: "SELECT * FROM todayLines ORDER BY createdAt, rowid") }
    }

    /// Writes a line that serves no goal onto today's list.
    @discardableResult public func addTodayLine(_ text: String, now: Date = Date()) throws -> TodayLine {
        let text = try Self.lineText(text)
        return try write { db in
            let line = TodayLine(id: UUID().uuidString, text: text, tickedAt: nil, createdAt: now, updatedAt: now)
            try line.insert(db)
            return line
        }
    }

    public func setTodayLineTicked(_ id: String, _ ticked: Bool, now: Date = Date()) throws {
        try write { db in
            guard var line = try TodayLine.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard (line.tickedAt != nil) != ticked else { return }
            line.tickedAt = ticked ? now : nil; line.updatedAt = now
            try line.update(db)
        }
    }

    /// Takes a line with no goal off today's list. It lives nowhere else, so it is gone.
    public func deleteTodayLine(_ id: String) throws {
        try write { db in guard try TodayLine.deleteOne(db, key: id) else { throw StoreError.notFound } }
    }

    /// The morning after: what was picked and done before `day` began leaves today's list. A minigoal stays on the map,
    /// done; a line with no goal is gone. What is still open stays, however long it has been there.
    public func clearToday(before day: Date) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM todayLines WHERE tickedAt < ?", arguments: [day])
            try db.execute(sql: "UPDATE goalLines SET pickedAt = NULL WHERE pickedAt < ? AND tickedAt < ?", arguments: [day, day])
            // Done by its work rather than by hand: it holds work, and the last of it was finished before the day began.
            try db.execute(sql: """
                UPDATE goalLines SET pickedAt = NULL WHERE pickedAt < ? AND tickedAt IS NULL
                AND EXISTS (SELECT 1 FROM goalLines w JOIN tasks t ON t.id = w.taskId WHERE w.parentLineId = goalLines.id AND t.state = 'done')
                AND NOT EXISTS (SELECT 1 FROM goalLines w JOIN tasks t ON t.id = w.taskId WHERE w.parentLineId = goalLines.id
                                AND t.state != 'dropped' AND (t.state != 'done' OR t.updatedAt >= ?))
                """, arguments: [day, day])
        }
    }

    // MARK: Guesses

    /// How long finished work stays worth guessing a goal for.
    static let guessWindow: TimeInterval = 30 * 86400

    /// Guesses which open subgoal, and which of its lines, the board's work is for. It looks at tasks on no goal yet,
    /// still open or finished in the last weeks, and at lines still as the user wrote them. A task is guessed for one
    /// place at most, a line before a subgoal, and each place shows its few best. Nothing here links anything.
    public func goalGuesses(now: Date = Date(), perTarget: Int = 3) throws -> [GoalGuess] {
        try db.read { db in
            let goals = try Goal.fetchAll(db, sql: "SELECT * FROM goals ORDER BY position, createdAt")
            let reached = Set(goals.filter { $0.reachedAt != nil }.map(\.id))
            let subgoals = goals.filter { sub in sub.parentId.map { !reached.contains($0) && !reached.contains(sub.id) } ?? false }
            guard !subgoals.isEmpty else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.*, g.name AS memberGroupName, m.groupId AS memberGroupId FROM tasks t
                LEFT JOIN taskGroupMembers m ON m.taskId = t.id LEFT JOIN taskGroups g ON g.id = m.groupId
                WHERE t.state != 'dropped' AND (t.state != 'done' OR t.updatedAt >= ?)
                AND NOT EXISTS (SELECT 1 FROM goalLines l WHERE l.taskId = t.id)
                AND (t.workspaceId IS NULL OR EXISTS (SELECT 1 FROM workspaces w WHERE w.id = t.workspaceId AND w.removedAt IS NULL))
                ORDER BY t.updatedAt DESC LIMIT 400
                """, arguments: [now.addingTimeInterval(-Self.guessWindow)])
            guard !rows.isEmpty else { return [] }
            let work = try rows.map { row -> (task: FaciendaTask, groupName: String?, groupId: String?, words: GoalMatch.Words) in
                let task = try FaciendaTask(row: row)
                return (task, row["memberGroupName"], row["memberGroupId"], GoalMatch.Words(task.displayName + " " + String(task.title.prefix(800))))
            }
            // A word much of the board's work uses says nothing about which goal a task is for.
            var uses: [String: Int] = [:]
            for item in work { for word in item.words.all { uses[word, default: 0] += 1 } }
            let common = work.count < 8 ? [] : Set(uses.filter { $0.value * 4 > work.count }.keys)
            func terms(_ text: String) -> [String] { TaskLookup.terms(text).filter { !common.contains($0) } }

            let ids = subgoals.map(\.id), marks = ", ".join(repeating: "?", count: ids.count)
            // Where each subgoal's work lives already, from what was started and what was placed.
            var homes: [String: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT l.subgoalId, CASE WHEN l.taskId IS NULL THEN l.groupId ELSE m.groupId END AS grp
                FROM goalLines l LEFT JOIN taskGroupMembers m ON m.taskId = l.taskId WHERE l.subgoalId IN (\(marks))
                """, arguments: StatementArguments(ids)) {
                let sub: String = row["subgoalId"]
                if let group: String = row["grp"] { homes[sub, default: []].insert(group) }
            }
            // Lines still as written are what work can be for. A line that became a task is that task.
            let lines = try GoalLine.fetchAll(db, sql: """
                SELECT l.* FROM goalLines l LEFT JOIN tasks t ON t.id = l.taskId
                WHERE l.subgoalId IN (\(marks)) AND l.parentLineId IS NULL AND (t.id IS NULL OR t.state = 'dropped')
                ORDER BY l.subgoalId, l.position
                """, arguments: StatementArguments(ids)).map { (line: $0, terms: terms($0.text)) }
            let subs = subgoals.map { (sub: $0, terms: terms($0.text)) }
            let dismissed = Set(try Row.fetchAll(db, sql: "SELECT taskId, targetId FROM goalGuessDismissals").map { ($0["taskId"] as String) + "|" + ($0["targetId"] as String) })

            var found: [String: [(guess: GoalGuess, fit: Double)]] = [:]
            for item in work {
                func open(_ target: String) -> Bool { !dismissed.contains(item.task.id + "|" + target) }
                // A task lives near a line when it is in the group the line starts in, or, for a line with no group
                // yet, in one the subgoal's other work is in.
                let bestLine = lines.filter { open($0.line.id) }.compactMap { entry -> (line: GoalLine, fit: Double)? in
                    let near = item.groupId.map { entry.line.groupId == $0 || (entry.line.groupId == nil && homes[entry.line.subgoalId]?.contains($0) == true) } ?? false
                    return GoalMatch.fit(of: entry.terms, in: item.words, near: near).map { (entry.line, $0) }
                }.max { $0.fit < $1.fit }
                if let bestLine {
                    found[bestLine.line.id, default: []].append((GoalGuess(task: item.task, groupName: item.groupName, groupId: item.groupId, subgoalId: bestLine.line.subgoalId, lineId: bestLine.line.id), bestLine.fit))
                    continue
                }
                let bestSub = subs.filter { open($0.sub.id) }.compactMap { entry -> (sub: Goal, fit: Double)? in
                    let near = item.groupId.map { homes[entry.sub.id]?.contains($0) == true } ?? false
                    return GoalMatch.fit(of: entry.terms, in: item.words, near: near).map { (entry.sub, $0) }
                }.max { $0.fit < $1.fit }
                if let bestSub {
                    found[bestSub.sub.id, default: []].append((GoalGuess(task: item.task, groupName: item.groupName, groupId: item.groupId, subgoalId: bestSub.sub.id, lineId: nil), bestSub.fit))
                }
            }
            // Each place shows its best fits, the newest first among equals.
            return found.values.flatMap { $0.sorted { ($0.fit, $0.guess.task.updatedAt) > ($1.fit, $1.guess.task.updatedAt) }.prefix(perTarget).map(\.guess) }
                .sorted { ($0.task.updatedAt, $0.task.id) > ($1.task.updatedAt, $1.task.id) }
        }
    }

    /// The user said a guessed task is not for that line or subgoal. It is not offered there again.
    public func dismissGoalGuess(taskId: String, targetId: String, now: Date = Date()) throws {
        try write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO goalGuessDismissals (taskId, targetId, createdAt) VALUES (?, ?, ?)", arguments: [taskId, targetId, now])
        }
    }

    // MARK: Pictures

    /// A goal's picture sits with the group covers, so it travels with the library.
    public func coverURL(goalId: String) -> URL { coversDirectory.appending(path: "goal-" + goalId + ".jpg") }
    public func previousCoverURL(goalId: String) -> URL { coversDirectory.appending(path: "goal-" + goalId + ".previous.jpg") }

    /// Replaces the picture, keeping the old one for undo. A note is a wish the new picture already honours.
    public func saveCover(goalId: String, image: Data, style: String, note: String? = nil) throws {
        guard let goal = try db.read({ try Goal.fetchOne($0, key: goalId) }) else { throw StoreError.notFound }
        try Self.replaceCover(coverURL(goalId: goalId), previous: previousCoverURL(goalId: goalId), with: image)
        try write { db in
            try db.execute(sql: "UPDATE goals SET coverStyle = ?, coverPaintedAt = ?, coverNotes = ? WHERE id = ?",
                           arguments: [style, Date(), Self.notes(goal.coverNoteList, adding: note), goalId])
        }
    }

    // MARK: Helpers

    private static func insertLine(_ db: Database, _ line: GoalLine, after afterId: String?) throws -> GoalLine {
        var siblings = try GoalLine.fetchAll(db, sql: "SELECT * FROM goalLines WHERE subgoalId = ? AND parentLineId IS NULL ORDER BY position, createdAt", arguments: [line.subgoalId])
        let index = afterId.flatMap { id in siblings.firstIndex { $0.id == id }.map { $0 + 1 } } ?? siblings.count
        var line = line
        line.position = index
        siblings.insert(line, at: index)
        try line.insert(db)
        for (position, sibling) in siblings.enumerated() where sibling.position != position || sibling.id == line.id {
            try db.execute(sql: "UPDATE goalLines SET position = ? WHERE id = ?", arguments: [position, sibling.id])
        }
        return line
    }

    /// Keeps a planned line's row in its group's plan: added at the end of the group's plan when a group is chosen, moved
    /// with the line, and taken away when the line has no group. A started line is left alone.
    static func planLine(_ db: Database, for line: inout GoalLine, now: Date) throws {
        guard line.taskId == nil else { return }
        let existing = try line.planLineId.flatMap { try PlanLine.fetchOne(db, key: $0) }
        if let existing, existing.groupId == line.groupId { return }
        if let existing {
            // Let go first, so the row leaving the board doesn't take the line with it.
            line.planLineId = nil
            try line.update(db)
            if existing.launchedTaskId == nil { try dropPlanLine(db, existing) }
        }
        guard let group = line.groupId, try TaskGroup.fetchOne(db, key: group) != nil else {
            if line.planLineId != nil { line.planLineId = nil; try line.update(db) }
            return
        }
        let siblings = try siblings(db, groupId: group, parentId: nil)
        let plan = PlanLine(id: UUID().uuidString, groupId: group, parentId: nil, position: siblings.count,
                            text: String(line.text.prefix(planLineLimit)), launchedTaskId: nil, createdAt: now, updatedAt: now)
        try plan.insert(db)
        line.planLineId = plan.id
        try line.update(db)
    }

    private static func dropPlanLine(_ db: Database, _ plan: PlanLine) throws {
        try plan.delete(db)
        try renumber(db, siblings(db, groupId: plan.groupId, parentId: plan.parentId))
    }

    /// Takes a line out and closes the gap. Work it held takes its place in the subgoal, as lines of its own.
    private static func removeLine(_ db: Database, _ line: GoalLine) throws {
        if line.parentLineId == nil {
            try db.execute(sql: "UPDATE goalLines SET parentLineId = NULL, position = ? WHERE parentLineId = ?", arguments: [line.position, line.id])
        }
        try line.delete(db)
        try renumberLines(db, subgoalId: line.subgoalId)
    }

    /// The subgoal's own lines, numbered again. Work under a line keeps its order there.
    private static func renumberLines(_ db: Database, subgoalId: String) throws {
        let lines = try GoalLine.fetchAll(db, sql: "SELECT * FROM goalLines WHERE subgoalId = ? AND parentLineId IS NULL ORDER BY position, createdAt", arguments: [subgoalId])
        for (index, line) in lines.enumerated() where line.position != index {
            try db.execute(sql: "UPDATE goalLines SET position = ? WHERE id = ?", arguments: [index, line.id])
        }
    }

    private static func requireSubgoal(_ db: Database, _ id: String) throws {
        guard let goal = try Goal.fetchOne(db, key: id) else { throw StoreError.notFound }
        guard goal.parentId != nil else { throw StoreError.invalid("Work serves a subgoal, not a whole goal.") }
    }

    private static func goalText(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError.invalid("Give it a name first.") }
        guard text.count <= goalTextLimit else { throw StoreError.invalid("Keep it under \(goalTextLimit) characters.") }
        return text
    }

    private static func lineText(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError.invalid("Write what you want done first.") }
        guard text.count <= planLineLimit else { throw StoreError.invalid("Keep a line under \(planLineLimit) characters.") }
        return text
    }
}

private extension String {
    func join(repeating item: String, count: Int) -> String { Array(repeating: item, count: count).joined(separator: self) }
}

/// How a task's words are held against a line's, for guessing which goal board work is for. Plain word matching, so a
/// guess can always be explained by the words both share.
enum GoalMatch {
    /// A task's words, found by their first letters so "upload" meets "uploads" without comparing every pair.
    struct Words: Sendable {
        let all: Set<String>
        private let starts: [Substring: [String]]

        init(_ text: String) {
            let terms = TaskLookup.terms(text)
            all = Set(terms)
            starts = Dictionary(grouping: terms.filter { $0.count >= 4 }, by: { $0.prefix(4) })
        }

        /// The same word, or one that begins with the other.
        func has(_ word: String) -> Bool {
            if all.contains(word) { return true }
            guard word.count >= 4 else { return false }
            return starts[word.prefix(4)]?.contains { $0.hasPrefix(word) || word.hasPrefix($0) } ?? false
        }
    }

    /// How much of a line a task covers, from 0 to 1 and a little more when the task already lives where the line's
    /// work does. Nil when too little is shared to guess from: two words covering half the line are enough, one word
    /// only when it is all the line says or the task lives there already.
    static func fit(of line: [String], in task: Words, near: Bool) -> Double? {
        let met = line.filter(task.has)
        guard let first = met.first else { return nil }
        let share = Double(met.count) / Double(line.count)
        guard met.count >= 2 ? share >= 0.5 : (line.count == 1 || near) && first.count >= 4 else { return nil }
        return share + (near ? 0.25 : 0)
    }
}
