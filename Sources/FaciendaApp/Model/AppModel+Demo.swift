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
        let office = try store.createGroup(name: "Home office"), trips = try store.createGroup(name: "Time away")
        _ = try store.createGroup(name: "Reading")
        for task in try store.tasks() {
            if task.title.contains("desk") || task.title.contains("office") || task.title.contains("tudio") { try store.assignGroup(taskId: task.id, groupId: office.id) }
            if task.title.contains("weekend") { try store.assignGroup(taskId: task.id, groupId: trips.id) }
        }
        connection = "Demo workspace"
    }
}
