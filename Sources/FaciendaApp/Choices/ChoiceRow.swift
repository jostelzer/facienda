import SwiftUI

/// One line in the popover: icon, title, optional detail. The whole row is the button.
struct ChoiceRow: View {
    let title: String
    var detail: String? = nil
    let symbol: String
    var highlighted = false
    /// The icon's colour when the row is not highlighted, for rows inside a coloured section.
    var tint: Color? = nil
    /// The highlighted row's colour, so it matches its section.
    var accent: Color = Palette.blue
    /// How many lines the detail may take; nil shows it whole, as for a message about to be sent.
    var detailLines: Int? = 2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16).padding(.top, 1)
                    .foregroundStyle(highlighted ? accent : tint ?? Palette.ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(detailLines).fixedSize(horizontal: false, vertical: detailLines == nil) }
                }
                Spacer(minLength: 0)
                if highlighted { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 3) }
            }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(highlighted ? accent : Palette.ink)
        .background(highlighted ? accent.opacity(0.12) : hovering ? Palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
}

/// A small spinner with a word on what is being read, in place of rows still to come.
struct ChoiceProgress: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted) }
            .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

extension View {
    /// The edge of a text field among the choices, blue while it has the keyboard.
    func choiceField(focused: Bool) -> some View {
        padding(.horizontal, 9).padding(.vertical, 7)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Palette.blue.opacity(0.6) : Palette.line, lineWidth: 1))
    }
}
