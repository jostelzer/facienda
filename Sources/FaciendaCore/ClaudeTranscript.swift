import Foundation

/// Reads a Claude Code session's transcript into the same public conversation Codex chats produce:
/// the user's messages and Claude's replies, never tool calls, tool output or thinking.
public enum ClaudeTranscript {
    /// Where Claude Code keeps one folder of transcripts per project.
    public static var projectsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (environment ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")).appending(path: "projects")
    }

    /// Claude Code names a project's folder after its path, with every character but ASCII letters and digits replaced by "-".
    public static func projectFolderName(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Finds a session's transcript by its Claude Code session ID. Only UUID-shaped IDs are looked up.
    public static func locate(cliSessionId: String, cwd: String?, in root: URL = projectsDirectory) -> URL? {
        guard UUID(uuidString: cliSessionId) != nil else { return nil }
        let name = cliSessionId.lowercased() + ".jsonl"
        if let cwd {
            for path in [cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path] {
                let guess = root.appending(path: projectFolderName(path)).appending(path: name)
                if FileManager.default.fileExists(atPath: guess.path) { return guess }
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func read(_ url: URL, threadId: String, fallbackTitle: String = "Claude session") throws -> CodexConversation {
        let data = try Data(contentsOf: url)
        return conversation(from: data, threadId: threadId, fallbackTitle: fallbackTitle)
    }

    /// How long a background job keeps a session running after its turn ended, while the job has not reported back. A
    /// session can end its turn and wait for a build it started; one that leaves a server running, or is quit, never
    /// hears back.
    public static let shellWait: TimeInterval = 20 * 60
    public static let agentWait: TimeInterval = 60 * 60

    private struct Turn {
        var id: String
        var startedAt: Date?
        var completedAt: Date?
        var items: [JSONValue] = []
        var interrupted = false
    }

    public static func conversation(from data: Data, threadId: String, fallbackTitle: String = "Claude session") -> CodexConversation {
        reading(from: data, threadId: threadId, fallbackTitle: fallbackTitle).conversation
    }

    /// The conversation, and while the session waits on background jobs it started, when the last of them stops counting.
    /// A turn the session ended is finished even while such a job runs: its answer is the user's to read now, not once
    /// the job reports back. The job's notice wakes the session into a turn of its own.
    /// `replies` are the words Facienda holds as the user's replies to this task. A runner has sent them on bare,
    /// without the delivery's marker; only by that record is another session's message the user's.
    public static func reading(from data: Data, threadId: String, fallbackTitle: String = "Claude session", now: Date = Date(), replies: [String] = [])
        -> (conversation: CodexConversation, waitingUntil: Date?) {
        let replies = Set(replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let decoder = JSONDecoder()
        var turns: [Turn] = []
        var title: String?
        var lastWasAssistantEnd = false
        var jobs: [String: Date] = [:]
        /// A finished job woke the session after its turn had ended; what it writes from here is a new turn.
        var woke: (id: String, at: Date?)?
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let entry = try? decoder.decode(JSONValue.self, from: Data(line)) else { continue }
            let type = entry["type"].string ?? ""
            if type == "custom-title", let custom = entry["customTitle"].string, !custom.isEmpty { title = custom; continue }
            // A job that finishes while a turn runs is queued into that turn rather than waking the session.
            let queued = entry["attachment"]
            if type == "attachment", queued["type"].string == "queued_command", queued["commandMode"].string == "task-notification" {
                for id in finishedJobs(queued["prompt"].string ?? "") { jobs[id] = nil }
                continue
            }
            // Claude Code marks another session's message as meta too, and the runner's relays of the user's replies come
            // that way; they are sorted from other sessions' messages below.
            let relayed = entry["origin"]["kind"].string == "peer"
            guard type == "user" || type == "assistant", entry["isSidechain"].bool != true, entry["isMeta"].bool != true || relayed else { continue }
            // The summary that carries a long session on is Claude's own, and the turn it interrupts goes on after it.
            if type == "user", entry["isCompactSummary"].bool == true || entry["isVisibleInTranscriptOnly"].bool == true { continue }
            let message = entry["message"]
            let at = entry["timestamp"].string.flatMap(date)
            let uuid = entry["uuid"].string ?? UUID().uuidString
            if type == "user" {
                let result = entry["toolUseResult"]
                if let at, let id = result["backgroundTaskId"].string { jobs[id] = at.addingTimeInterval(shellWait) }
                // Subagents and workflows started in the background, or a stopped subagent sent on again.
                let launched = result["status"].string == "async_launched" ? result["agentId"].string ?? result["taskId"].string : nil
                if let at, let id = launched ?? result["resumedAgentId"].string { jobs[id] = at.addingTimeInterval(agentWait) }
                if let stopped = result["task_id"].string { jobs[stopped] = nil }
                // A finished job wakes the session, which works on from there.
                if entry["origin"]["kind"].string == "task-notification", let text = message["content"].string {
                    for id in finishedJobs(text) { jobs[id] = nil }
                    if !turns.isEmpty {
                        if lastWasAssistantEnd { woke = (uuid, at) }
                        lastWasAssistantEnd = false
                    }
                    continue
                }
                guard let text = userText(message["content"]) else {
                    // Tool output keeps the turn running.
                    if message["content"].array?.contains(where: { $0["type"].string == "tool_result" }) == true { lastWasAssistantEnd = false }
                    continue
                }
                if text.hasPrefix("[Request interrupted") {
                    // Stopped before the woken session wrote anything: the turn that ended before it stays answered.
                    if woke == nil, !turns.isEmpty { turns[turns.count - 1].interrupted = true }
                    woke = nil
                    lastWasAssistantEnd = true
                    continue
                }
                guard let shown = visibleUserText(text, origin: entry["origin"]["kind"].string, replies: replies) else { continue }
                woke = nil
                var turn = Turn(id: uuid, startedAt: at, completedAt: nil)
                turn.items.append(.object(["type": .string("userMessage"), "id": .string(uuid),
                                           "content": .array([.object(["type": .string("text"), "text": .string(shown)])])]))
                turns.append(turn)
                lastWasAssistantEnd = false
            } else {
                let blocks = message["content"].array ?? []
                if let start = woke { turns.append(Turn(id: start.id, startedAt: start.at)); woke = nil }
                if turns.isEmpty { turns.append(Turn(id: uuid, startedAt: at)) }
                for (index, block) in blocks.enumerated() where block["type"].string == "text" {
                    guard let text = block["text"].string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    turns[turns.count - 1].items.append(.object(["type": .string("agentMessage"), "id": .string("\(uuid):\(index)"), "text": .string(text)]))
                }
                if let at { turns[turns.count - 1].completedAt = at }
                let stop = message["stop_reason"].string
                lastWasAssistantEnd = stop == nil ? blocks.allSatisfy { $0["type"].string != "tool_use" } : stop != "tool_use"
            }
        }
        let waitingUntil = jobs.values.filter { $0 > now }.max()
        let result = turns.enumerated().map { index, turn -> CodexConversationTurn in
            // Every reply before the turn's last is a progress update.
            let agentIndices = turn.items.indices.filter { turn.items[$0]["type"].string == "agentMessage" }
            var items = turn.items
            for index in agentIndices.dropLast() {
                if case .object(var fields) = items[index] { fields["phase"] = .string("commentary"); items[index] = .object(fields) }
            }
            let isLast = index == turns.count - 1
            let status = turn.interrupted ? "interrupted" : (isLast && !lastWasAssistantEnd ? "inProgress" : "completed")
            return CodexConversationTurn(id: turn.id, status: status, startedAt: turn.startedAt,
                                         completedAt: status == "completed" ? turn.completedAt : nil, error: .null, items: items)
        }
        return (CodexConversation(threadId: threadId, title: title ?? fallbackTitle, turns: result), waitingUntil)
    }

    /// The background jobs a task notification says have finished, failed or been stopped.
    private static func finishedJobs(_ text: String) -> [String] {
        text.components(separatedBy: "<task-id>").dropFirst().compactMap { part in
            part.range(of: "</task-id>").map { String(part[..<$0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    /// Plain text a person or another session wrote. Tool output and images alone are not messages.
    private static func userText(_ content: JSONValue) -> String? {
        if let text = content.string { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
        guard let blocks = content.array, !blocks.contains(where: { $0["type"].string == "tool_result" }) else { return nil }
        let text = blocks.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The user's own messages, and Facienda's deliveries relayed by its runner. Background-task notices,
    /// reminders, slash commands and other sessions' messages are machinery, not conversation.
    private static func visibleUserText(_ text: String, origin: String?, replies: Set<String>) -> String? {
        if let inner = crossSessionBody(text) {
            return inner.hasPrefix("Facienda dispatch: ") || replies.contains(inner) ? inner : nil
        }
        if text.hasPrefix("Facienda dispatch: ") { return text }
        if let origin, origin != "human" { return nil }
        return MemoryUserMessages.words(in: text)
    }

    private static func crossSessionBody(_ text: String) -> String? {
        guard let open = text.range(of: "<cross-session-message"), let start = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let end = text.range(of: "</cross-session-message>", options: .backwards), start.upperBound <= end.lowerBound else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeSecondDates = ISO8601DateFormatter()
    private static let dateLock = NSLock()
    private static func date(_ text: String) -> Date? {
        dateLock.withLock { fractionalDates.date(from: text) ?? wholeSecondDates.date(from: text) }
    }
}

/// What Facienda knows about the Claude app on this Mac.
public enum ClaudeDesktop {
    /// Where the Claude app keeps its record of each session (`local_<id>.json`), by account and organisation.
    public static var sessionRegistry: URL {
        URL.applicationSupportDirectory.appending(path: "Claude/claude-code-sessions")
    }
    /// Whether the Claude app has adopted the session with this Claude Code session ID.
    public static func sessionExists(cliSessionId: String, registry: URL = sessionRegistry) -> Bool {
        let name = "local_" + cliSessionId.lowercased() + ".json"
        guard let accounts = try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil) else { return false }
        for account in accounts {
            guard let organisations = try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil) else { continue }
            for organisation in organisations where FileManager.default.fileExists(atPath: organisation.appending(path: name).path) { return true }
        }
        return false
    }
    public static func waitForSession(cliSessionId: String, seconds: TimeInterval, registry: URL = sessionRegistry) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if sessionExists(cliSessionId: cliSessionId, registry: registry) { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return sessionExists(cliSessionId: cliSessionId, registry: registry)
    }
    /// The newest Claude Code the app has installed, named in transcripts it adopts.
    public static func cliVersion() -> String {
        let folder = URL.applicationSupportDirectory.appending(path: "Claude/claude-code")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.first?.isNumber == true }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending } ?? "2.1.0"
    }
    /// The permission mode the user's Claude settings give new sessions.
    public static func defaultPermissionMode(settings: URL = ClaudePermissions.settingsURL) -> String {
        guard let data = try? Data(contentsOf: settings), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = (root["permissions"] as? [String: Any])?["defaultMode"] as? String, !mode.isEmpty else { return "default" }
        return mode
    }
}

extension ClaudeTranscript {
    /// Writes a session's opening message where Claude Code keeps transcripts, so the Claude app can adopt the session
    /// as if the user had sent that message there. The entry mirrors what the app itself writes.
    public static func writeOpening(sessionId: String, cwd: String, message: String, title: String, permissionMode: String, version: String, in root: URL = projectsDirectory) throws -> URL {
        let folder = root.appending(path: projectFolderName(cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: sessionId + ".jsonl")
        let timestamp = dateLock.withLock { fractionalDates.string(from: Date()) }
        let entry: [String: Any] = [
            "parentUuid": NSNull(), "isSidechain": false, "promptId": UUID().uuidString.lowercased(), "type": "user",
            "message": ["role": "user", "content": message], "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp,
            "permissionMode": permissionMode, "origin": ["kind": "human"], "promptSource": "sdk", "turnOrigin": "human", "faciendaSource": "dispatch",
            "turnPosition": ["promptIndex": 1, "turnIndex": 1], "userType": "external", "entrypoint": "claude-desktop",
            "cwd": cwd, "sessionId": sessionId, "version": version, "gitBranch": ""
        ]
        let titleEntry: [String: Any] = ["type": "custom-title", "customTitle": title, "sessionId": sessionId]
        var text = ""
        for object in [entry, titleEntry] {
            text += String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n"
        }
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
    /// Removes an opening Facienda wrote, if the app never adopted it. A transcript the app has used is kept.
    public static func removeOpening(sessionId: String, cwd: String, in root: URL = projectsDirectory) {
        let file = root.appending(path: projectFolderName(cwd)).appending(path: sessionId + ".jsonl")
        guard let data = try? Data(contentsOf: file), data.split(separator: UInt8(ascii: "\n")).count <= 2 else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
