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
                return CodexConversationMessage(id: messageId, role: .codex, text: text,
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
            return CodexConversationMessage(id: messageId, role: delegated == nil ? .user : .automation, text: text, attachments: attachments)
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
    public static func render(_ text: String) -> String {
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

    /// What clicking a link in agent-written text may do. The text is untrusted: web and mail links open, files are only
    /// shown in Finder, Codex and Claude chat links open by their ID alone, and everything else does nothing.
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

    /// A local picture agent text may show: a regular file, not a link, inside one of `roots`. Nothing on the network ever loads.
    public static func localImage(_ url: URL, within roots: [URL]) -> URL? {
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
        try write { db in
            guard try Self.isLinked(db, taskId: taskId, threadId: conversation.threadId) else { throw StoreError.conflict }
            try Self.insertConversation(db, taskId: taskId, conversation: conversation, fetchedAt: fetchedAt)
        }
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
            var task = FaciendaTask(title: originalRequest, state: .needsMe,
                nextAction: "Review the latest \(provider.name) answer", returnAt: nil, cwd: cwd.isEmpty ? nil : cwd)
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
        let payload = String(decoding: try JSONEncoder().encode(conversation), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO threadSnapshots(taskId, threadId, payload, fetchedAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(taskId, threadId) DO UPDATE SET payload = excluded.payload, fetchedAt = excluded.fetchedAt
            WHERE excluded.fetchedAt >= threadSnapshots.fetchedAt
            """, arguments: [taskId, conversation.threadId, payload, fetchedAt])
    }
}
