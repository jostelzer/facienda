import SwiftUI

/// Where the island is: down the left of the window, under the bar, as wide as the user made it. Only its free right
/// edge moves; the board takes the room beside it.
enum IslandFrame {
    /// The gap between the island and the window's edges, and between the board's panel and the island and edges.
    static let margin: CGFloat = 10
    /// The bar across the top of the window, one line tall, above the island and the board alike.
    static let bar: CGFloat = 40
    /// Room at the window's left for its traffic lights, which the bar starts after.
    static let lights: CGFloat = 92
    /// How far the bar sits from the window's top: centred on the traffic lights, in a title row as tall as a toolbar.
    static let barTop: CGFloat = 6
    /// Where the island and the board begin: below the bar and a margin.
    static let top: CGFloat = barTop + bar + margin
    /// How far the board sits in from its panel's edge. With the panel's 26 pt corners, the 12 pt corners of the field and
    /// the cards inside nest in them.
    static let inset: CGFloat = 14
    /// The narrowest island that still holds its planets and limits.
    static let narrowest: CGFloat = 190
    /// The least the board keeps beside the island.
    static let board = CGSize(width: 360, height: 260)

    /// The island's width for its saved share of the window, or for a first island the old sidebar's: a quarter of the
    /// window, within bounds. Never narrower than the narrowest island, nor so wide that the board loses its room.
    static func width(share: Double, in window: CGSize) -> CGFloat {
        guard window.width > 0 else { return narrowest }
        let first = min(max(window.width * 0.25, 220), 560) - margin * 2
        let wanted = share.isFinite && share > 0 ? window.width * share : first
        return clamped(wanted, in: window)
    }

    /// A width the window can hold, as a dragged edge settles it.
    static func clamped(_ width: CGFloat, in window: CGSize) -> CGFloat {
        min(max(width, narrowest), max(window.width - board.width - margin * 3, narrowest))
    }

    /// The island itself: its width, the window's height below the bar, a margin from each edge.
    static func frame(width: CGFloat, in window: CGSize) -> CGRect {
        CGRect(x: margin, y: top, width: width, height: max(window.height - top - margin, 0))
    }

    /// The width share an island saved before it was always full height, so a width the user chose carries over.
    static func share(fromSavedFrame text: String) -> Double? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }), parts[2] > 0 else { return nil }
        return parts[2]
    }
}
