import SwiftUI
import WebKit
import FaciendaCore
import FaciendaBridge

/// Claude's plan limits, read from claude.ai the way its Settings → Usage page reads them. There is no documented
/// usage API, so the person signs in to claude.ai inside Facienda once and a hidden claude.ai page asks for the
/// numbers. Facienda never reads Claude Code's or the Claude app's credentials. If claude.ai changes, the rows hide.
@MainActor @Observable final class ClaudeUsage {
    static let shared = ClaudeUsage()

    enum Status: Equatable { case off, checking, ready, signedOut, failed(String) }
    private(set) var usage: PlanUsage?
    private(set) var status: Status
    var showSignIn = false
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private static let enabledKey = "claudeUsage"
    private static let home = URL(string: "https://claude.ai/api/organizations")!
    @ObservationIgnored private var readAt = Date.distantPast
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var page: WKWebView?
    @ObservationIgnored private let loader = PageLoader()

    private init() { status = UserDefaults.standard.bool(forKey: Self.enabledKey) ? .checking : .off }

    /// Called from each workspace's service tick; reads at most every five minutes, or once a window has reset.
    func refreshIfDue() async {
        guard enabled, Date().timeIntervalSince(readAt) > 300 || usage?.stale() == true else { return }
        await refresh()
    }

    /// After signing in: remember the choice and read straight away. Returns whether claude.ai answered.
    @discardableResult func connect() async -> Bool {
        let wasEnabled = enabled
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        await refresh()
        // A sign-in that never finished leaves the feature off, but keeps the reason on screen.
        if status != .ready, !wasEnabled { UserDefaults.standard.set(false, forKey: Self.enabledKey) }
        return status == .ready
    }

    /// Stops reading and signs Facienda out of claude.ai by clearing its claude.ai website data.
    func disconnect() async {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        usage = nil; status = .off; page = nil
        let store = WKWebsiteDataStore.default(), types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { $0.displayName.contains("claude.ai") }
        await store.removeData(ofTypes: types, for: records)
    }

    func refresh() async {
        guard enabled, !reading else { return }
        reading = true; readAt = Date()
        defer { reading = false }
        if usage == nil { status = .checking }
        do {
            let page = page ?? WKWebView(frame: .zero, configuration: Self.configuration)
            self.page = page
            if page.url?.host != "claude.ai" { try await loader.load(Self.home, in: page) }
            let answer = try JSONValue.from(try await page.callAsyncJavaScript(Self.script, contentWorld: .page))
            if answer["signedOut"] == .bool(true) { usage = nil; status = .signedOut; return }
            if let message = answer["error"].string { throw ClaudeUsageError(message: "claude.ai answered \(message)") }
            guard let read = PlanUsage(claude: answer["usage"], capabilities: answer["capabilities"].array?.compactMap(\.string) ?? [],
                                       tier: answer["tier"].string) else {
                throw ClaudeUsageError(message: "claude.ai sent usage Facienda does not recognise")
            }
            usage = read; status = .ready
        } catch {
            // The page may have drifted to a sign-in screen or an old document; start fresh next time.
            page = nil; usage = nil
            status = .failed(error.localizedDescription)
        }
    }

    static var configuration: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }

    /// Runs on claude.ai, so its own sign-in cookie applies. Prefers the organization that carries the paid plan.
    private static let script = """
        const organizations = await fetch('/api/organizations', { credentials: 'include' });
        if (organizations.status === 401 || organizations.status === 403) return { signedOut: true };
        if (!organizations.ok) return { error: 'organizations ' + organizations.status };
        const list = await organizations.json();
        const plan = (o) => (o.capabilities || []).some((c) => c === 'claude_max' || c === 'claude_pro');
        const organization = list.find(plan) || list[0];
        if (!organization) return { signedOut: true };
        const usage = await fetch('/api/organizations/' + organization.uuid + '/usage', { credentials: 'include' });
        if (usage.status === 401 || usage.status === 403) return { signedOut: true };
        if (!usage.ok) return { error: 'usage ' + usage.status };
        return { usage: await usage.json(), capabilities: organization.capabilities || [], tier: organization.rate_limit_tier || null };
        """
}

struct ClaudeUsageError: LocalizedError { let message: String; var errorDescription: String? { message } }

private extension JSONValue {
    /// WebKit hands back Foundation objects; round-trip them through JSON.
    static func from(_ value: Any?) throws -> JSONValue {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

/// Waits for one navigation of a hidden page to finish.
@MainActor private final class PageLoader: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, any Error>?

    func load(_ url: URL, in page: WKWebView) async throws {
        pending?.resume(throwing: CancellationError())
        page.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            page.load(URLRequest(url: url, timeoutInterval: 20))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(error) }
    private func finish(_ error: (any Error)?) {
        guard let pending else { return }
        self.pending = nil
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

// MARK: - Settings and sign-in

struct ClaudeUsageSettings: View {
    @Bindable private var claude = ClaudeUsage.shared
    var demo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "CLAUDE USAGE")
            Text("Show how much of your Claude plan’s 5-hour and weekly limits is left at the foot of the sidebar. Sign in to claude.ai once inside Facienda; it reads the same numbers as Claude’s Settings → Usage page. claude.ai has no official usage API, so this can stop working without notice.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let line = statusLine { Text(line).font(.system(size: 12)).foregroundStyle(claude.status == .ready ? Palette.muted : Palette.accent) }
            HStack {
                if claude.status != .ready && claude.status != .checking {
                    Button("Sign in to Claude…") { claude.showSignIn = true }.buttonStyle(QuietButton(prominent: true)).disabled(demo)
                }
                if claude.enabled {
                    Button("Check now") { Task { await claude.refresh() } }.buttonStyle(QuietButton()).disabled(claude.status == .checking)
                    Button("Stop and sign out") { Task { await claude.disconnect() } }.buttonStyle(QuietButton())
                }
            }
        }
        .sheet(isPresented: $claude.showSignIn) { ClaudeSignInView() }
    }

    private var statusLine: String? {
        switch claude.status {
        case .off: nil
        case .checking: "Checking claude.ai…"
        case .ready: claude.usage.map { usage in
            (usage.plan ?? "Claude") + " · " + usage.windows.map { "\($0.leftPercent)% of \($0.name.lowercased()) left" }.joined(separator: " · ")
        }
        case .signedOut: "Signed out of claude.ai. Sign in again to keep showing Claude usage."
        case .failed(let message): message
        }
    }
}

/// Someone using Claude whose limits aren't showing: one quiet line under the meters, so they never just vanish.
struct ClaudeUsagePrompt: View {
    @Bindable private var claude = ClaudeUsage.shared
    @State private var signingIn = false

    var body: some View {
        if let label {
            Button {
                if case .failed = claude.status { Task { await claude.refresh() } } else { signingIn = true }
            } label: {
                HStack(spacing: 8) {
                    Text("Claude").frame(width: 42, alignment: .leading)
                    Text(label)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.system(size: 11)).lineLimit(1).foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .help(help)
            .sheet(isPresented: $signingIn) { ClaudeSignInView() }
        }
    }

    private var label: String? {
        switch claude.status {
        case .off: "Sign in to see usage"
        case .signedOut: "Signed out · sign in again"
        case .failed: "Usage unavailable · try again"
        case .checking, .ready: nil
        }
    }
    private var help: String {
        if case .failed(let message) = claude.status { return message }
        return "Sign in to claude.ai once inside Facienda to see your plan’s 5-hour and weekly limits here."
    }
}

/// Setup's optional last step for Claude: sign in to claude.ai so the sidebar shows the plan's limits.
struct ClaudeUsageOffer: View {
    @Bindable private var claude = ClaudeUsage.shared
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show your Claude limits").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Optional. Sign in to claude.ai once inside Facienda and the sidebar shows how much of your plan’s 5-hour and weekly limits is left. You can also do this later in Settings › Connections.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if claude.status == .ready {
                Label("Showing Claude usage", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Palette.green)
            } else {
                Button(claude.status == .checking ? "Checking claude.ai…" : "Sign in to claude.ai…") { signingIn = true }
                    .buttonStyle(QuietButton()).disabled(claude.status == .checking)
            }
        }
        .sheet(isPresented: $signingIn) { ClaudeSignInView() }
    }
}

/// claude.ai's own sign-in page. Email sign-in works here; Google may refuse to sign in inside an app window.
struct ClaudeSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    /// Why the last attempt to read usage failed, once the page looked signed in.
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Claude").font(.system(size: 13, weight: .semibold))
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("I’m signed in") { Task { await signedIn() } }.buttonStyle(QuietButton(prominent: true)).disabled(checking)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ClaudeLoginPage { await signedIn() }
            Divider()
            Group {
                if let problem { Text(problem).foregroundStyle(Palette.accent) }
                else { Text("Use “Continue with email” if Google sign-in is refused. Facienda keeps this claude.ai sign-in only to read your usage.").foregroundStyle(Palette.muted) }
            }
            .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(width: 520, height: 680)
    }

    /// Each finished page might be the signed-in app; try reading usage and close once it works.
    private func signedIn() async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        if await ClaudeUsage.shared.connect() { dismiss(); return }
        switch ClaudeUsage.shared.status {
        case .signedOut: problem = "claude.ai doesn’t see you as signed in yet. Finish signing in, then press I’m signed in."
        case .failed(let message): problem = message
        default: problem = nil
        }
    }
}

private struct ClaudeLoginPage: NSViewRepresentable {
    let onPage: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }
    func makeNSView(context: Context) -> WKWebView {
        let page = WKWebView(frame: .zero, configuration: ClaudeUsage.configuration)
        context.coordinator.watch(page)
        page.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        return page
    }
    func updateNSView(_ page: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject {
        let onPage: @MainActor () async -> Void
        private var observation: NSKeyValueObservation?
        init(onPage: @escaping @MainActor () async -> Void) { self.onPage = onPage }

        /// claude.ai moves to the chat page without a full page load after sign-in, so watch the address itself.
        func watch(_ page: WKWebView) {
            observation = page.observe(\.url, options: [.new]) { [weak self] page, _ in
                Task { @MainActor in
                    // Signed out, claude.ai keeps showing its login and verification pages.
                    guard let self, let url = page.url, url.host == "claude.ai", !url.path.hasPrefix("/login") else { return }
                    // Give the new page a moment to store its sign-in.
                    try? await Task.sleep(for: .seconds(1))
                    await self.onPage()
                }
            }
        }
    }
}
