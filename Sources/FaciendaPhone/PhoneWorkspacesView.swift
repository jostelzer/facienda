import SwiftUI
import SwiftData
import FaciendaCompanion

private enum WorkspaceEditor: Identifiable {
    case create, rename(CompanionWorkspace)
    var id: String {
        switch self {
        case .create: "create"
        case .rename(let workspace): workspace.workspaceID
        }
    }
    var workspace: CompanionWorkspace? {
        if case .rename(let workspace) = self { workspace } else { nil }
    }
}

struct PhoneWorkspacesView: View {
    @Binding var selectedID: String
    let cloudEnabled: Bool
    @Query private var records: [CompanionWorkspace]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editor: WorkspaceEditor?

    private var workspaces: [CompanionWorkspace] { CompanionWorkspace.unique(records) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(workspaces.filter { search.isEmpty || $0.name.localizedStandardContains(search) }, id: \.workspaceID) { workspace in
                        HStack(spacing: 16) {
                            Button {
                                selectedID = workspace.workspaceID; dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: workspace.workspaceID == selectedID ? "checkmark.circle.fill" : "square.stack.3d.up")
                                        .foregroundStyle(PhoneStyle.accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(workspace.name).foregroundStyle(.primary)
                                        if cloudEnabled {
                                            Text(workspace.syncedAt == nil ? "Waiting for Mac" : workspace.ready ? "Connected" : "Connect Codex on your Mac")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open \(workspace.name)")
                            // Your Mac owns the names of the workspaces it syncs; rename them there.
                            if !cloudEnabled {
                                Button { editor = .rename(workspace) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).accessibilityLabel("Rename \(workspace.name)")
                            }
                        }.padding(.vertical, 5)
                    }
                    Button("New workspace", systemImage: "plus") { editor = .create }
                        .accessibilityIdentifier("newWorkspace")
                } footer: {
                    Text(cloudEnabled ? "New workspaces sync to your Mac through iCloud; rename them on your Mac. Each workspace keeps its own tasks and memory." : "Workspaces and tasks are saved on this iPhone. A signed iCloud build syncs them with your Mac.")
                }
            }
            .searchable(text: $search, prompt: "Find a workspace")
            .navigationTitle("Workspaces")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editor) { editing in
                PhoneWorkspaceNameView(workspace: editing.workspace) { createdID in
                    if let createdID { selectedID = createdID }
                    editor = nil
                }
            }
        }.tint(PhoneStyle.accent)
    }
}

private struct PhoneWorkspaceNameView: View {
    let workspace: CompanionWorkspace?
    let onSaved: (String?) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(workspace: CompanionWorkspace?, onSaved: @escaping (String?) -> Void) {
        self.workspace = workspace; self.onSaved = onSaved
        _name = State(initialValue: workspace?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("For example, Work or Personal", text: $name).focused($focused)
                        .submitLabel(.done).onSubmit(save).accessibilityIdentifier("workspaceName")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(workspace == nil ? "New workspace" : "Rename workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(workspace == nil ? "Create" : "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveWorkspace")
                }
            }.onAppear { focused = true }
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !name.contains(where: { $0.isNewline }) else { error = "Use a single line for the name."; return }
        let record = workspace ?? CompanionWorkspace(name: name)
        if workspace == nil { context.insert(record) }
        record.name = name; record.nameUpdatedAt = Date()
        do {
            try context.save()
            onSaved(workspace == nil ? record.workspaceID : nil)
        } catch { context.rollback(); self.error = "Couldn’t save the workspace. \(error.localizedDescription)" }
    }
}
