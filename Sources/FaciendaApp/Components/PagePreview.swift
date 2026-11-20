import SwiftUI
import WebKit
import FaciendaCore

/// A web page or picture an agent made in the task's folder, such as a mock or a screenshot, shown in a window of its own. The page is the
/// agent's and untrusted: nothing loads from the network, it reads only the files in its own folder, it cannot open
/// windows, and its links go nowhere but within that folder. `CodexMarkdown.localPage` decides which pages come here.
struct PagePreview: View {
    static let window = "page"
    let file: URL
    /// Agents change their mocks while the user looks; reloading shows the page as it is now.
    @State private var reloads = 0

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: file.path) {
                PageView(file: file, reloads: reloads)
            } else {
                ContentUnavailableView("Nothing here any more", systemImage: "doc.questionmark",
                                       description: Text("\(file.lastPathComponent) was moved or deleted."))
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(file.lastPathComponent)
        .navigationSubtitle(file.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .toolbar {
            ToolbarItemGroup {
                Button { reloads += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r").help("Show the page as it is now (⌘R)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show in Finder")
            }
        }
    }
}

private struct PageView: NSViewRepresentable {
    let file: URL
    let reloads: Int

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing the page stores outlives the window.
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.navigationDelegate = context.coordinator
        page.uiDelegate = context.coordinator
        page.underPageBackgroundColor = .windowBackgroundColor
        context.coordinator.reloads = reloads
        Task { await context.coordinator.load(in: page) }
        return page
    }

    func updateNSView(_ page: WKWebView, context: Context) {
        guard context.coordinator.reloads != reloads else { return }
        context.coordinator.reloads = reloads
        Task { await context.coordinator.load(in: page) }
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let file: URL
        var reloads = 0
        private var folder: URL { file.deletingLastPathComponent() }
        init(file: URL) { self.file = file }

        /// Every load but the page's own folder and what it carries inline is blocked before the page starts, so
        /// a page cannot send what it reads anywhere.
        /// WebKit's filters have no alternation, so each allowed scheme is a rule of its own.
        private static let offline = "[" + ([#"{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}"#]
            + ["file", "data", "blob", "about"].map { #"{"trigger": {"url-filter": "^\#($0):"}, "action": {"type": "ignore-previous-rules"}}"# })
            .joined(separator: ",") + "]"

        func load(in page: WKWebView) async {
            guard let rules = try? await Self.rules() else {
                // Without the block in place the page is not shown at all.
                page.loadHTMLString("<p style=\"font: 13px -apple-system; color: gray; padding: 20px\">Facienda could not show this page offline.</p>", baseURL: nil)
                return
            }
            let controller = page.configuration.userContentController
            controller.removeAllContentRuleLists(); controller.add(rules)
            page.loadFileURL(file, allowingReadAccessTo: folder)
        }

        private static func rules() async throws -> WKContentRuleList? {
            try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "facienda.page-preview.offline", encodedContentRuleList: offline)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" { return .allow }
            guard url.isFileURL else { return .cancel }
            let path = url.standardizedFileURL.path, root = folder.standardizedFileURL.path
            return path == file.standardizedFileURL.path || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
