import SwiftUI
import FaciendaCore

struct MemoryView: View {
    @Bindable var model: AppModel
    private var enabled: Bool { model.memorySettings?.enabled == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "LEARNING")
            Text("Every workspace has its own memory, beside Board and Plan.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Toggle("Learn from your words", isOn: Binding(get: { enabled }, set: { value in
                model.perform {
                    let settings = try model.store.memorySettings()
                    try model.store.saveMemorySettings(enabled: value, workerModel: settings.workerModel, workerReasoningEffort: settings.workerReasoningEffort)
                    model.refresh()
                }
                Task { await model.syncMemory() }
            }))
            Toggle("Use the AI worker to curate memory", isOn: Binding(get: { model.memorySettings?.useAIWorker == true }, set: { value in
                model.perform { try model.store.setMemoryAIWorker(value); model.refresh() }
            })).disabled(!enabled)
            Text("Only your own words are learned. Suggestions from agents wait in Proposals.").font(.caption).foregroundStyle(Palette.muted)
            Text("Memory is stored in your library and searched on this Mac. The AI worker chosen in Settings processes text after secrets are removed.").font(.caption).foregroundStyle(Palette.muted)
            Button("Learn now") { Task { await model.syncMemory() } }.disabled(model.memorySyncing || !enabled).buttonStyle(.borderless)
            if model.memorySyncing { ProgressView().controlSize(.small) }
            if let error = model.memoryError { Text(error).font(.caption).foregroundStyle(Palette.accent).textSelection(.enabled) }
        }
    }
}
