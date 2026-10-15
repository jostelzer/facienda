import SwiftUI
import QuartzCore
import os
import FaciendaCore

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Palette {
    static let paper = Color(light: 0xF9F8F5, dark: 0x1C1E1D)
    static let sidebar = Color(light: 0xF0EFEA, dark: 0x171918)
    static let card = Color(light: 0xFFFFFF, dark: 0x242725)
    /// An unread row's slip, a step lighter than the card in dark mode where shadows barely show.
    static let slip = Color(light: 0xFFFFFF, dark: 0x2C302D)
    static let ink = Color(light: 0x292D29, dark: 0xEEEDE5)
    static let muted = Color(light: 0x7B7E76, dark: 0xA4A79F)
    static let line = Color(light: 0xE5E5DC, dark: 0x353A35)
    /// A line one step firmer, for the rim of a card under the pointer.
    static let firmLine = Color(light: 0xC9C8BC, dark: 0x545A54)
    static let accent = Color(light: 0xA54D37, dark: 0xEA9A7D)
    /// Only what came back unseen: the unread dot, slip and rim.
    static let blue = Color(light: 0x3785E8, dark: 0x71AEFF)
    /// Work for review is the resting state of open work, so its marks stay in ink and leave the colour to the exceptions.
    static let review = ink
    static let amber = Color(light: 0x926516, dark: 0xE8BD6B)
    /// Orchid, for steps the user took on themselves: apart from the blue of review and the amber of waiting.
    static let purple = Color(light: 0xA4479F, dark: 0xEC93E0)
    static let selected = Color(light: 0xEEE8DA, dark: 0x39382F)
    static let green = Color(light: 0x56705C, dark: 0x97B69C)
}
/// How everything in Facienda moves: one curve that eases in, gathers speed and lands softly, never overshooting.
/// Only the duration changes, with how far a thing goes. Every part of one change rides one animation, so the parts
/// start and land together; a part that must wait for room shows within that animation, never on a timer of its own.
enum Motion {
    /// The curve itself, for the slow loops that breathe on it: a landing spot, the wash behind a group's sheet.
    static func curve(_ duration: Double) -> Animation { .timingCurve(0.65, 0, 0.35, 1, duration: duration) }
    /// Across the window: switching workspace, a group's sheet opening and folding home.
    static let travel = curve(0.52)
    /// Within the page: cards and rows making room or changing place, panels, filters, plan lines, toasts.
    static let move = curve(0.34)
    /// In place: what answers the pointer or the keys, and what stands in for travel under Reduce Motion.
    static let fade = curve(0.16)
}
/// For measuring: how many frames a motion really drew, logged once it lands (Console, category "Motion").
/// Temporary, while the workspace switch and the group sheet are tuned.
@MainActor enum MotionLog {
    private static var name: String?
    private static var started: CFTimeInterval = 0
    private static var frames: [CFTimeInterval] = []
    private static let log = Logger(subsystem: "org.facienda.mac", category: "Motion")

    static func begin(_ motion: String) { name = motion; started = CACurrentMediaTime(); frames = [] }
    static func frame() { if name != nil { frames.append(CACurrentMediaTime()) } }
    static func end() {
        guard let name, let first = frames.first, let last = frames.last else { self.name = nil; return }
        let gaps = zip(frames.dropFirst(), frames).map { $0 - $1 }
        let span = max(last - first, 0.001)
        let ms = { (seconds: Double) in Int((seconds * 1000).rounded()) }
        log.notice("""
            \(name, privacy: .public): \(frames.count) frames over \(ms(span)) ms, \(Int(Double(frames.count - 1) / span)) fps, \
            first frame \(ms(first - started)) ms after the start, longest gap \(ms(gaps.max() ?? 0)) ms, \
            \(gaps.filter { $0 > 0.025 }.count) gaps over 25 ms
            """)
        self.name = nil; frames = []
    }
}
extension Color {
    init(light: Int, dark: Int) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}
extension TaskState {
    var tint: Color {
        switch self {
        case .needsMe: Palette.review
        case .running, .done: Palette.green
        case .waiting: Color(light: 0x8D764E, dark: 0xC4AB7C)
        default: Palette.muted
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .needsMe: "circle.fill"
        case .waiting: "hourglass"
        case .scheduled: "clock"
        case .done: "checkmark.circle.fill"
        case .dropped: "minus.circle"
        case .inbox: "tray"
        }
    }
}
extension TaskStatus {
    var tint: Color {
        switch self {
        case .done: Palette.green
        case .ready, .needsInput, .needsPermission, .needsReview: Palette.review
        case .recovery, .prerequisiteChanged: Palette.accent
        case .working, .checking, .starting, .queued: Palette.green
        case .awaitingSend, .waitingForClaude: Palette.blue
        case .startingInClaude: Palette.green
        case .waiting, .waitingForChat, .prerequisites: Palette.amber
        case .scheduled: Palette.amber
        case .paused, .notStarted, .dropped: Palette.muted
        }
    }
    var symbol: String {
        switch self {
        case .ready: "hand.thumbsup.fill"
        case .needsInput: "questionmark.circle.fill"
        case .needsPermission: "hand.raised.fill"
        case .needsReview: "eye.fill"
        case .recovery, .prerequisiteChanged: "exclamationmark.circle.fill"
        case .paused: "pause.circle"
        case .checking: "magnifyingglass"
        case .waitingForChat, .waiting: "hourglass"
        case .starting, .working: "circle.dotted"
        case .queued: "ellipsis.circle"
        case .awaitingSend: "paperplane.circle"
        case .waitingForClaude: "moon.zzz"
        case .startingInClaude: "sparkle"
        case .notStarted: "play.circle"
        case .done: "checkmark.circle.fill"
        case .dropped: "archivebox"
        case .prerequisites: "link"
        case .scheduled: "clock"
        }
    }
}

struct TaskStatusBadge: View {
    let status: TaskStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.tint.opacity(0.10), in: Capsule())
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.muted) }
}
struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 11 : 12, weight: .medium))
            .padding(.horizontal, compact ? 8 : 14).padding(.vertical, compact ? 0 : 9)
            .frame(height: compact ? 32 : nil)
            .foregroundStyle(prominent ? Palette.paper : Palette.ink)
            .background(prominent ? Palette.ink : Palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? .clear : Palette.line, lineWidth: 1))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}
struct EmptyNote: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Palette.muted)
            Text(title).font(.system(size: 22, weight: .regular, design: .serif))
            Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 280)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AgentProvider {
    var tint: Color {
        switch self {
        case .codex: Palette.ink
        case .claude: Color(light: 0xD97757, dark: 0xE58B6B)
        }
    }
}

/// The app a task runs in, drawn as its mark: the ChatGPT knot for Codex, the Claude starburst for Claude.
struct ProviderMark: View {
    let provider: AgentProvider
    var size: CGFloat = 13

    var body: some View {
        let unit = size / 24
        Group {
            switch provider {
            case .codex: ChatGPTKnot().stroke(style: StrokeStyle(lineWidth: max(1, 1.8 * unit), lineJoin: .round))
            case .claude: ClaudeBurst().stroke(style: StrokeStyle(lineWidth: max(1.2, 2.3 * unit), lineCap: .round))
            }
        }
        .foregroundStyle(provider.tint)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Six rounded petals turned 60° apart, in a 24-point box.
private struct ChatGPTKnot: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let petal = Path(roundedRect: CGRect(x: -3.9 * unit, y: -9.6 * unit, width: 7.8 * unit, height: 13.4 * unit), cornerRadius: 3.9 * unit)
        var path = Path()
        for turn in 0..<6 {
            path.addPath(petal, transform: CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: Double(turn) * .pi / 3))
        }
        return path
    }
}

/// Eleven uneven rays around the centre, in a 24-point box.
private struct ClaudeBurst: Shape {
    private static let rays: [(angle: Double, length: Double)] = [
        (0, 10.5), (33, 9), (64, 10), (97, 8.6), (130, 10.3), (163, 9), (196, 10.2), (229, 8.8), (262, 10.4), (295, 9.1), (328, 10)
    ]

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        for ray in Self.rays {
            let angle = ray.angle * .pi / 180
            let direction = CGPoint(x: sin(angle), y: -cos(angle))
            path.move(to: CGPoint(x: rect.midX + direction.x * unit, y: rect.midY + direction.y * unit))
            path.addLine(to: CGPoint(x: rect.midX + direction.x * ray.length * unit, y: rect.midY + direction.y * ray.length * unit))
        }
        return path
    }
}
