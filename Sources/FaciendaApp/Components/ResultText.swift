import SwiftUI
import FaciendaCore
import Textual

/// Agent-written Markdown. The text is untrusted: pictures load only from Facienda's data folder, never the network;
/// links follow `CodexMarkdown.action(for:)`, and a web link whose text hides its address asks first, showing it.
struct ResultText: View {
    let model: AppModel
    let text: String
    @State private var confirming: URL?

    var body: some View {
        let markdown = CodexMarkdown.render(text)
        StructuredText(markdown: markdown)
            .font(.system(size: 13)).foregroundStyle(Palette.ink)
            .textual.textSelection(.enabled)
            .textual.imageAttachmentLoader(LocalImageLoader(roots: [model.store.workFolder]))
            .textual.emojiAttachmentLoader(LocalImageLoader(roots: []))
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                switch CodexMarkdown.action(for: url) {
                case .web(let url), .mail(let url):
                    if CodexMarkdown.linkNeedsConfirmation(url, in: markdown) { confirming = url } else { NSWorkspace.shared.open(url) }
                case .reveal(let path):
                    if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    else { model.error = "Nothing exists at \(path) any more." }
                case .codexThread(let id), .claudeSession(let id):
                    model.openThread(id)
                case .ignore:
                    break
                }
                return .handled
            })
            .alert(confirming?.scheme == "mailto" ? "Write this email?" : "Open this page?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { url in
                Button("Open") { NSWorkspace.shared.open(url); confirming = nil }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: { url in
                Text("The link's text does not show where it leads. It opens:\n\n" + CodexApproval.visible(url.absoluteString))
            }
    }
}

/// Loads a picture only when it is a regular file inside one of `roots`; anything else, the network above all, stays text.
struct LocalImageLoader: AttachmentLoader {
    let roots: [URL]
    private let files: any AttachmentLoader = .image()

    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> AnyAttachment {
        guard let file = CodexMarkdown.localImage(url, within: roots) else { throw URLError(.unsupportedURL) }
        let erase: (any Textual.Attachment) -> AnyAttachment = AnyAttachment.init
        return erase(try await files.attachment(for: file, text: text, environment: environment))
    }
}
