import SwiftUI
import AppKit
import FaciendaCore

/// The two runners Facienda can start tasks through.
enum RunnerKind: String, CaseIterable, Identifiable {
    case codex, claude

    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude" }
    var subtitle: String { self == .codex ? "Delivered by Facienda" : "A Claude app session" }
    /// Codex stays ink-neutral and Claude takes the accent, the same split the task rows use.
    var tint: Color { self == .codex ? Palette.ink : Palette.accent }
    var wash: Color { self == .codex ? Palette.ink.opacity(0.05) : Palette.accent.opacity(0.09) }
    var edge: Color { self == .codex ? Palette.line : Palette.accent.opacity(0.28) }
}

/// What one runner is doing, in a word and a tone.
struct RunnerStatus {
    enum Tone { case good, warn, idle }
    let label: String
    let tone: Tone

    @MainActor static func codex(_ model: AppModel) -> RunnerStatus {
        if model.codexNeedsReconnect { return RunnerStatus(label: "Needs reconnect", tone: .warn) }
        if model.workspaceReady {
            return DispatcherHost.shared.mode == .needsApproval ? RunnerStatus(label: "Needs approval", tone: .warn) : RunnerStatus(label: "Connected", tone: .good)
        }
        return RunnerStatus(label: "Not set up", tone: .idle)
    }

    @MainActor static func claude(_ model: AppModel) -> RunnerStatus {
        guard model.claudeInstalled else { return RunnerStatus(label: "Claude not installed", tone: .idle) }
        if let runner = model.claudeRunner, runner.isBound {
            return runner.isAwake() ? RunnerStatus(label: "Connected", tone: .good) : RunnerStatus(label: "Asleep", tone: .warn)
        }
        return model.claudeSetupOpened ? RunnerStatus(label: "Waiting for Send", tone: .warn) : RunnerStatus(label: "Not set up", tone: .idle)
    }
}

struct StatusPill: View {
    let status: RunnerStatus
    private var color: Color { status.tone == .good ? Palette.green : status.tone == .warn ? Palette.amber : Palette.muted }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.label).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }.padding(.horizontal, 9).padding(.vertical, 3).background(color.opacity(0.13), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

/// Settings › Runners: status for each runner, and a walk-through the first time.
struct RunnersPane: View {
    @Bindable var model: AppModel
    @State private var guide: RunnerKind?

    var body: some View {
        Group {
            if let kind = guide {
                RunnerSetupGuide(model: model, kind: kind, back: { guide = nil })
            } else {
                overview
            }
        }.modifier(ClaudeAccessPrompt(model: model))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runners").font(.system(size: 26, design: .serif))
                Text("Your tasks run inside Codex or Claude, so you can open, steer and stop them there. You connect each one once.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 14) {
                codexCard
                claudeCard
            }
            if model.claudeInstalled { ClaudeAccessStatus(model: model).settingsCard() }
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "FOLDERS")
                ClaudeRunnerFolderSetting(model: model)
            }.settingsCard()
        }
    }

    private func card<Content: View>(_ kind: RunnerKind, status: RunnerStatus, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RunnerMark(kind: kind)
                Text(kind.name).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                StatusPill(status: status)
            }
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(kind.wash, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(kind.edge, lineWidth: 1))
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var codexCard: some View {
        card(.codex, status: RunnerStatus.codex(model)) {
            detail("Facienda hands each task, reply and due check to Codex as soon as it is queued. Task chats open in \(model.store.nativeProjectName).")
            if model.codexNeedsReconnect {
                Text("This library still uses a runner inside Codex that checks every minute. Reconnect to replace it.")
                    .font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            } else if model.workspaceReady, let runner = model.nativeRunner {
                detail(runner.lastSeen.map { "Last looked for work \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Waiting for the first look at the queue.")
            }
            DispatcherApprovalNote()
            HStack(spacing: 8) {
                if model.workspaceReady || model.codexNeedsReconnect {
                    RunWorkspaceSetupButton(model: model)
                } else {
                    Button("Set up…") { guide = .codex }.buttonStyle(QuietButton(prominent: true))
                }
            }
            WorkspaceSetupStatusView(model: model)
        }
    }

    private var claudeCard: some View {
        card(.claude, status: RunnerStatus.claude(model)) {
            detail("A session in the Claude app that applies the model you choose, relays your replies and runs scheduled checks.")
            if !model.claudeInstalled {
                detail("Install the Claude app to use Claude models.")
            } else if let runner = model.claudeRunner, runner.isBound, let session = runner.sessionId {
                let awake = runner.isAwake()
                detail(runner.lastSeen.map { "Last seen \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Waiting for the runner’s first check.")
                detail(awake ? "New task sessions start on their own." : "Claude was closed, so the runner stopped. New Claude tasks wait here and start on their own once it wakes.")
                HStack(spacing: 8) {
                    if !awake {
                        Button(model.connectingClaude ? "Opening Claude…" : "Wake runner") { model.requestClaudeConnection(repair: true) }
                            .buttonStyle(QuietButton(prominent: true)).disabled(model.connectingClaude || model.demo)
                    }
                    Button("Open runner ↗") { model.openThread(session) }.buttonStyle(QuietButton())
                    if awake {
                        Button("New session…") { model.requestClaudeConnection(repair: true) }
                            .buttonStyle(QuietButton()).disabled(model.connectingClaude || model.demo)
                            .help("Retire this runner and open a fresh session in Claude")
                    }
                }
                if !awake { Text("Waking opens a new session in Claude. Press Send there, once.").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            } else {
                Button(model.claudeSetupOpened ? "Continue setup…" : "Set up…") { guide = .claude }.buttonStyle(QuietButton(prominent: true))
            }
            if let error = model.claudeSetupError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.accent).textSelection(.enabled)
            }
        }
    }
}

/// The runner's initial in a ring, in its own colour.
private struct RunnerMark: View {
    let kind: RunnerKind
    var body: some View {
        Text(kind.name.prefix(1)).font(.system(size: 12, weight: .bold)).foregroundStyle(kind.tint)
            .frame(width: 26, height: 26).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind.tint, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

// MARK: - The walk-through

/// First-time runner setup as a short tutorial. The one thing that cannot happen here, pressing Send inside Codex or
/// Claude, gets its own highlighted card and the page waits for it.
struct RunnerSetupGuide: View {
    @Bindable var model: AppModel
    @State var kind: RunnerKind
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Button { back() } label: { Label("Runners", systemImage: "chevron.left").font(.system(size: 12)) }.buttonStyle(.borderless)
                Eyebrow(text: "First-time setup")
                Text("Connect your runners").font(.system(size: 26, design: .serif))
                Text("A runner lives inside Codex or Claude and starts your tasks there. Set up each one once; you only need the one you plan to use.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(RunnerKind.allCases) { option in picker(option) }
            }
            Group {
                if kind == .codex { codexSteps } else { claudeSteps }
            }
            Divider()
            Text("You can come back to this any time in Settings › Runners.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func picker(_ option: RunnerKind) -> some View {
        let status = option == .codex ? RunnerStatus.codex(model) : RunnerStatus.claude(model)
        return Button { kind = option } label: {
            HStack(spacing: 10) {
                RunnerMark(kind: option)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name).font(.system(size: 13, weight: .semibold))
                    Text(option.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                StatusPill(status: status)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(kind == option ? option.wash : Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(kind == option ? option.tint : Palette.line, lineWidth: kind == option ? 1.5 : 1))
        }.buttonStyle(.plain).accessibilityAddTraits(kind == option ? .isSelected : [])
    }

    // MARK: Codex

    private var codexSignedIn: Bool { model.connected && model.accountReady }

    private var codexSteps: some View {
        let ready = model.workspaceReady && !model.codexNeedsReconnect
        return VStack(alignment: .leading, spacing: 0) {
            GuideStep(number: 1, kind: .codex, state: codexSignedIn ? .done : .now, title: "Sign in to Codex") {
                if codexSignedIn {
                    note("Facienda found Codex on this Mac and your account is signed in.")
                } else {
                    note(model.connection)
                    if model.signInID != nil {
                        ProgressView("Finish signing in to Codex in your browser…").controlSize(.small)
                        Button("Cancel sign-in") { Task { await model.cancelSignIn() } }.buttonStyle(QuietButton())
                    } else if model.connected && !model.connecting {
                        Button("Sign in to Codex…") { Task { await model.signInToCodex() } }.buttonStyle(QuietButton(prominent: true)).disabled(model.signingIn)
                    } else {
                        Button("Check Codex sign-in") { Task { await model.connect() } }.buttonStyle(QuietButton(prominent: true)).disabled(model.connecting)
                    }
                    if let error = model.signInError { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent) }
                }
            }
            GuideStep(number: 2, kind: .codex, state: ready ? .done : codexSignedIn ? .now : .later, title: ready ? "Facienda is connected to Codex" : "Connect Facienda to Codex") {
                if ready {
                    note("Tasks, replies and due checks go to Codex as soon as they are queued, even while Facienda is closed.")
                    DispatcherApprovalNote()
                } else if codexSignedIn {
                    note("Facienda sets up the \(model.store.nativeProjectName) project and its tools in Codex itself. There is nothing to send in Codex.")
                    RunWorkspaceSetupButton(model: model)
                    WorkspaceSetupStatusView(model: model)
                }
            }
            GuideStep(number: 3, kind: .codex, state: ready ? .now : .later, title: "Start your first task", last: true) {
                if ready { note("Add a task and pick a Codex model. It starts in Codex without any further clicks.") }
            }
        }
    }

    // MARK: Claude

    private var claudeSteps: some View {
        let bound = model.claudeRunner?.isBound == true
        let awake = model.claudeRunner?.isAwake() == true
        let installed = model.claudeInstalled
        return VStack(alignment: .leading, spacing: 0) {
            GuideStep(number: 1, kind: .claude, state: installed ? .done : .now, title: installed ? "Claude app found" : "Install the Claude app") {
                note(installed ? "Facienda found the Claude app on this Mac." : "Claude tasks run as sessions in the Claude app. Install it, then come back here.")
            }
            GuideStep(number: 2, kind: .claude, state: !installed ? .later : model.missingClaudeSetup.isEmpty ? .done : .optional, title: "See permission prompts on the board") {
                if installed {
                    if model.missingClaudeSetup.isEmpty {
                        ClaudeAccessStatus(model: model)
                    } else {
                        note("Optional. Adds a hook to ~/.claude/settings.json that shows a raised hand on a task while its Claude session waits for your permission. It adds no allow rules there: only the runner’s and tasks’ own folders let Facienda’s own helper and tools run without asking. A backup is kept and you review the change first.")
                        Button("Add hook…") { model.requestClaudeAccess() }.buttonStyle(QuietButton()).disabled(model.demo)
                    }
                }
            }
            GuideStep(number: 3, kind: .claude, state: bound ? .done : installed ? .now : .later, title: bound ? "The runner is connected" : "Go to Claude and press Send, once") {
                if bound {
                    note("Its session now relays your replies and runs scheduled checks. New Claude tasks start on their own.")
                } else if installed {
                    note("The runner is a normal session in the Claude app, so you start it there.")
                    OnceCallout(kind: .claude, steps: ["Press **Open setup in Claude**. Claude opens a new session in \(FaciendaStore.defaultClaudeRunnerFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).", "In Claude, press **Send**. The session becomes your runner."],
                                composer: "Facienda dispatch: connect this session as the runner…") {
                        Button(model.connectingClaude ? "Opening Claude…" : model.claudeSetupOpened ? "Open setup in Claude again" : "Open setup in Claude") { model.requestClaudeConnection() }
                            .buttonStyle(QuietButton(prominent: !model.claudeSetupOpened)).disabled(model.connectingClaude || model.demo)
                    }
                    if model.claudeSetupOpened {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            note("Waiting for the runner’s first check. This page updates on its own.")
                        }
                    }
                    ClaudeRunnerFolderSetting(model: model)
                }
            }
            GuideStep(number: 4, kind: .claude, state: awake ? .done : bound ? .now : .later, title: "Keep Claude open", last: true) {
                if bound {
                    note("The runner works while its session runs, so it sleeps when Claude quits. New tasks wait and start by themselves once you wake it.")
                    if !awake {
                        Button(model.connectingClaude ? "Opening Claude…" : "Wake runner") { model.requestClaudeConnection(repair: true) }
                            .buttonStyle(QuietButton(prominent: true)).disabled(model.connectingClaude || model.demo)
                    }
                }
            }
            if let error = model.claudeSetupError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.accent).textSelection(.enabled).padding(.top, 12)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// One numbered step, joined to the next by a line.
/// The step that has to happen inside Codex or Claude, drawn so nobody misses it.
private struct OnceCallout<Actions: View>: View {
    let kind: RunnerKind
    let steps: [String]
    let composer: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ONCE PER RUNNER").font(.system(size: 10, weight: .bold)).tracking(1.6)
                .foregroundStyle(kind == .codex ? Palette.paper : .white)
                .padding(.horizontal, 9).padding(.vertical, 3).background(kind.tint, in: Capsule())
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text(try! AttributedString(markdown: text)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ComposerSketch(kind: kind, text: composer)
            HStack(spacing: 10) { actions() }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(kind == .codex ? Palette.card : kind.wash, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(kind == .codex ? Palette.firmLine : kind.edge, lineWidth: 1))
    }
}
