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
    @AppStorage(MobileCompanion.sharesAllTasksKey) private var mobileSharesAllTasks = false
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
            // Builds without iCloud, such as the Tester build, have no iPhone companion to offer.
            if model.mobileCloudBuild { iPhoneCompanionSection.settingsCard() }
            ClaudeUsageSettings(demo: model.demo).settingsCard()
        case .memory:
            chatSearchSection.settingsCard()
            if let workspaces { MemorySpacesSettings(workspaces: workspaces).settingsCard() }
            MemoryView(model: model)
        case .library:
            librarySection.settingsCard()
            Text("Tasks and confirmed notes stay in your library folder. When enabled, Hindsight stores learned memory in its own database and sends text to its configured model provider. Facienda never edits Codex conversation storage.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
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

    private var iPhoneCompanionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "IPHONE COMPANION")
            Toggle("Receive tasks through iCloud", isOn: Binding(get: { model.mobileSyncEnabled }, set: { model.setMobileSync($0) }))
                .disabled(model.demo)
            Text(model.mobileSyncStatus).font(.system(size: 12)).foregroundStyle(Palette.muted)
            if model.mobileSyncEnabled && !model.demo {
                Button("Reconnect iCloud") { model.setMobileSync(true) }.buttonStyle(QuietButton())
                Text("If an iPhone request stays waiting for your Mac, reconnect to check for it again.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Toggle("Show tasks made on this Mac on iPhone", isOn: $mobileSharesAllTasks).disabled(model.demo)
            Text(mobileSharesAllTasks ? "Every task's name, status and latest line are copied to your private iCloud database." : "Your iPhone sees only the tasks it sent, with their status. Requests from iPhone wait here until you start them.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text("Use the same Apple account on your iPhone. This Mac syncs your workspace names and sends each request to the workspace you choose on your phone. Keep Facienda open and enable this connection on one Mac per account.").font(.system(size: 11)).foregroundStyle(Palette.muted)
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

/// Which memory the current workspace uses, and every memory in the library.
private struct MemorySpacesSettings: View {
    @Bindable var workspaces: WorkspaceController
    @State private var renaming: MemorySpace?
    @State private var deleting: MemorySpace?
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "MEMORY")
            if let current = workspaces.current {
                Picker("“\(current.name)” uses", selection: Binding(get: { current.memorySpaceId }, set: { workspaces.setMemory(current, to: $0) })) {
                    ForEach(workspaces.memorySpaces) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 360)
                Text("Each memory is separate: a workspace only learns into and recalls from its own. Switching keeps what was learned in the old memory; new learning goes to the new one.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(workspaces.memorySpaces) { space in
                    let users = workspaces.workspaces.filter { $0.memorySpaceId == space.id }.map(\.name)
                    HStack(spacing: 10) {
                        Image(systemName: "book.closed").foregroundStyle(Palette.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(space.name).font(.system(size: 13, weight: .medium))
                            Text(users.isEmpty ? "Not used by any workspace" : users.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer()
                        Button { draft = space.name; renaming = space } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Rename \(space.name)").accessibilityLabel("Rename \(space.name)")
                        Button(role: .destructive) { deleting = space } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(!users.isEmpty)
                            .help(users.isEmpty ? "Delete \(space.name)" : "Choose another memory for its workspaces before deleting it")
                            .accessibilityLabel("Delete \(space.name)")
                    }.padding(.horizontal, 12).padding(.vertical, 8).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Button("New memory…") { draft = ""; adding = true }.buttonStyle(QuietButton())
            if let error = workspaces.error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent) }
        }
        .alert("New memory", isPresented: $adding) {
            TextField("For example, Work", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Create") { workspaces.createMemory(name: draft) }
        } message: { Text("A new memory starts empty and stays separate from every other memory.") }
        .alert("Rename memory", isPresented: Binding(presenting: $renaming), presenting: renaming) { space in
            TextField("Name", text: $draft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { workspaces.renameMemory(space, to: draft); renaming = nil }
        }
        .alert("Delete memory?", isPresented: Binding(presenting: $deleting), presenting: deleting) { space in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete memory", role: .destructive) { workspaces.deleteMemory(space); deleting = nil }
        } message: { space in
            Text("Delete the \(space.name) memory and its confirmed notes from Facienda? What Hindsight already learned stays in its bank on this Mac.")
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
