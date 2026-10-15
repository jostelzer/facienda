import SwiftUI
import UniformTypeIdentifiers
import FaciendaCore

struct TaskComposer: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool
    @State private var importing = false
    @State private var dropping = false
    @State private var submitting = false
    @State private var mic = Dictation()

    private var canStart: Bool {
        !model.composerRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.demo && !model.dispatching && !model.capturing && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                if model.composerRequest.isEmpty {
                    Text("Write your request here…")
                        .foregroundStyle(Palette.muted).padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.composerRequest)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { key in
                        guard key.modifiers.isEmpty || key.modifiers == .command else { return .ignored }
                        mic.finishing(start)
                        return .handled
                    }
                    .accessibilityLabel("Task request")
                    .accessibilityIdentifier("taskRequest")
            }.font(.system(size: 17)).frame(minHeight: 200, idealHeight: 240, maxHeight: 300)
            if !model.composerAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.composerAttachments, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().scaledToFit().frame(width: 24, height: 24)
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 150)
                                Button {
                                    model.composerAttachments.removeAll { $0 == url }
                                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                                    .buttonStyle(.plain).help("Remove attachment").accessibilityLabel("Remove " + url.lastPathComponent)
                            }.padding(8).background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { importing = true } label: { Label("Attach files", systemImage: "paperclip") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .help("Add images, video, audio, or documents")
                Text("or drop images, media, documents")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                MicButton(dictation: mic, shortcut: "⌘D", size: 15) { dictate() }
                ModelChoiceMenu(model: model)
                Button { mic.finishing(start) } label: { Label("Start task", systemImage: "arrow.up") }
                    .buttonStyle(QuietButton(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Enter to start · Shift-Enter for a new line")
                    .disabled(!canStart)
            }
        }.padding(22).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(dropping || focused ? Palette.blue.opacity(0.6) : Palette.line, lineWidth: dropping ? 2 : 1))
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls): attach(urls)
                case let .failure(error): model.error = error.localizedDescription
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                attach(urls)
                return !urls.isEmpty && urls.allSatisfy(\.isFileURL)
            } isTargeted: { dropping = $0 }
            .disabled(submitting || model.capturing)
            .task(id: model.composerFocusRequest) { await focus() }
            .onAppear {
                model.composersOnScreen += 1
                // The voice hotkey opened this sheet to talk into it.
                if model.listenOnCompose { model.listenOnCompose = false; Task { await focus(); mic.warm(); dictate() } }
            }
            .onChange(of: model.dictationRequest) { dictate() }
            .onDisappear { model.composersOnScreen -= 1; mic.cancel() }
    }

    private func dictate() {
        focused = true
        mic.toggle(into: $model.composerRequest, vocabulary: model.dictationVocabulary)
    }

    private func focus() async {
        await Task.yield()
        focused = true
    }

    private func attach(_ urls: [URL]) {
        for url in urls where url.isFileURL && !model.composerAttachments.contains(url) {
            model.composerAttachments.append(url)
        }
        focused = true
    }

    private func start() {
        guard canStart else { return }
        submitting = true
        Task {
            defer { submitting = false }
            if await model.capture(title: model.composerRequest, intention: "", area: "Personal", date: Date(), startNow: true, attachments: model.composerAttachments, model: model.composerModel) {
                model.composerRequest = ""
                model.composerAttachments = []
            }
        }
    }
}
