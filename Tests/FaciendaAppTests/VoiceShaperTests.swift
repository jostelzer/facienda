import Testing

/// Loudness every 10 ms: `steps` of one level.
private func hear(_ shaper: inout VoiceShaper, _ level: Double, steps: Int) {
    for _ in 0..<steps { shaper.hear(level) }
}

@Test func voiceOpensAShapeAndQuietClosesIt() {
    var shaper = VoiceShaper()
    hear(&shaper, 0.1, steps: 20)
    #expect(shaper.shapes.isEmpty)
    hear(&shaper, 0.6, steps: 30)
    #expect(shaper.shapes.count == 1 && shaper.shapes[0].open)
    #expect(abs(shaper.shapes[0].start - 0.2) < 0.001)
    hear(&shaper, 0.1, steps: 12)
    let shape = try! #require(shaper.shapes.first)
    // The quiet that closed it is not part of it.
    #expect(!shape.open && shape.contour.count == 30 && abs(shape.duration - 0.3) < 0.001)
}

@Test func clicksAreTooShortToKeep() {
    var shaper = VoiceShaper()
    hear(&shaper, 0.7, steps: 3)
    hear(&shaper, 0.1, steps: 12)
    #expect(shaper.shapes.isEmpty)
}

@Test func aLongStretchSplitsAtAClearDip() {
    var shaper = VoiceShaper()
    hear(&shaper, 0.1, steps: 50)
    hear(&shaper, 0.8, steps: 50)
    // Still above room noise, but well under the peak: a gap between words in fluent speech.
    hear(&shaper, 0.35, steps: 6)
    hear(&shaper, 0.8, steps: 20)
    #expect(shaper.shapes.count == 2)
    #expect(!shaper.shapes[0].open && shaper.shapes[1].open)
}

@Test func writtenVoiceIsForgottenAndACutShapeKeepsTheRest() {
    var shaper = VoiceShaper()
    hear(&shaper, 0.6, steps: 30)
    hear(&shaper, 0.1, steps: 20)
    hear(&shaper, 0.6, steps: 40)
    #expect(shaper.shapes.count == 2)
    // Whisper has written down everything up to 0.7 s, part way into the second shape.
    shaper.cover(until: 0.7)
    let rest = try! #require(shaper.shapes.first)
    #expect(shaper.shapes.count == 1 && abs(rest.start - 0.7) < 0.001 && rest.contour.count == 20 && rest.open)
    shaper.cover(until: .infinity)
    #expect(shaper.shapes.isEmpty)
}

@Test func theRoomSetsTheBar() {
    var shaper = VoiceShaper()
    // A noisy room: nothing in it is a voice.
    for index in 0..<200 { shaper.hear(index % 2 == 0 ? 0.3 : 0.36) }
    #expect(shaper.shapes.isEmpty)
    #expect(abs(shaper.floor - 0.3) < 0.01)
    // A voice well above it is.
    hear(&shaper, 0.6, steps: 20)
    #expect(shaper.shapes.count == 1)
}
