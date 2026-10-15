import Foundation
import FaciendaCore

/// What is left of one agent's subscription limits. Shaped for any agent so Claude can report the same way.
public struct PlanUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// Length of the window in minutes; nil when the service does not say.
        public let minutes: Int?
        public let usedPercent: Int
        public let resetsAt: Date?
        public var leftPercent: Int { max(0, min(100, 100 - usedPercent)) }

        public init(minutes: Int?, usedPercent: Int, resetsAt: Date?) {
            self.minutes = minutes; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        }
        /// "5h", "wk", "day"; fits the sidebar.
        public var shortName: String {
            switch minutes {
            case 10080: "wk"
            case 1440: "day"
            case let m? where m % 1440 == 0: "\(m / 1440)d"
            case let m? where m % 60 == 0: "\(m / 60)h"
            case let m?: "\(m)m"
            case nil: ""
            }
        }
        /// "5-hour limit", "Weekly limit"; used in the hover text.
        public var name: String {
            switch minutes {
            case 10080: "Weekly limit"
            case 1440: "Daily limit"
            case let m? where m % 1440 == 0: "\(m / 1440)-day limit"
            case let m? where m % 60 == 0: "\(m / 60)-hour limit"
            case let m?: "\(m)-minute limit"
            case nil: "Usage limit"
            }
        }
    }

    public let agent: String
    /// The subscription, such as "ChatGPT Pro". Nil when the service does not name it.
    public let plan: String?
    /// Shortest window first, so the 5-hour limit sits above the weekly one.
    public let windows: [Window]
    /// The service says this agent is blocked until a window resets.
    public let limitReached: Bool

    public init(agent: String, plan: String?, windows: [Window], limitReached: Bool) {
        self.agent = agent; self.plan = plan
        self.windows = windows.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
        self.limitReached = limitReached
    }

    /// A window has started over since this was read, so the numbers are out of date.
    public func stale(at now: Date = Date()) -> Bool { windows.contains { ($0.resetsAt ?? .distantFuture) <= now } }
}

extension PlanUsage {
    /// Reads `account/rateLimits/read`. Nil when the account has no ChatGPT plan limits, such as an API key.
    init?(codex response: JSONValue) {
        let snapshot = response["rateLimitsByLimitId"]["codex"].object != nil ? response["rateLimitsByLimitId"]["codex"] : response["rateLimits"]
        let windows = [snapshot["primary"], snapshot["secondary"]].compactMap { window -> Window? in
            guard let used = window["usedPercent"].number else { return nil }
            return Window(minutes: window["windowDurationMins"].number.map { Int($0) }, usedPercent: Int(used),
                          resetsAt: window["resetsAt"].number.map { Date(timeIntervalSince1970: $0) })
        }
        guard !windows.isEmpty else { return nil }
        self.init(agent: "Codex", plan: Self.chatGPTPlan(snapshot["planType"].string), windows: windows,
                  limitReached: snapshot["rateLimitReachedType"].string != nil)
    }

    static func chatGPTPlan(_ raw: String?) -> String? {
        let names = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "promax": "Pro Max",
                     "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        guard let raw, raw != "unknown" else { return nil }
        if let name = names[raw] { return "ChatGPT " + name }
        if raw.contains("enterprise") { return "ChatGPT Enterprise" }
        if raw.contains("business") { return "ChatGPT Business" }
        if raw.hasPrefix("edu") { return "ChatGPT Edu" }
        return "ChatGPT"
    }
}

extension PlanUsage {
    /// Reads claude.ai's usage page response (`/api/organizations/{id}/usage`). The API is undocumented,
    /// so both spellings seen in the wild are accepted. Nil when it holds no 5-hour or weekly window.
    public init?(claude usage: JSONValue, capabilities: [String] = [], tier: String? = nil) {
        let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes -> Window? in
            let window = usage[key]
            guard let used = window["utilization"].number ?? window["utilization_pct"].number else { return nil }
            let reset = window["resets_at"] == .null ? window["reset_at"] : window["resets_at"]
            return Window(minutes: minutes, usedPercent: Int(used.rounded()), resetsAt: Self.date(reset))
        }
        guard !windows.isEmpty else { return nil }
        self.init(agent: "Claude", plan: Self.claudePlan(capabilities: capabilities, tier: tier), windows: windows,
                  limitReached: windows.contains { $0.leftPercent == 0 })
    }

    static func claudePlan(capabilities: [String], tier: String?) -> String? {
        let tier = tier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Claude Max 20x" }
        if tier.contains("max_5x") { return "Claude Max 5x" }
        if capabilities.contains("claude_max") || tier.contains("max") { return "Claude Max" }
        if capabilities.contains("claude_pro") || tier.contains("pro") { return "Claude Pro" }
        return nil
    }

    static func date(_ value: JSONValue) -> Date? {
        if let seconds = value.number { return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
        guard let text = value.string else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Python servers send microseconds, which the formatter rejects; a reset time needs no sub-second precision.
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: whole)
    }
}

extension CodexBridge {
    public func planUsage() async throws -> PlanUsage? {
        PlanUsage(codex: try await request("account/rateLimits/read"))
    }
}
