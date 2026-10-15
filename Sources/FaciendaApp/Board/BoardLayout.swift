import SwiftUI

/// A card's column, and its place in that column's stack.
struct BoardSlot: Equatable { var lane: Int; var row: Int }

struct BoardSlotValue: Equatable {
    var lane: Int
    /// The card's place in its column, from the top.
    var row: Int
    /// Display order, which breaks ties between cards asking for the same place.
    var order: Int
    /// A lifted card wins its row outright, so it can be put above a card that is already there.
    var lifted: Bool
}
struct BoardSlotKey: LayoutValueKey { static let defaultValue = BoardSlotValue(lane: 0, row: 0, order: 0, lifted: false) }

/// Equal columns. Each card names its column and its place in it; cards stack from the top, so they stay siblings and slide when they move.
struct BoardLayout: Layout {
    var lanes: Int
    var spacing: CGFloat

    private func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = max(1, lanes), width = width.isFinite ? max(width, 1) : 600
        let laneWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var bottom: CGFloat = 0
        let slots = subviews.indices.map { ($0, subviews[$0][BoardSlotKey.self]) }
        for lane in 0..<count {
            let column = slots.filter { min(max($0.1.lane, 0), count - 1) == lane }
                .sorted { ($0.1.row, $0.1.lifted ? 0 : 1, $0.1.order) < ($1.1.row, $1.1.lifted ? 0 : 1, $1.1.order) }
            var floor: CGFloat = -spacing
            for (index, _) in column {
                let height = subviews[index].sizeThatFits(ProposedViewSize(width: laneWidth, height: nil)).height
                let y = floor + spacing
                frames[index] = CGRect(x: CGFloat(lane) * (laneWidth + spacing), y: y, width: laneWidth, height: height)
                floor = y + height; bottom = max(bottom, floor)
            }
        }
        return (frames, bottom)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // An unconstrained proposal asks for the ideal size; any finite width will do.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
