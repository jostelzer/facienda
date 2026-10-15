import Foundation

/// A stretch of voice, from when it rose above the room until it went quiet, with its loudness every 10 ms.
/// Dictation draws it as the outline of its sound until Whisper's words for it arrive.
struct VoiceShape: Identifiable, Equatable {
    let id: Int
    /// Seconds since listening began.
    var start: Double
    var end: Double
    /// Loudness, 0…1, every `VoiceShaper.step` seconds.
    var contour: [Double]
    /// Still being spoken.
    var open: Bool
    var duration: Double { end - start }
}

/// Cuts the microphone's loudness into shapes, without any model, so the voice shows up the moment it starts.
/// It follows the room's noise: a shape opens well above it and closes after a short quiet near it. Fluent speech
/// rarely goes quiet between words, so a clear dip below the shape's recent peak ends a shape too, and a long one
/// ends at the next small dip; that keeps shapes about a word long.
struct VoiceShaper {
    static let step = 0.01
    /// How far above the room a voice must rise to open a shape, and how close to it counts as quiet (0…1 is 55 dB).
    static let rise = 0.14, settle = 0.07
    /// 120 ms of quiet ends a shape.
    static let quietSteps = 12
    /// 30 ms this far under the recent peak splits a shape that has run at least `splittable`.
    static let dip = 0.12, dipSteps = 3, splittable = 0.2
    /// Past this, any small dip splits it.
    static let longest = 0.9
    static let shortest = 0.08
    /// The room is the quietest tenth of the last three seconds.
    static let roomSteps = 300

    private(set) var shapes: [VoiceShape] = []
    /// The room's noise. A typical room until there is enough to measure.
    private(set) var floor = 0.25
    private var recent: [Double] = []
    private var clock = 0
    private var quietRun = 0
    private var dipRun = 0
    private var peak = 0.0
    private var nextID = 0

    mutating func hear(_ level: Double) {
        let now = Double(clock) * Self.step
        clock += 1
        listen(to: level)
        guard shapes.last?.open == true, var shape = shapes.last else {
            if level >= floor + Self.rise {
                shapes.append(VoiceShape(id: nextID, start: now, end: now + Self.step, contour: [level], open: true))
                nextID += 1; peak = level; quietRun = 0; dipRun = 0
            }
            return
        }
        shape.contour.append(level)
        shape.end = now + Self.step
        peak = max(level, peak - 0.004)
        let quiet = level < floor + Self.settle
        quietRun = quiet ? quietRun + 1 : 0
        dipRun = !quiet && level < peak - Self.dip ? dipRun + 1 : 0
        shapes[shapes.count - 1] = shape
        if quietRun >= Self.quietSteps {
            close(trimming: quietRun)
        } else if dipRun >= Self.dipSteps, shape.duration >= Self.splittable {
            close(trimming: dipRun)
        } else if shape.duration >= Self.longest, level < peak - 0.04 {
            close(trimming: 0)
        }
    }

    /// Keeps `floor` at the quietest tenth of recent sound. Exact silence in the first 300 ms is the microphone starting, not the room.
    private mutating func listen(to level: Double) {
        guard level > 0 || clock > 30 else { return }
        recent.append(level)
        if recent.count > Self.roomSteps { recent.removeFirst(recent.count - Self.roomSteps) }
        guard recent.count >= 30, clock % 10 == 0 else { return }
        floor = min(recent.sorted()[recent.count / 10], 0.45)
    }

    /// Forgets the voice up to `time`, which Whisper has written down. A shape it cut through keeps only the rest.
    mutating func cover(until time: Double) {
        shapes = shapes.compactMap { shape in
            guard shape.end > time else { return nil }
            guard shape.start < time else { return shape }
            var rest = shape
            let cut = min(Int(((time - shape.start) / Self.step).rounded()), shape.contour.count)
            rest.contour.removeFirst(cut)
            rest.start = time
            return rest.contour.isEmpty || (!rest.open && rest.duration < Self.shortest) ? nil : rest
        }
    }

    private mutating func close(trimming steps: Int) {
        var shape = shapes.removeLast()
        let trim = min(steps, shape.contour.count - 1)
        shape.contour.removeLast(trim)
        shape.end -= Double(trim) * Self.step
        shape.open = false
        quietRun = 0; dipRun = 0; peak = 0
        if shape.duration >= Self.shortest { shapes.append(shape) }
    }
}
