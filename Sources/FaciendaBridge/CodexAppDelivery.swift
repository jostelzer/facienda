import AppKit
import Foundation
import FaciendaCore

/// Hands work to the desktop app without acquiring its chat's writer lock. Queue entries are durable, but
/// clientUserMessageId is not an idempotency key: after an uncertain add, inspect the queue instead of adding again.
enum CodexAppDelivery {
    static func queued(_ dispatch: NativeDispatch, bridge: CodexBridge) async throws -> String? {
        guard let thread = dispatch.threadId else { return nil }
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = ["threadId": .string(thread), "limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await bridge.request("thread/queue/list", params: .object(params))
            guard let entries = response["data"].array else { throw BridgeError.server("Codex did not return its queued messages.") }
            for entry in entries where entry["clientUserMessageId"].string == dispatch.id {
                let text = (entry["input"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
                guard text.hasPrefix("Facienda dispatch: \(dispatch.id)\n"), let id = entry["id"].string else {
                    throw BridgeError.server("The queued Codex message does not match this delivery.")
                }
                return id
            }
            let next = response["nextCursor"].string
            if next == cursor && next != nil { throw BridgeError.server("Codex repeated a queue page.") }
            cursor = next
        } while cursor != nil
        return nil
    }

    /// Only this short-lived process creates the empty chat. Its exit releases the writer before the app wakes.
    static func create(executable: String, params: JSONValue, title: String, effort: String?) async throws -> String {
        let creator = CodexBridge()
        do {
            try await creator.connect(executable: executable)
            let response = try await creator.request("thread/start", params: params, timeout: .seconds(60))
            guard let thread = response["thread"]["id"].string else { throw BridgeError.server("Codex did not return the new chat.") }
            _ = try await creator.request("thread/name/set", params: .object(["threadId": .string(thread), "name": .string(title)]))
            if let effort {
                _ = try await creator.request("thread/settings/update", params: .object(["threadId": .string(thread), "effort": .string(effort)]))
            }
            await creator.disconnectAndWait()
            return thread
        } catch {
            await creator.disconnectAndWait()
            throw error
        }
    }

    /// Codex's background queue wake route does not navigate or activate its window. Keep this isolated because
    /// both the route and queue API are experimental; failure must leave the recorded delivery recoverable.
    @MainActor static func wake(_ thread: String) async throws {
        guard UUID(uuidString: thread) != nil, let url = URL(string: "codex://threads/wake/\(thread)") else {
            throw BridgeError.server("Codex returned an invalid chat ID.")
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { throw BridgeError.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }
}
