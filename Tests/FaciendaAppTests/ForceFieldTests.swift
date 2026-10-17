import CoreGraphics
import Testing

private let island = CGRect(x: 0, y: 0, width: 280, height: 600)
private func gap(_ at: [String: CGPoint], _ a: String, _ b: String) -> CGFloat {
    let dx = at[a]!.x - at[b]!.x, dy = at[a]!.y - at[b]!.y
    return (dx * dx + dy * dy).squareRoot()
}

@Test func planetsWithRoomStayExactlyAtTheirOwnPlaces() {
    let bodies = ["a": ForceField.Body(home: CGPoint(x: 80, y: 100), radius: 35),
                  "b": ForceField.Body(home: CGPoint(x: 190, y: 300), radius: 35)]
    let at = ForceField.settle(bodies, held: nil, in: island)
    #expect(at["a"] == CGPoint(x: 80, y: 100) && at["b"] == CGPoint(x: 190, y: 300))
}

@Test func aHeldPlanetStaysAndTheOthersMakeRoomWithoutEverTouchingIt() {
    // Carried right onto another planet: the held one stays under the pointer and the other gives way.
    let bodies = ["held": ForceField.Body(home: CGPoint(x: 140, y: 300), radius: 44),
                  "other": ForceField.Body(home: CGPoint(x: 150, y: 310), radius: 35)]
    let at = ForceField.settle(bodies, held: "held", in: island)
    #expect(at["held"] == CGPoint(x: 140, y: 300))
    #expect(gap(at, "held", "other") >= 44 + 35 + 6 - 0.5)
}

@Test func planetsLeanAwayBeforeTheyTouchButKeepNearTheirPlaces() {
    // Within reach but not touching: the other leans away a little, not all the way out of reach.
    let bodies = ["held": ForceField.Body(home: CGPoint(x: 100, y: 300), radius: 35),
                  "other": ForceField.Body(home: CGPoint(x: 190, y: 300), radius: 35)]
    let at = ForceField.settle(bodies, held: "held", in: island, gap: 6, lean: 26)
    #expect(at["other"]!.x > 190 && at["other"]!.x < 100 + 35 + 35 + 6 + 26)
}

@Test func aCrowdedIslandKeepsEveryPlanetApartAndInside() {
    // Six planets all given the same place still end up apart, and none leaves the island.
    let bodies = Dictionary(uniqueKeysWithValues: (0..<6).map { ("p\($0)", ForceField.Body(home: CGPoint(x: 140, y: 300), radius: 35)) })
    let at = ForceField.settle(bodies, held: "p0", in: island)
    for (a, b) in [("p0", "p1"), ("p1", "p2"), ("p2", "p3"), ("p3", "p4"), ("p4", "p5"), ("p0", "p5"), ("p1", "p4")] {
        #expect(gap(at, a, b) >= 76 - 1)
    }
    for point in at.values { #expect(island.insetBy(dx: 34.5, dy: 34.5).contains(point)) }
}
