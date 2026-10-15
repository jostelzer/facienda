import SwiftUI

/// Every workspace to switch to, and the workspace actions, for the Workspaces menu and the menu bar.
struct WorkspaceMenuItems: View {
    @Bindable var workspaces: WorkspaceController
    var includeQuickActions = true

    var body: some View {
        ForEach(workspaces.workspaces) { workspace in
            Button {
                _ = workspaces.open(workspace)
            } label: {
                if workspace.id == workspaces.current?.id {
                    Label(workspace.name, systemImage: "checkmark")
                } else { Text(workspace.name) }
            }.help(workspaces.memoryName(for: workspace) + " memory")
        }
        Divider()
        if includeQuickActions {
            Button("New workspace…", systemImage: "plus") { workspaces.error = nil; workspaces.sheet = .create }
        }
        if let current = workspaces.current {
            Button("Edit workspace…", systemImage: "pencil") { workspaces.error = nil; workspaces.sheet = .edit(current) }
        }
        if includeQuickActions {
            Button("Manage workspaces…", systemImage: "square.stack.3d.up") {
                workspaces.reload(); workspaces.error = nil; workspaces.sheet = .manage
            }
        }
    }
}
