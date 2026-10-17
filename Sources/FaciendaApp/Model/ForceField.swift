import CoreGraphics

/// The planets on the island keep a little space round each other, like magnets of the same pole. Each is drawn to its
/// own place and pushed away by the others, already a little before they touch, so a planet carried towards others makes
/// them lean away, and they drift home again once it has gone. The planet being held stays exactly where it is; nothing
/// ever overlaps, and nothing leaves the island.
enum ForceField {
    struct Body: Equatable {
        /// Where the planet belongs: the place the user gave it.
        var home: CGPoint
        /// How far it reaches from its centre, rings included.
        var radius: CGFloat
    }

    /// How strongly a planet is drawn home, and pushed by a neighbour that is too near; the held one pushes harder.
    private static let pull: CGFloat = 0.15, push: CGFloat = 0.15, heldPush: CGFloat = 0.3
    private static let rounds = 120

    /// Where every planet comes to rest. `gap` is the space always kept between two planets, `lean` how much further out
    /// they already start to give way. A planet in `held` stays at its home whatever is near.
    static func settle(_ bodies: [String: Body], held: String?, in bounds: CGRect, gap: CGFloat = 6, lean: CGFloat = 26) -> [String: CGPoint] {
        let ids = bodies.keys.sorted()
        guard ids.count > 1 else { return bodies.mapValues { inside($0.home, $0.radius, bounds) } }
        var at = bodies.mapValues { inside($0.home, $0.radius, bounds) }
        for _ in 0..<rounds {
            // Drawn home, and pushed away from every neighbour within reach.
            for id in ids where id != held {
                let body = bodies[id]!, here = at[id]!
                var move = CGVector(dx: (body.home.x - here.x) * pull, dy: (body.home.y - here.y) * pull)
                for other in ids where other != id {
                    let away = apart(here, at[other]!, id, other)
                    let reach = body.radius + bodies[other]!.radius + gap + lean
                    guard away.distance < reach else { continue }
                    let strength = (reach - away.distance) * (other == held ? heldPush : push)
                    move.dx += away.unit.dx * strength; move.dy += away.unit.dy * strength
                }
                at[id] = inside(CGPoint(x: here.x + move.dx, y: here.y + move.dy), body.radius, bounds)
            }
            // Never touching: two planets closer than their gap are parted by exactly the overlap. The held one never yields.
            for (index, a) in ids.enumerated() {
                for b in ids[(index + 1)...] {
                    let away = apart(at[b]!, at[a]!, b, a), need = bodies[a]!.radius + bodies[b]!.radius + gap
                    guard away.distance < need else { continue }
                    let overlap = need - away.distance, share: CGFloat = a == held ? 1 : b == held ? 0 : 0.5
                    if b != held {
                        at[b] = inside(CGPoint(x: at[b]!.x + away.unit.dx * overlap * share, y: at[b]!.y + away.unit.dy * overlap * share), bodies[b]!.radius, bounds)
                    }
                    if a != held {
                        at[a] = inside(CGPoint(x: at[a]!.x - away.unit.dx * overlap * (1 - share), y: at[a]!.y - away.unit.dy * overlap * (1 - share)), bodies[a]!.radius, bounds)
                    }
                }
            }
        }
        return at
    }

    /// How far `point` lies from `other`, and the way from `other` to it. Two planets on the very same spot part along a
    /// direction of their own, so the result never depends on chance.
    private static func apart(_ point: CGPoint, _ other: CGPoint, _ id: String, _ otherID: String) -> (distance: CGFloat, unit: CGVector) {
        let dx = point.x - other.x, dy = point.y - other.y, distance = (dx * dx + dy * dy).squareRoot()
        if distance > 0.01 { return (distance, CGVector(dx: dx / distance, dy: dy / distance)) }
        let side: CGFloat = id < otherID ? 1 : -1
        return (0.01, CGVector(dx: side * 0.6, dy: side * 0.8))
    }

    /// Kept whole inside the island; on an island too small for it, in the middle.
    private static func inside(_ point: CGPoint, _ radius: CGFloat, _ bounds: CGRect) -> CGPoint {
        let room = bounds.insetBy(dx: radius, dy: radius)
        guard room.width >= 0, room.height >= 0 else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return CGPoint(x: min(max(point.x, room.minX), room.maxX), y: min(max(point.y, room.minY), room.maxY))
    }
}
