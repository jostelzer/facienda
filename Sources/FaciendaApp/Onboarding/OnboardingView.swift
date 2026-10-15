import SwiftUI
import FaciendaCore

/// First run in four pages: where Facienda keeps its data, then Codex, then Claude, then the models Facienda uses.
/// Either app can be skipped.
struct OnboardingView: View {
    @State private var setup: OnboardingModel
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    let onComplete: (AppModel) -> Void

    init(setup: OnboardingModel = OnboardingModel(), onComplete: @escaping (AppModel) -> Void) {
        _setup = State(initialValue: setup)
        self.onComplete = onComplete
    }

    private static let pages = ["Data folder", "Codex", "Claude", "Models"]

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 28) {
                switch setup.step {
                case 0: folderPage
                case 1: codexPage
                case 2: claudePage
                default: modelsPage
                }
                if let error = setup.error ?? setup.model?.signInError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Palette.accent)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                footer
            }.padding(48).frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 880, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
        .preferredColorScheme(appearance.colorScheme)
        .task(id: setup.step) {
            guard setup.step > 0, setup.model?.demo != true else { return }
            if setup.step == 1 { await setup.checkCodex() }
            while !Task.isCancelled {
                setup.model?.refresh()
                // The hooks are in place once Codex is connected, so their trust ticks off here once the user grants it.
                if setup.step == 1, let model = setup.model, model.workspaceReady { await model.refreshCodexHookTrust() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 10) {
                Image("BrandIcon").resizable().frame(width: 34, height: 34)
                Text("facienda").font(.system(size: 24, design: .serif))
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, title in
                    Label(title, systemImage: index < setup.step ? "checkmark.circle.fill" : "\(index + 1).circle")
                        .font(.system(size: 13, weight: index == setup.step ? .semibold : .regular))
                        .foregroundStyle(index == setup.step ? Palette.ink : Palette.muted)
                }
            }
            Spacer()
        }.padding(32).frame(maxHeight: .infinity, alignment: .topLeading).background(Palette.sidebar)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 32, design: .serif)).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Data folder

    private var folderPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Where should Facienda keep its data?")
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(Palette.muted)
                Text(setup.dataFolder.path).font(.system(size: 13)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { Task { await setup.chooseFolder() } }.buttonStyle(QuietButton())
            }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Codex

    private var codexPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Let’s set up Codex")
            if let model = setup.model {
                VStack(alignment: .leading, spacing: 0) { codexSteps(model) }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                if !model.workspaceReady {
                    DisclosureGroup("Advanced") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Codex executable", text: Binding(get: { model.executable }, set: { model.executable = $0; model.accountReady = false; model.connected = false }))
                                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        }.padding(.top, 8)
                    }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    @ViewBuilder private func codexSteps(_ model: AppModel) -> some View {
        if setup.busy && !model.connected {
            ProgressView("Looking for Codex…").controlSize(.small)
        } else if !model.connected {
            GuideStep(number: 1, kind: .codex, state: .now, title: "Open Codex on this Mac", last: true) {
                Button("Try again") { Task { await setup.checkCodex() } }.buttonStyle(QuietButton(prominent: true))
            }
        } else if !model.accountReady {
            GuideStep(number: 1, kind: .codex, state: .now, title: "Sign in to Codex", last: true) {
                if model.signInID != nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { Task { await model.cancelSignIn() } }.buttonStyle(QuietButton())
                    }
                } else {
                    Button("Sign in…") { Task { await model.signInToCodex() } }
                        .buttonStyle(QuietButton(prominent: true)).disabled(model.signingIn)
                }
            }
        } else {
            // Facienda connects itself. Only trusting its hooks happens in Codex, and that is optional.
            let ready = model.workspaceReady && !model.codexNeedsReconnect, trusted = model.codexHooksTrusted == true
            GuideStep(number: 1, kind: .codex, state: ready ? .done : .now, title: "Connect Facienda to Codex") {
                if ready {
                    Text("Tasks start in Codex on their own, in the \(model.store.nativeProjectName) project.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    RunWorkspaceSetupButton(model: model)
                    if model.connectingWorkspace { WorkspaceSetupStatusView(model: model) }
                }
                DispatcherApprovalNote()
            }
            GuideStep(number: 2, kind: .codex, state: trusted ? .done : ready ? .optional : .later, title: "Trust Facienda’s hooks in Codex", last: true) {
                if ready && !trusted {
                    Text("Optional. The board then shows when a chat is working or waiting for you.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    CodexHooksSketch().frame(maxWidth: 360)
                    Button("Open Codex") { model.openCodex() }.buttonStyle(QuietButton())
                }
            }
            if let error = model.workspaceSetupError ?? model.codexToolsError {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Claude

    private var claudePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Let’s set up Claude")
            if let model = setup.model {
                VStack(alignment: .leading, spacing: 0) { claudeSteps(model) }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                    .modifier(ClaudeAccessPrompt(model: model))
            }
        }
    }

    @ViewBuilder private func claudeSteps(_ model: AppModel) -> some View {
        if !model.claudeInstalled && !model.claudeConnected {
            Text("The Claude app isn’t installed on this Mac.").font(.system(size: 13)).foregroundStyle(Palette.muted)
        } else {
            // As for Codex: what to do in Claude shows before the user leaves for it.
            let opened = model.claudeSetupOpened || model.claudeConnected, ready = model.claudeConnected
            let next: GuideStepState = ready ? .done : opened ? .now : .later
            GuideStep(number: 1, kind: .claude, state: opened ? .done : .now, title: "Open the setup in Claude") {
                if !ready {
                    Button(model.connectingClaude ? "Opening…" : model.claudeSetupOpened ? "Open again" : "Run setup in Claude") {
                        // Without Codex, new tasks start in Claude.
                        if !model.workspaceReady { model.composerModel = .claudeStandard }
                        model.connectClaudeWithAccess()
                    }
                    .buttonStyle(QuietButton(prominent: !model.claudeSetupOpened)).disabled(model.connectingClaude || model.demo)
                }
            }
            GuideStep(number: 2, kind: .claude, state: next, title: "Trust the workspace in Claude") {
                if !ready { Text("Claude asks once whether to trust the runner’s workspace in \(model.claudeRunnerFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
            GuideStep(number: 3, kind: .claude, state: next, title: "Press Send in Claude") {
                if !ready { ComposerSketch(kind: .claude, text: "Connect Facienda to Claude…").frame(maxWidth: 360) }
            }
            GuideStep(number: 4, kind: .claude, state: next, title: "Come back here", last: true) { waiting(opened && !ready) }
            if ready && !model.missingClaudeSetup.isEmpty { ClaudeAccessStatus(model: model) }
            if ready && !model.demo { Divider().padding(.vertical, 20); ClaudeUsageOffer() }
            if let error = model.claudeSetupError {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Models

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Choose your background model")
            if let model = setup.model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ServiceModelSettings(model: model)
                            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                        Text("You can change it any time in Settings › Models.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private func waiting(_ opened: Bool) -> some View {
        if opened {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Just a moment…").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if setup.step > 0 {
                Button("Back") { setup.step -= 1 }.buttonStyle(QuietButton())
                    .disabled(setup.busy || setup.model?.connectingWorkspace == true)
            }
            Spacer()
            switch setup.step {
            case 0:
                Button("Continue") { setup.useFolder() }.buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
            case 1:
                if setup.model?.workspaceReady == true {
                    Button("Continue") { setup.step = 2 }.buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { setup.step = 2 }.buttonStyle(QuietButton())
                }
            case 2:
                if let model = setup.model {
                    if model.claudeConnected {
                        Button("Continue") { toModels(model) }.buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Skip") { toModels(model) }.buttonStyle(QuietButton())
                    }
                }
            default:
                if let model = setup.model {
                    Button("Done") { finish(model, ready: model.workspaceReady || model.claudeConnected) }
                        .buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// The models page opens on what suits the apps just connected, saved at once so it holds even if left as it is.
    private func toModels(_ model: AppModel) {
        if (try? model.store.serviceModel()) == nil { model.chooseServiceModel(model.recommendedServiceModel) }
        // Without Codex, new tasks start in Claude.
        if !model.workspaceReady && model.claudeConnected { model.composerModel = .claudeStandard }
        setup.step = 3
    }

    /// Setup ends on the dashboard; the first task is the user's to start when they are ready.
    private func finish(_ model: AppModel, ready: Bool) {
        onComplete(model)
    }
}
