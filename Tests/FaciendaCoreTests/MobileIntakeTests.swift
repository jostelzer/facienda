import Foundation
import Testing
@testable import FaciendaCore

@Test func mobileIntakePreservesUserEditsAndRejectsInvalidRequests() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaMobileTests/\(UUID().uuidString)/test.sqlite"))
    let id = UUID().uuidString
    let date = Date().addingTimeInterval(-300)
    _ = try store.receiveMobileRequest(id: id, text: "  Check kitchen capture  ", createdAt: date)
    _ = try store.update(id) { $0.displayTitle = "Camera investigation"; $0.state = .done }
    let repeated = try store.receiveMobileRequest(id: id, text: "Changed delivery", createdAt: Date())
    #expect(repeated.title == "Check kitchen capture")
    #expect(repeated.displayName == "Camera investigation")
    #expect(repeated.state == .done)
    #expect(abs(repeated.createdAt.timeIntervalSince(date)) < 0.001)
    #expect(try store.tasks().count == 1)
    #expect(try store.events(taskId: id).filter { $0.kind == "mobile.received" }.count == 1)
    #expect(throws: StoreError.self) { try store.receiveMobileRequest(id: "invalid", text: "Task", createdAt: date) }
    #expect(throws: StoreError.self) { try store.receiveMobileRequest(id: UUID().uuidString, text: " \n ", createdAt: date) }
}

@Test func mobileRequestsWaitToBeStartedAndNeverReachTasksMadeOnTheMac() throws {
    let store = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaMobileTests/\(UUID().uuidString)/test.sqlite"))
    let id = UUID().uuidString
    let task = try store.receiveMobileRequest(id: id, text: " Book the dentist ", createdAt: Date())
    #expect(task.state == .inbox)
    #expect(try store.dispatches().isEmpty)
    #expect(try store.mobileRequestTexts() == [id: "Book the dentist"])
    // A request reusing the ID of a task made on this Mac is refused and changes nothing.
    let local = try store.create(FaciendaTask(id: UUID().uuidString, title: "Private plan"))
    #expect(throws: StoreError.self) { try store.receiveMobileRequest(id: local.id, text: "Start it", createdAt: Date()) }
    #expect(try store.task(local.id).title == "Private plan")
    #expect(try store.events(taskId: local.id).allSatisfy { $0.kind != "mobile.received" })
    #expect(try store.mobileRequestTexts().keys.sorted() == [id])
    #expect(try store.dispatches().isEmpty)
}
