import SwiftUI
import FaciendaCore
import FaciendaBridge

/// Results beneath the bar.
struct OmnibarPanel: View {
    @Bindable var omnibar: OmnibarModel
    /// Room below the bar, footer included.
    var tallest: CGFloat = 500
    @State private var hovered: String?
    @State private var contentHeight: CGFloat = 0
    private var model: AppModel { omnibar.model }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(omnibar.sections) { section in
                            if let title = section.title {
                                Eyebrow(text: title).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                            }
                            ForEach(section.items) { item in row(item).id(item.id) }
                            if let footnote = section.footnote {
                                Text(footnote).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                        }
                    }.padding(6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, 44), 460, max(tallest - 34, 44)))
                .onChange(of: omnibar.highlighted) { _, id in proxy.scrollTo(id) }
            }
            Divider()
            HStack(spacing: 14) {
                ForEach(hints, id: \.key) { hint in
                    HStack(spacing: 4) {
                        Text(hint.key).font(.system(size: 10, weight: .semibold))
                        Text(hint.label).font(.system(size: 10))
                    }
                }
                Spacer()
            }.foregroundStyle(Palette.muted).padding(.horizontal, 14).padding(.vertical, 7)
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
    }

    /// The keys that do something for the highlighted row, and nothing else.
    private var hints: [(key: String, label: String)] {
        if omnibar.dictation.isActive { return [("↵", "use it"), ("esc", "cancel")] }
        let item = omnibar.items.first { $0.id == omnibar.highlighted }
        var hints: [(key: String, label: String)] = []
        if omnibar.items.count > 1 && !omnibar.wraps { hints.append(("↑↓", "move")) }
        switch item?.kind {
        case .start, nil: hints.append(TaskLookup.asksForEarlier(omnibar.trimmed) ? ("↵", "find it") : ("↵", "start task"))
        case .remember: hints.append(("↵", "remember"))
        case .command: hints.append(("↵", "go"))
        case let .task(task):
            hints.append(("↵", "bring back"))
            if model.canOpen(task) { hints.append(("⌥↵", "open in \(model.agent(for: task).name)")) }
        case let .chat(chat): hints += [("↵", "choose"), ("⌥↵", "open in \(chat.provider.name)")]
        case .note: hints.append(("↵", "show in Memory"))
        case .enableChatSearch: hints.append(("↵", "turn on"))
        }
        // Asking for an earlier task finds it on Return, so starting it as new moves to ⌘↵ too.
        if item.map({ $0.kind != .start }) ?? false || TaskLookup.asksForEarlier(omnibar.trimmed) { hints.append(("⌘↵", "start task")) }
        hints.append(("esc", "close"))
        return hints
    }

    private var startTitle: String {
        if OmnibarModel.codexThreadID(omnibar.trimmed) != nil { return "Add Codex chat as task" }
        if ClaudeDesktop.sessionID(inLink: omnibar.trimmed) != nil { return "Add Claude session as task" }
        if TaskLookup.asksForEarlier(omnibar.trimmed) && omnibar.followUp == nil { return omnibar.finding ? "Finding the task…" : "Find the earlier task" }
        return "Start task"
    }

    private func row(_ item: OmnibarItem) -> some View {
        let active = omnibar.highlighted == item.id
        return HStack(alignment: .top, spacing: 10) {
            content(item, showActions: active || hovered == item.id)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Palette.selected : hovered == item.id ? Palette.selected.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { omnibar.highlighted = item.id; omnibar.run(item) }
        .onHover { inside in if inside { hovered = item.id } else if hovered == item.id { hovered = nil } }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityAction { omnibar.run(item) }
    }

    @ViewBuilder private func content(_ item: OmnibarItem, showActions: Bool) -> some View {
        switch item.kind {
        case .start:
            icon("arrow.up.circle.fill", tint: Palette.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(startTitle).font(.system(size: 13, weight: .semibold))
                if TaskLookup.asksForEarlier(omnibar.trimmed) && omnibar.followUp == nil {
                    Text("Brings back the task you mean. ⌘↵ starts a new one.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                if let chat = omnibar.followUp { Text("Continues from “\(chat.title)”").font(.system(size: 10)).foregroundStyle(Palette.blue) }
            }
            Spacer(minLength: 8)
            if showActions && OmnibarModel.codexThreadID(omnibar.trimmed) == nil { action("Add files…", "paperclip") { omnibar.perform(.composer) } }
        case let .remember(text):
            icon("book.closed", tint: Palette.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember").font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
        case let .command(command):
            icon(command.symbol, tint: Palette.muted)
            Text(command.title).font(.system(size: 13))
            Spacer(minLength: 8)
        case let .task(task):
            TaskDot(kind: TaskDot.Kind(model: model, task: task), animated: false).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName).font(.system(size: 13)).lineLimit(1)
                Text(model.taskStatus(task)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if showActions {
                if task.state.isOpen { action("Mark done", "checkmark") { model.complete(task); Task { await omnibar.refresh() } } }
                if model.links.contains(where: { $0.taskId == task.id }) { action("Open in \(model.agent(for: task).name)", "arrow.up.right") { omnibar.runSecondary(item) } }
            }
        case let .chat(chat):
            icon("bubble.left.and.bubble.right", tint: Palette.muted)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chat.title.isEmpty ? "Untitled chat" : chat.title).font(.system(size: 13)).lineLimit(1)
                    Text(chat.updatedAt, format: .dateTime.day().month(.abbreviated).year()).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    if chat.provider == .claude { Text("Claude").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    if model.links.contains(where: { $0.codexThreadId == chat.threadId }) {
                        Text("Task").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.blue)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Palette.blue.opacity(0.1), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            if showActions {
                action("Open in Codex", "arrow.up.right") { model.openThread(chat.threadId) }
                action("Follow up", "arrow.turn.down.right") { omnibar.continueFrom(chat) }
            }
        case let .note(fact):
            icon("book.closed", tint: Palette.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.text).font(.system(size: 13)).lineLimit(2)
                Text(fact.confirmedAt == nil ? "Unconfirmed note" : "Confirmed by you").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
        case .enableChatSearch:
            icon("text.magnifyingglass", tint: Palette.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Search inside your Codex chats").font(.system(size: 13, weight: .semibold))
                Text("Facienda keeps a private index on this Mac of your messages and Codex’s final replies, never tool output. Turn it off any time in Settings.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Turn on") { omnibar.run(item) }.buttonStyle(QuietButton(prominent: true, compact: true))
                    Button("Titles only") { model.setChatSearch(false); Task { await omnibar.refresh() } }.buttonStyle(QuietButton(compact: true))
                }.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18).padding(.top, 1)
    }

    private func action(_ label: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(label, systemImage: symbol).font(.system(size: 11, weight: .medium)) }
            .buttonStyle(.borderless).foregroundStyle(Palette.ink).help(label)
    }
}
