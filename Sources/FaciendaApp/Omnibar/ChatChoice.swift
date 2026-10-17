import SwiftUI
import FaciendaCore
import FaciendaBridge

/// What to do with a Codex chat or Claude session picked from search or an answer: spawn a task from it, or have a
/// task continue in it, replacing that task's chat. Facienda never shows the chat's contents here.
struct ChatChoice: View {
    let omnibar: OmnibarModel
    let chat: ChatResult
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var importing = false
    private var model: AppModel { omnibar.model }
    private var linkedTask: FaciendaTask? {
        model.links.first { $0.codexThreadId == chat.threadId }.flatMap { link in model.tasks.first { $0.id == link.taskId } }
    }
    private var openTasks: [FaciendaTask] {
        model.tasks.filter { $0.state.isOpen && (filter.isEmpty || $0.displayName.localizedCaseInsensitiveContains(filter)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.title.isEmpty ? "Untitled chat" : chat.title).font(.system(size: 18, weight: .semibold)).fullTextOnHover(chat.title, lines: 2)
                    if !chat.cwd.isEmpty || chat.provider == .claude {
                        Text([chat.provider == .claude ? "Claude session" : nil, chat.cwd.isEmpty ? nil : chat.cwd].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton(compact: true))
            }
            if let task = linkedTask {
                Text("This chat already belongs to “\(task.displayName)”.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button { close(); model.bringBack(task, into: nil) } label: { Label("Bring back", systemImage: "arrow.uturn.up") }
                    .buttonStyle(QuietButton(prominent: true, compact: true)).keyboardShortcut(.defaultAction)
            } else {
                let claude = chat.provider == .claude
                Button {
                    importing = true
                    Task {
                        if claude { await model.importClaudeSession(chat.threadId) } else { await model.importThread(chat.thread) }
                        importing = false
                        if linkedTask != nil { close() }
                    }
                } label: { Label(importing ? "Creating task…" : "New task from this chat", systemImage: "plus") }
                    .buttonStyle(QuietButton(prominent: true, compact: true)).keyboardShortcut(.defaultAction)
                    .disabled(importing || !(claude || model.connected))
                    .help(claude || model.connected ? "Spawn a task that tracks this chat" : "Connect Codex in Settings to create a task from this chat")
                Divider()
                Eyebrow(text: "Continue a task in this chat")
                Text("It takes the place of the task's chat: your replies and checks go here from now on.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                TextField("Find a task", text: $filter).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(openTasks) { task in
                            Button { if model.handOver(chat.candidate, taskID: task.id) { close() } } label: {
                                HStack {
                                    Text(task.displayName).font(.system(size: 13)).shortened(to: 1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain).fullTextOnHover(task.displayName)
                        }
                        if openTasks.isEmpty {
                            Text(filter.isEmpty ? "No open tasks to continue." : "No open task matches.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(8)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }
        .padding(24).frame(width: 460).background(Palette.paper)
    }

    private func close() {
        omnibar.chosenChat = nil
        omnibar.finish()
    }
}
