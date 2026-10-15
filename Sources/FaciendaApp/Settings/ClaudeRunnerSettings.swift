import SwiftUI
import AppKit
import FaciendaCore

/// Where runner sessions open. Each setup gets a new folder inside it, since the Claude app opens a link's folder
/// only when it has not seen it before.
struct ClaudeRunnerFolderSetting: View {
    @Bindable var model: AppModel
    @AppStorage(AppModel.claudeRunnerFolderKey) private var chosen = ""

    var body: some View {
        HStack(spacing: 10) {
            Text("Runner sessions open in").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text((chosen.isEmpty ? FaciendaStore.defaultClaudeRunnerFolder.path : chosen).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button("Change…") { choose() }.buttonStyle(.borderless).font(.system(size: 12)).disabled(model.demo)
            if !chosen.isEmpty { Button("Use default") { chosen = "" }.buttonStyle(.borderless).font(.system(size: 11)) }
        }.help("Each new runner session gets its own folder here, named for this library. It applies the next time you connect or wake the runner.")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use Folder"; panel.message = "Choose where Claude runner sessions open"
        panel.directoryURL = URL(fileURLWithPath: chosen.isEmpty ? FaciendaStore.defaultClaudeRunnerFolder.deletingLastPathComponent().path : chosen)
        if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
    }
}

/// Whether Facienda's hook is in the Claude settings, so Facienda learns when a task waits for a permission.
struct ClaudeAccessStatus: View {
    @Bindable var model: AppModel

    var body: some View {
        let missing = model.missingClaudeSetup
        if missing.isEmpty {
            HStack(spacing: 10) {
                Label("Permission prompts show on the board", systemImage: "checkmark.shield").font(.system(size: 12))
                Button("Remove…") { model.removeClaudeAccess() }.buttonStyle(.borderless).font(.system(size: 11))
                    .help("Remove Facienda’s hook, and any rules earlier versions added, from your Claude settings")
            }
        } else {
            HStack(spacing: 10) {
                Text("Claude’s permission prompts don’t show in Facienda yet.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button("Add hook…") { model.requestClaudeAccess() }.buttonStyle(.borderless).font(.system(size: 12)).disabled(model.demo)
            }
        }
    }
}

/// The single question before Facienda adds its hook to the Claude settings. Its answer covers every session and task.
struct ClaudeAccessPrompt: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert("Show Claude’s permission prompts in Facienda?", isPresented: $model.askingClaudeAccess) {
            Button("Allow") { model.answerClaudeAccess(allow: true) }
            Button("Not now") { model.answerClaudeAccess(allow: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Facienda adds this to ~/.claude/settings.json:\n\n" + model.missingClaudeSetup.joined(separator: "\n")
                 + "\n\nThe hook shows on your board when a task waits for your permission; it never answers for you. No allow rules are added there; Facienda’s own tools run without asking only in its runner and task folders. A backup is kept, and Settings can remove it.")
        }
    }
}
