import CoreGraphics

/// The island's spaces, like a phone's home screen: as many columns as fit, two to four, and rows of one height from the
/// top down, each space holding a tile with its name under it. The outer tiles stand as far in from the island's sides as
/// the cards do from the board's, and the rest spread evenly between them. Spaces are counted along the rows, so a wider
/// or narrower island keeps the same order and only wraps it differently.
struct IslandGrid: Equatable {
    let columns: Int
    /// The room each space takes across, and from one tile's middle to the next across and down.
    let column: CGFloat
    let pitch: CGFloat
    let row: CGFloat
    /// A tile's side and the radius of its corners.
    let tile: CGFloat
    let corner: CGFloat
    /// The spaces on the island: the rows that fit, or as many as the lowest tile needs.
    let spaces: Int
    /// The island's width, which the names under the outer tiles keep inside.
    let width: CGFloat

    /// Room above the first row, and under each tile for a name of two lines and the gap to the next row.
    static let top: CGFloat = 14, under: CGFloat = 54
    /// How far the outer tiles stand in from the island's sides: the board's inset, so tiles and cards share an edge.
    static let side = IslandFrame.inset

    /// How wide a name under a tile may be at rest: the room to the next tile, so a long name wraps no sooner than it
    /// must, but never more than keeps it centred under its tile and a few points short of the island's edge.
    func name(at x: CGFloat) -> CGFloat { max(min(pitch - 4, (min(x, width - x) - 3) * 2), 0) }

    init(area: CGSize, lastTaken: Int) {
        width = area.width
        columns = min(max(Int(area.width / 72), 2), 4)
        column = area.width / CGFloat(columns)
        // About three fifths of a column, as on a phone.
        var tile = min(max((column * 0.6).rounded(), 44), 62), row = tile + Self.under
        let fits = max(Int((area.height - Self.top) / row), 1), needed = max(lastTaken, 0) / columns + 1
        if needed > fits {
            // More rows than the island holds: every row gives up some height, and the tiles shrink with it.
            row = (area.height - Self.top) / CGFloat(needed)
            tile = max((row - Self.under).rounded(), 24)
        }
        self.tile = tile
        self.row = row
        pitch = max((area.width - Self.side * 2 - tile) / CGFloat(columns - 1), 0)
        corner = (tile * 0.24).rounded()
        spaces = max(fits, needed) * columns
    }

    /// The middle of a space's tile.
    func centre(of space: Int) -> CGPoint {
        CGPoint(x: Self.side + tile / 2 + CGFloat(space % columns) * pitch, y: Self.top + CGFloat(space / columns) * row + tile / 2)
    }

    /// The space whose tile is nearest a point, among those on the island.
    func space(nearest point: CGPoint) -> Int {
        let across = min(max(Int(((point.x - Self.side - tile / 2) / pitch).rounded()), 0), columns - 1)
        let down = min(max(Int(((point.y - Self.top - tile / 2) / row).rounded()), 0), spaces / columns - 1)
        return down * columns + across
    }

    /// The space whose tile is under a point, give or take a little, if any.
    func space(under point: CGPoint, reach: CGFloat = 8) -> Int? {
        let space = space(nearest: point), middle = centre(of: space)
        return abs(point.x - middle.x) <= tile / 2 + reach && abs(point.y - middle.y) <= tile / 2 + reach ? space : nil
    }
}
