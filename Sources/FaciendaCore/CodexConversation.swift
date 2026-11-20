import Foundation
import GRDB

/// The public conversation in server order. Message text is never summarized.
public struct CodexConversation: Codable, Equatable, Sendable {
    public let threadId: String
    public let title: String
    public let turns: [CodexConversationTurn]

    public init(threadId: String, title: String, turns: [CodexConversationTurn]) {
        self.threadId = threadId; self.title = title; self.turns = turns
    }

    /// The lifecycle status the last turn proves, or nil while it may still be running. A chat loaded
    /// by another Codex app reads its unfinished turn as `interrupted`, so that is not proof it stopped.
    public var settledStatus: String? {
        switch turns.last?.status {
        case "completed": "idle"
        case "failed": "error"
        default: nil
        }
    }

    /// What this chat proves about its task when it works in another Codex app, or nil when nothing new.
    /// A running task settles once the last turn finished. Any other open task runs again when that turn is
    /// unfinished and started after the task last changed, so the agent has not reported on it yet.
    public func observedStatus(for task: FaciendaTask) -> String? {
        if task.state == .running { return settledStatus }
        guard task.state.isOpen, settledStatus == nil, let started = turns.last?.startedAt, started > task.updatedAt else { return nil }
        return "active"
    }

    /// When the chat last moved: the newest turn's end, or its start while it runs, from the user or the agent.
    public var lastMessageAt: Date? { turns.compactMap { $0.completedAt ?? $0.startedAt }.max() }

    /// What Facienda keeps of a chat: the messages and the requests other chats delegated, with every turn's status
    /// and times. Commands, tool calls, file changes and generated pictures stay in the agent's own chat; they are
    /// never shown here and made up nine tenths of what was saved.
    public var kept: CodexConversation {
        CodexConversation(threadId: threadId, title: title, turns: turns.map { turn in
            CodexConversationTurn(id: turn.id, status: turn.status, startedAt: turn.startedAt, completedAt: turn.completedAt, error: turn.error,
                items: turn.items.filter { ["agentMessage", "userMessage"].contains($0["type"].string ?? "") || $0.delegatedInput != nil })
        })
    }

    public func containsDelivery(_ dispatchId: String) -> Bool {
        turns.contains { turn in
            turn.items.contains { item in
                let text: String?
                if item["type"].string == "userMessage" {
                    text = (item["content"].array ?? []).filter { $0["type"].string == "text" }
                        .compactMap { $0["text"].string }.joined(separator: "\n")
                } else { text = item.delegatedInput }
                return text?.hasPrefix("Facienda dispatch: " + dispatchId + "\n") == true
            }
        }
    }
}

public struct CodexConversationTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let status: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let error: JSONValue
    public let items: [JSONValue]

    public init(id: String, status: String, startedAt: Date?, completedAt: Date?, error: JSONValue, items: [JSONValue]) {
        self.id = id; self.status = status; self.startedAt = startedAt
        self.completedAt = completedAt; self.error = error; self.items = items
    }
}

/// Reading-view messages. The cached server items remain unchanged.
public struct CodexConversationMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, codex, automation }
    public let id: String
    public let role: Role
    public let text: String
    public let isCommentary: Bool
    public let attachments: [JSONValue]

    public init(id: String, role: Role, text: String, isCommentary: Bool = false, attachments: [JSONValue] = []) {
        self.id = id; self.role = role; self.text = text
        self.isCommentary = isCommentary; self.attachments = attachments
    }
}

extension CodexConversationTurn {
    public func messages(originalRequest: String, dispatches: [NativeDispatch]) -> [CodexConversationMessage] {
        var messages: [CodexConversationMessage] = items.enumerated().compactMap { index, item in
            let messageId = "\(id):\(item["id"].string ?? String(index))"
            if item["type"].string == "agentMessage", let text = item["text"].string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CodexConversationMessage(id: messageId, role: .codex, text: Self.withoutHeartbeat(text),
                    isCommentary: item["phase"].string == "commentary")
            }
            let delegated = item.delegatedInput
            guard item["type"].string == "userMessage" || delegated != nil else { return nil }
            let content = item["content"].array ?? []
            let text = delegated ?? content.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
            let attachments = content.filter { $0["type"].string != "text" }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return nil }
            // Native delivery wraps the user's request in runner instructions and memory.
            // Use its persisted request, never display that envelope as if the user wrote it.
            let prefix = "Facienda dispatch: "
            if let firstLine = text.components(separatedBy: "\n").first, firstLine.hasPrefix(prefix),
               UUID(uuidString: String(firstLine.dropFirst(prefix.count))) != nil {
                let dispatchId = String(firstLine.dropFirst(prefix.count))
                if let dispatch = dispatches.first(where: { $0.id == dispatchId }) {
                    if dispatch.kind == "check" || dispatch.kind == "assess" {
                        return CodexConversationMessage(id: messageId, role: .automation,
                            text: dispatch.kind == "check" ? "Scheduled check" : "Prerequisite check")
                    }
                    return CodexConversationMessage(id: messageId, role: .user,
                        text: dispatch.message ?? originalRequest, attachments: attachments)
                }
                // Imported deliveries can lack local queue records. Keep their complete
                // instructions inspectable without guessing which text was user-authored.
                return CodexConversationMessage(id: messageId, role: .automation, text: text)
            }
            if delegated != nil { return CodexConversationMessage(id: messageId, role: .automation, text: text, attachments: attachments) }
            // A Codex automation wakes its chat with its own instructions.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<heartbeat>") {
                return CodexConversationMessage(id: messageId, role: .automation, text: "Automation run")
            }
            // The agent apps write into the user's turn too: a summary that carries a long session on, reminders,
            // the page open in the browser. Only the user's own words are shown as theirs.
            let words = MemoryUserMessages.words(in: text) ?? ""
            guard !words.isEmpty || !attachments.isEmpty else { return nil }
            return CodexConversationMessage(id: messageId, role: .user, text: words, attachments: attachments)
        }
        // Older workers were created by another dispatcher. Their exact task request
        // is saved locally, while Codex exposes the dispatcher prompt as a tool item.
        if items.contains(where: { $0["name"].string == "create_thread" && $0.delegatedInput != nil }),
           !messages.contains(where: { $0.role == .user }), !originalRequest.isEmpty {
            messages.insert(CodexConversationMessage(id: id + ":original-request", role: .user, text: originalRequest), at: 0)
        }
        return messages
    }
}

extension CodexConversationTurn {
    /// A Codex automation ends its answer with a block for the app that woke it. What that block tells the user is
    /// the answer above it already, or else its own message.
    static func withoutHeartbeat(_ text: String) -> String {
        guard text.contains("<heartbeat>") else { return text }
        let rest = text.replacing(/<heartbeat>.*?<\/heartbeat>/.dotMatchesNewlines(), with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { return rest }
        let message = text.firstMatch(of: /<message>(.*?)<\/message>/.dotMatchesNewlines()).map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) }
        return message.flatMap { $0.isEmpty ? nil : $0 } ?? text
    }
}

private extension JSONValue {
    var delegatedInput: String? {
        guard self["type"].string == "functionCallOutput", self["namespace"].string == "codex_app",
              ["create_thread", "send_message_to_thread"].contains(self["name"].string ?? ""),
              let output = self["output"].string, output.hasPrefix("<codex_delegation>"),
              output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("</codex_delegation>"),
              let start = output.range(of: "<input>"), let end = output.range(of: "</input>", options: .backwards),
              start.upperBound <= end.lowerBound else { return nil }
        return String(output[start.upperBound..<end.lowerBound])
    }
}

/// Adapts Codex's native file references for the Markdown renderer without altering
/// stored message text or the source document's destination.
public enum CodexMarkdown {
    /// `folders` are where the task works: a file the text names by a path relative to one of them, in code or as
    /// a link, becomes a link to it, as does an absolute path to a file that exists. Code blocks stay as written.
    public static func render(_ text: String, folders: [URL] = []) -> String {
        let cited = citations(text)
        return folders.isEmpty ? cited : linkingFiles(cited, folders: folders)
    }

    private static func citations(_ text: String) -> String {
        text.replacing(/:codex-file-citation\{path="((?:\\.|[^"\\])+)"(?:\s+[^}]*)?\}/) { match in
            let quotedPath = "\"" + String(match.output.1) + "\""
            guard let path = try? JSONDecoder().decode(String.self, from: Data(quotedPath.utf8)), path.hasPrefix("/") else {
                return String(match.output.0)
            }
            let url = URL(fileURLWithPath: path)
            var label = url.lastPathComponent
            for character in ["\\", "[", "]", "*", "_", "`"] {
                label = label.replacingOccurrences(of: character, with: "\\" + character)
            }
            return "[" + label + "](<" + url.absoluteString + ">)"
        }
    }

    /// Paths in code, in plain text or as a link's address. Links come first, so a path is never linked twice.
    private static let fileMention = try! NSRegularExpression(pattern: #"(\[[^\]\n]*\]\(\s*(<[^>\n]*>|[^)\s]+)[^)\n]*\))|(`+)([^`\n]+?)\3(?!`)|(?<![\w/:@.~\-])((?:~/|\.{1,2}/|/)?[\w@+.\-]+(?:/[\w@+.\-]+)*\.[A-Za-z][A-Za-z0-9]{0,7})(?![\w/])"#)

    private static func linkingFiles(_ text: String, folders: [URL]) -> String {
        // Fenced code is shown as written; only the prose between fences is read for paths.
        var fenced = false
        return text.components(separatedBy: "\n").map { line in
            let start = line.trimmingCharacters(in: .whitespaces)
            if start.hasPrefix("```") || start.hasPrefix("~~~") { fenced.toggle(); return line }
            return fenced ? line : linkingFiles(line: line, folders: folders)
        }.joined(separator: "\n")
    }

    private static func linkingFiles(line: String, folders: [URL]) -> String {
        var line = line
        for match in fileMention.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let whole = Range(match.range, in: line) else { continue }
            func group(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) } }
            let link: String
            if group(1) != nil {
                // A link to a relative path leads nowhere as it stands; it leads to the file in the task's folder.
                guard let raw = group(2), let address = Range(match.range(at: 2), in: line) else { continue }
                let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                guard !path.hasPrefix("/"), !path.hasPrefix("#"), URL(string: path)?.scheme == nil,
                      let file = file(named: path, in: folders) else { continue }
                line.replaceSubrange(address, with: "<" + file.absoluteString + ">")
                continue
            } else if let code = group(4) {
                // Only code that is a path and nothing more, as agents write a file they made.
                guard let file = file(named: code.trimmingCharacters(in: .whitespaces), in: folders) else { continue }
                // A link inside a link's own text is not a link: leave code that already stands in one alone.
                if whole.lowerBound > line.startIndex, line[line.index(before: whole.lowerBound)] == "[" { continue }
                link = "[" + String(line[whole]) + "](<" + file.absoluteString + ">)"
            } else if let bare = group(5) {
                // In plain text only a path with a folder in it, or a page, is looked for: not every word with a dot.
                guard bare.contains("/") || [".html", ".htm"].contains(where: bare.lowercased().hasSuffix),
                      let file = file(named: bare, in: folders) else { continue }
                var label = bare
                for character in ["\\", "[", "]", "*", "_", "`"] { label = label.replacingOccurrences(of: character, with: "\\" + character) }
                link = "[" + label + "](<" + file.absoluteString + ">)"
            } else { continue }
            line.replaceSubrange(whole, with: link)
        }
        return line
    }

    /// The regular file a path in agent text names: an absolute one as it stands, a relative one in the first of
    /// `folders` that has it. A trailing line number, as in `View.swift:42`, is not part of the name.
    static func file(named written: String, in folders: [URL]) -> URL? {
        let path = written.replacing(/:\d+(?::\d+)?$/, with: "")
        guard !path.isEmpty, !path.contains("://") else { return nil }
        let candidates: [URL]
        if path.hasPrefix("/") { candidates = [URL(fileURLWithPath: path)] }
        else if path.hasPrefix("~/") { candidates = [FileManager.default.homeDirectoryForCurrentUser.appending(path: String(path.dropFirst(2)))] }
        else { candidates = folders.map { $0.appending(path: path) } }
        return candidates.lazy.map(\.standardizedFileURL).first { file in
            (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// What clicking a link in agent-written text may do. The text is untrusted: web and mail links open, files are only
    /// shown in Finder (or, for a page in the task's folders, offline in Facienda: see `localPage`), Codex and Claude
    /// chat links open by their ID alone, and everything else does nothing.
    public enum LinkAction: Equatable, Sendable {
        case web(URL), mail(URL), reveal(String), codexThread(String), claudeSession(String), ignore
    }

    public static func action(for url: URL) -> LinkAction {
        switch url.scheme?.lowercased() {
        case nil:
            // A bare absolute path, as a citation or `[x](/path)` gives.
            let path = url.path(percentEncoded: false)
            return path.hasPrefix("/") ? .reveal(URL(fileURLWithPath: path).standardizedFileURL.path) : .ignore
        case "file":
            guard [nil, "", "localhost"].contains(url.host()?.lowercased()) else { return .ignore }
            let path = url.path(percentEncoded: false)
            return path.hasPrefix("/") ? .reveal(URL(fileURLWithPath: path).standardizedFileURL.path) : .ignore
        case "http", "https":
            return url.host()?.isEmpty == false && url.user == nil && url.password == nil ? .web(url) : .ignore
        case "mailto":
            return .mail(url)
        case "codex":
            // Only the form Facienda itself writes: codex://threads/<id>.
            guard ["threads", "thread"].contains(url.host()?.lowercased()), url.query == nil, url.fragment == nil else { return .ignore }
            let id = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !id.isEmpty && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) ? .codexThread(id) : .ignore
        case "claude":
            // Only the form Facienda itself writes: claude://code/continue?session=local_<uuid>.
            guard url.host()?.lowercased() == "code", url.path == "/continue",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value,
                  id.hasPrefix("local_"), UUID(uuidString: String(id.dropFirst("local_".count))) != nil else { return .ignore }
            return .claudeSession(id.lowercased())
        default:
            return .ignore
        }
    }

    /// Whether a web or mail link should be confirmed before it opens: unless every place the text shows it, it shows
    /// its own address (a bare URL, or link text that is the URL or its host), the reader cannot see where it leads.
    public static func linkNeedsConfirmation(_ url: URL, in markdown: String) -> Bool {
        let target = url.absoluteString
        func same(_ raw: String) -> Bool {
            let raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            return raw == target || URL(string: raw)?.absoluteString == target
        }
        var shown: [String] = []
        let range = NSRange(markdown.startIndex..., in: markdown)
        let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(\s*(<[^>\n]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#)
        var bare = markdown
        for match in linkPattern.matches(in: markdown, range: range).reversed() {
            guard let text = Range(match.range(at: 1), in: markdown), let raw = Range(match.range(at: 2), in: markdown),
                  let whole = Range(match.range, in: bare) else { continue }
            if same(String(markdown[raw])) { shown.append(String(markdown[text])) }
            bare.replaceSubrange(whole, with: " ")
        }
        // Reference definitions hide their address behind the reference's text.
        let references = try! NSRegularExpression(pattern: #"(?m)^\s{0,3}\[[^\]\n]+\]:\s*(\S+)"#)
        for match in references.matches(in: bare, range: NSRange(bare.startIndex..., in: bare)) {
            if let raw = Range(match.range(at: 1), in: bare), same(String(bare[raw])) { return true }
        }
        let plain = try! NSRegularExpression(pattern: #"(?:https?://|mailto:)[^\s<>()\]]+"#)
        let barePlain = plain.matches(in: bare, range: NSRange(bare.startIndex..., in: bare)).contains { match in
            Range(match.range, in: bare).map { same(String(bare[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\""))) } ?? false
        }
        let host = url.host()?.lowercased() ?? ""
        let honest = shown.allSatisfy { text in
            let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "")
            return same(text) || (!host.isEmpty && [host, "www." + host].contains(text.lowercased())) || text == url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return !(honest && (barePlain || !shown.isEmpty))
    }

    /// A page agent text links to that Facienda may show itself: a local `.html` file or a picture inside one of
    /// `roots`, shown with nothing loaded from the network. Files elsewhere are only revealed in Finder, like any other.
    public static func localPage(_ url: URL, within roots: [URL]) -> URL? {
        guard let file = localFile(url, within: roots), (["html", "htm"] + pictureTypes).contains(file.pathExtension.lowercased()) else { return nil }
        return file
    }

    /// Pictures a web view shows as they are, with nothing in them that runs.
    static let pictureTypes = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    /// A local picture agent text may show: a regular file, not a link, inside one of `roots`. Nothing on the network ever loads.
    public static func localImage(_ url: URL, within roots: [URL]) -> URL? { localFile(url, within: roots) }

    private static func localFile(_ url: URL, within roots: [URL]) -> URL? {
        guard case let .reveal(path) = action(for: url), !roots.isEmpty else { return nil }
        let file = URL(fileURLWithPath: path)
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard roots.contains(where: { root in
            let root = root.resolvingSymlinksInPath().standardizedFileURL.path
            return root != "/" && resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else { return nil }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true else { return nil }
        return URL(fileURLWithPath: resolved)
    }
}

public struct CodexConversationSnapshot: Sendable {
    public let conversation: CodexConversation
    public let fetchedAt: Date
}

extension FaciendaStore {
    public func conversationSnapshot(taskId: String, threadId: String) throws -> CodexConversationSnapshot? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT s.* FROM threadSnapshots s JOIN threadLinks l ON l.taskId = s.taskId AND l.codexThreadId = s.threadId WHERE s.taskId = ? AND s.threadId = ?", arguments: [taskId, threadId]) else { return nil }
            let payload: String = row["payload"]
            return CodexConversationSnapshot(conversation: try JSONDecoder().decode(CodexConversation.self, from: Data(payload.utf8)), fetchedAt: row["fetchedAt"])
        }
    }

    public func saveConversation(taskId: String, conversation: CodexConversation, fetchedAt: Date = Date()) throws {
        let answer: String? = try write { db in
            guard try Self.isLinked(db, taskId: taskId, threadId: conversation.threadId) else { throw StoreError.conflict }
            try Self.insertConversation(db, taskId: taskId, conversation: conversation, fetchedAt: fetchedAt)
            return try Self.recordAnswer(db, taskId: taskId, conversation: conversation)
        }
        // The documents the answer links to are offered to the task's workspace, as for an answer the agent saved.
        if let answer { _ = try? proposeSources(fromAnswer: answer, taskId: taskId) }
    }

    /// The agent answers in its own chat, so a finished turn's last answer is the task's result: what the row's line,
    /// the next steps and memory are read from. An answer the agent saved itself during that turn stands instead, a
    /// scheduled check reports through its own tool, and what a chat said before its task existed is no result of it.
    /// Returns the answer when it was new.
    static func recordAnswer(_ db: Database, taskId: String, conversation: CodexConversation) throws -> String? {
        guard let turn = conversation.turns.last, turn.status == "completed", let ended = turn.completedAt,
              let task = try FaciendaTask.fetchOne(db, key: taskId), task.state.isOpen, ended > task.createdAt else { return nil }
        let dispatches = try NativeDispatch.filter(Column("taskId") == taskId).fetchAll(db)
        let messages = turn.messages(originalRequest: task.title, dispatches: dispatches)
        guard !messages.contains(where: { $0.role == .automation }),
              let answer = messages.last(where: { $0.role == .codex && !$0.isCommentary })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else { return nil }
        let known = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE taskId = ? AND kind = 'codex.result' AND at >= ?",
                                     arguments: [taskId, turn.startedAt ?? ended]) ?? 0
        guard known == 0 else { return nil }
        try TaskEvent(taskId: taskId, threadId: conversation.threadId, source: .app, kind: "codex.result", payload: answer, verified: false, at: ended).insert(db)
        return answer
    }

    /// Import is a single transaction; it never queues work or invents a deadline.
    /// `cliSessionId` names a Claude session's transcript; Codex chats have none.
    public func importThread(originalRequest: String, title: String, cwd: String, conversation: CodexConversation,
                             provider: AgentProvider = .codex, cliSessionId: String? = nil) throws -> FaciendaTask {
        let threadId = conversation.threadId
        guard !originalRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !threadId.isEmpty else { throw StoreError.invalid("The chat's original request and identity are required.") }
        return try write { db in
            if let existing = try ThreadLink.fetchOne(db, sql: "SELECT * FROM threadLinks WHERE codexThreadId = ?", arguments: [threadId]) {
                guard let task = try FaciendaTask.fetchOne(db, key: existing.taskId) else { throw StoreError.notFound }
                return task
            }
            // The user imports a chat they started themselves, so its agent goes ahead like on any task they make.
            var task = FaciendaTask(title: originalRequest, state: .needsMe,
                nextAction: "Review the latest \(provider.name) answer", returnAt: nil, automationScope: .autonomous, cwd: cwd.isEmpty ? nil : cwd)
            if provider == .claude { task.workerProvider = .claude }
            if !title.isEmpty { task.displayTitle = title; task.displayTitleSource = "import" }
            task.workspaceId = workspaceID
            try task.insert(db)
            try TaskEvent(taskId: task.id, source: .user, kind: "task.created", payload: originalRequest).insert(db)
            try ThreadLink(taskId: task.id, codexThreadId: threadId, title: title, provider: provider).insert(db)
            if provider == .claude {
                // A session started outside Facienda keeps the model it has.
                try ClaudeSession(threadId: threadId, taskId: task.id, cliSessionId: cliSessionId, cwd: cwd.isEmpty ? nil : cwd, linkedAt: Date(),
                                  model: nil, effort: nil, fast: false, configureState: "skipped").save(db)
            }
            try TaskEvent(taskId: task.id, threadId: threadId, source: .user, kind: "thread.imported").insert(db)
            try Self.insertConversation(db, taskId: task.id, conversation: conversation, fetchedAt: Date())
            return task
        }
    }

    private static func insertConversation(_ db: Database, taskId: String, conversation: CodexConversation, fetchedAt: Date) throws {
        let payload = String(decoding: try JSONEncoder().encode(conversation.kept), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO threadSnapshots(taskId, threadId, payload, fetchedAt, lastMessageAt, chatEnd) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(taskId, threadId) DO UPDATE SET payload = excluded.payload, fetchedAt = excluded.fetchedAt,
              lastMessageAt = excluded.lastMessageAt, chatEnd = excluded.chatEnd
            WHERE excluded.fetchedAt >= threadSnapshots.fetchedAt
            """, arguments: [taskId, conversation.threadId, payload, fetchedAt, conversation.lastMessageAt, try chatEnd(db, taskId: taskId, conversation: conversation)])
    }

    /// When each task's chats last moved, by task ID. Read beside the snapshot, so the board never decodes whole chats.
    public func lastMessages() throws -> [String: Date] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.taskId AS taskId, MAX(s.lastMessageAt) AS at FROM threadSnapshots s
                JOIN threadLinks l ON l.taskId = s.taskId AND l.codexThreadId = s.threadId
                JOIN tasks t ON t.id = s.taskId
                WHERE s.lastMessageAt IS NOT NULL \(workspaceID == nil ? "" : "AND t.workspaceId = ?")
                GROUP BY s.taskId
                """, arguments: StatementArguments(workspaceID.map { [$0] } ?? []))
            return Dictionary(rows.compactMap { row in (row["at"] as Date?).map { (row["taskId"] as String, $0) } }, uniquingKeysWith: max)
        }
    }

    static func registerLastMessages(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("snapshot_last_message") { db in
            try db.execute(sql: "ALTER TABLE threadSnapshots ADD COLUMN lastMessageAt DATETIME")
            try db.execute(sql: lastMessageBackfill)
        }
    }

    /// Chats saved before only messages were kept shrink once. A row that does not read as a chat stays as it is.
    static func registerSlimSnapshots(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("slim_thread_snapshots") { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT taskId, threadId, payload FROM threadSnapshots")
            var slimmed: [(String, String, String)] = []
            while let row = try rows.next() {
                let payload: String = row["payload"]
                guard let conversation = try? JSONDecoder().decode(CodexConversation.self, from: Data(payload.utf8)) else { continue }
                let kept = String(decoding: try JSONEncoder().encode(conversation.kept), as: UTF8.self)
                if kept.utf8.count < payload.utf8.count { slimmed.append((row["taskId"], row["threadId"], kept)) }
            }
            for (taskId, threadId, payload) in slimmed {
                try db.execute(sql: "UPDATE threadSnapshots SET payload = ? WHERE taskId = ? AND threadId = ?", arguments: [payload, taskId, threadId])
            }
        }
    }

    /// Saved chats keep their turns' times as seconds since 2001; this reads them once, in GRDB's date format.
    static let lastMessageBackfill = """
        UPDATE threadSnapshots SET lastMessageAt = (
          SELECT strftime('%Y-%m-%d %H:%M:%f', 978307200 + MAX(coalesce(json_extract(value, '$.completedAt'), json_extract(value, '$.startedAt'))), 'unixepoch')
          FROM json_each(payload, '$.turns'))
        """
}
