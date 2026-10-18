import AppKit
import SwiftUI

/// Where a lifted group will come down. It breathes gently so the eye finds it.
struct LandingSpot: View {
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RoundedRectangle(cornerRadius: 12).fill(Palette.blue.opacity(breathing ? 0.12 : 0.05))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.blue.opacity(breathing ? 0.8 : 0.45), lineWidth: 1.5))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.curve(0.8).repeatForever(autoreverses: true)) { breathing = true }
            }
    }
}

/// A ring that expands and fades once when a group lands.
struct LandingPulse: View {
    let finished: () -> Void
    @State private var out = false
    var body: some View {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.blue, lineWidth: 2)
            .scaleEffect(out ? 1.035 : 1).opacity(out ? 0 : 0.9).allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.45)) { out = true } completion: { finished() } }
    }
}

/// A group holding something new wears a steady blue edge. Nothing on the edge moves: the unread dots inside the card carry the movement.
struct FreshRim: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.blue.opacity(0.85), lineWidth: 1.5)
            .opacity(on ? 1 : 0).animation(Motion.move, value: on)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The ring round the row the top bar's reading acts on: what Return will open, bring back or reply to. It comes and
/// goes in place with the reading, on the fade.
struct ReadingRing: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.blue, lineWidth: 1.5)
            .opacity(on ? 1 : 0).animation(Motion.fade, value: on)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The unread dot. While the work waits, a thin ring leaves it every few seconds and fades, so a task that came back
/// is seen from across the board. Every dot reads the same clock, so several on a board ring together.
/// It keeps ringing under Reduce Motion, like the running arc: it grows in place and never travels.
struct UnreadDot: View {
    let size: CGFloat
    static let period = 3.2
    /// The share of each period the ring takes to spread and fade; the rest is stillness.
    private static let spread = 0.45
    private static let reach = 3.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            let progress = min(phase / Self.spread, 1)
            // Eased out: the ring leaves quickly and slows as it fades.
            let eased = 1 - (1 - progress) * (1 - progress)
            Circle().fill(Palette.blue).frame(width: size, height: size)
                .background {
                    Circle().strokeBorder(Palette.blue, lineWidth: 1.5).frame(width: size, height: size)
                        .scaleEffect(1 + (Self.reach - 1) * eased).opacity(0.85 * (1 - eased))
                }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// An unread row sits on a slip of paper lifted just off the card, inside its edges. The slip rises when the work
/// comes back and settles flat when the task is opened. It is light blue with a thin blue edge, the only blue on the
/// card besides its rim. It stands tallest just after the work came back and sinks over the first hour, so the
/// freshest thing on the board is the loudest. Coming back to
/// Facienda after a while lifts the slips again, all together; otherwise it holds still.
struct UnreadSlip: View {
    let on: Bool
    /// When the work came back; nil stands as fresh.
    let since: Date?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flat for the moment before a greeting lifts it again.
    @State private var greeting = false
    @State private var leftAt: Date?

    /// A quick look at another app doesn't count as having been away.
    private static let away: TimeInterval = 20
    private static let settling: TimeInterval = 3600
    /// How far a slip sinks: after the first hour it keeps this much of its lift.
    private static let rest = 0.12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let age = since.map { context.date.timeIntervalSince($0) } ?? 0
            let fresh = max(Self.rest, 1 - age / Self.settling)
            let lift = on && !greeting ? fresh : 0
            // Dark shadows need far more weight to read against a dark card.
            let near = scheme == .dark ? 0.25 : 0.06, far = scheme == .dark ? 0.40 : 0.08
            // The blue belongs to the new row alone: a crisp light-blue slip with a thin blue edge, never a glow around it.
            RoundedRectangle(cornerRadius: 8).fill(Palette.slip)
                .overlay { RoundedRectangle(cornerRadius: 8).fill(Palette.blue.opacity(scheme == .dark ? 0.14 : 0.08)) }
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.blue.opacity(0.4 + 0.25 * lift), lineWidth: 1) }
                .shadow(color: .black.opacity(on ? near : 0), radius: on ? 1 : 0, y: on ? 1 : 0)
                .shadow(color: .black.opacity(far * lift), radius: 2 + 3 * lift, y: 1 + 2 * lift)
                .opacity(on ? 1 : 0)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in leftAt = .now }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in greet() }
    }

    private func greet() {
        defer { leftAt = nil }
        guard on, !reduceMotion, let leftAt, Date.now.timeIntervalSince(leftAt) >= Self.away else { return }
        greeting = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(Motion.move) { greeting = false }
        }
    }
}
