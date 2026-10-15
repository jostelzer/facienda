import SwiftUI
import FaciendaCore
import FaciendaBridge

/// The sheet for having a task continue in another chat: Codex chats and Claude sessions by title, to open, import,
/// or make the task's chat in place of the one it has.
struct ThreadBrowser: View {
    @Bindable var model: AppModel
    var taskID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosenTask = ""
    /// Codex's title search over every chat, not only the pages loaded so far.
    @State private var found: [CodexThread]?
    /// Chats from outside this workspace appear only on request, to import or link one.
    @State private var showingOthers = false
    @State private var claudeSessions: [ClaudeDesktop.Session] = []
    private var shownClaude: [ClaudeDesktop.Session] {
        claudeSessions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query) }.prefix(query.isEmpty ? 12 : 30).map { $0 }
    }
    private var shown: [CodexThread] {
        let loaded = model.threads.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }
        guard let found, !query.isEmpty else { return loaded }
        let ids = Set(found.map(\.id))
        return found + loaded.filter { !ids.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(taskID == nil ? "Chats" : "Continue in another chat").font(.system(size: 22, weight: .semibold))
                Spacer()
                if taskID != nil { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button { Task { if model.connected { await model.pollThreads() } else { await model.connect() } } } label: { Label(model.connected ? "Refresh" : "Connect", systemImage: "arrow.clockwise") }.buttonStyle(QuietButton()).disabled(model.connecting)
            }

            if taskID != nil {
                Text("The chat you pick takes the place of this task's chat: your replies and checks go there from now on.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            TextField("Find a chat by title", text: $query).textFieldStyle(.roundedBorder)
            if taskID == nil { Picker("Link to task", selection: $chosenTask) { Text("Choose a task").tag(""); ForEach(model.tasks.filter(\.state.isOpen)) { Text($0.displayName).tag($0.id) } } }
            ScrollView {
                LazyVStack(spacing: 10) {
                    let scope = model.chatScope
                    let mine = shown.filter { scope.contains(threadId: $0.id, cwd: $0.cwd) }
                    ForEach(mine) { row($0) }
                    if mine.isEmpty && !model.threads.isEmpty {
                        Text("No chats in this workspace yet.").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    if !shownClaude.isEmpty {
                        Eyebrow(text: "Claude sessions").frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                        ForEach(shownClaude) { claudeRow($0) }
                    }
                    if taskID != nil || showingOthers {
                        let others = shown.filter { !scope.contains(threadId: $0.id, cwd: $0.cwd) }
                        if !others.isEmpty { Eyebrow(text: "Other Codex chats").frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14) }
                        ForEach(others) { row($0) }
                    } else if !model.threads.isEmpty {
                        Button("Show other Codex chats to import…") { showingOthers = true }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    if model.nextCursor != nil && query.isEmpty { Button("Load more threads") { Task { await model.pollThreads(loadMore: true) } }.buttonStyle(QuietButton()) }
                    if model.threads.isEmpty { EmptyNote(symbol: "bubble.left.and.bubble.right", title: "Bring context along.", detail: "Connect to your local Codex app-server to browse and link existing conversations.") }
                }
            }
        }.padding(30).background(Palette.paper)
            .task { claudeSessions = await model.claudeAppSessions() }
            .task(id: query) {
                guard !query.isEmpty, model.connected else { found = nil; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                found = try? await model.bridge.listThreads(search: query).data
            }
    }

    private func row(_ thread: CodexThread) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(thread.title.isEmpty ? "Untitled thread" : thread.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(thread.statusLabel) · Polled · \(thread.cwd)").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }; Spacer()
            Button("Open ↗") { model.openThread(thread.id) }.buttonStyle(.borderless)
            if taskID == nil {
                Button(model.importingThreadID == thread.id ? "Importing…" : "Import task") { Task { await model.importThread(thread) } }
                    .buttonStyle(QuietButton()).disabled(model.importingThreadID != nil || model.links.contains { $0.codexThreadId == thread.id })
            }
            continueButton(ChatCandidate(threadId: thread.id, provider: .codex, title: thread.title, cwd: thread.cwd.isEmpty ? nil : thread.cwd))
        }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
    }

    private func claudeRow(_ session: ClaudeDesktop.Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title.isEmpty ? "Untitled session" : session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("Claude · \(session.lastActivityAt.formatted(.dateTime.day().month(.abbreviated))) · \(session.cwd)").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }; Spacer()
            Button("Open ↗") { model.openThread(session.id) }.buttonStyle(.borderless)
            if taskID == nil {
                Button(model.importingThreadID == session.id ? "Importing…" : "Import task") { Task { await model.importClaudeSession(session.id) } }
                    .buttonStyle(QuietButton()).disabled(model.importingThreadID != nil || model.links.contains { $0.codexThreadId == session.id })
            }
            continueButton(session.chat)
        }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
    }

    /// The task continues in this chat, replacing its own. A chat that already belongs to a task can't be picked.
    private func continueButton(_ chat: ChatCandidate) -> some View {
        let target = taskID ?? chosenTask
        let current = model.links.first { $0.codexThreadId == chat.threadId }
        return Button(current?.taskId == target && current?.role == "work" ? "Its chat" : "Continue here") {
            if model.handOver(chat, taskID: target), taskID != nil { dismiss() }
        }.buttonStyle(QuietButton()).disabled(target.isEmpty || current != nil && !(current?.taskId == target && current?.role != "work"))
    }
}
