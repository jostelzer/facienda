import CryptoKit
import Foundation
import GRDB

/// Splits text into chunks of at most `limit` characters, preferring paragraph, line, sentence and word breaks.
/// A port of the recursive splitter Hindsight uses, so the same document produces the same chunks.
public enum MemoryChunker {
    public static let limit = 3_000
    static let separators = ["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""]

    public static func split(_ text: String, limit: Int = limit) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        return recurse(trimmed, separators: separators, limit: limit)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func recurse(_ text: String, separators: [String], limit: Int) -> [String] {
        guard let index = separators.firstIndex(where: { $0.isEmpty || text.contains($0) }) else { return [text] }
        let separator = separators[index], rest = Array(separators.dropFirst(index + 1))
        // The separator stays with the piece that follows it.
        var pieces: [String] = []
        if separator.isEmpty { pieces = text.map(String.init) } else {
            let parts = text.components(separatedBy: separator)
            pieces = parts.enumerated().map { $0.offset == 0 ? $0.element : separator + $0.element }.filter { !$0.isEmpty }
        }
        var chunks: [String] = [], current = ""
        for piece in pieces {
            if piece.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks += rest.isEmpty ? [piece] : recurse(piece, separators: rest, limit: limit)
            } else if current.count + piece.count > limit {
                chunks.append(current); current = piece
            } else {
                current += piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
