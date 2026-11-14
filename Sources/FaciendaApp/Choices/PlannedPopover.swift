import SwiftUI

/// A planned task opened from its row on a group's card, or a minigoal opened in its subgoal: its words, where it
/// starts, and Start. The words are kept as the popover closes, so nothing is lost to a click outside; Esc leaves them
/// as they were.
struct PlannedPopover<Place: View>: View {
    let text: String
    let canStart: Bool
    let startHelp: String
    /// A minigoal never starts itself: Start starts a task toward it, named like it.
    var minigoal = false
    @ViewBuilder let place: () -> Place
    let save: (String) -> Void
    let start: (String) -> Void
    let remove: () -> Void
    let dismiss: () -> Void
    @State private var draft = ""
    /// Set once Start, Remove or Esc has dealt with the words, so closing does not save them again.
    @State private var settled = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if !minigoal { TaskDot(kind: .notStarted) }
                Text(minigoal ? "Minigoal" : "Planned").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            TextField(minigoal ? "What should be true" : "What you want done", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Palette.firmLine : Palette.line, lineWidth: 1))
                .focused($focused)
                .onSubmit(dismiss)
            HStack(spacing: 8) {
                Text(minigoal ? "Tasks start in" : "Starts in").font(.system(size: 12)).foregroundStyle(Palette.muted)
                place()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { settled = true; remove(); dismiss() } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).help(minigoal ? "Its tasks stay with the subgoal" : "Take it out of the plan")
                Spacer()
                Button { settled = true; dismiss() } label: { Text("Cancel") }
                    .buttonStyle(QuietButton(compact: true)).keyboardShortcut(.cancelAction)
                Button(action: launch) { Label(minigoal ? "Start a task" : "Start", systemImage: "play.fill") }
                    .buttonStyle(QuietButton(prominent: true, compact: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart || trimmed.isEmpty).help(startHelp + " (⌘Return)")
            }
        }
        .padding(14).frame(width: 340)
        .onAppear { draft = text; focused = true }
        .onDisappear { if !settled { keep() } }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func keep() {
        guard !trimmed.isEmpty, trimmed != text else { return }
        save(trimmed)
    }

    private func launch() {
        guard canStart, !trimmed.isEmpty else { return }
        settled = true
        if trimmed != text { save(trimmed) }
        start(trimmed)
        dismiss()
    }
}

/// The place menu inside a planned task's popover: the place's name, which opens its choices.
struct PlannedPlaceLabel: View {
    let name: String
    var suggested = false

    var body: some View {
        HStack(spacing: 5) {
            if suggested { Image(systemName: "sparkles").font(.system(size: 9)) }
            Text(name).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
        .padding(.horizontal, 9).frame(height: 24)
        .background(Palette.card, in: Capsule()).overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        .contentShape(Capsule())
    }
}
