import Foundation

/// The uncased BERT WordPiece tokenizer shared by the memory embedder and reranker.
/// Matches Hugging Face's `BertTokenizerFast` for these models; fixtures in the tests pin that.
public struct MemoryTokenizer: Sendable {
    public static let maxTokens = 512
    let vocab: [String: Int32]
    let cls: Int32, sep: Int32, unk: Int32

    public init(vocabulary url: URL) throws {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() where !line.isEmpty { vocab[String(line)] = Int32(index) }
        guard let cls = vocab["[CLS]"], let sep = vocab["[SEP]"], let unk = vocab["[UNK]"] else {
            throw StoreError.invalid("The memory vocabulary is incomplete.")
        }
        (self.vocab, self.cls, self.sep, self.unk) = (vocab, cls, sep, unk)
    }

    /// `[CLS] text [SEP]`, truncated to the model limit.
    public func encode(_ text: String, limit: Int = maxTokens) -> [Int32] {
        [cls] + pieces(text).prefix(limit - 2) + [sep]
    }

    /// `[CLS] query [SEP] document [SEP]` with segment IDs, trimming the longer side first.
    public func encodePair(_ query: String, _ document: String, limit: Int = maxTokens) -> (ids: [Int32], types: [Int32]) {
        var a = pieces(query), b = pieces(document)
        while a.count + b.count > limit - 3 { if a.count > b.count { a.removeLast() } else { b.removeLast() } }
        let ids = [cls] + a + [sep] + b + [sep]
        return (ids, [Int32](repeating: 0, count: a.count + 2) + [Int32](repeating: 1, count: b.count + 1))
    }

    func pieces(_ text: String) -> [Int32] {
        words(text).flatMap(wordPiece)
    }

    /// Bert normalization and pre-tokenization: clean, isolate CJK, lowercase, strip accents, split on spaces and punctuation.
    func words(_ text: String) -> [String] {
        var words: [String] = [], current = ""
        func flush() { if !current.isEmpty { words.append(current); current = "" } }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0 || v == 0xFFFD || (isControl(scalar) && !isWhitespace(scalar)) { continue }
            if isWhitespace(scalar) { flush(); continue }
            if isCJK(v) || isPunctuation(scalar) { flush(); words.append(String(scalar)); continue }
            current.unicodeScalars.append(scalar)
        }
        flush()
        return words.compactMap { word in
            let folded = String(String.UnicodeScalarView(word.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.properties.generalCategory != .nonspacingMark }))
            return folded.isEmpty ? nil : folded
        }.flatMap { word in
            // Lowercasing and accent stripping can expose punctuation, so split once more.
            var parts: [String] = [], part = ""
            for scalar in word.unicodeScalars {
                if isPunctuation(scalar) { if !part.isEmpty { parts.append(part); part = "" }; parts.append(String(scalar)) } else { part.unicodeScalars.append(scalar) }
            }
            if !part.isEmpty { parts.append(part) }
            return parts
        }
    }

    func wordPiece(_ word: String) -> [Int32] {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count <= 100 else { return [unk] }
        var ids: [Int32] = [], start = 0
        while start < scalars.count {
            var end = scalars.count, found: Int32?
            while start < end {
                var piece = String(String.UnicodeScalarView(scalars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            ids.append(id)
            start = end
        }
        return ids
    }

    private func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r" || s.properties.generalCategory == .spaceSeparator
    }

    private func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned: true
        default: false
        }
    }

    private func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
