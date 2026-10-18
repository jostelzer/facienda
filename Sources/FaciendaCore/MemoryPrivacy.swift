import Foundation
import GRDB

/// Source identity is recorded by the capture boundary, never inferred from what a message says.
public enum MemorySourceKind: String, Codable, Sendable {
    case userRequest, userReply, userDecision, codexUser, claudeUser, curatedNotes, legacy

    var level: MemoryLevel {
        switch self {
        case .userRequest, .userReply, .codexUser, .claudeUser: .user
        case .userDecision: .decision
        case .curatedNotes: .note
        case .legacy: .assistant
        }
    }
}

/// Applied at memory's storage and model boundaries, including structured values containing quoted messages.
public enum MemoryRedaction {
    private static let patterns: [NSRegularExpression] = [
        #"(?s)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----.*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|$)"#,
        #"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16})\b"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
        #"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9+/=_~.-]+"#,
        #"(?i)(?<=://)[^\s/@]+:[^\s/@]+@"#,
        #"(?i)\b(?:password|passphrase)\s+is\s+[^\r\n]+"#,
        #"(?i)\b(?:password|passwd|pwd|passphrase|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|secret[_ -]?key|token)\b[\"']?\s*(?:[:=]|\bis\b)\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;&<>]+)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var result = TaskHandle.redact(text)
        for pattern in patterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
        }
        return result
    }

    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(redact(text))
        case .array(let values): .array(values.map(redact))
        case .object(let fields):
             .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
                let sensitive = key.range(of: #"(?i)^(?:password|passwd|passphrase|api[_-]?key|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|authorization|credentials)$"#, options: .regularExpression) != nil
                return (key, sensitive && value.string != nil ? .string("[redacted]") : redact(value))
            }))
        default: value
        }
    }

    /// JSON remains valid when an event contains a structured answer or a quoted secret.
    public static func payload(_ text: String) -> String {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return redact(text) }
        let clean = redact(json)
        return clean == json ? text : clean.json
    }
}

extension FaciendaStore {
    static func registerMemoryPrivacy(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("memory_source_identity") { db in
            try db.execute(sql: """
                ALTER TABLE memoryDocuments ADD COLUMN sourceKind TEXT NOT NULL DEFAULT 'legacy';
                ALTER TABLE memoryDocuments ADD COLUMN taskId TEXT;
                """)
        }
    }
}
