import Foundation
import Testing

/// Each workspace keeps its own folded cards, Unsorted's empty key included, and a board with none folded leaves nothing behind.
@Test func foldedCardsAreKeptPerWorkspace() throws {
    let name = "FaciendaFoldedCards-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    // The suite is removed with its file afterwards, so the run leaves nothing behind.
    defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(name).plist"))
    }

    FoldedCards.save(["group-a", ""], for: "library#home", in: defaults)
    FoldedCards.save(["group-b"], for: "library#work", in: defaults)
    #expect(FoldedCards.load("library#home", from: defaults) == ["group-a", ""])
    #expect(FoldedCards.load("library#work", from: defaults) == ["group-b"])
    #expect(FoldedCards.load("library#other", from: defaults).isEmpty)

    FoldedCards.save([], for: "library#home", in: defaults)
    #expect(defaults.object(forKey: FoldedCards.key("library#home")) == nil)
    #expect(FoldedCards.load("library#work", from: defaults) == ["group-b"])
}
