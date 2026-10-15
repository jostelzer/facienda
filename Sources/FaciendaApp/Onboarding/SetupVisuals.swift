import SwiftUI

/// One step of a guide, in Facienda's own marks: a green check once done, the step's number filled while it is the
/// one to do, and an outlined number for what comes later. A line joins the steps.
enum GuideStepState { case done, now, optional, later }

struct GuideStep<Content: View>: View {
    typealias State = GuideStepState
    let number: Int
    let kind: RunnerKind
    let state: State
    let title: String
    var last = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                badge
                if !last { Rectangle().fill(Palette.line).frame(width: 2).frame(maxHeight: .infinity) }
            }.frame(width: 30)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: state == .later ? .medium : .semibold))
                    .foregroundStyle(state == .later ? Palette.muted : Palette.ink)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5).padding(.bottom, last ? 0 : 22)
        }.accessibilityElement(children: .contain)
    }

    private var badge: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Palette.green)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            case .now:
                Circle().fill(kind.tint)
                Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(kind == .codex ? Palette.paper : .white)
            case .optional, .later:
                Circle().fill(Palette.card)
                Circle().strokeBorder(Palette.firmLine, lineWidth: 1.5)
                Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            }
        }.frame(width: 30, height: 30)
    }
}

/// The Codex or Claude composer as a small drawing, its Send arrow ringed, so the button to press is easy to find.
struct ComposerSketch: View {
    let kind: RunnerKind
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(kind == .codex ? Palette.paper : .white)
                .frame(width: 24, height: 24).background(kind.tint, in: Circle())
                .overlay(Circle().strokeBorder(Palette.blue.opacity(0.4), lineWidth: 3))
        }.padding(10).background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Where Codex trusts hooks, drawn the way Codex shows untrusted ones: Settings › Hooks › User config ("5 need review"),
/// then the banner's Trust all button, ringed.
struct CodexHooksSketch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(["Settings", "Hooks", "User config"].enumerated()), id: \.offset) { index, place in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted) }
                    Text(place).font(.system(size: 12, weight: .medium))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.amber)
                Text("Hooks run outside of the sandbox…").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer(minLength: 8)
                Text("Trust all").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                    .overlay(Capsule().strokeBorder(Palette.blue.opacity(0.4), lineWidth: 3).padding(-3))
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("In Codex, open Settings, Hooks, User config, and choose Trust all.")
    }
}
