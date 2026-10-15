import SwiftUI

/// The keyboard shortcuts worth remembering, in one place for the ⌘/ card and Settings.
/// The menus in FaciendaApp.swift and the hotkeys in AppDelegate.swift hold the real bindings.
enum Shortcuts {
    struct Group: Identifiable {
        let title: String
        let items: [(keys: String, does: String)]
        var id: String { title }
    }
    static let groups: [Group] = [
        Group(title: "Capture and talk", items: [
            ("⌃⌥Space", "Quick capture, from any app"),
            ("⌃⌥D", "Quick capture with the microphone on, from any app"),
            ("⌘N", "New task"),
            ("⌘K", "Find or ask"),
            ("⌘D", "Microphone on or off"),
        ]),
        Group(title: "Go", items: [
            ("⌘1 – ⌘4", "Dashboard, In progress, For review, Waiting"),
            ("⌘]  ⌘[", "Next or previous task that needs you"),
        ]),
        Group(title: "The selected task", items: [
            ("⌘↩", "Start the task or send the reply"),
            ("⇧⌘↩", "Accept the recommendation, when one question is open"),
            ("⇧⌘E", "Mark done"),
            ("⌘Z  ⇧⌘Z", "Undo or redo"),
        ]),
        Group(title: "Housekeeping", items: [
            ("⇧⌘G", "New group"),
            ("⇧⌘W", "Switch workspace"),
            ("⌘,", "Settings"),
            ("⌘/", "This list"),
        ]),
    ]
}

struct ShortcutsCard: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard shortcuts").font(.system(size: 22, weight: .semibold))
            ForEach(Shortcuts.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: group.title)
                    ForEach(group.items, id: \.keys) { item in
                        HStack(spacing: 12) {
                            Text(item.keys).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 96, alignment: .leading)
                            Text(item.does).font(.system(size: 13))
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton()) }
        }.padding(28).frame(width: 460).background(Palette.paper).foregroundStyle(Palette.ink)
    }
}
