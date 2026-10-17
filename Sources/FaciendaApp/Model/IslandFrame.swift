import SwiftUI

/// Where the island may be: anywhere in the window, at least a little roomy, as long as it leans on one of the walls.
/// Walls pull it on while it is carried, so it clicks into place rather than being tidied away after it is let go.
enum IslandFrame {
    /// The gap between the island and the wall it leans on.
    static let margin: CGFloat = 10
    static let smallest = CGSize(width: 190, height: 220)
    /// The least the board keeps beside the island, however the island is placed.
    static let board = CGSize(width: 360, height: 260)

    /// The saved frame, or for a first island the old sidebar's place: its share of the width, all the way down the left.
    static func decode(_ text: String, share: Double, in window: CGSize) -> CGRect {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        // Anything unreadable or outside the window falls back to the first place rather than losing the island.
        if parts.count == 4, parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }), parts[2] > 0, parts[3] > 0, window.width > 0, window.height > 0 {
            return CGRect(x: parts[0] * window.width, y: parts[1] * window.height, width: parts[2] * window.width, height: parts[3] * window.height)
        }
        let width = min(max(window.width * share, 220), 560) - margin * 2
        return CGRect(x: margin, y: margin, width: width, height: window.height - margin * 2)
    }

    static func encode(_ frame: CGRect, in window: CGSize) -> String {
        guard window.width > 0, window.height > 0 else { return "" }
        return [frame.minX / window.width, frame.minY / window.height, frame.width / window.width, frame.height / window.height]
            .map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    private static func walls(_ window: CGSize) -> CGRect { CGRect(origin: .zero, size: window).insetBy(dx: margin, dy: margin) }

    /// Kept whole inside the window and no smaller than the smallest island.
    static func inside(_ frame: CGRect, in window: CGSize) -> CGRect {
        let walls = walls(window)
        guard walls.width > 0, walls.height > 0 else { return frame }
        var frame = frame
        frame.size.width = min(max(frame.width, smallest.width), walls.width)
        frame.size.height = min(max(frame.height, smallest.height), walls.height)
        frame.origin.x = min(max(frame.minX, walls.minX), walls.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, walls.minY), walls.maxY - frame.height)
        return frame
    }

    /// How near a wall has to come before it pulls the island onto itself as well.
    static let pull: CGFloat = 40

    /// The walls an island touches, which tell when it clicks onto another one.
    static func touching(_ frame: CGRect, in window: CGSize) -> Set<Edge> {
        let walls = walls(window)
        var touching = Set<Edge>()
        if frame.minX - walls.minX < 0.5 { touching.insert(.leading) }
        if walls.maxX - frame.maxX < 0.5 { touching.insert(.trailing) }
        if frame.minY - walls.minY < 0.5 { touching.insert(.top) }
        if walls.maxY - frame.maxY < 0.5 { touching.insert(.bottom) }
        return touching
    }

    /// Inside the window and on its nearest wall, plus a second wall when it is pulled into a corner. Walls it only
    /// reaches by spanning the window (a tall island from top to bottom) do not count, so such an island leans on a side.
    /// Used while the island is carried, so it already sits where it will stay and nothing moves when it is let go.
    static func snap(_ frame: CGRect, in window: CGSize) -> CGRect {
        let walls = walls(window)
        guard walls.width > 0, walls.height > 0 else { return frame }
        var frame = inside(frame, in: window)
        let left = frame.minX - walls.minX, right = walls.maxX - frame.maxX
        let top = frame.minY - walls.minY, bottom = walls.maxY - frame.maxY
        // An axis with almost no play cannot be leaned on; its distance counts as never near.
        let across = walls.width - frame.width < pull ? .infinity : min(left, right)
        let down = walls.height - frame.height < pull ? .infinity : min(top, bottom)
        let sideways = across <= down || across < pull, upDown = down < across || down < pull
        if sideways, across.isFinite { frame.origin.x = left <= right ? walls.minX : walls.maxX - frame.width }
        if upDown, down.isFinite { frame.origin.y = top <= bottom ? walls.minY : walls.maxY - frame.height }
        // Spanning both ways, it has nowhere to go and already touches every wall.
        return frame
    }

    /// While one edge is dragged it clicks onto its wall when it comes near. An island that has come off every wall it
    /// can lean on goes onto the nearest, as a carried one would.
    static func resized(_ frame: CGRect, moving edge: Edge, in window: CGSize) -> CGRect {
        let walls = walls(window)
        guard walls.width > 0, walls.height > 0 else { return frame }
        var frame = inside(frame, in: window)
        switch edge {
        case .leading where frame.minX - walls.minX < pull: frame.size.width += frame.minX - walls.minX; frame.origin.x = walls.minX
        case .trailing where walls.maxX - frame.maxX < pull: frame.size.width = walls.maxX - frame.minX
        case .top where frame.minY - walls.minY < pull: frame.size.height += frame.minY - walls.minY; frame.origin.y = walls.minY
        case .bottom where walls.maxY - frame.maxY < pull: frame.size.height = walls.maxY - frame.minY
        default: break
        }
        return snap(frame, in: window)
    }

    /// The edges that lie free in the window, which may be dragged; one resting on a wall stays on it.
    static func freeEdges(_ frame: CGRect, in window: CGSize) -> Set<Edge> {
        Set([Edge.leading, .trailing, .top, .bottom]).subtracting(touching(frame, in: window))
    }

    /// The room the board leaves for the island: the board takes the largest stretch of window beside it, right of it,
    /// left of it, below or above, and never so little that it has too small a board.
    static func room(for frame: CGRect, in window: CGSize) -> EdgeInsets {
        guard window.width > 0, window.height > 0 else { return EdgeInsets() }
        let across = max(window.width - board.width, 0), down = max(window.height - board.height, 0)
        let sides: [(Edge, CGFloat)] = [
            (.leading, (window.width - frame.maxX) * window.height), (.trailing, frame.minX * window.height),
            (.top, (window.height - frame.maxY) * window.width), (.bottom, frame.minY * window.width),
        ]
        // On a tie the board keeps to the right of the island, where the old sidebar left it.
        var side = sides[0]
        for candidate in sides.dropFirst() where candidate.1 > side.1 + 1 { side = candidate }
        return switch side.0 {
        case .leading: EdgeInsets(top: 0, leading: min(frame.maxX, across), bottom: 0, trailing: 0)
        case .trailing: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: min(window.width - frame.minX, across))
        case .top: EdgeInsets(top: min(frame.maxY, down), leading: 0, bottom: 0, trailing: 0)
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: min(window.height - frame.minY, down), trailing: 0)
        }
    }
}
