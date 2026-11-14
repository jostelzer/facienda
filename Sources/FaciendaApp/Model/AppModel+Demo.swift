import Foundation
import FaciendaCore

extension AppModel {
    func seedDemo() throws {
        try store.renameWorkspace(workspaceID, to: "Personal")
        _ = try store.create(FaciendaTask(title: "Find a quiet weekend getaway", state: .inbox))
        _ = try store.create(FaciendaTask(title: "Compare desk lighting options", state: .inbox))
        var first = FaciendaTask(title: "A quieter home office", intention: "Make space for focused work.", definitionOfDone: "Choose a desk and confirm the order.", area: "Personal", state: .needsMe, nextAction: "Choose the oak desk or keep looking", brief: "The shortlist is ready. Three desks fit the space and budget. The oak option has the best balance of build quality and a small footprint. Nothing has been ordered.")
        first.createdAt = Date().addingTimeInterval(-86400 * 2)
        try store.create(first)
        try store.requestDecision(Decision(taskId: first.id, question: "Which direction feels right?", context: "The oak desk fits the room, has cable management, and leaves space by the window.", recommendation: "Go with the oak desk", options: ["Go with the oak desk", "Explore one more option"]))
        let work = try store.create(FaciendaTask(title: "Prepare the autumn release", area: "Facienda", state: .running, nextAction: "Review the release notes when ready", brief: "Codex is preparing a concise release summary and checking the migration guide."))
        try store.link(ThreadLink(taskId: work.id, codexThreadId: "demo-release", title: "Release preparation"))
        try store.observe(threadId: "demo-release", status: "active", source: .appServer, verified: true)
        let coast = try store.create(FaciendaTask(title: "A weekend on the coast", area: "Personal", state: .needsMe, nextAction: "Pick the weekend that works", brief: "Two quiet places and a flexible travel plan are ready. Just choose a date."))
        // Its answer came back: the new row shows where the task went and what is open.
        try store.saveRecap(TaskRecap(taskId: coast.id, turnId: "demo", steps: ["trains instead of driving"], tip: "choose between Comporta and Ericeira",
                                      said: "ok trains are fine. which of the two places is quieter in october, and is there parking near the station?", saidAt: Date().addingTimeInterval(-1500),
                                      answer: "Ericeira is quieter mid-week and both have parking; Comporta is a longer ride from the station.", ask: "Book Ericeira?",
                                      answeredAt: Date().addingTimeInterval(-1200)), after: nil)
        var waiting = FaciendaTask(title: "Studio lighting proposal", area: "Work", state: .waiting, nextAction: "Check the supplier’s revised quote", returnAt: Date().addingTimeInterval(7200), brief: "Waiting for the revised quote. Check back later today.")
        waiting.waitingOn = "Lighting supplier"; waiting.checkAt = waiting.returnAt; try store.create(waiting)
        try store.link(ThreadLink(taskId: waiting.id, codexThreadId: "demo-supplier", title: waiting.title))
        _ = try store.planCheck(taskId: waiting.id, threadId: "demo-supplier", expectedRevision: 0, nextCheck: waiting.checkAt!, purpose: waiting.nextAction, reason: "The supplier promised a revised quote this afternoon.", waitingOn: "Lighting supplier")
        let measured = try store.create(FaciendaTask(title: "Measure the studio", state: .done))
        try store.addTaskDependencies(taskId: waiting.id, prerequisiteIDs: [measured.id, first.id])
        _ = try store.setExternalBlocker(taskId: waiting.id, kind: "person", title: "Revised quote", sourceReference: "Mail · Lighting supplier", criterion: "A revised quote includes installation and delivery.", freshnessSeconds: nil)
        try store.link(ThreadLink(taskId: first.id, codexThreadId: "demo-office", title: first.title))
        let call = try store.create(FaciendaTask(title: "Call home", area: "Personal", state: .scheduled, nextAction: "Make time for a proper catch-up", returnAt: Date().addingTimeInterval(14400), brief: "A little time set aside for the people who matter."))
        var reminder = WaitPlan(conditions: [.time(call.returnAt ?? Date().addingTimeInterval(86400))], note: "Call home before dinner")
        reminder.summary = WaitCompiler.summary(reminder, taskName: { _ in nil })
        try store.park(call.id, plan: reminder)
        _ = try store.create(FaciendaTask(title: "Revisit the reading list", area: "Personal", state: .scheduled, nextAction: "Choose the next book", returnAt: Date().addingTimeInterval(86400 * 3)))
        try store.remember(MemoryFact(kind: "preference", text: "Keep preparation separate from the final decision.", source: "Demo preference — illustrative data"))
        for rule in ["Prices in euro, delivery included.", "Never book or pay; prepare it and ask."] {
            var fact = MemoryFact(kind: FaciendaStore.ruleKind, text: rule, source: "Demo rule — illustrative data"); fact.confirmedAt = Date()
            try store.remember(fact, source: .user)
        }
        let office = try store.createGroup(name: "Home office"), trips = try store.createGroup(name: "Time away")
        let reading = try store.createGroup(name: "Reading")
        for task in try store.tasks() {
            if task.title.contains("desk") || task.title.contains("office") || task.title.contains("tudio") { try store.assignGroup(taskId: task.id, groupId: office.id) }
            if task.title.contains("weekend") { try store.assignGroup(taskId: task.id, groupId: trips.id) }
        }
        try seedDemoGoals(office: office.id, trips: trips.id, reading: reading.id, release: work.id, measured: measured.id)
        // What came in through the bar, so the Feed has something to show: requests that became these tasks, a reply,
        // an answer and a note remembered, spread over the last day.
        let hour: TimeInterval = 3600
        for (text, reading, by, task, ago) in [
            ("measure the studio before we buy anything", "New task", IntakeEntry.Decider.rule, Optional(measured.id), 26 * hour),
            ("remember prices in euro, delivery included", "Remember · prices in euro, delivery included", .rule, nil, 20 * hour),
            ("call home before dinner", "New task", .rule, Optional(call.id), 7 * hour),
            ("find two quiet places on the coast for a weekend", "New task", .rule, Optional(coast.id), 5 * hour),
            ("tell the supplier the quote must include installation", "Reply · Studio lighting proposal", .model, Optional(waiting.id), 3 * hour),
            ("prepare the autumn release", "New task", .rule, Optional(work.id), 2 * hour),
            ("go with the oak desk", "Answer · A quieter home office", .model, Optional(first.id), 0.4 * hour),
        ] as [(String, String, IntakeEntry.Decider, String?, TimeInterval)] {
            try store.recordIntake(text: text, reading: reading, decidedBy: by, taskId: task, at: Date().addingTimeInterval(-ago))
        }
        connection = "Demo workspace"
    }

    /// A few goals across the demo's groups, with some reached already, so Goals shows its island, a board and a ledger.
    private func seedDemoGoals(office: String, trips: String, reading: String, release: String, measured: String) throws {
        let library = store.library, day: TimeInterval = 86400, now = Date()
        let home = try library.addGoal("A calmer home", now: now.addingTimeInterval(-60 * day))
        let room = try library.addGoal("A quieter home office", parentId: home.id, now: now.addingTimeInterval(-40 * day))
        let studio = try library.addGoal("Measure the studio", parentId: home.id, now: now.addingTimeInterval(-50 * day))
        let balcony = try library.addGoal("Plants on the balcony", parentId: home.id, now: now.addingTimeInterval(-20 * day))
        for task in try store.tasks() where task.title.contains("office") { try library.serve(taskId: task.id, subgoalId: room.id) }
        // A line that holds work, and beside it a task still only on the board, for Goals to find.
        let light = try library.addGoalLine("Better light at the desk", to: room.id)
        for task in try store.tasks() where task.title.contains("proposal") { try library.serve(taskId: task.id, lineId: light.id) }
        let rug = try library.addGoalLine("Find a rug that dampens the echo", to: room.id)
        // A minigoal whose work is all done, folded at the foot of its card.
        let quiet = try library.addGoalLine("Soften the sound in the room", to: room.id)
        let curtains = try store.create(FaciendaTask(title: "Hang heavier curtains", state: .done))
        try library.serve(taskId: curtains.id, lineId: quiet.id)
        try library.serve(taskId: measured, subgoalId: studio.id)
        try library.setGoalReached(studio.id, at: now.addingTimeInterval(-12 * day))
        try library.addGoalLine("Ask which herbs take the afternoon sun", to: balcony.id)
        let boxes = try library.addGoalLine("Self-watering boxes", to: balcony.id)
        try library.setGoalLinePlace(boxes.id, workspaceId: workspaceID, groupId: nil)
        let rest = try library.addGoal("Time to recharge", now: now.addingTimeInterval(-30 * day))
        let away = try library.addGoal("A weekend away each month", parentId: rest.id, now: now.addingTimeInterval(-30 * day))
        let books = try library.addGoal("A book a month", parentId: rest.id, now: now.addingTimeInterval(-30 * day))
        for task in try store.tasks() where task.title.contains("weekend") { try library.serve(taskId: task.id, subgoalId: away.id) }
        for task in try store.tasks() where task.title.contains("reading") { try library.serve(taskId: task.id, subgoalId: books.id) }
        let pick = try library.addGoalLine("Pick November's book", to: books.id)
        try library.setGoalLinePlace(pick.id, workspaceId: workspaceID, groupId: reading)
        let ship = try library.addGoal("Ship the autumn release", now: now.addingTimeInterval(-45 * day))
        let notes = try library.addGoal("Release notes people read", parentId: ship.id, now: now.addingTimeInterval(-45 * day))
        let guide = try library.addGoal("A migration guide", parentId: ship.id, now: now.addingTimeInterval(-25 * day))
        try library.serve(taskId: release, subgoalId: notes.id)
        try library.addGoalLine("Outline the guide from last year's questions", to: guide.id)
        let flat = try library.addGoal("Settle into the new flat", now: now.addingTimeInterval(-120 * day))
        let moved = try library.addGoal("Move everything in", parentId: flat.id, now: now.addingTimeInterval(-120 * day))
        try library.setGoalReached(moved.id, at: now.addingTimeInterval(-80 * day))
        try library.setGoalReached(flat.id, at: now.addingTimeInterval(-70 * day))
        // Today's list: a few minigoals picked this morning, and what serves no goal.
        for (line, minutes) in [(light, 3.0), (rug, 2), (pick, 1)] { try library.setGoalLinePicked(line.id, true, now: now.addingTimeInterval(-minutes * 60)) }
        try library.addTodayLine("Return the borrowed drill", now: now.addingTimeInterval(-120))
        let parcel = try library.addTodayLine("Post the parcel", now: now.addingTimeInterval(-60))
        try library.setTodayLineTicked(parcel.id, true, now: now)
    }
}
