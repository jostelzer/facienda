import SwiftUI
import FaciendaCore
import FaciendaBridge

/// The Settings sheet: a side list of panes, with the runners first because they are what has to be working.
struct SettingsView: View {
    @Bindable var model: AppModel
    private var pane: SettingsPane { model.settingsPane }
    var workspaces: WorkspaceController? = nil
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("groupCovers") private var groupCovers = true
    @AppStorage("coverBaseStyle") private var coverBaseStyle = GroupCoverPainter.defaultBaseStyle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            sideList
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if pane != .runners { Text(pane.title).font(.system(size: 26, design: .serif)) }
                    paneContent
                    if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(Palette.green) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.vertical, 28)
            }
        }.frame(width: 820, height: 640).background(Palette.paper)
            .onDisappear { model.settingsPane = .general }
            .preferredColorScheme(appearance.colorScheme)
            .sheet(item: $model.connectionPlan) { plan in
                ConnectionReviewView(plan: plan, error: model.error,
                    onCancel: { model.connectionPlan = nil }, onApply: { await model.applyConnection(plan) })
            }
    }

    private var sideList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: "Settings").padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 2)
            ForEach(SettingsPane.allCases) { item in
                Button { model.settingsPane = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).frame(width: 18).foregroundStyle(Palette.muted)
                        Text(item.title).font(.system(size: 13, weight: pane == item ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        if item == .runners, let tone = runnersTone { Circle().fill(tone).frame(width: 8, height: 8) }
                    }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                        .background(pane == item ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction).padding(.horizontal, 6)
        }.padding(.horizontal, 10).padding(.vertical, 20).frame(width: 210).background(Palette.sidebar)
    }

    /// Green when every runner in use is working, amber when one needs attention, nothing when none is set up.
    private var runnersTone: Color? {
        let codex = RunnerStatus.codex(model), claude = RunnerStatus.claude(model)
        if codex.tone == .warn || claude.tone == .warn { return Palette.amber }
        if codex.tone == .good || claude.tone == .good { return Palette.green }
        return nil
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            appearanceSection.settingsCard()
            picturesSection.settingsCard()
            notificationsSection.settingsCard()
            if AppUpdater.shared.isAvailable { updatesSection.settingsCard() }
        case .runners:
            RunnersPane(model: model)
        case .connections:
            codexConnectionSection.settingsCard()
            ClaudeUsageSettings(demo: model.demo).settingsCard()
        case .memory:
            chatSearchSection.settingsCard()
            MemoryView(model: model).settingsCard()
        case .library:
            librarySection.settingsCard()
            Text("Memory stays in your library folder. Search and situation matching run on this Mac. When enabled, the AI worker receives redacted user text to curate entries; its suggestions wait for your review. Facienda never edits Codex conversation storage.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
        case .storage:
            StorageSettings(model: model)
        case .models:
            ServiceModelSettings(model: model).settingsCard()
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "APPEARANCE")
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in Text(option.label).tag(option) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("Follow your Mac, or choose the light or dark palette. Your choice is remembered.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private var picturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "PICTURES")
            Toggle("Paint pictures for workspaces and groups", isOn: $groupCovers)
            Text("Codex paints a picture for each workspace and dashboard group from its name and tasks. Right-click one to repaint or adjust it.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("Base style").font(.system(size: 13, weight: .medium)).padding(.top, 4)
            TextField("Base style", text: $coverBaseStyle, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...8).labelsHidden()
            HStack(alignment: .firstTextBaseline) {
                Text("New pictures and repaints follow this. Pictures already painted stay as they are until you repaint them.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                if coverBaseStyle != GroupCoverPainter.defaultBaseStyle {
                    Button("Restore default") { coverBaseStyle = GroupCoverPainter.defaultBaseStyle }.buttonStyle(QuietButton())
                }
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "UPDATES")
            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") beta").font(.system(size: 13))
                Spacer()
                if AppUpdater.shared.phase == .ready {
                    Button("Update to \(AppUpdater.shared.version ?? "the new version")") { AppUpdater.shared.install() }.buttonStyle(QuietButton(prominent: true))
                } else {
                    Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }.buttonStyle(QuietButton()).disabled(!AppUpdater.shared.canCheck)
                }
            }
            Text("Facienda looks for a new version once a day and downloads it. Then Update in the top bar installs it and opens Facienda again.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private var chatSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "CHAT SEARCH")
            Toggle("Search inside Codex chats", isOn: Binding(get: { model.chatSearchEnabled == true }, set: { model.setChatSearch($0) }))
                .disabled(model.demo)
            Text("The top bar can find what was said in any Codex chat on this Mac. Facienda keeps a private index of your messages and Codex’s final replies, never tool output or reasoning. Turning this off deletes the index.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            if model.chatSearchEnabled == true, let progress = model.chatIndexProgress {
                Text(progress.building ? "Indexing \(progress.indexed) of \(progress.known) chats…" : "\(progress.indexed) chats indexed\(progress.failed > 0 ? " · \(progress.failed) could not be read" : "").")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if let error = model.chatIndexError { Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent) }
        }
    }

    private var codexConnectionSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Eyebrow(text: "CODEX CONNECTION")
            TextField("Codex CLI executable", text: $model.executable).textFieldStyle(.roundedBorder)
            Text(model.connection).font(.system(size: 12)).foregroundStyle(Palette.muted)
            if model.connected && !model.connecting && !model.accountReady {
                if model.signInID != nil {
                    ProgressView("Finish signing in to Codex in your browser…").controlSize(.small)
                    Button("Cancel sign-in") { Task { await model.cancelSignIn() } }.buttonStyle(QuietButton())
                } else {
                    Button("Sign in to Codex…") { Task { await model.signInToCodex() } }
                        .buttonStyle(QuietButton(prominent: true)).disabled(model.signingIn)
                }
            }
            if let error = model.signInError { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent) }
            HStack {
                Button(model.connected ? "Stop connection" : "Check Codex sign-in") { Task { if model.connected { await model.disconnect() } else { await model.connect() } } }.buttonStyle(QuietButton()).disabled(model.connecting)
                Button("Review tools and hooks…") { Task { await model.prepareConnection(disconnect: false) } }.buttonStyle(QuietButton())
            }
            Text("Setup connects Facienda’s tools and hooks in Codex. Review them here to repair the connection; Codex runs the hooks once you trust them with /hooks.").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            Button("Review removal of Facienda integration…") { Task { await model.prepareConnection(disconnect: true) } }.font(.system(size: 11)).buttonStyle(.borderless)
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "NOTIFICATIONS")
            Button(model.notificationEnabled ? "Notifications enabled" : "Enable local notifications") { Task { await model.enableNotifications() } }.buttonStyle(QuietButton()).disabled(model.notificationEnabled)
            Text("The app checks return dates while running and catches up when reopened. Keep Facienda open for timely check-ins.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("Quick capture: ⌃⌥Space     By voice: ⌃⌥D     New task: ⌘N     Microphone: ⌘D     All shortcuts: ⌘/").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "YOUR LIBRARY")
            Text("Every workspace lives in one library and shares one Codex connection. Facienda keeps the library in its own folder, apart from what tasks make; Storage shows both.").font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text(model.store.libraryDirectory.path).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled)
            Button("Show library folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }.buttonStyle(QuietButton())
        }
    }
}

extension View {
    /// One group of settings on a quiet card.
    func settingsCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
    }
}
