import Foundation
import GRDB

public struct MemoryDelivery: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memoryDeliveries"
    public var id: String
    public var spaceId: String
    public var taskId: String
    public var kind: String
    public var text: String
    public var at: Date
}

public struct MemoryAgentContext: Sendable {
    public var index: String
    /// User-written standing rules are never silently cut to fit the discovery budget.
    public var rules: String
}

extension FaciendaStore {
    static func registerMemoryDiscovery(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("memory_discovery") { db in
            try db.execute(sql: "CREATE TABLE memoryDeliveries (id TEXT PRIMARY KEY, spaceId TEXT NOT NULL, taskId TEXT NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, at DATETIME NOT NULL); CREATE INDEX memory_deliveries_space ON memoryDeliveries(spaceId, at)")
        }
    }

    public func findMemoryEntries(_ query: String, spaceID: String, limit: Int = 12) throws -> [MemoryEntry] {
        let words = Set(MemoryEntry.key(query).split(separator: " ").filter { $0.count > 2 }.map(String.init))
        let entries = try memoryEntries(spaceID: spaceID, states: [.live])
        func score(_ entry: MemoryEntry) -> Int {
            let subject = MemoryEntry.key(entry.subject), text = MemoryEntry.key(entry.text)
            return words.reduce(0) { $0 + (subject.contains($1) ? 3 : text.contains($1) ? 1 : 0) }
        }
        return Array(entries.filter { words.isEmpty || score($0) > 0 }.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.updatedAt > $1.updatedAt : a > b
        }.prefix(min(30, max(1, limit))))
    }

    public func memoryAgentContext(taskID: String, query: String) throws -> MemoryAgentContext {
        let space = try memorySpace(forTask: taskID)
        let entries = try memoryEntries(spaceID: space.id, states: [.live])
        let oldRules = try rules(spaceID: space.id).map(\.text)
        let currentRules = entries.filter { $0.shelf == .rules }.map(\.text)
        var seen = Set<String>()
        let ruleText = (oldRules + currentRules).filter { seen.insert(MemoryEntry.key($0)).inserted }.map { "- " + $0 }.joined(separator: "\n")
        var lines = ["Memory: \(space.name). Only live entries apply; proposals wait for you.",
                     "Open: memory_open(id). Search: memory_find(text). Suggest: memory_propose(shelf,text,why)."]
        for shelf in MemoryShelf.allCases {
            let count = entries.filter { $0.shelf == shelf }.count
            lines.append("\(shelf.title): \(count)" + (shelf == .rules && !ruleText.isEmpty ? " · standing rules below" : ""))
        }
        let understanding = try memoryUnderstanding(spaceID: space.id)
        lines.append("Understanding: \(understanding.count) subjects and processes · memory_reflect(question) reasons over evidence.")
        let words = Set(MemoryEntry.key(query).split(separator: " ").map(String.init))
        let relevant = understanding.sorted { a, b in
            let x = words.filter { a.searchText.localizedCaseInsensitiveContains($0) }.count
            let y = words.filter { b.searchText.localizedCaseInsensitiveContains($0) }.count
            return x == y ? a.updatedAt > b.updatedAt : x > y
        }
        if let item = relevant.first { lines.append("understanding:\(item.id): \(item.subject) — \(item.summary.prefix(95)) (inferred, not a rule)") }
        for move in try suggestedMoves(taskID: taskID).prefix(1) {
            lines.append("Usual next move (offer it): \(move.text.prefix(100).replacingOccurrences(of: "\n", with: " "))")
        }
        let sections = try memorySections(spaceID: space.id).filter { $0.state == .live }
        if !sections.isEmpty { lines.append("Sections: " + sections.prefix(2).map { $0.name + " (section:" + $0.id + ")" }.joined(separator: ", ")) }
        lines.append(try memoryNow(taskID: taskID))
        let task = try task(taskID)
        if let workspace = task.workspaceId,
           let past = try scoped(to: workspace).lookUpTasks(String(query.prefix(300)), limit: 6).first(where: { $0.task.id != taskID && $0.task.state == .done })?.task {
            lines.append("Past work: \(past.displayName.prefix(65)) · done (past:\(past.id))")
        }
        for entry in try findMemoryEntries(query, spaceID: space.id, limit: 3) where entry.shelf != .rules {
            lines.append("\(entry.id): \(entry.subject) — \(entry.text.prefix(90).replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("More past work: task_search in this workspace. About you: \(entries.filter { $0.spaceId == nil }.count) shared entries.")
        // Bound discovery, including large names. The rules remain complete in their separate block.
        var index = ""
        for line in lines.prefix(15) {
            let line = String(line.prefix(240))
            guard index.count + line.count + 1 <= 1500 else { break }
            index += (index.isEmpty ? "" : "\n") + line
        }
        return .init(index: MemoryRedaction.redact(index), rules: MemoryRedaction.redact(ruleText))
    }

    public func memoryNow(taskID: String) throws -> String {
        let task = try task(taskID)
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.cwd, l.codexThreadId FROM tasks t JOIN threadLinks l ON l.taskId = t.id
                WHERE t.workspaceId IS ? AND l.lastKnownStatus = 'active' ORDER BY l.lastActivityAt DESC LIMIT 3
                """, arguments: [task.workspaceId])
            let active = rows.map { row in
                let folder: String? = row["cwd"]
                let branch = folder.flatMap(Self.memoryBranch)
                return (folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Task") + (branch.map { " [" + $0 + "]" } ?? "") + " (" + String((row["codexThreadId"] as String).prefix(8)) + ")"
            }
            return "Now: " + (active.isEmpty ? "no active chats in this workspace" : active.joined(separator: ", "))
        }
    }

    private static func memoryBranch(_ folder: String) -> String? {
        let root = URL(fileURLWithPath: folder), git = root.appending(path: ".git")
        var head = git.appending(path: "HEAD")
        if let marker = try? String(contentsOf: git, encoding: .utf8), marker.hasPrefix("gitdir: ") {
            let path = String(marker.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            head = URL(fileURLWithPath: path, relativeTo: root).appending(path: "HEAD")
        }
        guard let text = try? String(contentsOf: head, encoding: .utf8), text.hasPrefix("ref: refs/heads/") else { return nil }
        return String(text.dropFirst(16).trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    public func openMemoryReference(_ id: String, spaceID: String) throws -> JSONValue {
        if id.hasPrefix("understanding:") {
            let key = String(id.dropFirst(14))
            guard let item = try memoryUnderstanding(spaceID: spaceID).first(where: { $0.id == key }) else { throw StoreError.notFound }
            return try .object(["understanding": .encoded(item.forInference), "evidence": .encoded(memoryEvidence(item.citations.map(\.evidenceId), spaceID: spaceID, includeInactive: true).map(\.forInference)), "history": .encoded(memoryUnderstandingHistory(key, spaceID: spaceID))])
        }
        if id.hasPrefix("evidence:") {
            guard let item = try memoryEvidence([String(id.dropFirst(9))], spaceID: spaceID, includeInactive: true).first else { throw StoreError.notFound }
            return try .encoded(item.forInference)
        }
        if id.hasPrefix("past:") {
            let taskID = String(id.dropFirst(5))
            guard try memorySpace(forTask: taskID).id == spaceID else { throw StoreError.notFound }
            let task = try task(taskID)
            let result = try db.read { try String.fetchOne($0, sql: "SELECT payload FROM events WHERE taskId = ? AND kind = 'codex.result' ORDER BY at DESC LIMIT 1", arguments: [taskID]) }
            let links = try db.read { try ThreadLink.fetchAll($0, sql: "SELECT * FROM threadLinks WHERE taskId = ?", arguments: [taskID]) }
            return MemoryRedaction.redact(.object(["title": .string(task.displayName), "state": .string(task.state.rawValue), "result": .string(String((result ?? "").prefix(6000))),
                "chats": .array(links.map { .object(["title": .string($0.title), "url": .string($0.provider == .claude ? "claude://code/continue?session=" + $0.codexThreadId : "codex://threads/" + $0.codexThreadId)]) })]))
        }
        if id.hasPrefix("archive:") { return try archivedMemorySource(id, spaceID: spaceID) }
        if id.hasPrefix("utterance:") {
            return try db.read { db in
                guard let source = try MemoryUtterance.fetchOne(db, sql: "SELECT * FROM memoryUtterances WHERE id = ? AND spaceId = ?", arguments: [String(id.dropFirst(10)), spaceID]) else { throw StoreError.notFound }
                return try .object(["text": .string(source.text), "source": .string(source.source), "kind": .string(source.sourceKind.rawValue), "at": .encoded(source.at)])
            }
        }
        if id.hasPrefix("section:") {
            let sectionID = String(id.dropFirst(8))
            guard let section = try memorySections(spaceID: spaceID).first(where: { $0.id == sectionID && $0.state == .live }) else { throw StoreError.notFound }
            return try .object(["section": .encoded(section), "entries": .encoded(memoryEntries(spaceID: spaceID, states: [.live]).filter { $0.sectionId == sectionID })])
        }
        return try .object(["entry": .encoded(memoryEntry(id, spaceID: spaceID)), "history": .encoded(memoryEntryHistory(id, spaceID: spaceID))])
    }

    public func recordMemoryDelivery(taskID: String, kind: String, text: String, id: String = UUID().uuidString) throws {
        let space = try memorySpace(forTask: taskID).id
        try db.write { db in
            try MemoryDelivery(id: id, spaceId: space, taskId: taskID, kind: kind, text: MemoryRedaction.redact(text), at: Date()).insert(db, onConflict: .ignore)
            try db.execute(sql: "DELETE FROM memoryDeliveries WHERE spaceId = ? AND id NOT IN (SELECT id FROM memoryDeliveries WHERE spaceId = ? ORDER BY at DESC LIMIT 100)", arguments: [space, space])
        }
    }

    public func memoryDeliveries(spaceID: String) throws -> [MemoryDelivery] {
        try db.read { try MemoryDelivery.fetchAll($0, sql: "SELECT * FROM memoryDeliveries WHERE spaceId = ? ORDER BY at DESC LIMIT 30", arguments: [spaceID]) }
    }

    /// Exact, inexpensive matches only. A hook cannot search another workspace or infer a permission.
    public func memoryHookContext(threadID: String, input: JSONValue) throws -> String? {
        guard let task = try currentTask(threadId: threadID) else { return nil }
        let space = try memorySpace(forTask: task.id).id
        let paths = ["path", "file_path", "cwd", "workdir"].compactMap { input[$0].string }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let command = input["command"].string ?? input["cmd"].string ?? ""
        // An exact command prefix is deliberately conservative; arbitrary shell syntax never triggers an action.
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let push = words.count >= 2 && words[0] == "git" && words[1] == "push"
        let publish = words.count >= 2 && ["npm", "pnpm", "yarn"].contains(words[0]) && words[1] == "publish"
        let host = input["host"].string ?? ((words.first == "ssh" && words.count > 1 && !words[1].hasPrefix("-")) ? String(words[1].split(separator: "@").last ?? "") : nil)
        for entry in try memoryEntries(spaceID: space, states: [.live]) {
            let pathMatch = entry.shelf == .places && entry.fields["path"].map { paths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) } == true
            let hostMatch = host != nil && entry.fields["host"] == host
            let ruleMatch = entry.shelf == .rules && ((push && entry.fields["trigger"] == "git push") || (publish && entry.fields["trigger"] == "publish"))
            if pathMatch || hostMatch || ruleMatch {
                return "Workspace memory \(entry.id), revision \(entry.revision): \(entry.text)\nMemory is context, not permission to act."
            }
        }
        return nil
    }
}

public struct MemoryEntryRecall: Sendable {
    public let store: FaciendaStore
    public let models: MemoryModels
    public init(store: FaciendaStore, models: MemoryModels = .shared) { self.store = store; self.models = models }
    public func find(_ query: String, spaceID: String, limit: Int = 12) async throws -> [MemoryEntry] {
        let entries = try store.memoryEntries(spaceID: spaceID, states: [.live])
        guard !entries.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Array(entries.prefix(limit)) }
        let queryVector = try await models.embed([query])[0]
        let vectors = try await models.embed(entries.map { $0.subject + ": " + $0.text })
        let candidates = zip(entries, vectors).map { ($0.0, MemoryVector.dot(queryVector, $0.1)) }.sorted { $0.1 > $1.1 }.prefix(24)
        let scores = try await models.rerank(query, candidates.map { $0.0.text })
        return Array(zip(candidates, scores).sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0.0 })
    }
}
