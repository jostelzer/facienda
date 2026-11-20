import Foundation
import Testing
@testable import FaciendaCore

/// Counts model calls and answers none, for checks that nothing asks the worker.
private final class CountingWorker: MemoryInference, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        lock.withLock { count += 1 }
        throw StoreError.invalid("No model in tests.")
    }
}

private func nativeStore() throws -> (FaciendaStore, String) {
    let library = try FaciendaStore(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaNativeMemory/\(UUID().uuidString)/test.sqlite"))
    let store = library.scoped(to: try library.defaultWorkspace().id)
    return (store, try store.resolvedMemorySpace(nil).id)
}

@Test func newLibrariesLearnInsideFacienda() throws {
    let (store, _) = try nativeStore()
    #expect(try JSONValue.encoded(store.memorySettings())["engine"] == .null)
}

@Test func memoryContextNeedsNoLearnedRecall() async throws {
    let (store, space) = try nativeStore()
    try store.saveMemorySettings(enabled: true, workerModel: nil)
    var note = MemoryFact(text: "Use oak floors", source: "Invented user"); note.confirmedAt = Date(); note.spaceId = space
    try store.remember(note, source: .user)
    let context = try await WorkspaceMemoryService(store: store, inference: CountingWorker()).context(query: "floors", spaceID: space)
    #expect(context["userConfirmed"].array?.count == 1)
    #expect(context["learned"] == .null)
    #expect(context["status"].string?.contains("never overrides user rules") == true)
}

@Test func chunkerKeepsTextAndBreaksAtParagraphs() {
    let text = String(repeating: "a", count: 2_000) + "\n\n" + String(repeating: "b", count: 2_000)
    let chunks = MemoryChunker.split(text)
    #expect(chunks.count == 2 && chunks[0].allSatisfy { $0 == "a" } && chunks[1].allSatisfy { $0 == "b" })
    #expect(MemoryChunker.split("short") == ["short"])
    #expect(MemoryChunker.split(chunks.joined(separator: "\n\n")) == chunks, "re-chunking is stable")
}
