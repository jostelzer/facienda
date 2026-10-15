import SwiftUI

/// Asks how a painted picture should change, or what new picture to paint instead, and shows the wishes every repaint already honours.
struct CoverWishPopover: View {
    @Binding var wish: String
    let notes: [String]
    let subject: String
    let forget: () -> Void
    let apply: () -> Void
    let cancel: () -> Void
    /// Brings back the picture the last change replaced; nil when there is none.
    var restore: (() -> Void)? = nil

    private var empty: Bool { wish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How should the \(subject) change?").font(.system(size: 12, weight: .semibold))
            TextField("more green · at night · or: a lighthouse instead", text: $wish)
                .textFieldStyle(.roundedBorder).font(.system(size: 13)).frame(width: 300)
                .onSubmit { if !empty { apply() } }
            if !notes.isEmpty {
                Text("Remembered: " + notes.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(3)
                    .frame(width: 300, alignment: .leading)
                Button("Forget these", action: forget).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack {
                if let restore {
                    Button("Restore previous \(subject)", action: restore).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Repaint", action: apply).keyboardShortcut(.defaultAction).disabled(empty)
            }
        }.padding(14)
    }
}
