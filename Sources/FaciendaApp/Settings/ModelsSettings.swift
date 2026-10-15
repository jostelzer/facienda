import SwiftUI
import FaciendaCore

/// The model for Facienda's own background work, in Codex or in Claude. Shown on the last setup page and in
/// Settings › Models. The model a task runs on is chosen with each task, in the composer.
struct ServiceModelSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        let recommended = model.recommendedServiceModel
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "BACKGROUND WORK")
            Text("Names for new tasks, one-line headlines, recaps, next steps, waits, finding earlier tasks and built-in memory. A small, fast model does this well.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProviderMark(provider: provider, size: 12)
                        Text(provider.name.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(availability(provider)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    ForEach(TaskModelChoice.models(for: provider), id: \.id) { option in
                        let choice = ServiceModelChoice(provider: provider, model: option.id)
                        let selected = model.serviceModel == choice
                        Button { model.chooseServiceModel(choice) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? Palette.blue : Palette.muted)
                                Text(option.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                                if choice == recommended {
                                    Text("Recommended").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.green)
                                        .padding(.horizontal, 6).padding(.vertical, 1).background(Palette.green.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.demo)
                    }
                }
            }
            if !model.serviceModelReady {
                Label(model.serviceModel.provider == .claude
                      ? "Claude Code isn't on this Mac yet. Install the Claude app, or choose a Codex model."
                      : "Codex isn't connected yet. Connect it on the Codex page, or choose a Claude model.",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            } else if model.serviceModel.provider == .claude {
                Text("Runs through Claude Code with no tools and nothing saved, under the account Claude Code is signed in with.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func availability(_ provider: AgentProvider) -> String {
        switch provider {
        case .codex: model.codexServiceAvailable ? "Connected" : "Not connected"
        case .claude: model.claudeServiceAvailable ? "Connected" : "Not installed"
        }
    }
}
