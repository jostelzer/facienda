import Foundation
import FaciendaCore

public struct CodexProject: Decodable, Sendable {
    public struct Root: Decodable, Sendable { public let path: String }
    public let id: String
    public let name: String
    public let roots: [Root]
    /// When the project's newest chat was active, in Unix seconds; nil without chats.
    public let recencyAt: Double?
}

extension CodexBridge {
    /// Name the project registered by the native connection link without creating another.
    /// Codex registers the folder once its setup message is sent, so callers wait as long as that may take.
    public func connectProject(directory: URL, name: String, within wait: Duration = .seconds(15)) async throws -> CodexProject {
        struct Page: Decodable { let data: [CodexProject]; let nextCursor: String? }
        struct Response: Decodable { let project: CodexProject }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let deadline = ContinuousClock.now.advanced(by: wait)
        repeat {
            var cursor: String?
            repeat {
                var params: [String: JSONValue] = ["limit": .number(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let page = try await request("project/list", params: .object(params)).decoded(Page.self)
                if let existing = page.data.first(where: { project in
                    project.roots.count == 1 && URL(fileURLWithPath: project.roots[0].path).standardizedFileURL.resolvingSymlinksInPath() == directory
                }) {
                    if existing.name == name { return existing }
                    return try await request("project/update", params: .object([
                        "projectId": .string(existing.id), "name": .string(name)
                    ])).decoded(Response.self).project
                }
                cursor = page.nextCursor
            } while cursor != nil
            guard ContinuousClock.now < deadline else {
                throw BridgeError.server("Codex has not registered the workspace folder yet. Reopen the connection to try again.")
            }
            try await Task.sleep(for: .milliseconds(500))
        } while true
    }

    /// Every local Codex project.
    public func projects() async throws -> [CodexProject] {
        struct Page: Decodable { let data: [CodexProject]; let nextCursor: String? }
        var all: [CodexProject] = [], cursor: String?
        repeat {
            var params: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request("project/list", params: .object(params)).decoded(Page.self)
            all += page.data; cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    /// The Codex project spanning exactly these folders, so a group's chats can work across all of them.
    /// A project of the user's that already matches is used as it is. Otherwise Facienda keeps one of its own:
    /// the one it made before, given these folders, or a new one named after the group. The user's projects are never changed.
    public func groupProject(folders: [String], name: String, current: (id: String, owned: Bool)?) async throws -> (id: String, owned: Bool) {
        func normal(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        let wanted = Set(folders.map(normal)), all = try await projects()
        let roots = JSONValue.array(folders.map { .object(["path": .string($0)]) })
        if let match = all.first(where: { Set($0.roots.map { normal($0.path) }) == wanted }) {
            return (match.id, current?.id == match.id && current?.owned == true)
        }
        if let current, current.owned, all.contains(where: { $0.id == current.id }) {
            _ = try await request("project/update", params: .object(["projectId": .string(current.id), "roots": roots]))
            return current
        }
        // Codex requires a key per creation so a retried request doesn't make a second project.
        let created = try await request("project/create", params: .object([
            "idempotencyKey": .string(UUID().uuidString), "name": .string(name), "roots": roots
        ]))
        guard let id = created["project"]["id"].string ?? created["id"].string else { throw BridgeError.server("Codex did not return the new project.") }
        return (id, true)
    }
}
