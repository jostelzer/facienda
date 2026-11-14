import SwiftUI
import FaciendaCore

/// The card's switch between the order the user dragged and the order by date, beside the +: a round capsule with both glyphs,
/// three lines for the user's order and the sort arrows for by date, and a round thumb on the one in use. The thumb slides
/// on the same move as the rows, so the click and what it does land together. Like the +, it keeps a grace zone, since a click
/// anywhere else on a card folds it.
struct SortButton: View {
    let byDate: Bool
    let action: () -> Void
    @State private var hovering = false
    private static let slot: CGFloat = 24

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                glyph(Image(systemName: "line.3.horizontal"), on: !byDate)
                glyph(Image(systemName: "arrow.up.arrow.down"), on: byDate)
            }
            .background(alignment: .leading) {
                Circle().fill(Palette.card)
                    .overlay(Circle().strokeBorder(Palette.firmLine, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    .frame(width: Self.slot, height: Self.slot)
                    .offset(x: byDate ? Self.slot : 0)
            }
            .padding(1)
            .background(Capsule().fill(Palette.ink.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PlusButton.PressFade())
        .onHover { hovering = $0 }
        .animation(Motion.move, value: byDate)
        .animation(Motion.fade, value: hovering)
        .help(byDate ? "By date, newest first. Click for your order; ⌥-click does every card" : "Your order. Click to sort by date; ⌥-click does every card")
        .accessibilityLabel(byDate ? "Sorted by date" : "Sorted by hand")
        .accessibilityHint(byDate ? "Puts the card back in your order" : "Sorts the card by date, newest first")
        .background(GroupBoard.GraceZone())
    }

    /// The glyph of the order in use is in ink, the other muted; under the pointer both are in ink.
    private func glyph(_ image: some View, on: Bool) -> some View {
        image.font(.system(size: 11, weight: .medium))
            .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
            .frame(width: Self.slot, height: Self.slot)
    }
}

/// A day's name between the rows of a card sorted by date, in the margin the row names start from.
struct DayCaption: View {
    let band: DayBand
    let first: Bool

    var body: some View {
        Text(band.caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            .padding(.top, first ? 2 : 9).padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
