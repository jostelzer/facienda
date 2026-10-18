import SwiftUI
import FaciendaCore

/// Where each group's card sits on the board, keyed like the board's lists: group ID, or "" for Unsorted.
struct GroupCardKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}

/// A card's + opens its group as a sheet over a wash of its cover. The card grows out of its place into the middle
/// of the window, its cover sweeping from the top band into a tall panel on the left, and the field settles in on the right.
/// Starting the task folds the sheet straight back into the card, where the new row is already waiting.
/// The board's own + opens one for a group that does not exist yet: its name is typed on the empty cover, and the sheet
/// folds into the new card once the group is made.
///
/// Only a light frame moves: the sheet's surface and cover. The field, the model chooser and the task list stand still
/// in their final place and fade in once the frame has nearly arrived, so typing and popovers never sit inside a moving transform.
struct GroupSheetLayer: View {
    @Bindable var omnibar: OmnibarModel
    /// Every card's frame in this layer's space.
    var cards: [String: CGRect]
    var size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The group on screen. It stays while the sheet folds away, after the spotlight itself has gone.
    @State private var shown: String?
    @State private var progress = 0.0
    /// Whether the field and its neighbours take clicks: from the moment the sheet opens until it starts to fold.
    @State private var settled = false
    /// Folding home, where the cover hands over to the card's own banner as it lands.
    @State private var folding = false
    private var model: AppModel { omnibar.model }

    static let width: CGFloat = 760
    static let height: CGFloat = 440

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown {
                let look = model.look(for: shown), target = target
                let tasks = shown == AppModel.newGroupSheet ? [] : model.boardTasks(in: shown == AppModel.unsortedGroup ? nil : shown)
                // A new group's name is typed on the cover itself, so the moving frame carries none.
                let name = model.groups.first { $0.id == shown }?.name ?? (shown == AppModel.newGroupSheet ? "" : "Unsorted")
                MoodSpotlight(cover: look.cover, tint: look.tint) { model.releaseSpotlight() }
                    .opacity(min(max(progress, 0), 1))
                // Resting as the board sees it: nothing to do and nothing planned.
                GroupSheetFrame(cover: look.cover, tint: look.tint, name: name, resting: tasks.isEmpty && model.plannedLines(in: shown).isEmpty,
                                lastActive: model.lastActive(in: shown == AppModel.unsortedGroup ? nil : shown),
                                from: cards[shown] ?? target, to: target, progress: progress, landing: folding, reduceMotion: reduceMotion)
                // The motion starts once the field has focus: setting that up mid-flight dropped frames.
                GroupSheetContent(omnibar: omnibar, group: shown, name: name, tasks: tasks, ready: open)
                    .frame(width: target.width, height: target.height)
                    .offset(x: target.minX, y: target.minY)
                    // Read off the sheet's own progress, so the field lands with the frame rather than on a timer of its own.
                    .modifier(GroupSheetReveal(progress: progress, from: settled ? 0.6 : 0.85, reduceMotion: reduceMotion))
                    .allowsHitTesting(settled)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: model.spotlitGroup, initial: true) { old, group in
            if let old, old != group { omnibar.sheetClosed(old) }
            guard let group else {
                // A new group's sheet folds into the card just made for it rather than back into the +.
                if let landing = model.sheetLanding { model.sheetLanding = nil; if shown == AppModel.newGroupSheet { shown = landing } }
                return fold()
            }
            if old != group { omnibar.sheetOpened(group) }
            // A sheet still folding away opens again from where it is; another group starts from its own card.
            if shown == group { open() } else { progress = 0; settled = false; folding = false; shown = group }
        }
    }

    /// Centred beneath the top bar, a little above the middle.
    private var target: CGRect {
        let width = min(Self.width, size.width - 48), height = min(Self.height, size.height - 120)
        return CGRect(x: ((size.width - width) / 2).rounded(), y: max(64, ((size.height - height) / 2 - 12).rounded()), width: width, height: height)
    }

    /// The frame, the wash and the field ride one animation, as a workspace switch does.
    /// Reduce Motion keeps the sheet in place and only fades it.
    private func open() {
        settled = true; folding = false
        MotionLog.begin("Sheet opens")
        withAnimation(reduceMotion ? Motion.fade : Motion.travel) { progress = 1 } completion: { MotionLog.end() }
    }

    /// Folds back into its card on the same curve; the field is gone in the first stretch of the way.
    private func fold() {
        guard shown != nil else { return }
        settled = false; folding = true
        MotionLog.begin("Sheet folds")
        withAnimation(reduceMotion ? Motion.fade : Motion.travel, completionCriteria: .removed) { progress = 0 } completion: {
            MotionLog.end()
            if model.spotlitGroup == nil { shown = nil }
        }
    }
}

/// The moving part of the sheet at `progress` between its card (0) and the middle of the window (1):
/// a surface, the cover and the group's name. Nothing in it takes text or focus, so redrawing it every frame is cheap.
struct GroupSheetFrame: View, @MainActor Animatable {
    let cover: NSImage?
    let tint: Color
    let name: String
    /// A resting card dims its cover and sinks its banner into the board; the sheet starts from that look.
    let resting: Bool
    /// When a task in the group last changed, shown under its name.
    let lastActive: Date?
    var from: CGRect
    var to: CGRect
    var progress: Double
    /// Folding home: the cover fades over the last stretch onto the card's own banner beneath, rather than leaving at once.
    var landing: Bool
    var reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The cover's height on a card, and its width as the sheet's left panel.
    static let cardCover: CGFloat = 112
    static let panel: CGFloat = 230

    var body: some View {
        let _ = MotionLog.frame()
        // Under Reduce Motion nothing travels: the sheet stands in place and fades.
        let travel = reduceMotion ? 1 : progress
        let rect = Self.mix(from, to, travel)
        // The cover reaches the sheet's full height early, so it never trails a white strip beneath it.
        let tall = 1 - pow(1 - min(max(travel, 0), 1), 2.5)
        let top = min(Self.cardCover, from.height)
        let band = CGSize(width: from.width + (Self.panel - from.width) * travel, height: top + (rect.height - top) * tall)
        // The surface is solid almost at once, so the sheet is never see-through; its shadow comes with the travel.
        let surface = reduceMotion ? progress : Self.ramp(progress, 0, 0.15)
        let corner = 12 + 4 * min(max(travel, 0), 1)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        ZStack(alignment: .topLeading) {
            shape.fill(Palette.card.opacity(surface))
                .shadow(color: .black.opacity(0.38 * progress), radius: 28, y: 14)
            panel(band, travel: travel)
                // It grows out of the card's banner, so it is there from the start. Without a cover the card has no banner,
                // and under Reduce Motion the whole sheet fades, so then it comes with the surface, as it does when landing.
                .opacity(cover == nil || reduceMotion || landing ? surface : 1)
                // Clipped by the sheet's outline, not its own, so only the sheet's outer corners are round.
                .frame(width: max(rect.width, 1), height: max(rect.height, 1), alignment: .topLeading)
                .clipShape(shape)
            shape.strokeBorder(tint.opacity(0.5 * surface), lineWidth: 1)
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1), alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New task in " + name)
    }

    /// The cover, from the card's banner to the tall panel on the left. It starts exactly as the card draws it, fading into
    /// the card's colour with the name in ink on the fade, and turns into the panel as it travels: the fade darkens, the name
    /// grows and turns white, and a resting group's dimmed cover wakes. Nothing about it changes once it has landed.
    private func panel(_ size: CGSize, travel: Double) -> some View {
        let t = min(max(travel, 0), 1)
        // The card's own colour; a resting card has none, so its banner sinks into the board.
        let ground = resting ? Palette.paper : Palette.card
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let cover { Image(nsImage: cover).resizable().scaledToFill() } else { tint }
            }
            .frame(width: max(size.width, 1), height: max(size.height, 1)).clipped()
            .saturation(resting ? 0.6 + 0.4 * t : 1).brightness(resting ? -0.4 * (1 - t) : 0)
            LinearGradient(stops: [.init(color: ground.opacity(0), location: 0.3), .init(color: ground.opacity(0.55), location: 0.7),
                                   .init(color: ground, location: 1)], startPoint: .top, endPoint: .bottom).opacity(1 - t)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .init(x: 0.5, y: 0.4), endPoint: .bottom).opacity(t)
            VStack(alignment: .leading, spacing: 3 * t) {
                // One name in both inks: the white comes in over the card's ink before the ink goes, so it never thins or doubles.
                ZStack(alignment: .leading) {
                    Text(name).foregroundStyle(resting ? Palette.muted : Palette.ink).opacity(min(1, 2 - 2 * t))
                    Text(name).foregroundStyle(.white).opacity(min(1, 2 * t))
                }
                .font(.system(size: 15 + 2 * t, weight: .semibold)).lineLimit(t > 0 ? 2 : 1)
                .frame(minHeight: 22 * (1 - t), alignment: .leading)
                if let lastActive {
                    Text(Self.since(lastActive)).font(.system(size: 11)).foregroundStyle(.white).opacity(0.85 * t)
                        .frame(height: 14 * t, alignment: .top)
                }
            }
            // From where the card sets its title on the banner to where the panel sets it.
            .padding(.horizontal, 20 - 4 * t).padding(.top, 16).padding(.bottom, 10 + 6 * t)
            .frame(width: max(size.width, 1), alignment: .leading)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .bottomLeading)
        .clipped()
    }

    private static func since(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "Active just now" : "Last active " + date.formatted(.relative(presentation: .named))
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// 0 before `start`, 1 after `end`, eased in between.
    static func ramp(_ t: Double, _ start: Double, _ end: Double) -> Double {
        let x = min(max((t - start) / (end - start), 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// The field stands still in its final place while the frame travels beneath it, so it shows only over the last stretch
/// of the sheet's progress, from `from` to the end, and is gone in the first stretch of folding. Under Reduce Motion it fades with the sheet.
private struct GroupSheetReveal: ViewModifier, @MainActor Animatable {
    var progress: Double
    var from: Double
    var reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(reduceMotion ? progress : GroupSheetFrame.ramp(progress, from, 1))
    }
}

/// What lies over the sheet: on the right the field, its model and mic, and the group's tasks for context; on the left,
/// over the cover, a new group's name.
private struct GroupSheetContent: View {
    @Bindable var omnibar: OmnibarModel
    let group: String
    let name: String
    let tasks: [FaciendaTask]
    /// Called once the field has focus and its caret is in place.
    var ready: () -> Void
    @FocusState private var focused: Bool
    @FocusState private var naming: Bool
    @State private var selection: TextSelection?
    @State private var dropping = false
    private var model: AppModel { omnibar.model }
    private var isNew: Bool { group == AppModel.newGroupSheet }

    var body: some View {
        HStack(spacing: 0) {
            // The cover beneath belongs to the moving frame; only a new group's name takes clicks here.
            Group {
                if isNew { nameField } else { Color.clear.allowsHitTesting(false) }
            }.frame(width: GroupSheetFrame.panel)
            side
        }
        // Esc works wherever focus is in the sheet, not only in the field.
        .onExitCommand { model.releaseSpotlight() }
        // Focus once the field is in the window; asked any sooner, AppKit hands it to the top bar.
        // A draft kept from last time comes back with the caret after it, not selected, so the next key adds to it.
        // A new group starts with its name.
        .task {
            try? await Task.sleep(for: .milliseconds(30)); if isNew { naming = true } else { focused = true }
            try? await Task.sleep(for: .milliseconds(30)); selection = TextSelection(insertionPoint: omnibar.sheetText.endIndex)
            ready()
        }
        // While the sheet is up, ⌘D dictates into it rather than the bar beneath.
        .onAppear { model.composersOnScreen += 1 }
        .onDisappear { model.composersOnScreen -= 1 }
        .onChange(of: model.dictationRequest) { focused = true; omnibar.toggleDictation() }
    }

    /// The new group's name, where a group's name sits on its cover. Return goes on to its first task.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            TextField("", text: $omnibar.newGroupName, prompt: Text("Name the group").foregroundStyle(.white.opacity(0.72)))
                .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .focused($naming)
                .onSubmit { focused = true }
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(naming ? 0.7 : 0.45)).frame(height: 1) }
                .accessibilityLabel("Name of the new group")
            Text("Or leave it to Facienda").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                TextField(placeholder, text: $omnibar.sheetText, selection: $selection, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    // Fills the side, then scrolls.
                    .lineLimit(max(3, Int(proxy.size.height / 19)))
                    .focused($focused)
                    .onKeyPress(keys: [.return, .escape], phases: .down) { press in
                        if press.key == .return, press.modifiers.contains(.shift), !omnibar.dictation.isActive { omnibar.breakLine(at: &selection); return .handled }
                        return omnibar.handle(press)
                    }
                    .onSubmit { omnibar.submit() }
                    // Typing while dictating keeps what is there and stops listening, as in the bar.
                    .onChange(of: omnibar.sheetText) { _, text in omnibar.edited(text) }
                    .frame(width: proxy.size.width, alignment: .topLeading)
                    .overlay { VoiceShapes(dictation: omnibar.dictation, text: omnibar.sheetText.isEmpty ? placeholder : omnibar.sheetText) }
                    .accessibilityLabel(isNew ? "First task of the new group" : "What should happen in " + name)
            }
            .takesAttachments(omnibar, focus: $focused, dropping: $dropping)
            // The empty space below the text belongs to the field too: it shows the text cursor, and a click there puts the caret back in it.
            .contentShape(Rectangle())
            .pointerStyle(.horizontalText)
            .onTapGesture { focused = true }
            .padding(.leading, 22).padding(.trailing, 40).padding(.top, 20).padding(.bottom, 10)
            .background(Palette.blue.opacity(dropping ? 0.06 : 0))
            if !omnibar.attachments.isEmpty { AttachmentRow(omnibar: omnibar).padding(.horizontal, 22).padding(.bottom, 8) }
            HStack(spacing: 8) {
                // The mic leads, right under where the text begins.
                MicButton(dictation: omnibar.dictation, shortcut: "⌘D", size: 15, look: .ring) { focused = true; omnibar.toggleDictation() }
                    .padding(.vertical, -3)
                ModelChoiceMenu(model: model, boxed: true)
                AttachButton(omnibar: omnibar) { focused = true }
                Spacer(minLength: 8)
                if model.capturing { ProgressView().controlSize(.small) }
                else {
                    // With no task written yet there is no line to break; the room goes to Make group.
                    if !(isNew && omnibar.makesGroupOnly) { Text("⇧↵ new line").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    // Unsorted has no plan to hold it; a new group gets one with its first line.
                    if isNew || model.groups.contains(where: { $0.id == group }) {
                        Button { omnibar.plan() } label: { SheetButton.label("Plan", key: "⌥↵") }
                            .buttonStyle(SheetButton()).disabled(!omnibar.canPlan)
                            .help(!omnibar.attachments.isEmpty ? "A planned task holds text only; start it to send the files"
                                  : isNew ? "Make the group with this in its plan, not started (⌥↵)" : "Keep it in \(name)'s plan without starting it (⌥↵)")
                    }
                    if isNew && omnibar.makesGroupOnly {
                        Button { omnibar.submit() } label: { SheetButton.label("Make group", key: "↵") }
                            .buttonStyle(SheetButton(prominent: true)).disabled(!omnibar.canMakeGroup)
                            .help("Make the group without a task yet (↵)")
                    } else {
                        Button { omnibar.submit() } label: { SheetButton.label("Start", key: "↵") }
                            .buttonStyle(SheetButton(prominent: true)).disabled(!omnibar.canStart)
                            .help(isNew ? "Make the group and start its first task (↵)" : "Start it now in \(name) (↵)")
                    }
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 14)
            if !tasks.isEmpty {
                Divider()
                Eyebrow(text: "In this group").padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tasks) { task in row(task) }
                    }.padding(.bottom, 8)
                }.frame(maxHeight: 128).fixedSize(horizontal: false, vertical: true)
            }
        }
        // On the text side, top right, where the task panel keeps its own.
        .overlay(alignment: .topTrailing) {
            Button { model.releaseSpotlight() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help("Close without starting").accessibilityLabel("Close").padding(.top, 12).padding(.trailing, 12)
        }
    }

    private func row(_ task: FaciendaTask) -> some View {
        let unread = model.isUnread(task)
        return HStack(spacing: 8) {
            Text(task.displayName).font(.system(size: 12, weight: unread ? .semibold : .regular)).foregroundStyle(Palette.ink).fullTextOnHover(task.displayName)
            Spacer(minLength: 6)
            TaskDot(kind: TaskDot.Kind(model: model, task: task)).frame(width: 18, height: 16)
        }
        .padding(.leading, 22).padding(.trailing, 16).padding(.vertical, 4)
        // The same blue dot as on the board, in the gutter.
        .overlay(alignment: .leading) { if unread { UnreadDot(size: 6).padding(.leading, 9) } }
    }

    private var placeholder: String {
        switch omnibar.dictation.phase {
        case .downloading: return "Downloading the speech model… \(Int(omnibar.dictation.progress * 100))%"
        case .listening where !omnibar.dictation.modelReady: return "Loading the speech model, words follow…"
        case .listening where omnibar.dictation.showsVoice: return ""
        case .preparing, .listening: return "Listening…"
        case .idle, .finishing:
            if !omnibar.attachments.isEmpty { return "What should happen with \(omnibar.attachments.count == 1 ? "it" : "them")?" }
            return isNew ? "Its first task, or leave it empty" : "What should happen in \(name)?"
        }
    }
}

/// The app's QuietButton, sized to sit in a row of 24 pt chips: card and hairline, or ink when it is the one ↵ presses.
private struct SheetButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    static func label(_ title: String, key: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text(key).font(.system(size: 10)).opacity(0.6)
        }
        // A button's words never clip; the spacer before it gives way first.
        .fixedSize()
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(prominent ? Palette.paper : Palette.ink)
            .background(prominent ? Palette.ink : Palette.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? .clear : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}
