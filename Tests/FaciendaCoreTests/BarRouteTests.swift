import Foundation
import Testing
@testable import FaciendaCore

private func library() throws -> FaciendaStore {
    try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaBarRouteTests/\(UUID().uuidString)/test.sqlite"))
}

private let places = [
    BarPlace(workspaceID: "org", workspaceName: "Organisation", groupID: "house", groupName: "house", examples: ["Fix the boiler"]),
    BarPlace(workspaceID: "org", workspaceName: "Organisation"),
    BarPlace(workspaceID: "fac", workspaceName: "Facienda", groupID: "code", groupName: "facienda coding", examples: ["Lunar rings", "Bar reading"]),
    BarPlace(workspaceID: "fac", workspaceName: "Facienda"),
]

private func reply(_ fields: String) -> String {
    #"{"kind":"new","pick":null,"options":[],"message":"","until":"","then":"none","answer":"","sources":[],"#
        + fields + "}"
}

@Test func everyPlaceInTheLibraryComesWithItsWork() throws {
    let library = try library()
    let facienda = library.scoped(to: try library.createWorkspace(name: "Facienda").id)
    let house = library.scoped(to: try library.createWorkspace(name: "House").id)
    let coding = try facienda.createGroup(name: "facienda coding")
    let rings = try facienda.create(FaciendaTask(title: "Lunar rings", state: .running, nextAction: "Draw"))
    try facienda.assignGroup(taskId: rings.id, groupId: coding.id)
    _ = try facienda.create(FaciendaTask(title: "Loose idea", nextAction: "Think"))
    _ = try house.create(FaciendaTask(title: "Fix the boiler", nextAction: "Call"))

    let found = try library.barPlaces().filter { [facienda.workspaceID, house.workspaceID].contains($0.workspaceID) }
    #expect(found.map(\.label) == ["Facienda · facienda coding", "Facienda", "House"])
    #expect(found[0].examples == ["Lunar rings"] && found[1].examples == ["Loose idea"] && found[2].examples == ["Fix the boiler"])

    // Work matching the words typed is named where it lives, whichever workspace is open.
    let matched = try library.barPlaces(matching: "another lunar rings idea").filter { !$0.matches.isEmpty }
    #expect(matched.map(\.label) == ["Facienda · facienda coding"] && matched[0].matches == ["Lunar rings"])
}

@Test func theReaderPutsNewWorkInItsPlaceAndSaysWhenItIsNotSure() throws {
    let sure = try #require(BarReader.read(reply(#""place":3,"sure":true,"alt":null"#), candidates: [], notes: [], places: places))
    #expect(sure.kind == .new && sure.place?.label == "Facienda · facienda coding" && sure.sure && sure.alternative == nil)
    #expect(BarReading.start(sure).label == "New task in Facienda · facienda coding")

    let torn = try #require(BarReader.read(reply(#""place":1,"sure":false,"alt":3"#), candidates: [], notes: [], places: places))
    #expect(!torn.sure && torn.alternative?.label == "Facienda · facienda coding")
    #expect(BarReading.start(torn).label == "New task · Organisation · house or Facienda · facienda coding?")

    // Not sure and nothing else named: here without a group is offered beside the guess, unless the guess is that.
    let guess = try #require(BarReader.read(reply(#""place":3,"sure":false,"alt":null"#), candidates: [], notes: [], places: places, here: "org"))
    #expect(guess.alternative?.label == "Organisation")
    let home = try #require(BarReader.read(reply(#""place":2,"sure":false,"alt":null"#), candidates: [], notes: [], places: places, here: "org"))
    #expect(home.alternative == nil && BarReading.start(home).label == "New task in Organisation · not sure")

    // A place outside the list keeps the work here, and the bar says it is not sure.
    let lost = try #require(BarReader.read(reply(#""place":9,"sure":true,"alt":null"#), candidates: [], notes: [], places: places))
    #expect(lost.place == nil && !lost.sure && BarReading.start(lost).label == "New task here · not sure where it goes")

    // With one place there is nothing to choose, and nothing is said.
    let single = try #require(BarReader.read(reply(#""place":1,"sure":true,"alt":null"#), candidates: [], notes: [], places: [places[1]]))
    #expect(single.place == nil && single.sure && !BarReading.start(single).isWorthShowing)
}

@Test func thePromptListsThePlacesAndWhereThePersonPutEarlierWork() {
    let moved = [BarRouteCorrection(text: "another idea for lunar rings", workspaceID: "fac", groupID: "code"),
                 BarRouteCorrection(text: "somewhere gone", workspaceID: "gone", groupID: nil)]
    let prompt = BarReader.prompt(text: "make another ring idea", candidates: [], notes: [], places: places, here: "org", moved: moved)
    #expect(prompt.contains("HERE: Organisation"))
    #expect(prompt.contains(#"P3. Facienda · group facienda coding · has: "Lunar rings", "Bar reading""#))
    #expect(prompt.contains("P2. Organisation · no group"))
    let withMatch = [BarPlace(workspaceID: "fac", workspaceName: "Facienda", groupID: "code", groupName: "facienda coding", matches: ["Recall lunar rings work"]), places[1]]
    #expect(BarReader.prompt(text: "lunar ring idea", candidates: [], notes: [], places: withMatch, here: "org")
        .contains(#"P1. Facienda · group facienda coding · MATCHES TEXT: "Recall lunar rings work""#))
    #expect(prompt.contains(#"MOVED: "another idea for lunar rings" → P3"#))
    #expect(!prompt.contains("somewhere gone"))
    #expect(!BarReader.prompt(text: "x", candidates: [], notes: [], places: [places[0]]).contains("PLACES"))
    #expect(BarReader.worthReading("buy oat milk", matchesTasks: false, routes: true))
}

@Test func whereThePersonPutBarWorkIsKeptOncePerText() throws {
    let library = try library()
    let home = library.scoped(to: try library.createWorkspace(name: "Home").id)
    let made = try home.create(FaciendaTask(title: "Lunar rings idea", nextAction: "Think"))
    let typed = try home.create(FaciendaTask(title: "From a group's plus", nextAction: "Think"))
    try home.recordIntake(text: "another idea for lunar rings", reading: "New task", decidedBy: .model, taskId: made.id)
    #expect(try home.barText(forTask: made.id) == "another idea for lunar rings")
    #expect(try home.barText(forTask: typed.id) == nil)

    try home.recordRouteCorrection(text: "another idea for lunar rings", workspaceID: "a", groupID: "g1")
    try home.recordRouteCorrection(text: "Another idea for lunar rings", workspaceID: "b", groupID: nil)
    try home.recordRouteCorrection(text: "the boiler", workspaceID: "a", groupID: nil)
    let kept = try library.routeCorrections()
    #expect(kept.map(\.text) == ["the boiler", "Another idea for lunar rings"])
    #expect(kept[1].workspaceID == "b" && kept[1].groupID == nil)
}

@Test func aWorkspaceIsNamedOnlyByItsWholeName() {
    #expect(FaciendaStore.namedWorkspace(in: "hey please make in facienda another idea", among: places) == "fac")
    #expect(FaciendaStore.namedWorkspace(in: "the faciendas", among: places) == nil)
    #expect(FaciendaStore.namedWorkspace(in: "facienda or organisation?", among: places) == nil)
}

@Test func workPlacedWithoutBeingSureIsNoEvidence() throws {
    let library = try library()
    let here = library.scoped(to: try library.createWorkspace(name: "Organisation").id)
    _ = try library.createWorkspace(name: "Facienda")
    let guessed = try here.create(FaciendaTask(title: "Brainstorm a new lunar ring idea", nextAction: "Think"))
    try here.recordIntake(text: "brainstorm a lunar ring idea", reading: "New task in Organisation · not sure", decidedBy: .model, taskId: guessed.id)
    #expect(try library.barPlaces(matching: "lunar ring idea").allSatisfy { $0.matches.isEmpty && $0.examples.isEmpty })
}

@Test func aFoundTaskSaysWhereItLives() throws {
    let library = try library()
    let facienda = library.scoped(to: try library.createWorkspace(name: "Facienda").id)
    let house = library.scoped(to: try library.createWorkspace(name: "House").id)
    let coding = try facienda.createGroup(name: "facienda coding")
    let rings = try facienda.create(FaciendaTask(title: "Recall lunar rings work", nextAction: "Look"))
    try facienda.assignGroup(taskId: rings.id, groupId: coding.id)
    let boiler = try house.create(FaciendaTask(title: "Fix the boiler", nextAction: "Call"))
    // Searching from any workspace finds both, and each says where it is.
    #expect(Set(try house.library.lookUpTasks("lunar rings").map(\.task.id)) == [rings.id])
    let found = try library.taskPlaces(ofTasks: [rings.id, boiler.id])
    #expect(found[rings.id]?.label == "Facienda · facienda coding" && found[rings.id]?.groupID == coding.id)
    #expect(found[boiler.id]?.label == "House" && found[boiler.id]?.workspaceID == house.workspaceID)
}
