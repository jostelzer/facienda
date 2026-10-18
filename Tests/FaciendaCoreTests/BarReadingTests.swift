import Foundation
import Testing
@testable import FaciendaCore

@Test func aReadingSaysWhatReturnDoesToATask() {
    var open = FaciendaTask(title: "Deed transfer at the notary", state: .waiting, nextAction: "Wait for the notary")
    open.displayTitle = "Deed transfer"
    let done = FaciendaTask(title: "Call home", state: .done, nextAction: "Call")

    #expect(BarReading.task(open).label == "Open · Deed transfer")
    #expect(BarReading.task(done).label == "Bring back · Call home")
    // A message makes it a reply, whatever the task's state, and the message is kept word for word.
    let reply = BarReading.task(open, message: "  The notary called back: proxy signing is fine. ")
    #expect(reply.verb == .reply)
    #expect(reply.label == "Reply · Deed transfer")
    #expect(reply.message == "The notary called back: proxy signing is fine.")
    #expect(reply.taskID == open.id)
}

@Test func onlyStartingANewTaskGoesUnsaid() {
    #expect(BarReading(.start).isWorthShowing == false)
    #expect(BarReading(.remember).isWorthShowing)
    // A command's words are its whole label.
    #expect(BarReading(.command, target: "Go to Waiting").label == "Go to Waiting")
    #expect(BarReading(.trackChat).label == "Add the chat as a task")
}

@Test func typingAnOpenTaskFindsItInsteadOfMakingASecond() {
    let call = FaciendaTask(title: "Call home", state: .scheduled, nextAction: "Call")
    var named = FaciendaTask(title: "please compare the desk lighting options for me", state: .needsMe, nextAction: "Review")
    named.displayTitle = "Compare desk lighting options"
    let finished = FaciendaTask(title: "Book the car", state: .done, nextAction: "Book")
    let tasks = [call, named, finished]

    // Case, accents and punctuation don't matter; the words and their order do.
    #expect(BarReading.sameTask(as: "call home!", among: tasks)?.id == call.id)
    #expect(BarReading.sameTask(as: "Compare désk lighting options", among: tasks)?.id == named.id)
    #expect(BarReading.sameTask(as: "home call", among: tasks) == nil)
    #expect(BarReading.sameTask(as: "call home about the car", among: tasks) == nil)
    // A finished task is brought back by asking for it, not by typing its name.
    #expect(BarReading.sameTask(as: "book the car", among: tasks) == nil)
    #expect(BarReading.sameTask(as: "  ", among: tasks) == nil)
}

@Test func whatTheModelReadIsSaidLikeEverythingElse() {
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let call = FaciendaTask(title: "Call home", state: .scheduled, nextAction: "Call")
    let coast = FaciendaTask(title: "A weekend on the coast", state: .needsMe, nextAction: "Choose")
    let friday = ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z")!

    var park = BarReader.Reading(kind: .park, task: call); park.until = friday
    let parked = BarReading(park)
    #expect(parked?.label == "Park · Call home")
    #expect(parked?.detail(timeZone: lisbon) == "Until Fri 23 Oct, 09:00")
    #expect(parked?.read == true)

    var decide = BarReader.Reading(kind: .answer, task: coast); decide.message = "Book Ericeira"
    #expect(BarReading(decide)?.label == "Answer · A weekend on the coast")
    #expect(BarReading(decide)?.detail() == "Answers “Book Ericeira”")
    var reply = BarReader.Reading(kind: .reply, task: coast); reply.message = "Mid-week, please"
    #expect(BarReading(reply)?.detail() == "Sends “Mid-week, please”")
    #expect(BarReading(BarReader.Reading(kind: .done, task: call))?.label == "Mark done · Call home")
    #expect(BarReading(BarReader.Reading(kind: .new)) == nil)
    #expect(BarReading(BarReader.Reading(kind: .unclear))?.label == "Which one?")

    var unclear = BarReader.Reading(kind: .unclear); unclear.then = .park; unclear.until = friday
    #expect(BarReading.question(for: unclear, timeZone: lisbon) == "Park which one until Fri 23 Oct, 09:00?")
}
