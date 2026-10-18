import Foundation
import GRDB

/// Where new work typed in the top bar can go: a workspace, and one of its groups or none. The bar is the window's,
/// not a workspace's, so a task belongs wherever its work is, whichever workspace is open.
public struct BarPlace: Equatable, Hashable, Sendable {
    public let workspaceID: String
    public let workspaceName: String
    public let groupID: String?
    public let groupName: String?
    /// A few names of the work already there, newest first, so the reader can tell what belongs.
    public let examples: [String]
    /// Work there whose words match what was typed: the plainest sign of where it belongs.
    public let matches: [String]

    public init(workspaceID: String, workspaceName: String, groupID: String? = nil, groupName: String? = nil, examples: [String] = [],
                matches: [String] = []) {
        self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.groupID = groupID; self.groupName = groupName
        self.examples = examples; self.matches = matches
    }

    /// "Facienda · facienda coding", or the workspace alone for no group.
    public var label: String { groupName.map { "\(workspaceName) · \($0)" } ?? workspaceName }
}

/// Where the person put work that was typed in the bar, after it landed somewhere else or when Facienda was not sure.
/// The reader follows these for similar text.
public struct BarRouteCorrection: Equatable, Sendable {
    public let text: String
    public let workspaceID: String
    public let groupID: String?

    public init(text: String, workspaceID: String, groupID: String?) {
        self.text = text; self.workspaceID = workspaceID; self.groupID = groupID
    }
}

extension FaciendaStore {
    static let routeCorrectedKind = "route.corrected"

    /// Every place in the library: each workspace's groups, busiest first, then the workspace with no group. Each comes
    /// with the names of its latest work and of the work, in any workspace, whose words match the text.
    public func barPlaces(matching text: String = "", examples: Int = 6, groupsPerWorkspace: Int = 30) throws -> [BarPlace] {
        let found = text.isEmpty ? [] : try library.lookUpTasks(text, limit: 16).map(\.task)
        return try db.read { db in
            // Work the bar placed without being sure is no evidence of where such work goes, or one wrong guess would
            // draw more after it.
            let guessed = found.isEmpty ? [] : Set(try String.fetchAll(db, sql: """
                SELECT taskId FROM events WHERE kind = ? AND taskId IN (\(found.map { _ in "?" }.joined(separator: ", ")))
                AND json_valid(payload) AND json_extract(payload, '$.reading') LIKE '%not sure%'
                """, arguments: StatementArguments([Self.intakeKind] + found.map(\.id))))
            let hits = found.filter { !guessed.contains($0.id) }
            let members = hits.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT taskId, groupId FROM taskGroupMembers WHERE taskId IN (\(hits.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments(hits.map(\.id))).map { ($0["taskId"] as String, $0["groupId"] as String) })
            func matching(_ workspace: String, _ group: String?) -> [String] {
                hits.filter { $0.workspaceId == workspace && members[$0.id] == group }.prefix(4).map(\.displayName)
            }
            let workspaces = try Workspace.fetchAll(db, sql: "SELECT * FROM workspaces WHERE removedAt IS NULL ORDER BY position, createdAt")
            let name = "coalesce(nullif(t.displayTitle, ''), t.title)"
            let unguessed = """
                NOT EXISTS (SELECT 1 FROM events e WHERE e.taskId = t.id AND e.kind = '\(Self.intakeKind)'
                            AND json_valid(e.payload) AND json_extract(e.payload, '$.reading') LIKE '%not sure%')
                """
            var places: [BarPlace] = []
            for workspace in workspaces {
                let groups = try Row.fetchAll(db, sql: """
                    SELECT g.id, g.name, (SELECT max(t.updatedAt) FROM tasks t JOIN taskGroupMembers m ON m.taskId = t.id
                                          WHERE m.groupId = g.id) AS active
                    FROM taskGroups g WHERE g.workspaceId = ?
                    ORDER BY active IS NULL, active DESC, g.position LIMIT ?
                    """, arguments: [workspace.id, groupsPerWorkspace])
                for group in groups {
                    let id: String = group["id"]
                    let names = try String.fetchAll(db, sql: """
                        SELECT \(name) FROM tasks t JOIN taskGroupMembers m ON m.taskId = t.id
                        WHERE m.groupId = ? AND t.state != 'dropped' AND \(unguessed) ORDER BY t.updatedAt DESC LIMIT ?
                        """, arguments: [id, examples])
                    places.append(BarPlace(workspaceID: workspace.id, workspaceName: workspace.name, groupID: id, groupName: group["name"], examples: names,
                                           matches: matching(workspace.id, id)))
                }
                let loose = try String.fetchAll(db, sql: """
                    SELECT \(name) FROM tasks t WHERE t.workspaceId = ? AND t.state != 'dropped'
                    AND NOT EXISTS (SELECT 1 FROM taskGroupMembers m WHERE m.taskId = t.id) AND \(unguessed)
                    ORDER BY t.updatedAt DESC LIMIT ?
                    """, arguments: [workspace.id, examples])
                places.append(BarPlace(workspaceID: workspace.id, workspaceName: workspace.name, examples: loose, matches: matching(workspace.id, nil)))
            }
            return places
        }
    }

    /// Where each task lives: its workspace and group, which the bar shows as their pictures and names.
    public func taskPlaces(ofTasks ids: [String]) throws -> [String: BarPlace] {
        guard !ids.isEmpty else { return [:] }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, w.id AS workspaceId, w.name AS workspace, g.id AS groupId, g.name AS grp
                FROM tasks t JOIN workspaces w ON w.id = t.workspaceId
                LEFT JOIN taskGroupMembers m ON m.taskId = t.id LEFT JOIN taskGroups g ON g.id = m.groupId
                WHERE t.id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments(ids))
            return Dictionary(rows.map { row -> (String, BarPlace) in
                (row["id"], BarPlace(workspaceID: row["workspaceId"], workspaceName: row["workspace"], groupID: row["groupId"], groupName: row["grp"]))
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The one workspace the text names, as in "in facienda", whose places are then the only ones it can go to.
    public static func namedWorkspace(in text: String, among places: [BarPlace]) -> String? {
        let words = TaskLookup.words(text)
        var named = Set<String>()
        for place in places where !named.contains(place.workspaceID) {
            let name = TaskLookup.words(place.workspaceName)
            guard !name.isEmpty, words.count >= name.count else { continue }
            if (0...(words.count - name.count)).contains(where: { Array(words[$0..<($0 + name.count)]) == name }) { named.insert(place.workspaceID) }
        }
        return named.count == 1 ? named.first : nil
    }

    /// Keeps where the person put work typed in the bar, for the reader to learn from.
    public func recordRouteCorrection(text: String, workspaceID: String, groupID: String?) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var payload: [String: JSONValue] = ["text": .string(String(text.prefix(500))), "workspace": .string(workspaceID)]
        if let groupID { payload["group"] = .string(groupID) }
        let json = String(decoding: try JSONEncoder().encode(JSONValue.object(payload)), as: UTF8.self)
        try write { db in try TaskEvent(source: .user, kind: Self.routeCorrectedKind, payload: json).insert(db) }
    }

    /// The latest places the person chose, across the library, newest first, one per text.
    public func routeCorrections(limit: Int = 12) throws -> [BarRouteCorrection] {
        try db.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT payload FROM events WHERE kind = ? ORDER BY at DESC, rowid DESC LIMIT ?",
                                           arguments: [Self.routeCorrectedKind, limit * 3])
            var seen = Set<String>(), found: [BarRouteCorrection] = []
            for row in rows {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(row.utf8)),
                      let text = value["text"].string, let workspace = value["workspace"].string,
                      seen.insert(text.lowercased()).inserted else { continue }
                found.append(BarRouteCorrection(text: text, workspaceID: workspace, groupID: value["group"].string))
                if found.count == limit { break }
            }
            return found
        }
    }

    /// The words typed in the top bar that made this task, if it was made there.
    public func barText(forTask taskID: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: """
                SELECT json_extract(payload, '$.text') FROM events
                WHERE taskId = ? AND kind = ? AND json_valid(payload) AND json_extract(payload, '$.from') = ?
                ORDER BY at LIMIT 1
                """, arguments: [taskID, Self.intakeKind, Self.fromBar])
        }
    }
}
