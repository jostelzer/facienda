import Foundation

/// A Codex chat named in what the user typed, as `codex://threads/<id>`.
enum CodexChatLink {
    /// The chat a Codex deep link such as `codex://threads/<id>` points to, when the text names exactly one. Words
    /// around the link continue that chat rather than start a new one, which would only read it.
    static func threadID(in text: String) -> String? {
        let ids = Set(text.split(whereSeparator: \.isWhitespace).compactMap { word -> String? in
            // A link written at the end of a sentence or in brackets still counts.
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'“”‘’.,;:!?"))
            guard let url = URL(string: token), url.scheme?.lowercased() == "codex",
                  ["threads", "thread"].contains(url.host()?.lowercased()) else { return nil }
            let id = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty || id.contains("/") ? nil : id
        })
        return ids.count == 1 ? ids.first : nil
    }

    /// What to send on to a Codex chat named in the text: the text as written, unless its words only point at the chat
    /// ("find codex thread …", "this chat"), in which case the chat is only added.
    static func message(in text: String) -> String? {
        guard threadID(in: text) != nil else { return nil }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).filter { !$0.contains("codex://") }
            .flatMap { $0.split { !$0.isLetter && !$0.isNumber } }.map(String.init)
        return words.allSatisfy(pointingWords.contains) ? nil : text
    }

    /// Words that only say "this chat", in English and German.
    private static let pointingWords: Set<String> = [
        "find", "open", "add", "track", "link", "show", "get", "here", "this", "that", "the", "a", "an", "my", "our", "it",
        "codex", "chat", "thread", "threads", "conversation", "task", "as", "in", "on", "to", "from", "of", "please", "pls",
        "hey", "hi", "der", "die", "das", "den", "dem", "diesen", "diese", "dieser", "hier", "bitte", "finde", "öffne"
    ]
}
