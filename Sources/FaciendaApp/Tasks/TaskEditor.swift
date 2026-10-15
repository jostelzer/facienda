import SwiftUI
import FaciendaCore

/// Edits a task's fields by hand, from its menu.
struct TaskEditor: View {
    @Bindable var model: AppModel
    let original: FaciendaTask
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FaciendaTask
    init(model: AppModel, original: FaciendaTask) { self.model = model; self.original = original; _draft = State(initialValue: original) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit task").font(.system(size: 26, design: .serif))
            Form {
                TextField("Title", text: Binding(get: { draft.displayName }, set: { draft.displayTitle = $0; draft.displayTitleSource = "user" }))
                TextField("Why it matters", text: $draft.intention, axis: .vertical)
                TextField("Done looks like", text: $draft.definitionOfDone, axis: .vertical)
                TextField("Area", text: $draft.area)
                Picker("State", selection: $draft.state) { ForEach(TaskState.allCases.filter { $0.isOpen || $0 == original.state }, id: \.self) { Text($0.label).tag($0) } }
                TextField("Next action", text: $draft.nextAction, axis: .vertical)
                Toggle("Return date", isOn: Binding(get: { draft.returnAt != nil }, set: { draft.returnAt = $0 ? (draft.returnAt ?? Date()) : nil }))
                if draft.returnAt != nil { DatePicker("Return", selection: Binding(get: { draft.returnAt ?? Date() }, set: { draft.returnAt = $0 })) }
                if draft.state == .waiting {
                    TextField("Waiting on", text: Binding(get: { draft.waitingOn ?? "" }, set: { draft.waitingOn = $0 }))
                    DatePicker("Check on", selection: Binding(get: { draft.checkAt ?? draft.returnAt ?? Date() }, set: { draft.checkAt = $0 }))
                }
                Picker("Automation", selection: $draft.automationScope) { ForEach(AutomationScope.allCases, id: \.self) { Text($0.label).tag($0) } }
                TextField("Brief", text: $draft.brief, axis: .vertical).lineLimit(3...5)
                HStack {
                    Text(draft.cwd ?? "No working folder").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose folder…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK { draft.cwd = panel.url?.path }
                    }
                }
                if let folders = draft.folders, folders.count > 1 {
                    Text("Also works in its group’s linked folders: " + folders.map(LinkedFolder.name(of:)).joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Save changes") {
                    do {
                        if draft.state == .waiting { draft.checkAt = draft.checkAt ?? draft.returnAt }
                        try model.store.update(original.id, expectedRevision: original.revision) { $0 = draft }
                        model.refresh(); dismiss()
                    } catch { model.error = error.localizedDescription }
                }.buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580, height: 680).background(Palette.paper)
    }
}
