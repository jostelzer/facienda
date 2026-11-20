import SwiftUI
import FaciendaCore

/// The opened task, over the whole board panel. It grows out of the row that was clicked and folds back into it, so
/// the board is still felt underneath; opened from anywhere else, it fades.
struct TaskOpenLayer: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A sheet growing from a row crosses the window; without a row, or with Reduce Motion, it only fades.
    static func motion(from row: CGRect?) -> Animation {
        row != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Motion.travel : Motion.fade
    }

    var body: some View {
        GeometryReader { proxy in
            if let task = model.selectedTask {
                let origin = proxy.frame(in: .global).origin
                let row = reduceMotion ? nil : model.openedFrom?.offsetBy(dx: -origin.x, dy: -origin.y)
                // One sheet for whichever task is open: the next task swaps in place instead of growing again.
                ZStack {
                    TaskOpenView(model: model, task: task) { close() }
                        .id(task.id).transition(.opacity)
                }
                .transition(row.map { .modifier(active: GrowFromRow(progress: 0, row: $0), identity: GrowFromRow(progress: 1, row: $0)) } ?? .opacity)
            }
        }
    }

    private func close() {
        withAnimation(Self.motion(from: model.openedFrom)) { model.select(nil) }
    }
}

/// The sheet's outline on its way between the row and the whole panel.
private struct GrowShape: Shape {
    var row: CGRect
    var progress: Double

    func path(in bounds: CGRect) -> Path {
        func between(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
        let rect = CGRect(x: between(row.minX, bounds.minX), y: between(row.minY, bounds.minY),
                          width: between(row.width, bounds.width), height: between(row.height, bounds.height))
        return Path(roundedRect: rect, cornerRadius: 9)
    }
}

/// Shows the sheet through an outline that grows from the row to the panel, coming up as it grows.
private struct GrowFromRow: ViewModifier, @MainActor Animatable {
    var progress: Double
    let row: CGRect

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask { GrowShape(row: row, progress: progress) }
            .overlay { GrowShape(row: row, progress: progress).stroke(Palette.firmLine, lineWidth: 1).opacity(1 - progress).allowsHitTesting(false) }
            .opacity(progress)
    }
}

/// One task in one column: the end of its chat to read, and under it the field to answer in. The answer is read
/// here, so most tasks never need the agent's own app; it stays one click away in the bar.
struct TaskOpenView: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    let close: () -> Void
    @State private var tail: ChatTail?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var viewport: CGFloat = 0
    /// The pointer is on the side left of the column, which goes back to the board, or on its round button. Kept
    /// apart because leaving one for the other can report the two in either order.
    @State private var onSide = false
    @State private var onBack = false
    /// The panel's width, which sets the side and so where the bar's name starts.
    @State private var width: CGFloat = 0
    /// Words were just sent: they land in the chat, and the task folds home a moment later.
    @State private var landing = false
    /// Settings › General: off keeps the task open once the words have landed.
    @AppStorage(Self.backAfterSendKey) private var backAfterSend = true
    static let backAfterSendKey = "backToBoardAfterSend"
    /// How long the landed words stay in view, under the agent's working line, before the task folds home. Folding at
    /// once took them away before they were seen to go anywhere.
    private static let landed: Duration = .milliseconds(340 + 700)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The reading width, shared by the chat and the dock under it: wide enough to use a large window, short of
    /// lines too long to read.
    private static let column: CGFloat = 920
    /// The margin left of the column at this width: the room the column leaves, never less than its 28 pt padding.
    private static func side(in width: CGFloat) -> CGFloat { (width - min(column, width - 56)) / 2 }
    private var landMotion: Animation { reduceMotion ? Motion.fade : Motion.move }
    private var agent: AgentProvider { model.agent(for: task) }
    private var recap: TaskRecap? { model.recap(for: task) }
    /// The task's group lends the view its picture and its colour, as it does the group's card. A task without a
    /// group, or a group without a cover, stays plain.
    private var look: (cover: NSImage, tint: Color)? {
        guard let group = model.groupMembers[task.id] else { return nil }
        let look = model.look(for: group)
        return look.cover.map { ($0, look.tint) }
    }
    /// Paper with a breath of the group's colour, as the island takes its open workspace's.
    private func ground(_ strength: Double) -> Color {
        look.map { Palette.paper.mix(with: $0.tint, by: strength, in: .device) } ?? Palette.paper
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            // The chat's end is what is answered, so that is where it opens; a short one still starts at the top.
            // The anchor alone left a chat that only just overflows at its top once the dock grew under it, so the
            // newest lines hid under the suggestion; it is moved to the end whenever the chat or its room changes.
            VStack(spacing: 0) {
                // The way back runs inside the chat's content, at least as tall as the view, so scrolling over the
                // side still scrolls the chat and only a click goes back.
                ScrollView { reading.frame(minHeight: viewport, alignment: .top).background(alignment: .leading) { backSide } }
                    .defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment)
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                        viewport = height
                        position.scrollTo(edge: .bottom)
                    }
                    .onChange(of: tail) { position.scrollTo(edge: .bottom) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Palette.line).frame(height: 1)
                dock
            }
            .overlay { backWash }
        }
        .background(ground(0.05))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // What was here to read has been read once the task is left, whichever way.
        .onDisappear { model.markReviewed(task.id) }
        // Leaving another way in the meantime ends the wait with the view.
        .task(id: landing) {
            guard landing, backAfterSend else { return }
            try? await Task.sleep(for: Self.landed)
            if !Task.isCancelled { close() }
        }
        .task(id: "\(task.id):\(model.connected):\(model.resultLink(for: task)?.id ?? ""):\(model.lastMessageAt(for: task)?.timeIntervalSince1970 ?? 0):\(model.pendingDispatch(for: task.id)?.id ?? "")") {
            // What is saved shows at once; the chat is then fetched afresh and read again.
            await read()
            await model.loadConversation(for: task)
            await read()
        }
    }

    /// A long chat runs to many megabytes, so it is read off the main thread, and only its last exchanges are kept.
    private func read() async {
        guard let link = model.resultLink(for: task) else { return }
        let store = model.store, dispatches = model.nativeDispatches, request = task.title, taskID = task.id, threadID = link.codexThreadId
        let latest = await Task.detached(priority: .userInitiated) {
            (try? store.conversationSnapshot(taskId: taskID, threadId: threadID))
                .map { ChatTail($0.conversation, originalRequest: request, dispatches: dispatches, limit: 5) }
        }.value
        if !Task.isCancelled, let latest { tail = latest }
    }

    // MARK: The bar

    /// The bar stands on the group's cover, which fades into the page as it fades into the group's card.
    @ViewBuilder private var header: some View {
        if let look {
            let page = ground(0.05)
            bar.padding(.top, 52)
                .background {
                    Image(nsImage: look.cover).resizable().scaledToFill().accessibilityHidden(true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        .overlay {
                            LinearGradient(stops: [.init(color: page.opacity(0), location: 0), .init(color: page.opacity(0.3), location: 0.36),
                                                   .init(color: page.opacity(0.9), location: 0.7), .init(color: page, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                }
                .clipped()
        } else { bar }
    }

    /// The way back is the side alone, so the bar holds only the task: its name starts where the chat's text does.
    private var bar: some View {
        let dot = TaskDot.Kind(model: model, task: task)
        return HStack(spacing: 10) {
            name.layoutPriority(2)
            HStack(spacing: 5) {
                TaskDot(kind: dot)
                if dot.waitsOnUser, let since = model.lastMessageAt(for: task) { MessageAge(date: since) }
            }
            .help(dot.label)
            Spacer(minLength: 8)
            TaskMenu(model: model, task: task).foregroundStyle(Palette.muted)
        }
        .padding(.leading, max(18, Self.side(in: width))).padding(.trailing, 14).frame(height: 50)
    }

    /// The name the user recognises, then where the thread went, greyed: the same line as on the task's row.
    private var name: some View {
        let name = Text(task.displayName).font(.system(size: 14, weight: .semibold))
        let tail = model.handovers[task.id]?.tail ?? recap?.steps.last
        return (tail.map { Text("\(name)\(Text(" · " + $0).font(.system(size: 14)).foregroundStyle(Palette.muted))") } ?? name)
            .lineLimit(1).textSelection(.enabled)
    }

    // MARK: Reading

    private var reading: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tail, tail.earlier > 0 { earlier(tail.earlier).padding(.leading, 2).padding(.bottom, 18) }
            VStack(alignment: .leading, spacing: 22) {
                ForEach(exchanges) { exchange in
                    // Only the last words can still be waiting for their answer.
                    let answers = exchange.answer != nil || exchange.id == exchanges.last?.id
                    VStack(alignment: .leading, spacing: Self.turnSpace) {
                        if let said = exchange.said { wanted(said, joined: answers) }
                        else if let note = exchange.note {
                            Text(note).font(.system(size: 11.5)).foregroundStyle(Palette.muted).padding(.leading, 2)
                        }
                        if answers { answered(exchange.answer) }
                    }
                    // Sent words come up out of the field below as the chat makes room for them.
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 64)))
                }
            }
            .animation(landMotion, value: landing)
            if let error = model.resultErrors[task.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.leading, 23).padding(.top, 8)
            }
            TaskDetail(model: model, task: task).padding(.top, 22)
        }
        .frame(maxWidth: Self.column, alignment: .leading)
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    /// The chat's last exchanges. Before the chat has been read, or for a task without one, what is known stands in:
    /// the user's last words or the request, and as much of the answer as was saved.
    private var exchanges: [ChatTail.Exchange] {
        var exchanges = known
        // Words just sent are not in the chat until the agent takes them; they stand at its end, waiting for the answer.
        if let sent = model.unanswered(for: task), exchanges.last?.said != sent.words {
            exchanges.append(ChatTail.Exchange(id: (exchanges.last?.id ?? -1) + 1, said: sent.words))
        }
        return exchanges
    }

    private var known: [ChatTail.Exchange] {
        if let tail, !tail.exchanges.isEmpty { return tail.exchanges }
        // A request that is only the task's name again is left out: the bar says it already.
        let said = recap?.said ?? (task.title.isEmpty || task.title == task.displayName ? nil : task.title)
        var answer: String?
        if let excerpt = model.latestResults[task.id]?.excerpt, !excerpt.isEmpty { answer = excerpt }
        else if let recap { answer = [recap.answer, recap.ask ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }
        return [ChatTail.Exchange(id: 0, said: said, answer: answer?.isEmpty == false ? answer : nil)]
    }

    /// The chat went on longer than what is shown; the rest is in the agent's own app.
    @ViewBuilder private func earlier(_ count: Int) -> some View {
        let line = count == 1 ? "1 earlier exchange" : "\(count) earlier exchanges"
        if model.canOpen(task) {
            Button { model.open(task) } label: {
                Text(line + " in \(agent.name)").font(.system(size: 11.5)).foregroundStyle(Palette.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open the whole chat in \(agent.name) (⌘O)")
        } else {
            Text(line).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
    }

    /// The ring and the agent's mark share one column, each centred on the first line of its text.
    private static let symbol: CGFloat = 14, symbolLine: CGFloat = 19, symbolSpace: CGFloat = 9, turnSpace: CGFloat = 10
    private static let ring: CGFloat = 8.5

    /// The user's words as the board's rows draw them, at reading size: grey beside a small ring, with a hairline from
    /// the ring down the length of the words to the mark of the answer, so the two read as one exchange.
    private func wanted(_ words: String, joined: Bool) -> some View {
        HStack(alignment: .top, spacing: Self.symbolSpace) {
            Circle().strokeBorder(Palette.muted, lineWidth: 1.3).frame(width: Self.ring, height: Self.ring)
                .frame(width: Self.symbol, height: Self.symbolLine)
            Text(words).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(12).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(alignment: .topLeading) {
            if joined {
                // From 2 pt under the ring to 2 pt above the mark, which sits 3 pt into its own line.
                let ringFoot = (Self.symbolLine + Self.ring) / 2
                Rectangle().fill(Palette.muted.opacity(0.55)).frame(width: 1).frame(width: Self.symbol)
                    .padding(.top, ringFoot + 2).padding(.bottom, -(Self.turnSpace + (Self.symbolLine - 13) / 2 - 2))
            }
        }
        .help("You")
    }

    /// The answer is the agent's text: only ever shown through `ResultText`, which asks before a misleading link and
    /// loads no picture from outside the work folder.
    private func answered(_ answer: String?) -> some View {
        HStack(alignment: .top, spacing: Self.symbolSpace) {
            ProviderMark(provider: agent, size: 13).frame(width: Self.symbol, height: Self.symbolLine)
            if let answer {
                ResultText(model: model, text: answer, task: task).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(waitingLine).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
        .help(agent.name)
    }

    private var waitingLine: String {
        if model.neverStarted(task) { return "Not started yet." }
        if model.belongs(task, to: .processing) { return "\(agent.name) is working. Its answer shows here." }
        return model.statusLine(for: task) ?? "Nothing to read yet."
    }

    // MARK: The dock

    /// Answering sits right under what is answered, in the same column.
    private var dock: some View {
        // A finished task has nothing left to read here, so Done also closes it and the board takes it in one move.
        TaskChoicesPopover(model: model, task: task, dock: true,
                           done: { withAnimation(TaskOpenLayer.motion(from: model.openedFrom)) { model.complete(task); model.select(nil) } },
                           parked: { _, label in model.offerUndo("Parked · " + label) }, dismiss: {}, afterSend: land)
            .frame(maxWidth: Self.column, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(look == nil ? Palette.card.opacity(0.6) : ground(0.14))
            .overlay(alignment: .leading) { backSide }
    }

    /// The words are sent and already stand at the chat's end; they move up into place and the chat scrolls with
    /// them, all on one move, before the task folds home.
    private func land() {
        landing = true
        withAnimation(landMotion) { position.scrollTo(edge: .bottom) }
    }

    // MARK: The way back

    /// The empty margin left of the column is the one way back to the board, from under the bar to the foot. It takes
    /// no room of its own: the column keeps its width, and a narrow window leaves only the column's padding.
    private var backSide: some View {
        GeometryReader { proxy in
            Color.clear.frame(width: Self.side(in: proxy.size.width))
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .onHover { inside in withAnimation(Motion.fade) { onSide = inside } }
        }
        .accessibilityHidden(true)
    }

    /// A soft round chevron rests at the side's middle, so the way back is found without hovering; on the side a
    /// rounded wash fills it and the chevron comes up. The chevron is a real button, which carries Esc and the label.
    private var backWash: some View {
        GeometryReader { proxy in
            let width = Self.side(in: proxy.size.width)
            let narrow = width < 60
            let lit = onSide || onBack
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Palette.ink.opacity(0.05))
                    .padding(.horizontal, narrow ? 3 : 8).padding(.vertical, 10)
                    .opacity(lit ? 1 : 0).allowsHitTesting(false)
                Button(action: close) {
                    Image(systemName: "chevron.left").font(.system(size: narrow ? 10 : 12, weight: .semibold))
                        .foregroundStyle(lit ? Palette.ink : Palette.muted)
                        .frame(width: narrow ? 22 : 30, height: narrow ? 22 : 30)
                        .background {
                            Circle().fill(lit ? Palette.card : Palette.ink.opacity(0.05))
                                .overlay { Circle().strokeBorder(Palette.line.opacity(lit ? 1 : 0), lineWidth: 1) }
                                .shadow(color: .black.opacity(lit ? 0.08 : 0), radius: 3, y: 1)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .help("Back to the board (Esc)").accessibilityLabel("Back to the board")
                .onHover { inside in withAnimation(Motion.fade) { onBack = inside } }
            }
            .frame(width: width, height: proxy.size.height)
        }
    }
}

