import SwiftUI
import FaciendaCore

/// The microphone beside a text field. Click to talk; click again to use what was said.
/// Right-click picks the language, which every mic shares.
struct MicButton: View {
    let dictation: Dictation
    /// The keyboard shortcut to mention in the tooltip, if the field has one.
    var shortcut: String?
    var size: CGFloat = 13
    var look: Look = .plain
    var toggle: () -> Void
    @State private var hovering = false

    /// Plain is a grey glyph beside a field's other controls. Lead opens a field, in ink with a larger target;
    /// ring is the same in a round card, for a row of chips.
    enum Look { case plain, lead, ring }
    @AppStorage(Dictation.languageKey) private var language = ""

    private var languageName: String { language.isEmpty ? "any language" : Self.name(language) }
    static func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }

    var body: some View {
        Button(action: toggle) {
            ZStack {
                if dictation.phase == .listening {
                    Circle().fill(Palette.blue.opacity(0.14)).scaleEffect(0.7 + 0.5 * dictation.level)
                }
                switch dictation.phase {
                case .idle: Image(systemName: "mic").foregroundStyle(look == .plain ? Palette.muted : Palette.ink)
                case .listening: Image(systemName: "mic.fill").foregroundStyle(Palette.blue)
                case .preparing, .downloading, .finishing: ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: size)).frame(width: side, height: side)
            .background {
                switch look {
                case .plain: EmptyView()
                case .lead: Circle().fill(Palette.ink.opacity(hovering ? 0.06 : 0))
                case .ring: Circle().fill(Palette.card).overlay(Circle().strokeBorder(Palette.line))
                }
            }
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.1), value: dictation.level)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(dictation.isActive ? "Stop dictating" : "Dictate")
        .contextMenu {
            Picker("Dictation language", selection: $language) {
                Text("Detect automatically").tag("")
                ForEach(Dictation.languages, id: \.self) { code in Text(Self.name(code)).tag(code) }
            }.pickerStyle(.inline)
        }
        .popover(isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            Label(dictation.error ?? "", systemImage: "exclamationmark.circle").font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true).frame(width: 260, alignment: .leading).padding(12)
        }
    }

    private var side: CGFloat { look == .plain ? size + 11 : 30 }

    private var help: String {
        let key = shortcut.map { " (\($0))" } ?? ""
        switch dictation.phase {
        case .idle: return WhisperEngine.isDownloaded ? "Dictate in \(languageName)\(key). Right-click to choose the language."
            : "Dictate\(key). The first time, Facienda downloads a 630 MB speech model; speech then stays on this Mac."
        case .downloading: return "Downloading the speech model. This happens once."
        case .preparing: return "Getting ready to listen…"
        case .listening: return "Listening in \(languageName). Click or press Return to use it."
        case .finishing: return "Writing down what you said…"
        }
    }
}

extension AppModel {
    /// Names Whisper would otherwise guess at: groups, and capitalized words and acronyms from open tasks,
    /// such as people and project names.
    var dictationVocabulary: [String] {
        var seen = Set<String>()
        var words: [String] = []
        for task in tasks where task.state.isOpen {
            let parts = task.displayName.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
            for (index, word) in parts.enumerated() where word.count > 1 {
                let acronym = word == word.uppercased() && word.contains(where: \.isLetter)
                // A title's first word is capitalized anyway, so there it counts only as an acronym.
                let name = index > 0 && word.first?.isUppercase == true
                if acronym || name { words.append(word) }
            }
        }
        return Array((groups.map(\.name) + words).filter { seen.insert($0.lowercased()).inserted }.prefix(60))
    }
}
