import AppKit
import SwiftUI

/// The voice heard since the last words, drawn after the text as the outline of its sound: as wide as it was long,
/// swelling on each syllable, blue while it is being spoken. When Whisper's words arrive, each outline stretches
/// to its word and fades, so the words seem to come out of the sound.
struct VoiceShapes: View {
    let dictation: Dictation
    /// The field's text, or the prompt it shows, which the outlines follow.
    let text: String
    var fontSize: CGFloat = 15
    /// Outlines carry on to the next lines; a one-line bar keeps them on its line instead.
    var wraps = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var leaving: [Leaving] = []
    @State private var width: CGFloat = 0

    static let pointsPerSecond: CGFloat = 100
    static let height: CGFloat = 18
    static let gap: CGFloat = 4

    static func length(_ shape: VoiceShape) -> CGFloat { max(6, CGFloat(shape.duration) * pointsPerSecond) }

    var body: some View {
        let frames = dictation.shapes.isEmpty ? [:] : Self.place(dictation.shapes, after: TextFlow(text, width: width, fontSize: fontSize), width: width, wraps: wraps)
        ZStack(alignment: .topLeading) {
            ForEach(dictation.shapes) { shape in
                if let frame = frames[shape.id] {
                    Silhouette(contour: shape.contour)
                        .fill(shape.open ? Palette.blue.opacity(0.55) : Palette.muted.opacity(0.3))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            ForEach(leaving) { LeavingShape(item: $0, reduceMotion: reduceMotion) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: Snapshot(text: text, shapes: dictation.shapes)) { old, new in arrive(from: old, to: new) }
    }

    private struct Snapshot: Equatable {
        let text: String
        let shapes: [VoiceShape]
    }

    /// Outlines whose voice Whisper has now written down stretch onto the new words, in order, and fade.
    private func arrive(from old: Snapshot, to new: Snapshot) {
        let gone = old.shapes.filter { shape in !new.shapes.contains { $0.id == shape.id } }
        guard !gone.isEmpty, width > 0 else { return }
        let before = Self.place(old.shapes, after: TextFlow(old.text, width: width, fontSize: fontSize), width: width, wraps: wraps)
        let start = old.text.commonPrefix(with: new.text).utf16.count
        let words = TextFlow(new.text, width: width, fontSize: fontSize).wordRects(from: start)
        let items = gone.enumerated().compactMap { index, shape -> Leaving? in
            guard let from = before[shape.id] else { return nil }
            let to = words.isEmpty ? from : words[min(index, words.count - 1)]
            return Leaving(id: shape.id, contour: shape.contour, from: from,
                           to: CGRect(x: to.minX, y: to.midY - Self.height / 2, width: max(to.width, 4), height: Self.height))
        }
        leaving += items
        let ids = Set(items.map(\.id))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            leaving.removeAll { ids.contains($0.id) }
        }
    }

    /// Where each outline goes: after the text, one after another, onto the next line when one is full.
    static func place(_ shapes: [VoiceShape], after flow: TextFlow, width: CGFloat, wraps: Bool) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        var (x, middle) = (flow.end.x, flow.end.y)
        for shape in shapes {
            let size = min(length(shape), max(width, 6))
            if wraps, x > 0, x + size > width { x = 0; middle += flow.lineHeight }
            frames[shape.id] = CGRect(x: x, y: middle - height / 2, width: size, height: height)
            x += size + gap
        }
        return frames
    }
}

private struct Leaving: Identifiable {
    let id: Int
    let contour: [Double]
    let from: CGRect
    let to: CGRect
}

/// An outline taking its word's place: it stretches to the word and fades, on one curve.
private struct LeavingShape: View {
    let item: Leaving
    let reduceMotion: Bool
    @State private var gone = false

    var body: some View {
        let frame = gone && !reduceMotion ? item.to : item.from
        Silhouette(contour: item.contour).fill(Palette.muted.opacity(0.3))
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .opacity(gone ? 0 : 1)
            .onAppear { withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.38)) { gone = true } }
    }
}

/// The outline of a sound, mirrored around the middle: loud parts swell, quiet parts thin, and both ends taper.
struct Silhouette: Shape {
    var contour: [Double]

    func path(in rect: CGRect) -> Path {
        let points = Self.smoothed(contour)
        var path = Path()
        guard points.count > 1 else { path.addEllipse(in: rect.insetBy(dx: 0, dy: rect.height / 2 - 1.5)); return path }
        let steps = CGFloat(points.count - 1), half = rect.height / 2
        let top = points.enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(index) / steps * rect.width, y: rect.midY - (0.8 + value * (half - 1)))
        }
        let ring = top + top.reversed().map { CGPoint(x: $0.x, y: 2 * rect.midY - $0.y) }
        path.move(to: ring[0])
        for index in 1..<ring.count {
            let a = ring[index - 1], b = ring[index]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.addLine(to: ring[ring.count - 1])
        path.closeSubpath()
        return path
    }

    /// Every 30 ms, as 0…1 above the room, tapering at both ends.
    static func smoothed(_ contour: [Double]) -> [CGFloat] {
        let chunk = 3
        var points: [CGFloat] = stride(from: 0, to: contour.count, by: chunk).map { start in
            let slice = contour[start..<min(start + chunk, contour.count)]
            let mean = slice.reduce(0, +) / Double(slice.count)
            return CGFloat(min(max((mean - 0.22) / 0.55, 0), 1))
        }
        for (index, factor) in [CGFloat(0.3), 0.65].enumerated() where points.count > 2 * index + 2 {
            points[index] *= factor
            points[points.count - 1 - index] *= factor
        }
        return points
    }
}

/// Where text in this font lies in a field this wide, measured the way AppKit lays it out.
@MainActor struct TextFlow {
    let text: String
    let lineHeight: CGFloat
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private let storage: NSTextStorage
    private let space: CGFloat

    init(_ text: String, width: CGFloat, fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize)
        self.text = text
        storage = NSTextStorage(string: text, attributes: [.font: font])
        container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        lineHeight = manager.defaultLineHeight(for: font)
        space = (" " as NSString).size(withAttributes: [.font: font]).width
    }

    /// Where the next word would begin, as its x and the middle of its line.
    var end: CGPoint {
        let length = (text as NSString).length
        guard length > 0 else { return CGPoint(x: 0, y: lineHeight / 2) }
        if text.last?.isNewline == true {
            let extra = manager.extraLineFragmentRect
            return CGPoint(x: 0, y: extra.height > 0 ? extra.midY : lineHeight * 1.5)
        }
        let glyph = manager.glyphIndexForCharacter(at: length - 1)
        let line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let last = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return CGPoint(x: last.maxX + (text.last?.isWhitespace == true ? 0 : space), y: line.midY)
    }

    /// The words from a UTF-16 offset on, each as the rectangle it takes.
    func wordRects(from start: Int) -> [CGRect] {
        let string = text as NSString
        guard start < string.length else { return [] }
        var rects: [CGRect] = []
        string.enumerateSubstrings(in: NSRange(location: start, length: string.length - start), options: .byWords) { _, range, _, _ in
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            rects.append(manager.boundingRect(forGlyphRange: glyphs, in: container))
        }
        return rects
    }
}
