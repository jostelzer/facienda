import CoreGraphics

/// A carried planet clicks into line with the others: level with one, or right above or below one, as soon as its
/// middle comes within a few points of that line. Each direction clicks on its own, so a planet can line up with two
/// planets at once. Only planets count, never the island's own middle or walls.
enum LineUp {
    struct Snap: Equatable {
        /// Where the planet goes: where the pointer has it, moved onto each line it clicked to.
        var point: CGPoint
        /// The planet it stands above or below, and the one it is level with.
        var column: String?
        var row: String?
    }

    /// How near a planet's middle has to come to another's line, in points, before it clicks onto it.
    static let reach: CGFloat = 10

    static func snap(_ point: CGPoint, to others: [String: CGPoint], within reach: CGFloat = reach) -> Snap {
        let column = nearest(others, to: point, along: \.x, within: reach), row = nearest(others, to: point, along: \.y, within: reach)
        return Snap(point: CGPoint(x: column.flatMap { others[$0]?.x } ?? point.x, y: row.flatMap { others[$0]?.y } ?? point.y),
                    column: column, row: row)
    }

    /// The planet whose line lies nearest in one direction, within reach. Of several on the same line, the closest one,
    /// and of two as close, the first by id, so the same pointer always clicks to the same planet.
    private static func nearest(_ others: [String: CGPoint], to point: CGPoint, along axis: KeyPath<CGPoint, CGFloat>, within reach: CGFloat) -> String? {
        let off = { (other: CGPoint) in abs(other[keyPath: axis] - point[keyPath: axis]) }
        let away = { (other: CGPoint) in hypot(other.x - point.x, other.y - point.y) }
        return others.filter { off($0.value) < reach }.min { a, b in
            if abs(off(a.value) - off(b.value)) > 0.5 { return off(a.value) < off(b.value) }
            return (away(a.value), a.key) < (away(b.value), b.key)
        }?.key
    }
}
