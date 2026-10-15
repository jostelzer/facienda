import SwiftUI
import FaciendaCore

/// Connects the library to Codex, all from Facienda: nothing has to be sent in Codex.
struct RunWorkspaceSetupButton: View {
    @Bindable var model: AppModel

    private var title: String {
        if model.connectingWorkspace { return "Connecting…" }
        if model.codexNeedsReconnect { return "Reconnect Codex" }
        return model.workspaceReady ? "Check and repair connection" : "Connect Codex"
    }

    var body: some View {
        Button(title) { Task { await model.connectWorkspace(repair: model.workspaceReady) } }
            .buttonStyle(QuietButton(prominent: !model.workspaceReady || model.codexNeedsReconnect))
            .disabled(model.connectingWorkspace || model.demo)
    }
}

struct WorkspaceSetupStatusView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.connectingWorkspace {
            ProgressView("Connecting Facienda to Codex…").controlSize(.small)
        } else if let error = model.workspaceSetupError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(Palette.accent)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The installed app delivers through a login item, which macOS may hold until the user allows it.
struct DispatcherApprovalNote: View {
    private var host: DispatcherHost { .shared }

    var body: some View {
        if host.mode == .needsApproval {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow Facienda in Login Items so tasks reach Codex while Facienda is closed. Until then they go out while it is open.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items…") { host.openLoginItems() }.buttonStyle(QuietButton())
            }
        } else if let problem = host.problem {
            Label(problem, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(Palette.accent).textSelection(.enabled)
        }
    }
}
