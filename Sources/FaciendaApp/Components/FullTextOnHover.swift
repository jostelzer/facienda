import SwiftUI

/// Words kept to a few lines say here whether that hid some of them, for the row around them to show them whole.
struct CutShortKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension Text {
    /// Keeps the words to `lines` lines and tells a `fullTextOnHover` around them when that hides some of them.
    func shortened(to lines: Int) -> some View {
        lineLimit(lines).modifier(CutShortMeasure(whole: self))
    }

    /// Keeps the words to `lines` lines. When that hides some of them, the pointer resting on them shows `full`.
    func fullTextOnHover(_ full: String, lines: Int = 1) -> some View {
        shortened(to: lines).fullTextOnHover(full)
    }
}

extension View {
    /// While words inside, kept short by `shortened(to:)`, can't all be seen, the pointer resting here shows `full`.
    /// `help` is the tooltip the rest of the time, and follows `full` when both are shown.
    func fullTextOnHover(_ full: String, help: String? = nil) -> some View {
        modifier(FullTextHelp(full: full, help: help))
    }
}

/// Lays the same words out again at the same width with no line limit: taller than what shows means some are hidden.
private struct CutShortMeasure: ViewModifier {
    let whole: Text
    @State private var shown: CGFloat = 0
    @State private var needed: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown = $0 }
            .background(alignment: .topLeading) {
                whole.lineLimit(nil).fixedSize(horizontal: false, vertical: true).hidden().allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { needed = $0 }
            }
            .preference(key: CutShortKey.self, value: needed > shown + 1)
    }
}

/// The tooltip of the view holding cut-short words. It is always set, even when empty, so the view keeps its identity
/// as the words are hidden or shown again, and a popover open on the row stays open.
private struct FullTextHelp: ViewModifier {
    let full: String
    let help: String?
    @State private var cut = false

    func body(content: Content) -> some View {
        content
            .help(cut ? [full, help].compactMap { $0 }.joined(separator: "\n\n") : help ?? "")
            .onPreferenceChange(CutShortKey.self) { cut = $0 }
            // Spent here, so a row further out doesn't take these words for its own.
            .transformPreference(CutShortKey.self) { $0 = false }
    }
}
