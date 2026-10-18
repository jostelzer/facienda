import SwiftUI
import FaciendaCore

/// The workspace sheets: manage them all, create one, or edit one.
struct WorkspaceSheetView: View {
    @Bindable var workspaces: WorkspaceController
    let sheet: WorkspaceSheet

    var body: some View {
        Group {
            switch sheet {
            case .manage: WorkspaceManagerView(workspaces: workspaces)
            case .create: WorkspaceNameView(workspaces: workspaces, workspace: nil)
            case .edit(let workspace): WorkspaceNameView(workspaces: workspaces, workspace: workspace)
            }
        }.id(sheet.id).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
    }
}

private struct WorkspaceManagerView: View {
    @Bindable var workspaces: WorkspaceController
    @State private var search = ""
    @State private var deletion: Workspace?
    @State private var deleting = false
    @FocusState private var searchFocused: Bool

    private var matches: [Workspace] {
        workspaces.workspaces.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Workspaces").font(.system(size: 28, design: .serif))
                Spacer()
                Button("Done") { workspaces.sheet = nil }.keyboardShortcut(.cancelAction)
            }
            Text("A separate board for each set of tasks, each with a memory of its own.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            TextField("Find a workspace", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { if let first = matches.first, workspaces.open(first) { workspaces.sheet = nil } }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(matches) { workspace in
                        HStack(spacing: 12) {
                            Button {
                                if workspaces.open(workspace) { workspaces.sheet = nil }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: workspace.id == workspaces.current?.id ? "checkmark.circle.fill" : "square.stack.3d.up")
                                        .foregroundStyle(workspace.id == workspaces.current?.id ? Palette.green : Palette.muted)
                                    Text(workspace.name).font(.system(size: 14, weight: .medium))
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open \(workspace.name)")
                            Button { workspaces.error = nil; workspaces.sheet = .edit(workspace) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Edit \(workspace.name)").accessibilityLabel("Edit \(workspace.name)")
                            Button(role: .destructive) { deletion = workspace } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete \(workspace.name)").accessibilityLabel("Delete \(workspace.name)")
                        }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if matches.isEmpty { Text(search.isEmpty ? "Create a workspace to get started." : "No matching workspaces").foregroundStyle(Palette.muted).padding(24) }
                }
            }.frame(minHeight: 140, maxHeight: .infinity)
            if let error = workspaces.error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("New workspace…") { workspaces.error = nil; workspaces.sheet = .create }.buttonStyle(QuietButton(prominent: true))
            }
        }.padding(28).frame(width: 570, height: 480).onAppear { searchFocused = true }
            .disabled(deleting)
            .alert("Delete workspace?", isPresented: Binding(presenting: $deletion), presenting: deletion) { workspace in
                Button("Cancel", role: .cancel) { deletion = nil }
                Button("Delete workspace", role: .destructive) {
                    deleting = true
                    Task { _ = await workspaces.remove(workspace); deleting = false; deletion = nil }
                }
            } message: { workspace in
                Text("Remove “\(workspace.name)” from Facienda? Its finished tasks, Codex chats and memory are kept in your library. A workspace with open tasks can't be deleted until they're done or moved.")
            }
    }
}

private struct WorkspaceNameView: View {
    @Bindable var workspaces: WorkspaceController
    let workspace: Workspace?
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(workspaces: WorkspaceController, workspace: Workspace?) {
        self.workspaces = workspaces
        self.workspace = workspace
        _name = State(initialValue: workspace?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(workspace == nil ? "New workspace" : "Edit workspace").font(.system(size: 28, design: .serif))
            Text(workspace == nil ? "Give this space a name. It starts with an empty memory of its own and uses your existing Codex connection." : "Choose the name you’ll see in the workspace switcher. Its memory keeps the same name.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 12, weight: .medium))
                TextField("For example, Work or Personal", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            }
            if let error = workspaces.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { workspaces.error = nil; workspaces.sheet = nil }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Spacer()
                Button(workspace == nil ? "Create workspace" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(QuietButton(prominent: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 4)
        }.padding(28).frame(width: 490).onAppear { nameFocused = true }
    }

    private func save() {
        guard let workspace else {
            if workspaces.create(name: name) { workspaces.sheet = nil }
            return
        }
        if workspaces.rename(workspace, to: name) { workspaces.sheet = nil }
    }
}
