import Foundation
import Testing
import Textual

/// A screenshot in an answer opens when clicked: a picture of a local file is also a link to it. A picture from the
/// web gets no link, so a click on it never reaches the network.
@MainActor @Test func localPicturesAreLinks() throws {
    let text = try PictureLinks().attributedString(for: "Done.\n\n![Review screen](</tmp/shots/review screen.png>)\n\n![Logo](https://example.org/logo.png) [Notes](https://example.org)")
    let links = text.runs.compactMap { run in run.imageURL.map { ($0.absoluteString, run.link?.absoluteString) } }
    #expect(links.count == 2)
    #expect(links.first { $0.0.hasSuffix("review%20screen.png") }?.1 == "/tmp/shots/review%20screen.png")
    #expect(links.first { $0.0.hasPrefix("https") }?.1 == nil)
    #expect(text.runs.contains { $0.link?.absoluteString == "https://example.org" })
}
