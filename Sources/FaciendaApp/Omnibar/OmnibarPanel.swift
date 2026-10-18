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
                                // Facienda's own question reads as a question, not as a label.
                                if section.id == "ask" {
                                    Label(title, systemImage: "questionmark.bubble").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.amber)
                                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                                } else {
                                    Eyebrow(text: title).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                                }
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
        case .start, nil:
            let reading = omnibar.defaultReading
            switch reading.verb {
            case .start, .trackChat, .ask, .answered: hints.append(("↵", "start task"))
            case .find: hints.append(("↵", "find it"))
            case .already: hints.append(("↵", "open it"))
            default: hints.append(("↵", reading.verbLabel.lowercased()))
            }
        case .remember: hints.append(("↵", "remember"))
        case .command: hints.append(("↵", "go"))
        case let .task(task):
            if item?.id.hasPrefix(OmnibarModel.askPrefix) == true { hints.append(("↵", omnibar.reading?.verbLabel.lowercased() ?? "choose")) }
            else { hints.append(("↵", task.state.isOpen ? "open" : "bring back")) }
            if model.canOpen(task) { hints.append(("⌥↵", "open in \(model.agent(for: task).name)")) }
        case let .chat(chat): hints += [("↵", "choose"), ("⌥↵", "open in \(chat.provider.name)")]
        case .note: hints.append(("↵", "show in Memory"))
        case .answer: hints.append(("↵", "close"))
        case .place: hints.append(("↵", "start it there"))
        }
        // Asking for an earlier task finds it on Return, so starting it as new moves to ⌘↵ too.
        if item.map({ $0.kind != .start }) ?? false || omnibar.defaultReading.verb != .start { hints.append(("⌘↵", "start task")) }
        hints.append(("esc", "close"))
        return hints
    }

    /// The first row is what Return does with nothing picked, said as the bar says it.
    private var startTitle: String {
        let reading = omnibar.defaultReading
        switch reading.verb {
        case .trackChat: return OmnibarModel.codexThreadID(omnibar.trimmed) != nil ? "Add Codex chat as task" : "Add Claude session as task"
        case .already: return "Open “\(reading.target)”"
        case .find: return omnibar.finding ? "Finding the task…" : "Find the earlier task"
        case .start:
            if omnibar.awaitingRead { return omnibar.routes ? "Finding where it goes…" : "Reading…" }
            guard let place = reading.place else { return "Start task" }
            return reading.alternative == nil ? "Start task in \(place.label)" : "Start task"
        // Above, Facienda asks or answers; this row is the way out of both.
        case .ask: return "None of these: start a new task"
        case .answered: return "Ask an agent instead"
        default: return reading.label
        }
    }

    /// Under the first row: what it would send or set, and how to start a task instead.
    private var startNote: String? {
        let reading = omnibar.defaultReading
        switch reading.verb {
        case .start:
            // Existing tasks the words match are below; the start row says so, so they are not missed.
            let found = omnibar.items.filter { $0.id.hasPrefix("task:") }.count
            return found == 0 ? nil : found == 1 ? "1 existing task matches below. ↓ to open it." : "\(found) existing tasks match below. ↓ to open one."
        case .trackChat, .ask: return nil
        case .answered: return "Starts a task whose agent looks further than what Facienda holds."
        case .already: return "Already on the board. ⌘↵ starts a second one."
        case .find: return omnibar.followUp == nil ? "Brings back the task you mean. ⌘↵ starts a new one." : nil
        case .remember: return "Kept in this workspace's memory. ⌘↵ starts it as a task."
        default:
            let detail = reading.detail()
            return (detail.isEmpty ? "" : detail + ". ") + "⌘↵ starts a new task instead."
        }
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
                Text(startTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let note = startNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                if let chat = omnibar.followUp { Text("Continues from “\(chat.title)”").font(.system(size: 10)).foregroundStyle(Palette.blue) }
            }
            Spacer(minLength: 8)
            if showActions && omnibar.defaultReading.verb == .start { action("Add files…", "paperclip") { omnibar.perform(.composer) } }
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
            // A task in another workspace is drawn from its own state; the open workspace knows its chats.
            let elsewhere = omnibar.isElsewhere(task), place = omnibar.taskPlaces[task.id]
            PlaceThumb(place: place, workspaces: omnibar.workspaces, elsewhere: elsewhere)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName).font(.system(size: 13)).fullTextOnHover(task.displayName)
                HStack(spacing: 0) {
                    if let place {
                        Text(place.label).foregroundStyle(elsewhere ? Palette.blue : Palette.muted)
                        Text(" · ").foregroundStyle(Palette.muted)
                    }
                    Text(elsewhere ? task.state.label : model.taskStatus(task)).foregroundStyle(Palette.muted)
                }
                .font(.system(size: 11)).lineLimit(1)
            }
            .frame(minHeight: 40)
            Spacer(minLength: 8)
            TaskDot(kind: elsewhere ? TaskDot.Kind(state: task.state) ?? .notStarted : TaskDot.Kind(model: model, task: task), animated: false)
                .frame(width: 18).padding(.top, 12)
            if showActions && !elsewhere {
                if task.state.isOpen { action("Mark done", "checkmark") { model.complete(task); Task { await omnibar.refresh() } } }
                if model.links.contains(where: { $0.taskId == task.id }) { action("Open in \(model.agent(for: task).name)", "arrow.up.right") { omnibar.runSecondary(item) } }
            }
        case let .chat(chat):
            icon("bubble.left.and.bubble.right", tint: Palette.muted)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chat.title.isEmpty ? "Untitled chat" : chat.title).font(.system(size: 13)).fullTextOnHover(chat.title)
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
        case let .answer(read):
            icon("text.bubble", tint: Palette.green)
            VStack(alignment: .leading, spacing: 6) {
                Text(read.answer).font(.system(size: 14, design: .serif)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                let notes = read.notes.map(\.text)
                if !notes.isEmpty {
                    ForEach(notes, id: \.self) { note in
                        Label(note, systemImage: "book.closed").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }
                Text("From what Facienda already holds. ⌘↵ asks an agent to look further.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
        case let .place(place):
            icon(place.groupID == nil ? "tray" : "rectangle.stack", tint: Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.label).font(.system(size: 13))
                if !place.examples.isEmpty {
                    Text("With " + place.examples.prefix(2).map { "“\($0)”" }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
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
