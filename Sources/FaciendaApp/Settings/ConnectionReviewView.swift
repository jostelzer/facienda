import SwiftUI
import FaciendaBridge

/// Shows the Codex configuration changes before Facienda backs up and applies them.
struct ConnectionReviewView: View {
    let plan: ConnectionPlan
    let error: String?
    let onCancel: () -> Void
    let onApply: () async -> Void
    @State private var applying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(plan.title).font(.system(size: 28, design: .serif))
            Text("Review the changes below. Facienda backs up your existing Codex configuration before applying them.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView { Text(plan.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(16).frame(height: 340).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent) }
            HStack {
                Button("Cancel", action: onCancel).disabled(applying)
                Spacer()
                Button(applying ? "Applying…" : "Back up and apply") {
                    applying = true; Task { await onApply(); applying = false }
                }.buttonStyle(QuietButton(prominent: true)).disabled(applying)
            }
        }.padding(28).frame(width: 700).background(Palette.paper).foregroundStyle(Palette.ink)
            .interactiveDismissDisabled(applying)
    }
}
