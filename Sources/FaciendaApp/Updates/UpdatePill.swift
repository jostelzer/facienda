import SwiftUI

/// The blue pill at the end of the top bar, as in Codex: it shows the download, then becomes the Update button.
/// Nothing shows while there is no new version.
struct UpdatePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let updater = AppUpdater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .downloading(let progress):
                pill(progress.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading", busy: true)
            case .installing:
                pill("Installing", busy: true)
            case .ready:
                Button { updater.install() } label: { pill("Update", busy: false) }
                    .buttonStyle(.plain)
                    .help("Facienda \(updater.version ?? "") is ready. Facienda quits, updates and opens again.")
            case .idle, .checking:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : Motion.move, value: updater.phase)
    }

    private func pill(_ label: String, busy: Bool) -> some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold))
            }
            Text(label).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).frame(height: 22)
        .background(Palette.blue, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}
