import Foundation
import FaciendaCore
import Textual

/// Textual's Markdown, with each picture of a local file also a link to that file, so a screenshot in an answer opens
/// larger when clicked. Agents write pictures bare, and Foundation drops a picture set inside a link, so the link is
/// added after parsing. Where it leads is still up to `CodexMarkdown.action(for:)`, as for any link.
struct PictureLinks: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        var text = try AttributedStringMarkdownParser.markdown().attributedString(for: input)
        let pictures = text.runs.compactMap { run -> (Range<AttributedString.Index>, URL)? in
            guard run.link == nil, let picture = run.imageURL, case .reveal = CodexMarkdown.action(for: picture) else { return nil }
            return (run.range, picture)
        }
        for (range, picture) in pictures { text[range].link = picture }
        return text
    }
}
