import SwiftUI
import CoreImage

extension AppModel {
    /// A group's cover and the colour drawn from it. Unsorted and groups without a cover use blue.
    func look(for group: String) -> (cover: NSImage?, tint: Color) {
        let cover = coversEnabled ? coverImages[group] : nil
        return (cover, cover.map { Color(nsColor: CoverTint.of($0)) } ?? Palette.blue)
    }
    /// The lit group's look.
    var spotlightLook: (cover: NSImage?, tint: Color)? { spotlitGroup.map(look(for:)) }
}

/// While a group's sheet is up the window fills with a blurred, slowly drifting wash of its cover,
/// so the whole room takes on that group's colours. A click on the wash lets the group go.
struct MoodSpotlight: View {
    var cover: NSImage?
    var tint: Color
    var release: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var drifting = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // Already blurred once, small: moving it costs nothing, where blurring the whole window every frame stuttered.
                wash.frame(width: size.width, height: size.height)
                    .scaleEffect(settled ? (drifting ? 1.08 : 1) : 1.25)
                    .offset(x: drifting ? -12 : 0, y: drifting ? 6 : 0)
                    .opacity(0.92)
                Color.black.opacity(0.5)
            }
            .frame(width: size.width, height: size.height).clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: release)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { settled = true; return }
            // The wash settles with the sheet, then drifts on the same curve, slowed right down.
            withAnimation(Motion.travel) { settled = true } completion: {
                withAnimation(Motion.curve(9).repeatForever(autoreverses: true)) { drifting = true }
            }
        }
    }

    @ViewBuilder private var wash: some View {
        if let cover { Image(nsImage: CoverWash.of(cover)).resizable().interpolation(.high).scaledToFill() } else { tint }
    }
}

/// A cover blurred and deepened once, at a small size, for the wash behind a group's sheet.
@MainActor enum CoverWash {
    private static let cache = NSMapTable<NSImage, NSImage>.weakToStrongObjects()
    private static let context = CIContext()

    static func of(_ image: NSImage) -> NSImage {
        if let known = cache.object(forKey: image) { return known }
        let wash = render(image) ?? image
        cache.setObject(wash, forKey: image)
        return wash
    }

    private static func render(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // About a fifth of a window's width, so a 7 px blur here reads like the 34 pt one across the window.
        let width = 240.0, source = CIImage(cgImage: cgImage)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: width / source.extent.width, y: width / source.extent.width))
        let output = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 7)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
            .cropped(to: scaled.extent)
        guard let result = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: result, size: output.extent.size)
    }
}

/// The colour a cover is mostly about: the hue its vivid pixels share most, kept bright enough to draw a rim with.
@MainActor enum CoverTint {
    private static let cache = NSMapTable<NSImage, NSColor>.weakToStrongObjects()

    static func of(_ image: NSImage) -> NSColor {
        if let known = cache.object(forKey: image) { return known }
        let tint = measure(image) ?? NSColor(Palette.blue)
        cache.setObject(tint, forKey: image)
        return tint
    }

    private static func measure(_ image: NSImage) -> NSColor? {
        let side = 24
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        // Twelve hue buckets; vivid, bright pixels count most and grey ones hardly at all.
        var buckets = Array(repeating: (weight: 0.0, x: 0.0, y: 0.0, saturation: 0.0), count: 12)
        for column in 0..<side {
            for row in 0..<side {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                let weight = pow(color.saturationComponent * color.brightnessComponent, 2)
                let angle = color.hueComponent * 2 * .pi, index = min(Int(color.hueComponent * 12), 11)
                buckets[index].weight += weight
                buckets[index].x += cos(angle) * weight; buckets[index].y += sin(angle) * weight
                buckets[index].saturation += color.saturationComponent * weight
            }
        }
        guard let top = buckets.max(by: { $0.weight < $1.weight }), top.weight > 0.01 else { return nil }
        var hue = atan2(top.y, top.x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return NSColor(hue: hue, saturation: min(max(top.saturation / top.weight, 0.45), 0.8), brightness: 0.75, alpha: 1)
    }
}
