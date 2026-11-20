import SwiftUI
import FaciendaCore

/// Model, reasoning and Fast mode for the next task: one chip in the composer, the top bar and the planner.
/// The model also decides the app the task runs in: Codex or Claude. Each model row carries its own reasoning and Fast,
/// so a model and its settings take one click: the name picks it as it last was, a dot picks it at that level, and
/// either closes the chooser. Fast keeps it open.
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
                        ModelRow(name: option.name, selected: option.id == choice.model, settings: model.composerChoice(option.id),
                                 levels: TaskModelChoice.efforts(for: provider), offersFast: option.offersFast,
                                 pick: { pick(option.id) }, pickLevel: { pick(option.id, effort: $0) },
                                 toggleFast: { model.toggleComposerFast(option.id) }, spokenName: "\(provider.name) \(option.name)")
                    }
                }
            }
            Text(footnote(choice)).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(16).frame(width: 400, alignment: .leading).background(Palette.paper)
    }

    /// Picking a model is the main choice, so the chooser closes once the pick shows. It stays open when that
    /// model's app cannot start the task yet, so the footnote can say why.
    private func pick(_ id: String, effort: String? = nil) {
        if let effort { model.chooseComposerModel(id, effort: effort) } else { model.chooseComposerModel(id) }
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

/// One model in a chooser. The name picks it as it last was. On the chosen row and the one under the pointer, dots show
/// its reasoning like signal bars and pick it at another level; the bolt switches Fast.
struct ModelRow: View {
    let name: String
    let selected: Bool
    /// The reasoning and Fast the model has, or would have if picked now.
    let settings: TaskModelChoice
    let levels: [String]
    var offersFast = false
    let pick: () -> Void
    /// Nil for a row that only picks, without levels.
    var pickLevel: ((String) -> Void)? = nil
    var toggleFast: (() -> Void)? = nil
    /// What VoiceOver reads for the name, when the name alone isn't enough.
    var spokenName: String? = nil
    @State private var hovering = false
    @State private var pointed: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Palette.blue : Palette.muted)
                    Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenName ?? name)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let pickLevel, selected || hovering { dots(pickLevel).transition(.opacity) }
            if offersFast, let toggleFast { bolt(toggleFast) }
        }
        .frame(height: 18).padding(.vertical, 6).padding(.horizontal, 8)
        .background(selected ? Palette.selected : hovering ? Palette.selected.opacity(0.5) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }

    private func dots(_ pickLevel: @escaping (String) -> Void) -> some View {
        let reached = levels.firstIndex(of: settings.effort) ?? 0
        return HStack(spacing: 6) {
            Text(TaskModelChoice.effortName(pointed ?? settings.effort))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                .frame(width: 64, alignment: .trailing)
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.element) { index, level in
                    Button { pickLevel(level) } label: {
                        Circle()
                            .fill(index <= reached ? (selected ? Palette.blue : Palette.muted) : Color.clear)
                            .overlay { if index > reached { Circle().strokeBorder(Palette.muted, lineWidth: 1.2) } }
                            .frame(width: 6, height: 6)
                            .scaleEffect(pointed == level ? 1.4 : 1)
                            .frame(width: 14, height: 18).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { pointed = level } else if pointed == level { pointed = nil }
                    }
                    .animation(Motion.fade, value: pointed)
                    .accessibilityLabel("\(name), \(TaskModelChoice.effortName(level)) reasoning")
                    .accessibilityAddTraits(selected && level == settings.effort ? .isSelected : [])
                }
            }
        }
    }

    /// Like the dots, the bolt shows a model's Fast only where you look; elsewhere it just says the model offers it.
    private func bolt(_ toggleFast: @escaping () -> Void) -> some View {
        let on = settings.fast && (selected || hovering)
        return Button(action: toggleFast) {
            Image(systemName: on ? "bolt.fill" : "bolt").font(.system(size: 10))
                .foregroundStyle(on ? Palette.amber : Palette.muted)
                .frame(width: 20, height: 18).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "Fast is on for \(name). For the next task only." : "Fast mode for \(name): for the next task only. Faster, billed higher.")
        .accessibilityLabel("Fast mode for \(name)")
        .accessibilityAddTraits(on ? .isSelected : [])
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
                    // A model that takes over carries the chat's reasoning, as changeModel does.
                    ModelRow(name: option.name, selected: option.id == current?.model,
                             settings: (current ?? TaskModelChoice.standard(for: own)).choosing(option.id),
                             levels: TaskModelChoice.efforts(for: own), pick: { pick(option.id) },
                             pickLevel: { pick(option.id, effort: $0) })
                }
            }
            Text(model.whyDown(own) ?? "Takes over from the next turn. The chat and its history stay.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                heading(other, "New chat")
                ForEach(TaskModelChoice.models(for: other), id: \.id) { option in
                    ModelRow(name: option.name, selected: false, settings: model.composerChoice(option.id),
                             levels: TaskModelChoice.efforts(for: other), pick: { pick(option.id) })
                        .disabled(!model.canStart(other))
                }
                Text("Continues in a new \(other.name) \(other == .claude ? "session" : "chat") with a handover note.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 8).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 360, alignment: .leading).background(Palette.paper)
        .disabled(model.demo)
    }

    private func heading(_ provider: AgentProvider, _ what: String) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 12)
            Text("\(provider.name) · \(what)".uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 8)
    }

    /// The pick shows at once; the chooser then closes, as the composer's does.
    private func pick(_ id: String, effort: String? = nil) {
        Task {
            await model.changeModel(of: task, to: id, effort: effort)
            try? await Task.sleep(for: .milliseconds(150))
            close()
        }
    }
}
