import SwiftUI
import FaciendaCore

/// Where the bar's input sits, so the results can hang beneath it.
struct OmnibarAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The input in the top bar. It widens as you type, then wraps and grows down over the page.
struct OmnibarField: View {
    @Bindable var omnibar: OmnibarModel
    /// Empty space beside the bar in the top bar, which it may take while you type.
    var spare: CGFloat = 0
    /// The window's height. Long text may take most of it before the bar scrolls.
    var reach: CGFloat = 0
    /// The widest the field gets. The top bar lets it run out to the board's right edge.
    var widest: CGFloat = 880
    /// Something of the window's at the bar's right end, before the model: the trail of what came in.
    var accessory: AnyView?
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    /// Blue wash that fades out when the bar is summoned, so the jump is easy to spot.
    @State private var flash = false
    @State private var slotWidth: CGFloat = 0
    @State private var fieldWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var dropping = false
    private var model: AppModel { omnibar.model }
    /// Results follow the text and the page. Letting a lit group go brings back the results for what was typed.
    private var refreshKey: String { [omnibar.query, model.destination.rawValue, model.spotlitGroup ?? "-", omnibar.wraps ? "wraps" : "-"].joined(separator: "|") }
    /// The most the bar can take.
    private var room: CGFloat { min(widest, slotWidth + spare) }
    /// Wide enough for the text on one line beside the chips.
    private var needed: CGFloat { textWidth + slotWidth - fieldWidth + 8 }
    /// Lines the bar shows before it scrolls: about 60% of the window, and never fewer than six.
    private var tallest: Int { max(6, Int(reach * 0.6 / 19)) }
    private var wraps: Bool { omnibar.query.contains(where: \.isNewline) || needed > room }

    var body: some View {
        // The top bar keeps one line's height; the bar spills down over the page beneath it.
        Color.clear.frame(height: 40)
            // While dictating it takes all the room, for the outlines of the voice not yet written down.
            .frame(minWidth: max(280, focused ? (omnibar.dictation.isActive ? room : min(room, needed)) : 0), maxWidth: widest)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slotWidth = $0 }
            .overlay(alignment: .top) { bar }
            .onChange(of: wraps, initial: true) { _, now in omnibar.wraps = now }
    }

    private var bar: some View {
        HStack(alignment: .top, spacing: 8) {
            // The mic opens the bar, where the eye starts: a 30 pt target that keeps the bar one line tall.
            MicButton(dictation: omnibar.dictation, shortcut: "⌘D", size: 16, look: .lead) { focused = true; omnibar.toggleDictation() }
                .padding(.leading, -7).padding(.vertical, -3)
            if let chat = omnibar.followUp {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                    Text(chat.title).lineLimit(1).frame(maxWidth: 140)
                    Button { omnibar.followUp = nil } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).accessibilityLabel("Stop continuing from this chat")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.blue.opacity(0.1), in: Capsule())
                    .frame(height: 24)
                    .help("The next task continues from “\(chat.title)”")
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(placeholder, text: $omnibar.query, selection: $selection, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    // Most of the window, then it scrolls. Out of focus the bar is one line again.
                    // The prompt stays on one line; only text the user writes may need more.
                    .lineLimit(focused && !omnibar.query.isEmpty ? tallest : 1)
                    .overlay { VoiceShapes(dictation: omnibar.dictation, text: omnibar.query.isEmpty ? placeholder : omnibar.query, wraps: false).clipped() }
                    .padding(.vertical, 3)
                    .focused($focused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape, .return], phases: .down) { press in
                        if press.key == .return, press.modifiers.contains(.shift), !omnibar.dictation.isActive { omnibar.breakLine(at: &selection); return .handled }
                        return omnibar.handle(press)
                    }
                    // If the field commits Return itself, the result is the same.
                    .onSubmit { omnibar.submit() }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
                    .background(alignment: .leading) {
                        Text(omnibar.query).font(.system(size: 15)).fixedSize().hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    }
                    .accessibilityLabel("Start a task, search, or ask")
                    .accessibilityIdentifier("omnibar")
                if !omnibar.attachments.isEmpty { AttachmentRow(omnibar: omnibar) }
            }
            if omnibar.finding || omnibar.awaitingRead {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(omnibar.finding ? "Finding the task…" : "Reading…").font(.system(size: 11, weight: .medium))
                }.foregroundStyle(Palette.muted).frame(height: 24).transition(.opacity)
            } else if let confirmation = omnibar.confirmation {
                Label(confirmation, systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
                    .frame(height: 24).transition(.opacity)
            } else if let reading = omnibar.reading {
                ReadingLine(reading: reading, nudge: omnibar.readingNudge).transition(.opacity)
            } else if omnibar.readingNow {
                // Something is being read: a reading may follow. Quiet, so plain typing is never interrupted.
                ProgressView().controlSize(.mini).frame(height: 24).help("Reading what you typed").transition(.opacity)
            }
            if let accessory {
                accessory.frame(height: 24)
                Rectangle().fill(Palette.line).frame(width: 1, height: 18).padding(.top, 3)
            }
            // In the field itself, so it stays while a group is spotlit and the results list is closed.
            ModelChoiceMenu(model: model, boxed: true)
            AttachButton(omnibar: omnibar) { focused = true }
            if omnibar.query.isEmpty && !focused && !omnibar.dictation.isActive {
                Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
                    .frame(height: 24)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).fill(Palette.blue.opacity(flash ? 0.28 : 0)).allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused || dropping ? Palette.blue.opacity(0.6) : Palette.line, lineWidth: dropping ? 2 : 1))
        .shadow(color: .black.opacity(focused && wraps ? 0.12 : 0), radius: 14, y: 8)
        .anchorPreference(key: OmnibarAnchorKey.self, value: .bounds) { $0 }
        .takesAttachments(omnibar, focus: $focused, dropping: $dropping)
        .animation(Motion.fade, value: omnibar.confirmation)
        .animation(Motion.fade, value: omnibar.reading)
        // The board rings what the reading acts on.
        .onChange(of: omnibar.reading?.taskID, initial: true) { _, id in if model.readingTarget != id { model.readingTarget = id } }
        .onDisappear { model.readingTarget = nil }
        .onChange(of: focused) { _, now in
            guard now else { return }
            // The bar and a group's sheet hold different things: going to the bar lets the sheet go, keeping its draft.
            if model.spotlitGroup != nil { model.releaseSpotlight() }
            omnibar.dismissed = false; omnibar.dictation.warm()
        }
        // Only typing in the bar opens its results; text handed back by a closing group sheet stays quiet.
        .onChange(of: omnibar.query) { _, text in
            // Typing in the bar is the bar's business: a group's sheet still up goes, keeping its draft.
            if model.spotlitGroup != nil { model.releaseSpotlight() }
            if focused { omnibar.dismissed = false }
            omnibar.edited(text)
        }
        .task(id: model.omnibarFocusRequest) { if model.omnibarFocusRequest > 0 {
            // ⌘K while a group's sheet is up goes back to the bar, keeping what was typed.
            if model.spotlitGroup != nil { model.releaseSpotlight() }
            await Task.yield(); focused = true
            flash = true
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeOut(duration: 1.1)) { flash = false }
        } }
        .task(id: refreshKey) { await omnibar.refresh() }
        .onChange(of: model.dictationRequest) { if model.composersOnScreen == 0 { focused = true; omnibar.toggleDictation() } }
    }

    private var placeholder: String {
        switch omnibar.dictation.phase {
        case .downloading: return "Downloading the speech model… \(Int(omnibar.dictation.progress * 100))%"
        case .preparing: return "Listening…"
        // The outlines follow this; once the model is ready, they say it all.
        case .listening where !omnibar.dictation.modelReady: return "Loading the speech model, words follow…"
        case .listening: return omnibar.dictation.showsVoice ? "" : "Listening…"
        case .idle, .finishing: break
        }
        if !omnibar.attachments.isEmpty { return "What should happen with \(omnibar.attachments.count == 1 ? "it" : "them")?" }
        return omnibar.followUp != nil ? "What should happen next?" : "Start a task, find anything, or ask…"
    }
}

/// What Return will do, at the bar's right end: the verb and what it acts on. Below it, what a reply sends, the answer a
/// question gets or the time a parked task comes back, word for word, since a model may have written it. A reading that
/// asks which task is meant is amber; one already on the board is quiet.
struct ReadingLine: View {
    let reading: BarReading
    var nudge = 0
    @State private var lit = false

    var body: some View {
        let tint = Self.tint(reading.verb)
        let detail = reading.detail()
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(reading.label).lineLimit(1).truncationMode(.middle)
                if reading.verb != .answered { Text("↵").foregroundStyle(tint.opacity(0.7)) }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).frame(height: 24)
            .background(tint.opacity(lit ? 0.26 : reading.verb == .already ? 0.12 : 0.1), in: RoundedRectangle(cornerRadius: 7))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(3).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: detail.isEmpty ? 340 : 380, alignment: .trailing)
        .help(detail.isEmpty ? reading.label : reading.label + ". " + detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Return: " + reading.label + (detail.isEmpty ? "" : ", " + detail))
        // Return was held because this only just appeared: it lights once, so it is seen before the next Return.
        .onChange(of: nudge) {
            withAnimation(Motion.fade) { lit = true } completion: { withAnimation(Motion.move) { lit = false } }
        }
    }

    static func tint(_ verb: BarReading.Verb) -> Color {
        switch verb {
        case .already: Palette.muted
        case .ask: Palette.amber
        case .answered: Palette.green
        default: Palette.blue
        }
    }

    private var symbol: String {
        switch reading.verb {
        case .start: "plus.circle"
        case .find: "magnifyingglass"
        case .open: "arrow.up.right.circle"
        case .bringBack: "arrow.uturn.backward.circle"
        case .reply: "arrowshape.turn.up.left"
        case .already: "checkmark.circle"
        case .remember, .note: "book.closed"
        case .trackChat: "link"
        case .command: "arrow.right.circle"
        case .chat: "bubble.left.and.bubble.right"
        case .decide: "questionmark.circle"
        case .done: "checkmark"
        case .park: "clock"
        case .ask: "questionmark.bubble"
        case .answered: "text.bubble"
        }
    }
}
