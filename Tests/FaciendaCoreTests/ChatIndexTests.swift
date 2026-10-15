import Foundation
import Testing
@testable import FaciendaCore

private func index() throws -> ChatIndex {
    try ChatIndex(url: FileManager.default.temporaryDirectory.appending(path: "FaciendaChatIndexTests/\(UUID().uuidString)/ChatIndex.sqlite"))
}

@Test func chatIndexFindsMessagesByWordPrefixAndGroupsThemByChat() throws {
    let index = try index()
    try index.record([ChatListing(threadId: "a", title: "Schema rollback plan", cwd: "/work", updatedAt: 200),
                      ChatListing(threadId: "b", title: "Weekend trip", cwd: "/home", updatedAt: 100)])
    #expect(try index.pending(limit: 10).map(\.threadId) == ["a", "b"])
    try index.replace(threadId: "a", messages: [
        ChatText(messageId: "t1:1", role: .user, at: Date(timeIntervalSince1970: 150), text: "How do we roll back the postgres migration?"),
        ChatText(messageId: "t1:2", role: .codex, at: Date(timeIntervalSince1970: 160), text: "Keep the old column until the migration is verified, then drop it.")
    ], updatedAt: 200)
    try index.replace(threadId: "b", messages: [ChatText(messageId: "t1:1", role: .user, at: nil, text: "Find a quiet place by the sea")], updatedAt: 100)
    #expect(try index.pending(limit: 10).isEmpty)

    let hits = try index.search("postg migr")
    #expect(hits.map(\.threadId) == ["a"])
    #expect(hits.first?.matches.map(\.messageId).sorted() == ["t1:1", "t1:2"])
    // Words may be spread over the chat: one in the title, one in a reply.
    #expect(try index.search("rollback verified").map(\.threadId) == ["a"])
    #expect(hits.first?.matches.first?.snippet.contains(ChatIndex.highlightStart) == true)
    // Titles are searchable too, and every word must match.
    #expect(try index.search("rollback").first?.titleMatched == true)
    #expect(try index.search("postgres sea").isEmpty)
    #expect(try index.search("   ").isEmpty)
    #expect(try index.messages(threadId: "a").map(\.role) == [.user, .codex])
}

@Test func searchListsTitleMatchesThenNewestChatsInsteadOfBestRepeats() throws {
    let index = try index()
    // The old chat repeats the word far more often; the new one mentions it once.
    try index.record([ChatListing(threadId: "old", title: "Notes", cwd: "/", updatedAt: 100),
                      ChatListing(threadId: "new", title: "Lighting rig", cwd: "/", updatedAt: 300),
                      ChatListing(threadId: "mid", title: "Portal review", cwd: "/", updatedAt: 200),
                      ChatListing(threadId: "newest", title: "Other", cwd: "/", updatedAt: 400)])
    try index.replace(threadId: "old", messages: [ChatText(messageId: "t:1", role: .user, at: nil, text: "portal portal portal portal portal")], updatedAt: 100)
    try index.replace(threadId: "new", messages: [ChatText(messageId: "t:1", role: .user, at: nil, text: "check the portal once")], updatedAt: 300)
    try index.replace(threadId: "newest", messages: [ChatText(messageId: "t:1", role: .user, at: nil, text: "the portal again")], updatedAt: 400)
    // The title match leads, then the others newest first.
    #expect(try index.search("portal").map(\.threadId) == ["mid", "newest", "new", "old"])
    #expect(try index.search("portal", limit: 2).map(\.threadId) == ["mid", "newest"])
    #expect(try index.search("portal").first(where: { $0.threadId == "old" })?.matches.count == 1)
}

@Test func chatIndexRereadsChangedChatsAndGivesUpAfterRepeatedFailures() throws {
    let index = try index()
    try index.record([ChatListing(threadId: "a", title: "Draft", cwd: "/", updatedAt: 1)])
    try index.replace(threadId: "a", messages: [ChatText(messageId: "t:1", role: .user, at: nil, text: "old words")], updatedAt: 1)
    try index.record([ChatListing(threadId: "a", title: "Renamed", cwd: "/", updatedAt: 2)])
    #expect(try index.pending(limit: 5).map(\.updatedAt) == [2])
    #expect(try index.search("draft").isEmpty && index.search("renamed").count == 1)
    try index.replace(threadId: "a", messages: [ChatText(messageId: "t:1", role: .user, at: nil, text: "new words")], updatedAt: 2)
    #expect(try index.search("old").isEmpty && index.search("new").count == 1)

    try index.record([ChatListing(threadId: "broken", title: "Huge", cwd: "/", updatedAt: 5)])
    for _ in 0..<3 { try index.fail(threadId: "broken", error: "timeout") }
    #expect(try index.pending(limit: 5).isEmpty)
    #expect(try index.progress() == ChatIndexProgress(known: 2, indexed: 1, failed: 1, listingComplete: false))
    // A later change earns new attempts.
    try index.record([ChatListing(threadId: "broken", title: "Huge", cwd: "/", updatedAt: 6)])
    #expect(try index.pending(limit: 5).map(\.threadId) == ["broken"])

    try index.erase()
    #expect(try index.progress().known == 0 && index.search("new").isEmpty)
}

@Test func questionsMatchAnyMeaningfulWord() throws {
    let index = try index()
    try index.record([ChatListing(threadId: "a", title: "Lighting", cwd: "/", updatedAt: 1)])
    try index.replace(threadId: "a", messages: [ChatText(messageId: "t:1", role: .codex, at: nil, text: "We chose the oak desk for the studio.")], updatedAt: 1)
    #expect(ChatIndex.keywords("What did we decide about the desk?") == ["decide", "desk"])
    let passages = try index.passages(for: "What did we decide about the desk?")
    #expect(passages.map(\.text) == ["We chose the oak desk for the studio."])
    #expect(try index.passages(for: "what was it?").isEmpty)
}

@Test func searchAndAnswersStayInsideOneWorkspace() throws {
    let index = try index()
    try index.record([ChatListing(threadId: "task", title: "Desk lamps", cwd: "/Users/me/Workspaces/home/Work/T1", updatedAt: 3),
                      ChatListing(threadId: "linked", title: "Lamp budget", cwd: "/Users/me/Code", updatedAt: 2),
                      ChatListing(threadId: "elsewhere", title: "Lamp for the office", cwd: "/Users/me/Workspaces/home/Work/T10", updatedAt: 1)])
    for id in ["task", "linked", "elsewhere"] {
        try index.replace(threadId: id, messages: [ChatText(messageId: "t:1", role: .codex, at: nil, text: "The brass lamp fits the desk.")], updatedAt: 1)
    }
    let scope = ChatScope(threadIds: ["linked"], directories: ["/Users/me/Workspaces/home/Work/T1/"])
    #expect(try index.search("lamp", in: scope).map(\.threadId) == ["task", "linked"])
    #expect(Set(try index.passages(for: "brass lamp", in: scope).map(\.threadId)) == ["task", "linked"])
    #expect(try index.search("lamp").count == 3)
}
