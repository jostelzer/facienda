import SwiftUI
import FaciendaCore

/// Model, reasoning and Fast mode for the next task: one chip in the composer, the top bar and the planner.
/// The model also decides the app the task runs in: Codex or Claude. Picking a model closes the chooser;
/// reasoning and Fast keep it open.
struct ModelChoiceMenu: View {
    @Bindable var model: AppModel
    /// Drawn as a chip with its own edge, for places where it sits inside another field or header.
    var boxed = false
    @State private var choosing = false

    var body: some View {
        let choice = model.composerModel
        Button { choosing.toggle() } label: {
            HStack(spacing: 5) {
                ProviderMark(provider: choice.provider, size: 13)
                Text(choice.name).foregroundStyle(Palette.ink)
                Text("·").foregroundStyle(Palette.muted)
                Text(TaskModelChoice.effortName(choice.effort)).foregroundStyle(Palette.muted)
                if choice.fast { Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Palette.amber) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, boxed ? 8 : 0).frame(height: boxed ? 24 : nil)
            .background(boxed ? Palette.paper : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { if boxed { RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize().font(.system(size: 12, weight: .medium))
        .help("Model, reasoning and speed for the next task. \(choice.provider.name) runs it.")
        .accessibilityLabel("Model: \(choice.provider.name) \(choice.name), \(TaskModelChoice.effortName(choice.effort)) reasoning\(choice.fast ? ", Fast" : "")")
        .accessibilityIdentifier("taskModel")
        .popover(isPresented: $choosing, arrowEdge: .bottom) { ModelChoicePanel(model: model) { choosing = false } }
    }
}

struct ModelChoicePanel: View {
    @Bindable var model: AppModel
    /// Closes the chooser once a model is picked; nil where the panel stands on its own.
    var close: (() -> Void)? = nil

    var body: some View {
        let choice = model.composerModel
        VStack(alignment: .leading, spacing: 16) {
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProviderMark(provider: provider, size: 12)
                        Text(provider.name.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(availability(provider)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.padding(.horizontal, 8)
                    ForEach(TaskModelChoice.models(for: provider), id: \.id) { option in
                        let selected = option.id == choice.model
                        Button { pick(option.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? Palette.blue : Palette.muted)
                                Text(option.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                                Spacer(minLength: 8)
                                if option.offersFast {
                                    Image(systemName: "bolt").font(.system(size: 10)).foregroundStyle(Palette.muted).help("Offers Fast mode")
                                }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(selected ? Palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(provider.name) \(option.name)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Reasoning").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                ReasoningPicker(effort: $model.composerModel.effort, options: TaskModelChoice.efforts(for: choice.provider))
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fast mode").font(.system(size: 12, weight: .medium))
                    Text(choice.offersFast ? "For the next task only. Faster, billed higher." : "\(choice.name) has no Fast mode.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("Fast mode", isOn: $model.composerModel.fast).toggleStyle(.switch).labelsHidden().disabled(!choice.offersFast)
            }
            Text(footnote(choice)).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 400, alignment: .leading).background(Palette.paper)
    }

    /// Picking a model is the main choice, so the chooser closes once the pick shows. It stays open when that
    /// model's app cannot start the task yet, so the footnote can say why.
    private func pick(_ id: String) {
        model.chooseComposerModel(id)
        guard let close, model.canStart(model.composerModel.provider) else { return }
        Task { try? await Task.sleep(for: .milliseconds(150)); close() }
    }

    private func availability(_ provider: AgentProvider) -> String {
        model.canStart(provider) ? "Connected" : "Not connected"
    }

    private func footnote(_ choice: TaskModelChoice) -> String {
        model.whyDown(choice.provider) ?? "Starts on its own in a new \(choice.provider.name) \(choice.provider == .claude ? "session" : "chat")."
    }
}

/// Reasoning levels as one row that always fits its width; a system segmented control can outgrow a popover.
struct ReasoningPicker: View {
    @Binding var effort: String
    let options: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == effort
                Button { effort = option } label: {
                    Text(TaskModelChoice.effortName(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? Color.white : Palette.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(selected ? Palette.blue : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TaskModelChoice.effortName(option) + " reasoning")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2).frame(maxWidth: .infinity)
        .background(Palette.selected, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The model of a task that already has a chat, in its opened task's answer box. A model of the same app takes over
/// the chat from its next turn, with its conversation; the other app's models continue the task in a new chat there.
struct ChatModelMenu: View {
    let model: AppModel
    let task: FaciendaTask
    @State private var choosing = false

    var body: some View {
        let current = model.chatModel(for: task)
        Button { choosing.toggle() } label: {
            HStack(spacing: 5) {
                Text(current?.name ?? "Model")
                if let current { Text(TaskModelChoice.effortName(current.effort)).foregroundStyle(Palette.muted) }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .help("The model \(model.agent(for: task).name) answers with, from its next turn on")
        .accessibilityLabel("Model: " + (current.map { "\($0.name), \(TaskModelChoice.effortName($0.effort)) reasoning" } ?? "unknown"))
        .popover(isPresented: $choosing, arrowEdge: .bottom) { ChatModelPanel(model: model, task: task) { choosing = false } }
    }
}

struct ChatModelPanel: View {
    let model: AppModel
    let task: FaciendaTask
    var close: () -> Void = {}

    var body: some View {
        let own = model.agent(for: task)
        let current = model.chatModel(for: task)
        let other = AgentProvider.allCases.first { $0 != own } ?? own
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                heading(own, "This chat")
                ForEach(TaskModelChoice.models(for: own), id: \.id) { option in
                    row(option.name, selected: option.id == current?.model) { pick(option.id) }
                }
            }
            if let current {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reasoning").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    ReasoningPicker(effort: Binding(get: { current.effort }, set: { effort in
                        Task { await model.changeModel(of: task, to: current.model, effort: effort) }
                    }), options: TaskModelChoice.efforts(for: own))
                }
            }
            Text(model.whyDown(own) ?? "Takes over from the next turn. The chat and its history stay.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                heading(other, "New chat")
                ForEach(TaskModelChoice.models(for: other), id: \.id) { option in
                    row(option.name, selected: false) { pick(option.id) }.disabled(!model.canStart(other))
                }
                Text("Continues in a new \(other.name) \(other == .claude ? "session" : "chat") with a handover note.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 8).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 320, alignment: .leading).background(Palette.paper)
        .disabled(model.demo)
    }

    private func heading(_ provider: AgentProvider, _ what: String) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 12)
            Text("\(provider.name) · \(what)".uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 8)
    }

    private func row(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Palette.blue : Palette.muted)
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(selected ? Palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The pick shows at once; the chooser then closes, as the composer's does.
    private func pick(_ id: String) {
        Task {
            await model.changeModel(of: task, to: id)
            try? await Task.sleep(for: .milliseconds(150))
            close()
        }
    }
}
