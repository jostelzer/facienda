import Foundation
import GRDB

/// A private, rebuildable full-text index of the Codex chats on this Mac.
/// It keeps only the user's messages and Codex's final replies: no reasoning, tool output or dispatch prompts.
/// Codex chats are not partitioned by Facienda workspace, so one index serves every workspace.
public final class ChatIndex: Sendable {
    public static let highlightStart = "\u{2}"
    public static let highlightEnd = "\u{3}"
    public static var defaultURL: URL { LibraryHome.supportDirectory.appending(path: "ChatIndex.sqlite") }
    /// Pasted logs can be huge. The start of a message carries what it is about.
    static let maximumMessageLength = 16_000

    let db: DatabasePool
    public let url: URL

    public init(url: URL = ChatIndex.defaultURL) throws {
        self.url = url
        db = try FaciendaStore.openPrivateDatabase(at: url, busyTimeout: 2)
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_chat_index") { db in
            try db.execute(sql: """
            CREATE TABLE chats (
              threadId TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, cwd TEXT NOT NULL,
              updatedAt DOUBLE NOT NULL, indexedUpdatedAt DOUBLE, indexedAt DATETIME,
              failures INTEGER NOT NULL DEFAULT 0, error TEXT
            );
            CREATE VIRTUAL TABLE chatText USING fts5(threadId UNINDEXED, messageId UNINDEXED, role UNINDEXED, at UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');
            CREATE TABLE listingState (id INTEGER PRIMARY KEY CHECK(id = 1), cursor TEXT, complete BOOLEAN NOT NULL);
            INSERT INTO listingState(id, cursor, complete) VALUES (1, NULL, 0);
            """)
        }
        return migrator
    }

    // MARK: Indexing

    /// Records chats from a listing. A chat whose Codex timestamp moved becomes due for reading again.
    public func record(_ listings: [ChatListing]) throws {
        try db.write { db in
            for chat in listings {
                if let row = try Row.fetchOne(db, sql: "SELECT title, updatedAt FROM chats WHERE threadId = ?", arguments: [chat.threadId]) {
                    let title: String = row["title"], updatedAt: Double = row["updatedAt"]
                    if title != chat.title {
                        try db.execute(sql: "DELETE FROM chatText WHERE threadId = ? AND role = 'title'", arguments: [chat.threadId])
                        try Self.insertTitle(db, chat)
                    }
                    if title != chat.title || updatedAt != chat.updatedAt {
                        // A changed chat gets a fresh set of attempts.
                        try db.execute(sql: "UPDATE chats SET title = ?, cwd = ?, updatedAt = ?, failures = CASE WHEN updatedAt = ? THEN failures ELSE 0 END WHERE threadId = ?",
                                       arguments: [chat.title, chat.cwd, chat.updatedAt, chat.updatedAt, chat.threadId])
                    }
                } else {
                    try db.execute(sql: "INSERT INTO chats(threadId, title, cwd, updatedAt) VALUES (?, ?, ?, ?)", arguments: [chat.threadId, chat.title, chat.cwd, chat.updatedAt])
                    try Self.insertTitle(db, chat)
                }
            }
        }
    }

    private static func insertTitle(_ db: Database, _ chat: ChatListing) throws {
        guard !chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try db.execute(sql: "INSERT INTO chatText(threadId, messageId, role, at, text) VALUES (?, '', 'title', NULL, ?)", arguments: [chat.threadId, chat.title])
    }

    /// Chats whose messages are missing or stale, newest first. Chats that failed three times wait for their next change.
    public func pending(limit: Int) throws -> [(threadId: String, updatedAt: Double)] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT threadId, updatedAt FROM chats
                WHERE (indexedUpdatedAt IS NULL OR indexedUpdatedAt != updatedAt) AND failures < 3
                ORDER BY updatedAt DESC LIMIT ?
                """, arguments: [limit]).map { ($0["threadId"], $0["updatedAt"]) }
        }
    }

    /// Replaces a chat's messages with what was read at `updatedAt`.
    public func replace(threadId: String, messages: [ChatText], updatedAt: Double) throws {
        try db.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM chats WHERE threadId = ?", arguments: [threadId]) == true else { return }
            try db.execute(sql: "DELETE FROM chatText WHERE threadId = ? AND role != 'title'", arguments: [threadId])
            for message in messages {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try db.execute(sql: "INSERT INTO chatText(threadId, messageId, role, at, text) VALUES (?, ?, ?, ?, ?)",
                               arguments: [threadId, message.messageId, message.role.rawValue, message.at?.timeIntervalSince1970, String(text.prefix(Self.maximumMessageLength))])
            }
            try db.execute(sql: "UPDATE chats SET indexedUpdatedAt = ?, indexedAt = ?, failures = 0, error = NULL WHERE threadId = ?", arguments: [updatedAt, Date(), threadId])
        }
    }

    public func fail(threadId: String, error: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE chats SET failures = failures + 1, error = ? WHERE threadId = ?", arguments: [error, threadId])
        }
    }

    /// Where the walk through older listing pages stopped.
    public func listingState() throws -> (cursor: String?, complete: Bool) {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT cursor, complete FROM listingState WHERE id = 1")!
            return (row["cursor"], row["complete"])
        }
    }

    public func setListingState(cursor: String?, complete: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE listingState SET cursor = ?, complete = ? WHERE id = 1", arguments: [cursor, complete])
        }
    }

    public func progress() throws -> ChatIndexProgress {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS known,
                       SUM(CASE WHEN indexedUpdatedAt IS NOT NULL THEN 1 ELSE 0 END) AS indexed,
                       SUM(CASE WHEN indexedUpdatedAt IS NULL AND failures >= 3 THEN 1 ELSE 0 END) AS failed
                FROM chats
                """)!
            let complete = try Bool.fetchOne(db, sql: "SELECT complete FROM listingState WHERE id = 1") ?? false
            return ChatIndexProgress(known: row["known"], indexed: row["indexed"] ?? 0, failed: row["failed"] ?? 0, listingComplete: complete)
        }
    }

    /// Deletes everything. Used when the user turns chat search off.
    public func erase() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM chats; DELETE FROM chatText; UPDATE listingState SET cursor = NULL, complete = 0 WHERE id = 1;")
        }
        try db.vacuum()
    }

    // MARK: Searching

    /// Chats containing every word (by prefix) somewhere in their title or messages, with up to
    /// `perChat` highlighted snippets each. Chats whose title matches come first, then the rest, newest first:
    /// like Codex's own list, a recent chat must not be crowded out by an older one that repeats the word more often.
    public func search(_ text: String, limit: Int = 6, perChat: Int = 3, in scope: ChatScope? = nil) throws -> [ChatHit] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, let anyWord = Self.matchQuery(words.joined(separator: " "), anyWord: false, joiner: " OR "),
              let allWords = Self.matchQuery(words.joined(separator: " "), anyWord: false) else { return [] }
        return try db.read { db in
            // A chat matches when each word appears in it, not necessarily in the same message.
            var chats: Set<String>?
            for word in words {
                let found = Set(try String.fetchAll(db, sql: "SELECT DISTINCT threadId FROM chatText WHERE chatText MATCH ?", arguments: [Self.matchQuery(word, anyWord: false)!]))
                chats = chats.map { $0.intersection(found) } ?? found
                if chats?.isEmpty != false { return [] }
            }
            let matched = chats ?? []
            let titled = Set(try String.fetchAll(db, sql: "SELECT DISTINCT threadId FROM chatText WHERE chatText MATCH ? AND role = 'title'", arguments: [allWords]))
            var hits = try Row.fetchAll(db, sql: "SELECT threadId, title, cwd, updatedAt FROM chats ORDER BY updatedAt DESC").compactMap { row -> ChatHit? in
                let threadId: String = row["threadId"]
                guard matched.contains(threadId), scope?.contains(threadId: threadId, cwd: row["cwd"]) != false else { return nil }
                return ChatHit(threadId: threadId, title: row["title"], cwd: row["cwd"], updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
                               titleMatched: titled.contains(threadId), matches: [])
            }
            // Stable: within each group the newest chat stays first.
            hits = Array((hits.filter(\.titleMatched) + hits.filter { !$0.titleMatched }).prefix(limit))
            if hits.isEmpty { return [] }
            let positions = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($1.threadId, $0) })
            let rows = try Row.fetchAll(db, sql: """
                SELECT threadId, messageId, role, at, snippet(chatText, 4, ?, ?, '…', 14) AS snippet
                FROM chatText
                WHERE chatText MATCH ? AND role != 'title' AND threadId IN (\(databaseQuestionMarks(count: hits.count)))
                ORDER BY bm25(chatText) LIMIT 600
                """, arguments: StatementArguments([Self.highlightStart, Self.highlightEnd, anyWord] + hits.map(\.threadId)))
            for row in rows {
                let threadId: String = row["threadId"]
                guard let index = positions[threadId], hits[index].matches.count < perChat, let role = ChatText.Role(rawValue: row["role"]) else { continue }
                hits[index].matches.append(ChatMatch(messageId: row["messageId"], role: role, at: Self.messageDate(row), snippet: row["snippet"]))
            }
            return hits
        }
    }

    /// Whole messages relevant to a question: any meaningful word may match. At most `perChat` from one chat.
    public func passages(for question: String, limit: Int = 8, perChat: Int = 3, in scope: ChatScope? = nil) throws -> [ChatPassage] {
        guard let match = Self.matchQuery(question, anyWord: true) else { return [] }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.threadId, c.title, c.cwd, chatText.messageId, chatText.role, chatText.at, chatText.text
                FROM chatText JOIN chats c ON c.threadId = chatText.threadId
                WHERE chatText MATCH ? AND chatText.role != 'title' ORDER BY bm25(chatText) LIMIT 200
                """, arguments: [match])
            var result: [ChatPassage] = [], perThread: [String: Int] = [:]
            for row in rows where result.count < limit {
                let threadId: String = row["threadId"]
                guard scope?.contains(threadId: threadId, cwd: row["cwd"]) != false,
                      perThread[threadId, default: 0] < perChat, let role = ChatText.Role(rawValue: row["role"]) else { continue }
                perThread[threadId, default: 0] += 1
                result.append(ChatPassage(threadId: threadId, title: row["title"], messageId: row["messageId"], role: role,
                                          at: Self.messageDate(row), text: row["text"]))
            }
            return result
        }
    }

    /// A chat's indexed messages in order, for previewing it without Codex.
    public func messages(threadId: String) throws -> [ChatText] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT messageId, role, at, text FROM chatText WHERE threadId = ? AND role != 'title' ORDER BY rowid", arguments: [threadId]).compactMap { row in
                guard let role = ChatText.Role(rawValue: row["role"]) else { return nil }
                return ChatText(messageId: row["messageId"], role: role, at: Self.messageDate(row), text: row["text"])
            }
        }
    }

    /// When a message was sent. The index keeps it in seconds, and nil when Codex gave no time.
    private static func messageDate(_ row: Row) -> Date? {
        let at: Double? = row["at"]
        return at.map(Date.init(timeIntervalSince1970:))
    }

    // MARK: Queries

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "did", "do", "does", "for", "from", "had", "has", "have",
        "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our", "so", "that", "the", "their",
        "them", "then", "there", "these", "this", "to", "was", "we", "were", "what", "when", "where", "which", "who", "why",
        "will", "with", "you", "your", "about", "again", "any", "all", "should", "would", "could", "tell", "know", "remember"
    ]

    /// The meaningful words of a question, lowercased and without punctuation.
    public static func keywords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// Every word must match by prefix, or, for questions, any meaningful word.
    static func matchQuery(_ text: String, anyWord: Bool, joiner: String? = nil) -> String? {
        let words = anyWord ? keywords(text) : text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: joiner ?? (anyWord ? " OR " : " AND "))
    }
}
