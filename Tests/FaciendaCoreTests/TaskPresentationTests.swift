import Foundation
import Testing
@testable import FaciendaCore

@Test func fiveTaskSectionsRemainDistinctAndQueueTakesPrecedence() {
    let cases: [(TaskState, TaskSection)] = [(.inbox, .forYou), (.running, .processing), (.needsMe, .forYou), (.waiting, .waiting), (.scheduled, .scheduled), (.done, .done), (.dropped, .done)]
    for (state, expected) in cases {
        let task = FaciendaTask(title: "Test", state: state)
        #expect(TaskSection.classify(task, queued: false) == expected)
        #expect(TaskSection.classify(task, queued: true) == (state.isOpen ? .processing : .done))
    }
}

@Test func generatedTitlePreservesRequestSearchAndHumanEdits() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "naming-\(UUID().uuidString)/tasks.sqlite")
    let store = try FaciendaStore(url: url)
    try store.bindRunner(threadId: "runner", automationId: nil)
    let original = "hey could you please check whether I already sent Mike a reply?"
    let task = try store.create(FaciendaTask(title: original, state: .needsMe))
    let named = try store.nameTask(task.id, runnerID: "runner", expectedTitle: original, displayTitle: "Check Mike correspondence", context: "Original request only")
    #expect(named.title == original)
    #expect(named.displayName == "Check Mike correspondence")
    #expect(try store.tasks(search: "correspondence").map(\.id) == [task.id])
    #expect(try store.tasks(search: "already").map(\.id) == [task.id])
    #expect(try store.tasks(search: "%").isEmpty)
    // Words of the display name match as word parts and in any order, not only as one exact phrase.
    #expect(try store.tasks(search: "check mike corr").map(\.id) == [task.id])
    #expect(try store.tasks(search: "corr check").map(\.id) == [task.id])
    #expect(try store.tasks(search: "check lumen").isEmpty)
    #expect(try FaciendaStore(url: url).task(task.id).displayName == named.displayName)
    #expect(try store.events(taskId: task.id).filter { $0.kind == "naming.proposed" }.count == 1)
    _ = try store.nameTask(task.id, runnerID: "runner", expectedTitle: original, displayTitle: "Another title", context: "Retry")
    #expect(try store.task(task.id).displayName == named.displayName)
    _ = try store.update(task.id) { $0.displayTitle = "My own title" }
    _ = try store.nameTask(task.id, runnerID: "runner", expectedTitle: original, displayTitle: "Agent overwrite", context: "Retry")
    #expect(try store.task(task.id).displayName == "My own title")
    #expect(try store.task(task.id).displayTitleSource == "user")
    #expect(throws: StoreError.self) { try store.update(task.id) { $0.displayTitle = " " } }
    #expect(throws: StoreError.self) { try store.nameTask(task.id, runnerID: "unrelated", expectedTitle: original, displayTitle: "Wrong", context: "No") }
    #expect(throws: StoreError.self) { try store.nameTask(task.id, runnerID: "runner", expectedTitle: "stale", displayTitle: "Wrong", context: "No") }
    // A name longer than the chat apps show whole is clipped at a word, so the chat title still carries the task's name.
    let long = try store.create(FaciendaTask(title: "long one", state: .needsMe))
    let clipped = try store.nameTask(long.id, runnerID: "runner", expectedTitle: "long one", displayTitle: "Check documents for Elsa’s German embassy appointment next week", context: "turn 1")
    #expect(clipped.displayName == "Check documents for Elsa’s German…")
    #expect(clipped.displayName.count <= TaskNameWriter.maximumLength && TaskNameWriter.maximumLength == 40)
    try store.link(ThreadLink(taskId: task.id, codexThreadId: "new-chat"))
    try store.recordChatName(taskID: task.id, threadID: "new-chat", observedTitle: "My own title", runnerID: "runner")
    #expect(try store.links().first?.title == "My own title")
    #expect(try store.events(taskId: task.id).first { $0.kind == "naming.observed" }?.verified == false)
}

@Test func requestedNameIsOneCleanLineAndPromptCarriesTheTask() throws {
    #expect(try TaskNameWriter.read(#"{"name":"“Return the desk lamp.”"}"#) == "Return the desk lamp")
    #expect(try TaskNameWriter.read(#"{"name":"Book\n**London** flights"}"#) == "Book London flights")
    #expect(try TaskNameWriter.read(#"{"name":"\#(String(repeating: "word ", count: 30))"}"#).count <= TaskNameWriter.maximumLength)
    #expect(throws: StoreError.self) { try TaskNameWriter.read(#"{"name":"  "}"#) }
    var task = FaciendaTask(title: "hey can u look at the thing with the lamp", intention: "Get a refund")
    task.displayTitle = "Lamp thing"
    let prompt = TaskNameWriter.prompt(for: task, latestResult: "Amazon accepted the return.", language: "German")
    #expect(prompt.contains("CURRENT NAME: Lamp thing") && prompt.contains("Get a refund") && prompt.contains("Amazon accepted") && prompt.contains("LANGUAGE: German"))
    #expect(prompt.contains("RECENT CHAT:\n(none)"))
    task.nextAction = "Print the return label"
    let evolved = TaskNameWriter.prompt(for: task, latestResult: nil, chat: "USER: actually swap it for the larger model instead", language: "German")
    #expect(evolved.contains("swap it for the larger model") && evolved.contains("Print the return label"))
}

@Test func groupNamedFromItsFirstTaskIsTheSubjectAndShort() throws {
    #expect(GroupNameWriter.provisional(from: "Order a monitor arm that fits the Studio Display") == "monitor arm")
    #expect(GroupNameWriter.provisional(from: "Taxes\nmore detail") == "taxes")
    #expect(GroupNameWriter.provisional(from: "   ") == "New group")
    #expect(GroupNameWriter.provisional(from: String(repeating: "Supercalifragilistic ", count: 4)).count <= GroupNameWriter.maximumLength)
    #expect(try GroupNameWriter.read(#"{"name":"“Desk setup.”"}"#) == "Desk setup")
    #expect(try GroupNameWriter.read(#"{"name":"\#(String(repeating: "word ", count: 30))"}"#).count <= GroupNameWriter.maximumLength)
    let prompt = GroupNameWriter.prompt(task: "Order a monitor arm", groups: ["facienda coding", "releasing"], language: "German")
    #expect(prompt.contains("GROUPS: facienda coding, releasing") && prompt.contains("Order a monitor arm") && prompt.contains("LANGUAGE: German"))
}
