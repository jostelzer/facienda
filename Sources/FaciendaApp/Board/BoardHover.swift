import SwiftUI

/// What the pointer is over on the board.
@MainActor @Observable final class BoardHover {
    var card: String?
    var row: String?
    var cover: String?
}

extension GroupBoard {
    /// A card's edge, which firms up under the pointer to mark the card as one thing to grab.
    struct CardEdge: View {
        let hover: BoardHover
        let key: String?
        var body: some View {
            let firm = key != nil && hover.card == key
            RoundedRectangle(cornerRadius: 12).strokeBorder(firm ? Palette.firmLine : Palette.line, lineWidth: 1).animation(Motion.fade, value: firm)
        }
    }

    /// The row under the pointer is washed so the click that opens it has somewhere to land.
    /// Every wash has the slip's shape and width, so a hovered row and an unread one read alike.
    /// On an unread row it sits just inside the slip's 1 pt edge and deepens the slip's blue instead of greying it.
    struct RowWash: View {
        let hover: BoardHover
        let id: String
        var slip = false
        var body: some View {
            let washed = hover.row == id, edge: CGFloat = slip ? 1 : 0
            ZStack {
                if washed {
                    RoundedRectangle(cornerRadius: 8 - edge).fill(slip ? Palette.blue.opacity(0.08) : Palette.selected.opacity(0.55))
                        .padding(.horizontal, -(GroupBoard.cardInset - GroupBoard.slipInset - edge)).padding(.vertical, edge)
                }
            }
            .animation(Motion.fade, value: washed)
        }
    }

    /// A row's own tile: a faint rounded ground in the slip's shape and width, so each row stands as one thing and the
    /// card needs no rules between them. The wash and an unread slip lie over it.
    struct RowTile: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(0.05))
                .padding(.horizontal, -(GroupBoard.cardInset - GroupBoard.slipInset))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// The cover's controls, shown while the pointer is over the cover or its adjust popover is open.
    struct CoverHover<Controls: View>: View {
        let hover: BoardHover
        let id: String
        let pinned: Bool
        @ViewBuilder let controls: () -> Controls
        var body: some View {
            let hovered = hover.cover == id
            ZStack { if hovered || pinned { controls() } }
                .animation(Motion.fade, value: hovered)
        }
    }
}
