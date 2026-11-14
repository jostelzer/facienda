import AppKit
import Testing
import Textual

/// A link in an agent's answer opens on the first click, even while Facienda is behind another app. This rests on
/// Textual's view keeping its name, so a Textual update that renames it fails here rather than in the user's hands.
@MainActor @Test func textualLinksTakeTheFirstClick() {
    _ = StructuredText(markdown: "linked")
    #expect(TextualFirstClick.view != nil)
    TextualFirstClick.install()
    #expect(TextualFirstClick.installed)
    TextualFirstClick.install()
    #expect(TextualFirstClick.installed)
    // Every other view still turns the first click down.
    #expect(!NSView().acceptsFirstMouse(for: nil))
}
