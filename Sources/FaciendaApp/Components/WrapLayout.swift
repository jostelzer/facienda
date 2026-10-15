import SwiftUI

/// Lays its views out left to right, starting a new line when the next one no longer fits.
struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let places = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: places.map(\.frame.maxX).max() ?? 0, height: places.map(\.frame.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for place in arrange(width: bounds.width, subviews) {
            subviews[place.index].place(at: CGPoint(x: bounds.minX + place.frame.minX, y: bounds.minY + place.frame.minY), proposal: ProposedViewSize(place.frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(index: Int, frame: CGRect)] {
        var places: [(index: Int, frame: CGRect)] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing / 2; lineHeight = 0 }
            places.append((index, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        return places
    }
}
