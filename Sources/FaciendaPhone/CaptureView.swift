import AVFoundation
import SwiftUI
import SwiftData
import FaciendaCompanion

struct CaptureView: View {
    let cloudEnabled: Bool
    let workspaceID: String
    let workspaceName: String
    let workspaceNeedsConnection: Bool
    let onSaved: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var draft: String
    @State private var voice = VoiceCapture()
    @State private var saveError: String?
    @FocusState private var editing: Bool

    init(cloudEnabled: Bool, workspaceID: String = "", workspaceName: String = "", workspaceNeedsConnection: Bool = false, onSaved: @escaping () -> Void) {
        self.cloudEnabled = cloudEnabled
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceNeedsConnection = workspaceNeedsConnection
        self.onSaved = onSaved
        _draft = AppStorage(wrappedValue: "", workspaceID.isEmpty ? "captureDraft" : "captureDraft:" + workspaceID)
    }

    private var voiceForeground: Color { colorScheme == .dark && voice.phase != .recording ? .black : .white }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 20_000 && voice.phase == .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("A little less on your mind.")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !workspaceName.isEmpty {
                    Label(workspaceNeedsConnection ? "\(workspaceName) · connect Codex on your Mac to start tasks" : "Send to \(workspaceName)", systemImage: "square.stack.3d.up")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("What needs doing?")
                            .font(.title2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.title2).scrollContentBackground(.hidden)
                        .frame(minHeight: 200)
                        .focused($editing)
                        .disabled(voice.phase != .idle)
                        .accessibilityLabel("Task request").accessibilityIdentifier("taskRequest")
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                if let message = saveError ?? voice.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                        if voice.hasRecording && voice.phase == .idle {
                            Button("Try transcription again") { Task { append(await voice.transcribe()) } }
                                .buttonStyle(.glass)
                        }
                    }.accessibilityIdentifier("captureError")
                }
                if draft.count > 20_000 { Text("Please keep the task under 20,000 characters.").font(.callout).foregroundStyle(.red) }
            }.padding(.horizontal, 24).padding(.top, 8)
                .containerRelativeFrame(.horizontal)
        }
        .background(PhoneStyle.canvas)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Facienda")
        .safeAreaInset(edge: .bottom) { captureControls }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
        }
        .onDisappear {
            if voice.phase == .recording { Task { append(await voice.finish()); voice.discard() } }
            else { voice.discard() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, voice.phase == .recording {
                Task { append(await voice.finish()) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            if voice.phase == .recording { Task { append(await voice.finish()) } }
        }
    }

    private var captureControls: some View {
        VStack(spacing: 18) {
            if voice.phase == .recording { VoiceWaveform(level: voice.level).frame(height: 30).accessibilityHidden(true) }
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button { editing = true } label: {
                        Image(systemName: "keyboard").font(.system(size: 20)).frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .disabled(voice.phase != .idle)
                    .accessibilityLabel("Type a task")
                    Spacer(minLength: 0)
                    Button {
                        editing = false
                        Task {
                            if voice.phase == .recording { append(await voice.finish()) }
                            else { await voice.start() }
                        }
                    } label: {
                        Group {
                            if voice.isBusy { ProgressView().tint(voiceForeground) }
                            else { Image(systemName: voice.phase == .recording ? "stop.fill" : "waveform").font(.system(size: 30, weight: .medium)) }
                        }.foregroundStyle(voiceForeground)
                            .frame(width: editing ? 52 : 84, height: editing ? 52 : 84)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .tint(voice.phase == .recording ? .red : PhoneStyle.accent)
                    .disabled(voice.isBusy)
                    .accessibilityLabel(voice.phase == .recording ? "Stop recording" : "Record a task")
                    .accessibilityIdentifier("voiceCapture")
                    .sensoryFeedback(.impact(weight: .light), trigger: voice.phase)
                    Spacer(minLength: 0)
                    Button(action: save) {
                        Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(!canSend)
                    .accessibilityLabel("Send task to Mac").accessibilityIdentifier("sendTask")
                }
            }
            if !editing && (!typeSize.isAccessibilitySize || voice.phase != .idle) {
                Text(voice.phase == .recording ? "Listening · tap to stop" : voice.phase == .transcribing ? "Transcribing on your device…" : voice.phase == .preparing ? "Preparing microphone…" : "Tap to speak, or type above")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
        .containerRelativeFrame(.horizontal)
        .background(PhoneStyle.canvas.opacity(0.97))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: voice.phase)
    }

    private func append(_ text: String?) {
        guard let text else { return }
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft += draft.isEmpty ? text : "\n" + text
    }

    private func save() {
        guard canSend else { return }
        let request = CompanionRequest(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID: workspaceID)
        context.insert(request)
        do {
            try context.save(); draft = ""; saveError = nil; editing = false; voice.discard(); onSaved()
        } catch { context.rollback(); saveError = "Couldn’t save your task. Your text is still here. \(error.localizedDescription)" }
    }
}

private struct VoiceWaveform: View {
    let level: Double
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<17) { index in
                Capsule().fill(PhoneStyle.accent)
                    .frame(width: 4, height: 5 + level * (12 + 14 * abs(sin(Double(index) * 1.7))))
            }
        }.frame(maxWidth: .infinity)
    }
}
