import AppKit

/// A workspace's name as it is set under its tile: the system font at one size on up to two lines, centred in the room
/// it has, as on a phone's home screen. A name whose longest word is wider than that room keeps its size and draws its
/// letters a little closer, as far as the word needs and no further than a phone would; a word still too wide then
/// breaks at a syllable with a hyphen, as in a book, rather than being cut or broken at any letter.
struct TileName: Equatable {
    /// The name with soft hyphens in the words too wide for a line, which the text shows as hyphens only where it breaks.
    let text: String
    /// How much closer than usual the letters sit, in points, zero or less.
    let tracking: CGFloat
    /// Whether the name needs more than two lines even so, and shows whole only while the pointer is on its tile.
    let cut: Bool

    static let size: CGFloat = 12
    /// The closest the letters ever come, about what a phone allows before it cuts a name.
    static let tightest: CGFloat = -0.6

    init(_ name: String, width: CGFloat) {
        let width = max(width, 1), words = name.components(separatedBy: " ")
        // Tighten in tenths of a point, only as far as the longest word needs.
        let tracking = words.map { word -> CGFloat in
            let over = Self.width(of: word, tracking: 0) - width
            guard over > 0 else { return 0 }
            return max(Self.tightest, -((over / CGFloat(max(word.count, 1)) * 10).rounded(.up) / 10))
        }.min() ?? 0
        self.tracking = tracking
        text = words.map { Self.width(of: $0, tracking: tracking) > width ? Self.hyphenated($0) : $0 }.joined(separator: " ")
        let lines = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: Self.attributes(tracking)).height
        cut = lines > (NSLayoutManager().defaultLineHeight(for: Self.font) * 2).rounded(.up) + 1
    }

    static var font: NSFont { NSFont.systemFont(ofSize: size) }

    private static func attributes(_ tracking: CGFloat) -> [NSAttributedString.Key: Any] { [.font: font, .kern: tracking] }

    private static func width(of word: String, tracking: CGFloat) -> CGFloat {
        (word as NSString).size(withAttributes: attributes(tracking)).width
    }

    /// A word with a soft hyphen at every place the Mac would hyphenate it, in the user's language or else British English.
    static func hyphenated(_ word: String) -> String {
        let length = (word as NSString).length
        guard length > 3 else { return word }
        var locale = CFLocaleCopyCurrent()
        if !CFStringIsHyphenationAvailableForLocale(locale) { locale = CFLocaleCreate(nil, CFLocaleIdentifier("en_GB" as CFString)) }
        let marks = Set((2...length).map {
            CFStringGetHyphenationLocationBeforeIndex(word as CFString, $0, CFRange(location: 0, length: length), 0, locale, nil)
        }.filter { $0 != kCFNotFound && $0 > 1 && $0 < length - 1 })
        let text = word as NSString
        var out = "", start = 0
        for mark in marks.sorted() {
            out += text.substring(with: NSRange(location: start, length: mark - start)) + "\u{AD}"
            start = mark
        }
        return out + text.substring(from: start)
    }
}
