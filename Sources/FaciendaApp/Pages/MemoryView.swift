import SwiftUI
import FaciendaCore

/// Memory in Settings: what Hindsight learned, and the notes kept in the memory shown.
struct MemoryView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var editing: MemoryFact?
    @State private var text = ""
    @State private var source = ""
    @State private var adding = false
    @State private var learned: [JSONValue] = []
    @State private var learnedSources: JSONValue = .null
    @State private var searching = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Picker("Memory", selection: Binding(get: { shownSpace ?? "" }, set: { id in model.viewedSpaceID = id == model.memorySpace?.id ? nil : id; learned = []; model.refresh() })) {
                    ForEach(model.memorySpaces) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
                Spacer(); Button("Remember something", systemImage: "plus") { text = ""; source = ""; adding = true }.buttonStyle(QuietButton())
            }
            Text(spaceDescription).font(.system(size: 12)).foregroundStyle(Palette.muted)
            HindsightSettings(model: model)
            HStack {
                TextField("Search workspace memory", text: $query).textFieldStyle(.roundedBorder)
                Button("Recall") {
                    searching = true
                    Task {
                        defer { searching = false }
                        do {
                            let context = try await WorkspaceMemoryService(store: model.store).context(query: query, spaceID: shownSpace)
                            learned = context["learned"]["results"].array ?? []
                            learnedSources = context["learned"]["source_facts"]
                            model.memoryError = context["error"].string
                        } catch { model.memoryError = error.localizedDescription }
                    }
                }.disabled(searching || (try? model.store.memorySettings().enabled) != true)
            }
            // Settings scrolls the whole pane, so the notes are a plain stack.
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(learned.enumerated()), id: \.offset) { _, fact in learnedCard(fact) }
                ForEach(model.viewedMemories.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { noteCard($0) }
                if model.viewedMemories.isEmpty { EmptyNote(symbol: "book.closed", title: "Start with what matters.", detail: "Save a preference, a useful fact, or a procedure. You can confirm or correct everything here.") }
            }
        }
            .sheet(isPresented: $adding) { memoryForm(isNew: true) }
            .sheet(item: $editing) { _ in memoryForm(isNew: false) }
    }

    /// Something Hindsight learned, with the sources it was drawn from.
    private func learnedCard(_ fact: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "LEARNED · " + (fact["type"].string ?? "memory"))
            Text(fact["text"].string ?? "").textSelection(.enabled)
            Text(sourceLabel(fact)).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
        }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    /// A note kept in this memory, to confirm, correct or move.
    private func noteCard(_ fact: MemoryFact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: fact.kind)
                Spacer()
                Text(fact.confirmedAt == nil ? "Unconfirmed" : "Confirmed by you").font(.system(size: 10)).foregroundStyle(fact.confirmedAt == nil ? Palette.accent : Palette.green)
            }
            Text(fact.text).font(.system(size: 16, design: .serif)).textSelection(.enabled)
            Text("Source: \(fact.source)").font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
            HStack {
                Button("Correct") { editing = fact; text = fact.text }
                if fact.confirmedAt == nil { Button("Confirm") { model.perform { try model.store.confirmMemory(fact.id); model.refresh() } } }
                if model.memorySpaces.count > 1 {
                    Menu("Move to") {
                        ForEach(model.memorySpaces.filter { $0.id != fact.spaceId }) { space in
                            Button(space.name) { model.perform { try model.store.moveMemory(fact.id, toSpace: space.id); model.refresh() } }
                        }
                    }.fixedSize()
                }
                Spacer()
                Text(fact.createdAt, format: .dateTime.day().month().year()).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.buttonStyle(.borderless)
        }.padding(22).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private var shownSpace: String? { model.viewedSpaceID ?? model.memorySpace?.id }
    private var spaceDescription: String {
        let name = model.memorySpaces.first { $0.id == shownSpace }?.name ?? "This"
        let users = ([model.workspace].compactMap { $0 } + model.otherWorkspaces).filter { $0.memorySpaceId == shownSpace }.map(\.name)
        return "The \(name) memory" + (users.isEmpty ? ", used by no workspace yet" : ", used by " + users.joined(separator: ", ")) + ". Hindsight learns from their task chats and consolidates related evidence. Your confirmed notes take precedence. Other memories stay completely separate."
    }
    private func sourceLabel(_ fact: JSONValue) -> String {
        let sources = (fact["source_fact_ids"].array ?? []).compactMap { id -> String? in
            guard let id = id.string else { return nil }
            let source = learnedSources[id]
            return source["context"].string ?? source["document_id"].string ?? id
        }
        if !sources.isEmpty { return "Sources: " + sources.joined(separator: "; ") }
        return "Source: " + (fact["context"].string ?? fact["document_id"].string ?? fact["id"].string ?? "not supplied")
    }
    private func memoryForm(isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isNew ? "Something worth remembering" : "Correct this memory").font(.system(size: 25, design: .serif))
            TextField("The fact or preference", text: $text, axis: .vertical).lineLimit(3...6)
            if isNew {
                TextField("Source, including date or context", text: $source)
            }
            HStack { Button("Cancel") { adding = false; editing = nil }; Spacer(); Button("Save") {
                model.perform {
                    if let editing { try model.store.correctMemory(editing.id, text: text) }
                    else { var fact = MemoryFact(text: text, source: source); fact.confirmedAt = Date(); fact.spaceId = shownSpace; try model.store.remember(fact, source: .user) }
                    model.refresh(); adding = false; editing = nil
                }
            }.buttonStyle(QuietButton(prominent: true)).disabled(text.isEmpty || (isNew && source.isEmpty)) }
        }.padding(28).frame(width: 520).background(Palette.paper)
    }
}

struct HindsightSettings: View {
    @Bindable var model: AppModel
    @State private var endpoint = "https://127.0.0.1:8888"
    @State private var workerModel = "gpt-6-luna"
    @State private var workerReasoningEffort = "high"
    private var enabled: Bool { model.memorySettings?.enabled == true }
    private var builtIn: Bool { model.memorySettings?.usesHindsight != true }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Learn from your tasks", isOn: Binding(get: { enabled }, set: { value in
                model.perform {
                    let current = try model.store.memorySettings()
                    try model.store.saveMemorySettings(endpoint: current.endpoint, enabled: value, workerModel: current.workerModel, workerReasoningEffort: current.workerReasoningEffort)
                    model.refresh()
                }
                Task { await model.syncMemory() }
            }))
            Picker("Memory engine", selection: Binding(get: { builtIn ? "native" : "hindsight" }, set: { engine in
                model.perform {
                    let current = try model.store.memorySettings()
                    try model.store.saveMemorySettings(endpoint: current.endpoint, enabled: current.enabled, workerModel: current.workerModel, workerReasoningEffort: current.workerReasoningEffort, engine: engine)
                    model.refresh()
                }
            })) {
                Text("Built into Facienda").tag("native")
                Text("Hindsight service (advanced)").tag("hindsight")
            }.pickerStyle(.segmented)
            Text(builtIn
                 ? "Facienda learns inside this app: facts and observations are stored in your library and searched on this Mac. Each memory learns separately."
                 : "These settings apply to every memory in your library; each memory keeps its own Hindsight bank. Changes to the switch save immediately.").font(.caption).foregroundStyle(Palette.muted)
            if !builtIn { TextField("Local Hindsight endpoint", text: $endpoint).textFieldStyle(.roundedBorder) }
            TextField("Fallback model for tasks launched without one (blank uses Codex default)", text: $workerModel).textFieldStyle(.roundedBorder)
            Picker("Reasoning for new task chats", selection: $workerReasoningEffort) {
                ForEach(["low", "medium", "high", "xhigh", "max", "ultra"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Text("Memory runs in hidden Codex threads using GPT-6 Luna with high reasoning. New tasks choose their own model, reasoning and Fast mode in the composer; the fields above are only the fallback. Existing task chats keep their model.").font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Button("Save settings") {
                    model.perform {
                        try model.store.saveMemorySettings(endpoint: builtIn ? (model.memorySettings?.endpoint ?? endpoint) : endpoint, enabled: enabled, workerModel: workerModel, workerReasoningEffort: workerReasoningEffort)
                        model.notice = "Memory settings saved."
                        model.refresh()
                    }
                    Task { await model.syncMemory() }
                }
                Button("Sync now") { Task { await model.syncMemory() } }.disabled(model.memorySyncing || !enabled)
                Button("Consolidate now") {
                    Task {
                        do {
                            guard try model.store.memorySettings().enabled else { return }
                            try await WorkspaceMemoryService(store: model.store, inference: memoryLuna).consolidate(spaceID: model.viewedSpaceID)
                            model.notice = builtIn ? "Consolidated waiting facts into observations." : "Hindsight accepted the consolidation request."
                            model.refresh()
                        } catch { model.memoryError = error.localizedDescription }
                    }
                }.disabled(!enabled)
                if model.memorySyncing { ProgressView().controlSize(.small) }
            }.buttonStyle(.borderless)
            if builtIn, let status = model.learnedStatus {
                Text("Sources: \(status.waiting) waiting · \(status.retained) learned · \(status.facts) facts · \(status.observations) observations\(status.unconsolidated > 0 ? " · \(status.unconsolidated) facts to consolidate" : "")").font(.caption).foregroundStyle(Palette.muted)
            } else if let status = model.memoryStatus {
                Text("Sources: \(status.pending) queued · \(status.processing) processing · \(status.completed) retained").font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = model.memoryError ?? (builtIn ? model.learnedStatus?.error : model.memoryStatus?.error) { Text(error).font(.caption).foregroundStyle(Palette.accent).textSelection(.enabled) }
            Text(builtIn
                 ? "Memory is stored in your library on this Mac and searched on-device. To learn, memory text is sent to OpenAI through Codex. Everything also syncs wherever your library folder syncs."
                 : "Memory is stored by a server on this Mac. Memory text is sent to OpenAI through Codex for processing. Source records also sync wherever your library folder syncs.").font(.caption).foregroundStyle(Palette.muted)
        }.task(id: model.store.url.path) {
            if let settings = try? model.store.memorySettings() {
                endpoint = settings.endpoint; workerModel = settings.workerModel ?? ""; workerReasoningEffort = settings.workerReasoningEffort
            }
        }
    }
}
