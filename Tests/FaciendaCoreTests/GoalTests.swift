import Foundation
import GRDB
import Testing
@testable import FaciendaCore

private func store() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/goals.sqlite"))
}

@Test func goalsHoldTwoLevelsAndKeepTheirPlaces() throws {
    let db = try store()
    let studio = try db.addGoal("  Open the studio to visitors ")
    let room = try db.addGoal("Finish the sound room", parentId: studio.id)
    let booking = try db.addGoal("A booking page", parentId: studio.id)
    #expect(studio.text == "Open the studio to visitors")
    #expect(booking.position == 1)
    // A subgoal can't hold subgoals of its own, and a name is needed.
    #expect(throws: StoreError.self) { try db.addGoal("Panels", parentId: room.id) }
    #expect(throws: StoreError.self) { try db.addGoal("   ") }

    try db.placeGoal(studio.id, x: 0.3, y: 0.4)
    try db.renameGoal(booking.id, to: "A booking page that works")
    try db.moveSubgoal(booking.id, to: 0)
    let goals = try db.goals()
    #expect(goals.map(\.text) == ["Open the studio to visitors", "A booking page that works", "Finish the sound room"])
    #expect(goals.first { $0.id == studio.id }?.x == 0.3)

    try db.deleteGoal(booking.id)
    #expect(try db.goals().first { $0.id == room.id }?.position == 0)
    // Deleting a goal takes its subgoals with it.
    try db.deleteGoal(studio.id)
    #expect(try db.goals().isEmpty)
}

@Test func subgoalsHoldLinesThatBecomeTasks() throws {
    let db = try store()
    let goal = try db.addGoal("Ship the field recorder")
    let sync = try db.addGoal("Offline sync", parentId: goal.id), listing = try db.addGoal("Store listing", parentId: goal.id)
    // Lines belong to subgoals, never to a goal itself.
    #expect(throws: StoreError.self) { try db.addGoalLine("Pick a name", to: goal.id) }

    let retry = try db.addGoalLine("Retry queue for uploads", to: sync.id)
    let conflict = try db.addGoalLine("Conflict test on two phones", to: sync.id)
    let first = try db.addGoalLine("Read the sync paper", to: sync.id, after: nil)
    _ = try db.addGoalLine("Sketch the retry states", to: sync.id, after: retry.id)
    #expect(try db.goalItems().filter { $0.line.subgoalId == sync.id }.map(\.line.text)
            == ["Retry queue for uploads", "Sketch the retry states", "Conflict test on two phones", "Read the sync paper"])

    // Started, a line shows its task; the task lives in a group of its own workspace.
    let group = try db.createGroup(name: "Sync engine")
    let task = try db.create(FaciendaTask(title: "Retry queue for uploads", state: .running))
    try db.assignGroup(taskId: task.id, groupId: group.id)
    try db.linkGoalLine(retry.id, taskId: task.id)
    let item = try #require(try db.goalItems().first { $0.line.id == retry.id })
    #expect(item.task?.id == task.id)
    #expect(item.groupName == "Sync engine")
    #expect(try db.servedSubgoal(taskId: task.id) == sync.id)

    // A task made elsewhere serves a subgoal through a line of its own, and moves rather than serving two.
    let crash = try db.create(FaciendaTask(title: "Fix the export crash", state: .done))
    try db.serve(taskId: crash.id, subgoalId: listing.id)
    #expect(try db.servedSubgoal(taskId: crash.id) == listing.id)
    try db.serve(taskId: crash.id, subgoalId: sync.id)
    #expect(try db.goalItems().filter { $0.task?.id == crash.id }.map(\.line.subgoalId) == [sync.id])
    try db.serve(taskId: crash.id, subgoalId: nil)
    #expect(try db.servedSubgoal(taskId: crash.id) == nil)

    // Lines move within a subgoal and across.
    try db.moveGoalLine(conflict.id, to: listing.id, at: 0)
    #expect(try db.goalItems().filter { $0.line.subgoalId == listing.id }.map(\.line.text) == ["Conflict test on two phones"])
    try db.moveGoalLine(first.id, to: sync.id, at: 0)
    #expect(try db.goalItems().filter { $0.line.subgoalId == sync.id }.map(\.line.position) == [0, 1, 2])

    // Reaching keeps the lines, so the ledger can still count what served it.
    let reached = Date(timeIntervalSince1970: 1_800_000_000)
    try db.setGoalReached(sync.id, at: reached)
    #expect(try db.goals().first { $0.id == sync.id }?.reachedAt == reached)
    #expect(try db.goalItems().contains { $0.task?.id == task.id })

    // Deleting a line or a subgoal leaves the work alone.
    try db.deleteGoalLine(first.id)
    try db.deleteGoal(sync.id)
    #expect(try db.goalItems().allSatisfy { $0.line.subgoalId == listing.id })
    #expect(try db.tasks().count == 2)
}

@Test func plannedLinesGetAPlaceAndSuggestions() throws {
    let db = try store()
    let personal = try db.defaultWorkspace()
    let office = try db.createGroup(name: "Home office"), garden = try db.createGroup(name: "Garden")
    let desk = try db.create(FaciendaTask(title: "Compare oak desk prices", state: .done))
    try db.assignGroup(taskId: desk.id, groupId: office.id)
    let goal = try db.addGoal("A calmer home"), room = try db.addGoal("A quieter office", parentId: goal.id)
    let lamp = try db.addGoalLine("Find a desk lamp", to: room.id)
    // With nothing to go on yet, words that match work in a group point there.
    #expect(try db.suggestedPlaces(for: lamp.id).first?.groupID == office.id)

    // Where the subgoal's other lines went counts more than matching words.
    let rug = try db.addGoalLine("A rug", to: room.id)
    try db.setGoalLinePlace(lamp.id, workspaceId: personal.id, groupId: garden.id)
    #expect(try db.suggestedPlaces(for: rug.id).first?.groupID == garden.id)
    #expect(try db.goalItems().first { $0.line.id == lamp.id }?.line.groupId == garden.id)

    // A group from another workspace is refused, and clearing the workspace clears the group.
    let other = try db.createWorkspace(name: "Studio")
    #expect(throws: StoreError.self) { try db.setGoalLinePlace(rug.id, workspaceId: other.id, groupId: office.id) }
    try db.setGoalLinePlace(lamp.id, workspaceId: nil, groupId: garden.id)
    #expect(try db.goalItems().first { $0.line.id == lamp.id }?.line.groupId == nil)
}

@Test func plannedLinesInAGroupShowOnItsCard() throws {
    let db = try store()
    let personal = try db.defaultWorkspace()
    let office = try db.createGroup(name: "Home office"), garden = try db.createGroup(name: "Garden")
    let goal = try db.addGoal("A calmer home"), room = try db.addGoal("A quieter office", parentId: goal.id)
    let lamp = try db.addGoalLine("Find a desk lamp", to: room.id)
    let rug = try db.addGoalLine("A rug", to: room.id)
    func line(_ id: String) throws -> GoalLine { try #require(try db.goalLine(id)) }
    func plan(_ id: String) throws -> PlanLine? { try db.planLines().first { $0.id == (try line(id)).planLineId } }

    // A group chosen, the line is a planned row on that group's card.
    try db.setGoalLinePlace(lamp.id, workspaceId: personal.id, groupId: office.id)
    #expect(try plan(lamp.id)?.groupId == office.id)
    #expect(try plan(lamp.id)?.text == "Find a desk lamp")

    // Edits go both ways, and so does a move to another group.
    try db.setGoalLineText(lamp.id, text: "Find a warm desk lamp")
    #expect(try plan(lamp.id)?.text == "Find a warm desk lamp")
    let row = try #require(try plan(lamp.id))
    try db.setPlanText(row.id, text: "Find a dimmable lamp")
    #expect(try line(lamp.id).text == "Find a dimmable lamp")
    try db.placePlanLine(row.id, groupId: garden.id, parentId: nil, before: nil)
    #expect(try line(lamp.id).groupId == garden.id)
    try db.setGoalLinePlace(lamp.id, workspaceId: personal.id, groupId: office.id)
    #expect(try db.planLines().filter { $0.groupId == garden.id }.isEmpty)
    #expect(try plan(lamp.id)?.groupId == office.id)

    // Started from the board, the line stays as written and holds the task. Its row is used up, so it lets it go.
    let task = try db.create(FaciendaTask(title: "Find a dimmable lamp", state: .running))
    let started = try #require(try plan(lamp.id)).id
    try db.linkPlanLine(started, taskId: task.id)
    #expect(try line(lamp.id).taskId == nil)
    #expect(try line(lamp.id).planLineId == nil)
    #expect(try db.servedLine(taskId: task.id) == lamp.id)
    #expect(try db.goalItems().first { $0.task?.id == task.id }?.line.parentLineId == lamp.id)
    #expect(try db.planLines().first { $0.id == started }?.launchedTaskId == task.id)

    // A planned row deleted from the board leaves the subgoal too; clearing the place takes the row away.
    try db.setGoalLinePlace(rug.id, workspaceId: personal.id, groupId: garden.id)
    try db.deletePlanLine(try #require(try plan(rug.id)).id)
    #expect(try db.goalLine(rug.id) == nil)
    let shelf = try db.addGoalLine("A bookshelf", to: room.id)
    try db.setGoalLinePlace(shelf.id, workspaceId: personal.id, groupId: garden.id)
    try db.setGoalLinePlace(shelf.id, workspaceId: nil, groupId: nil)
    #expect(try db.planLines().filter { $0.groupId == garden.id }.isEmpty)
    // Deleting a line takes its planned row; a started row stays with its task.
    try db.setGoalLinePlace(shelf.id, workspaceId: personal.id, groupId: garden.id)
    try db.deleteGoalLine(shelf.id)
    #expect(try db.planLines().filter { $0.groupId == garden.id }.isEmpty)
    try db.deleteGoalLine(lamp.id)
    #expect(try db.planLines().contains { $0.launchedTaskId == task.id })
}

@Test func linesPlacedBeforePlansJoinTheirGroupsPlan() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "FaciendaTests/\(UUID().uuidString)/goals.sqlite")
    let early = try FaciendaStore(url: url, migrate: false)
    try FaciendaStore.migrator.migrate(early.db, upTo: "goal_line_places")
    // Written as SQL, since a group saved as today's record would carry columns this older library lacks.
    let office = "office"
    try early.db.write { db in
        try db.execute(sql: "INSERT INTO taskGroups (id, name, position, createdAt) VALUES (?, 'Home office', 0, ?)", arguments: [office, Date()])
    }
    let goal = try early.addGoal("A calmer home"), room = try early.addGoal("A quieter office", parentId: goal.id)
    try early.db.write { db in
        try db.execute(sql: """
            INSERT INTO goalLines (id, subgoalId, position, text, createdAt, updatedAt, workspaceId, groupId)
            VALUES ('placed', ?, 0, 'Find a desk lamp', ?, ?, (SELECT workspaceId FROM taskGroups WHERE id = ?), ?), ('loose', ?, 1, 'A rug', ?, ?, NULL, NULL)
            """, arguments: [room.id, Date(), Date(), office, office, room.id, Date(), Date()])
    }
    let db = try FaciendaStore(url: url)
    let row = try #require(try db.planLines().first { $0.groupId == office })
    #expect(row.text == "Find a desk lamp")
    #expect(try db.goalLine("placed")?.planLineId == row.id)
    #expect(try db.goalLine("loose")?.planLineId == nil)
}

@Test func aLineHoldsTheWorkTowardIt() throws {
    let db = try store()
    let goal = try db.addGoal("Open the studio to visitors")
    let page = try db.addGoal("A booking page", parentId: goal.id), room = try db.addGoal("Finish the sound room", parentId: goal.id)
    let form = try db.addGoalLine("Booking form", to: page.id)
    let mail = try db.addGoalLine("Confirmation mail", to: page.id)
    let slots = try db.create(FaciendaTask(title: "Let visitors pick a time slot in the form", state: .done))
    let spam = try db.create(FaciendaTask(title: "Stop spam through the form", state: .running))

    // The line stays as written and holds both tasks, in the order they came.
    try db.serve(taskId: slots.id, lineId: form.id)
    try db.serve(taskId: spam.id, lineId: form.id)
    try db.serve(taskId: spam.id, lineId: form.id)
    func rows(_ sub: Goal) throws -> [String] { try db.goalItems().filter { $0.line.subgoalId == sub.id }.map { $0.task?.title ?? $0.line.text } }
    #expect(try rows(page) == ["Booking form", "Let visitors pick a time slot in the form", "Stop spam through the form", "Confirmation mail"])
    #expect(try db.goalItems().first { $0.line.id == form.id }?.task == nil)
    #expect(try db.servedSubgoal(taskId: slots.id) == page.id)
    #expect(try db.servedLine(taskId: slots.id) == form.id)

    // Work moves from line to line, and sits one level deep only.
    try db.serve(taskId: spam.id, lineId: mail.id)
    #expect(try db.servedLine(taskId: spam.id) == mail.id)
    let held = try #require(try db.goalItems().first { $0.task?.id == spam.id })
    #expect(throws: StoreError.self) { try db.serve(taskId: slots.id, lineId: held.line.id) }
    #expect(throws: StoreError.self) { try db.moveGoalLine(held.line.id, to: room.id, at: 0) }

    // A line written after it still lands among the subgoal's own lines, and a moved line takes its work along.
    _ = try db.addGoalLine("Calendar feed", to: page.id, after: form.id)
    #expect(try rows(page) == ["Booking form", "Let visitors pick a time slot in the form", "Calendar feed", "Confirmation mail", "Stop spam through the form"])
    try db.moveGoalLine(form.id, to: room.id, at: 0)
    #expect(try rows(room) == ["Booking form", "Let visitors pick a time slot in the form"])
    #expect(try db.servedSubgoal(taskId: slots.id) == room.id)
    #expect(try db.goalItems().filter { $0.line.subgoalId == page.id && $0.line.parentLineId == nil }.map(\.line.position) == [0, 1])

    // Choosing the subgoal itself takes the task out from under its line; another subgoal gives it a line of its own there.
    try db.serve(taskId: slots.id, subgoalId: room.id)
    #expect(try db.servedLine(taskId: slots.id) == nil)
    #expect(try rows(room) == ["Booking form", "Let visitors pick a time slot in the form"])
    try db.serve(taskId: slots.id, subgoalId: room.id)
    #expect(try rows(room) == ["Booking form", "Let visitors pick a time slot in the form"])
    try db.serve(taskId: slots.id, subgoalId: page.id)
    #expect(try db.servedLine(taskId: slots.id) == nil)
    #expect(try rows(room) == ["Booking form"])

    // Removing a line keeps its work with the subgoal, where the line was. A deleted task leaves nothing behind.
    try db.deleteGoalLine(mail.id)
    #expect(try rows(page) == ["Calendar feed", "Stop spam through the form", "Let visitors pick a time slot in the form"])
    try db.serve(taskId: slots.id, lineId: form.id)
    try db.deleteTask(slots.id)
    #expect(try rows(room) == ["Booking form"])

    // Started as it is, a line shows its task, and that task is no longer work under another line.
    try db.serve(taskId: spam.id, lineId: form.id)
    let feed = try #require(try db.goalItems().first { $0.line.text == "Calendar feed" })
    try db.linkGoalLine(feed.line.id, taskId: spam.id)
    #expect(try rows(room) == ["Booking form"])
    #expect(try db.goalItems().first { $0.line.id == feed.line.id }?.task?.id == spam.id)
}

@Test func boardWorkIsGuessedForLinesAndKeptOnlyByTheUser() throws {
    let db = try store()
    let now = Date()
    let goal = try db.addGoal("Open the studio to visitors")
    let page = try db.addGoal("A booking page", parentId: goal.id), room = try db.addGoal("Finish the sound room", parentId: goal.id)
    let closed = try db.addGoal("Paint the hallway", parentId: goal.id)
    try db.setGoalReached(closed.id, at: now)
    let form = try db.addGoalLine("Booking form with time slots", to: page.id)
    let panels = try db.addGoalLine("Acoustic panels", to: room.id)
    let studio = try db.createGroup(name: "Studio build")
    try db.setGoalLinePlace(panels.id, workspaceId: studio.workspaceId, groupId: studio.id)

    func task(_ title: String, _ state: TaskState = .done, in group: TaskGroup? = nil) throws -> FaciendaTask {
        let task = try db.create(FaciendaTask(title: title, state: state))
        if let group { try db.assignGroup(taskId: task.id, groupId: group.id) }
        return task
    }
    let slots = try task("Add time slots to the booking form")
    let glue = try task("Which glue holds the panels on plaster?", .running, in: studio)
    let door = try task("Seal the sound room door")
    let hallway = try task("Paint the hallway ceiling")
    let taxes = try task("Sort the tax receipts")
    let dropped = try task("Booking form slots, second try", .dropped)
    let stale = try task("Old booking form with slots")
    try db.db.write { try $0.execute(sql: "UPDATE tasks SET updatedAt = ? WHERE id = ?", arguments: [now.addingTimeInterval(-90 * 86400), stale.id]) }

    func guesses() throws -> [String: String] { Dictionary(uniqueKeysWithValues: try db.goalGuesses(now: now).map { ($0.task.id, $0.targetId) }) }
    // Shared words point at a line; one word is enough where the task already lives in the line's group. Work that
    // fits no line can still fit its subgoal. Reached subgoals, dropped tasks and long-finished ones are left out.
    #expect(try guesses() == [slots.id: form.id, glue.id: panels.id, door.id: room.id])
    #expect(try db.goalGuesses(now: now).first { $0.task.id == glue.id }?.groupName == "Studio build")
    #expect(try guesses()[hallway.id] == nil && guesses()[taxes.id] == nil && guesses()[dropped.id] == nil)

    // A guess links nothing by itself.
    #expect(try db.servedSubgoal(taskId: slots.id) == nil)
    #expect(try db.goalItems().count == 2)

    // Kept, the task is the line's and no longer guessed. Sent away, it is not offered there again.
    try db.serve(taskId: slots.id, lineId: form.id)
    try db.dismissGoalGuess(taskId: door.id, targetId: room.id)
    try db.dismissGoalGuess(taskId: door.id, targetId: room.id)
    #expect(try guesses() == [glue.id: panels.id])

    // A line that became a task is that task, so nothing is guessed for it.
    let started = try task("Acoustic panels", .running, in: studio)
    try db.linkGoalLine(panels.id, taskId: started.id)
    #expect(try guesses()[glue.id] != panels.id)
}

@Test func guessesNeedMoreThanACommonWord() {
    let task = GoalMatch.Words("Upload the retry queue fixes for the sync engine")
    // Half a line's words, two at least; endings don't matter.
    #expect(GoalMatch.fit(of: ["retry", "queue", "uploads"], in: task, near: false) == 1)
    #expect(GoalMatch.fit(of: ["retry", "budget", "review", "queue"], in: task, near: false) == 0.5)
    #expect(GoalMatch.fit(of: ["retry", "budget", "review", "notes", "queue"], in: task, near: false) == nil)
    // One word is enough only when it is the whole line, or the task lives where the line's work does.
    #expect(GoalMatch.fit(of: ["sync"], in: task, near: false) == 1)
    #expect(GoalMatch.fit(of: ["sync", "paper"], in: task, near: false) == nil)
    #expect(GoalMatch.fit(of: ["sync", "paper"], in: task, near: true) == 0.75)
    #expect(GoalMatch.fit(of: ["fix"], in: task, near: true) == nil)
    #expect(GoalMatch.fit(of: [], in: task, near: true) == nil)
}

@Test func todayHoldsPickedMinigoalsAndLinesWithNoGoal() throws {
    let db = try store()
    let morning = Calendar.current.startOfDay(for: Date()), yesterday = morning.addingTimeInterval(-6 * 3600), today = morning.addingTimeInterval(3600)
    let goal = try db.addGoal("Open the studio to visitors")
    let room = try db.addGoal("Finish the sound room", parentId: goal.id)
    let panels = try db.addGoalLine("Hang the acoustic panels", to: room.id, now: yesterday)
    let door = try db.addGoalLine("Seal the door", to: room.id, now: yesterday)
    let cable = try db.addGoalLine("Order the long cable", to: room.id, now: yesterday)

    // Picking is not a change to the line, and only a line the user wrote can be picked.
    try db.setGoalLinePicked(panels.id, true, now: yesterday)
    try db.setGoalLinePicked(door.id, true, now: yesterday)
    try db.setGoalLinePicked(cable.id, true, now: yesterday)
    #expect(try db.goalLine(panels.id)?.pickedAt != nil)
    #expect(try db.goalLine(panels.id)?.updatedAt == panels.updatedAt)
    let glue = try db.create(FaciendaTask(title: "Which glue holds the panels?", state: .done))
    try db.serve(taskId: glue.id, lineId: panels.id)
    let work = try #require(try db.goalItems().first { $0.task?.id == glue.id })
    #expect(throws: StoreError.self) { try db.setGoalLinePicked(work.line.id, true) }

    // Lines with no goal live only on the list.
    let milk = try db.addTodayLine("  Buy oat milk ", now: yesterday), post = try db.addTodayLine("Post the parcel", now: yesterday)
    #expect(try db.todayLines().map(\.text) == ["Buy oat milk", "Post the parcel"])
    #expect(throws: StoreError.self) { try db.addTodayLine("  ") }

    // Ticked by hand yesterday, or done by its work before today began: gone from the list the next morning. What is
    // still open stays. A ticked minigoal stays ticked on the map.
    try db.setGoalLineTicked(door.id, true, now: yesterday)
    try db.setTodayLineTicked(milk.id, true, now: yesterday)
    try db.db.write { try $0.execute(sql: "UPDATE tasks SET updatedAt = ? WHERE id = ?", arguments: [yesterday, glue.id]) }
    try db.clearToday(before: morning)
    #expect(try db.goalLine(panels.id)?.pickedAt == nil)
    #expect(try db.goalLine(door.id)?.pickedAt == nil)
    #expect(try db.goalLine(door.id)?.tickedAt != nil)
    #expect(try db.goalLine(cable.id)?.pickedAt != nil)
    #expect(try db.todayLines().map(\.id) == [post.id])

    // Done today, it stays for the rest of the day; picked again today, something done long ago stays too.
    try db.setGoalLineTicked(cable.id, true, now: today)
    try db.setTodayLineTicked(post.id, true, now: today)
    try db.setGoalLinePicked(panels.id, true, now: today)
    try db.clearToday(before: morning)
    #expect(try db.goalLine(cable.id)?.pickedAt != nil)
    #expect(try db.goalLine(panels.id)?.pickedAt != nil)
    #expect(try db.todayLines().count == 1)

    // Unticked, a line is open again; taken off, a line with no goal is gone.
    try db.setGoalLineTicked(cable.id, false, now: today)
    #expect(try db.goalLine(cable.id)?.tickedAt == nil)
    try db.deleteTodayLine(post.id)
    #expect(try db.todayLines().isEmpty)
}
