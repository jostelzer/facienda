import CoreGraphics
import Testing

private let others = ["studio": CGPoint(x: 90, y: 120), "garden": CGPoint(x: 210, y: 300)]

@Test func aPlanetFarFromEveryLineGoesExactlyWhereThePointerHasIt() {
    let snap = LineUp.snap(CGPoint(x: 150, y: 200), to: others)
    #expect(snap == LineUp.Snap(point: CGPoint(x: 150, y: 200), column: nil, row: nil))
}

@Test func aPlanetNearAnothersLineClicksOntoItInThatDirectionOnly() {
    // Nearly level with the garden: it comes level, and keeps its own place across.
    let level = LineUp.snap(CGPoint(x: 120, y: 306), to: others)
    #expect(level.point == CGPoint(x: 120, y: 300) && level.row == "garden" && level.column == nil)
    // Nearly under the studio.
    let under = LineUp.snap(CGPoint(x: 97, y: 260), to: others)
    #expect(under.point == CGPoint(x: 90, y: 260) && under.column == "studio" && under.row == nil)
}

@Test func aPlanetCanLineUpWithTwoPlanetsAtOnce() {
    let snap = LineUp.snap(CGPoint(x: 94, y: 296), to: others)
    #expect(snap.point == CGPoint(x: 90, y: 300) && snap.column == "studio" && snap.row == "garden")
}

@Test func ofSeveralPlanetsOnOneLineTheClosestOneIsTheGuide() {
    let stacked = ["near": CGPoint(x: 100, y: 200), "far": CGPoint(x: 100, y: 500)]
    #expect(LineUp.snap(CGPoint(x: 104, y: 260), to: stacked).column == "near")
    #expect(LineUp.snap(CGPoint(x: 104, y: 440), to: stacked).column == "far")
}
