import SwiftUI
import FaciendaCore

/// Shows the interpretation, its limits and its evidence together. Nothing here executes the process it describes.
struct MemoryUnderstandingView: View {
    @Bindable var model: AppModel
    @State private var items: [MemoryUnderstanding] = []
    @State private var progress: MemoryLearningProgress?
    @State private var question = ""
    @State private var reflection: MemoryReflection?
    @State private var asking = false
    @State private var learning = false
    @State private var problem: String?
    @State private var expanded: String?
    @State private var editing: String?
    @State private var correction = ""
    @State private var selectedKind = "all"
    private var space: String? { model.memorySpace?.id }
    private var filtered: [MemoryUnderstanding] { items.filter { selectedKind == "all" || $0.kind.rawValue == selectedKind } }

    init(model: AppModel) {
        self.model = model
        if model.demo, let space = model.memorySpace?.id {
            let demoItems = (try? model.store.memoryUnderstanding(spaceID: space)) ?? []
            _items = State(initialValue: demoItems)
            _expanded = State(initialValue: demoItems.first(where: { $0.kind == .process })?.id)
            _progress = State(initialValue: try? model.store.memoryLearningProgress(spaceID: space))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Understanding").font(.system(size: 23, design: .serif))
                    Text("What things mean, how processes work, and what experience suggests.")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(learning ? "Learning…" : "Read new conversations") { learn() }
                    .buttonStyle(QuietButton()).disabled(learning || model.demo || model.memorySettings?.useAIWorker != true)
            }
            if let progress {
                HStack {
                    Text("\(progress.processed) of \(progress.sources) source passages read · \(items.count) subjects · \((try? model.store.serviceModel())?.name ?? ServiceModelChoice.current.name)")
                    if progress.pending > 0 { Text("\(progress.pending) waiting").foregroundStyle(Palette.accent) }
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let error = progress.error {
                    HStack {
                        Text(error).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Button("Retry") {
                            if let space { try? model.store.retryMemoryLearning(spaceID: space); learn() }
                        }.buttonStyle(QuietButton()).disabled(learning || model.demo)
                    }
                }
            }
            HStack(alignment: .top) {
                TextField("Ask about a subject, a process, or the next move", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).onSubmit { ask() }
                Button(asking ? "Reflecting…" : "Ask memory") { ask() }
                    .buttonStyle(QuietButton()).disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.demo)
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            if let reflection {
                VStack(alignment: .leading, spacing: 9) {
                    Text(reflection.answer).font(.system(size: 15, design: .serif)).textSelection(.enabled)
                    if !reflection.nextMove.isEmpty { Text("Possible next move: " + reflection.nextMove).font(.system(size: 13, weight: .medium)) }
                    ForEach(reflection.uncertainties, id: \.self) { Text("Open question: " + $0).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                    DisclosureGroup("Based on \(reflection.citations.count) passages · \(reflection.model)") {
                        ForEach(Array(reflection.citations.enumerated()), id: \.offset) { _, citation in
                            evidenceQuote(citation, evidence: reflection.evidence)
                        }
                    }.font(.system(size: 12))
                }.padding(16).background(Palette.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            Picker("Understanding", selection: $selectedKind) {
                Text("All").tag("all"); Text("Things").tag("thing"); Text("Processes").tag("process"); Text("Patterns").tag("pattern")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440)
            if filtered.isEmpty {
                Text(items.isEmpty ? "As conversations are read, Facienda builds explanations and reusable processes here. Each conclusion keeps its evidence and can change when new information arrives." : "No understanding in this category yet.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.vertical, 8)
            }
            ForEach(filtered) { item in understandingCard(item) }
        }
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
        .task(id: space) {
            items = []; progress = nil; reflection = nil; question = ""; problem = nil; expanded = nil; editing = nil; asking = false; learning = false
            load()
            if model.demo { expanded = items.first(where: { $0.subject == "Review from structure to detail" })?.id }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                load()
            }
        }
    }

    private func understandingCard(_ item: MemoryUnderstanding) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.subject).font(.system(size: 18, design: .serif))
                    Text("\(item.kind.rawValue.capitalized) · \(item.state == .reviewed ? "Reviewed by you" : "Inferred · " + item.confidence) · revision \(item.revision)")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Menu {
                    Button("Correct…") { editing = item.id; correction = item.summary }
                    if item.state != .reviewed { Button("Confirm understanding") { review(item) } }
                    Button("Forget") { review(item, dismiss: true) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            if editing == item.id {
                TextField("Your understanding", text: $correction, axis: .vertical).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save correction") { review(item, summary: correction); editing = nil }
                    Button("Cancel") { editing = nil }
                }.buttonStyle(QuietButton())
            } else { Text(item.summary).font(.system(size: 14)).textSelection(.enabled) }
            if !item.appliesWhen.isEmpty { Text("Applies when: " + item.appliesWhen).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            DisclosureGroup(isExpanded: Binding(get: { expanded == item.id }, set: { expanded = $0 ? item.id : nil })) {
                VStack(alignment: .leading, spacing: 10) {
                    if !item.explanation.isEmpty { Text(item.explanation).font(.system(size: 13)).textSelection(.enabled) }
                    ForEach(Array(item.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index + 1). " + step.action).font(.system(size: 13, weight: .medium))
                            Text(step.why).font(.system(size: 12))
                            if !step.check.isEmpty { Text("Check: " + step.check).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        }
                    }
                    ForEach(item.exceptions, id: \.self) { Text("Exception: " + $0).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                    ForEach(item.questions, id: \.self) { Text("Unresolved: " + $0).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                    ForEach(item.connections, id: \.targetId) { connection in
                        if let target = items.first(where: { $0.id == connection.targetId }) {
                            Button(connection.relation.replacingOccurrences(of: "_", with: " ").capitalized + ": " + target.subject) { expanded = target.id }.buttonStyle(QuietButton())
                        }
                    }
                    let sources = (try? model.store.memoryEvidence(item.citations.map(\.evidenceId), spaceID: item.spaceId, includeInactive: true)) ?? []
                    if sources.contains(where: { !$0.active }) {
                        Text("Some sources have changed. Treat this interpretation as needing review.").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    }
                    ForEach(Array(item.citations.enumerated()), id: \.offset) { _, citation in evidenceQuote(citation, evidence: sources) }
                    let versions = (try? model.store.memoryUnderstandingHistory(item.id, spaceID: item.spaceId)) ?? []
                    if !versions.isEmpty {
                        DisclosureGroup("How this understanding changed") {
                            ForEach(versions) { version in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Revision \(version.snapshot.revision) · \(version.at.formatted(.dateTime.day().month().hour().minute()))").font(.caption).foregroundStyle(Palette.muted)
                                    Text(version.snapshot.summary).font(.system(size: 12)).textSelection(.enabled)
                                }.padding(.vertical, 5)
                            }
                        }.font(.system(size: 12))
                    }
                }.padding(.top, 8)
            } label: { Text("Why · process · evidence (\(item.citations.count))").font(.system(size: 12)) }
        }.padding(16).background(Palette.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func evidenceQuote(_ citation: MemoryUnderstanding.Citation, evidence: [MemoryEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“" + citation.quote + "”").font(.system(size: 12)).textSelection(.enabled)
            if let source = evidence.first(where: { $0.id == citation.evidenceId }) {
                Text(source.source + " · " + source.at.formatted(.dateTime.day().month().year()) + (source.active ? "" : " · earlier source"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
        }.padding(.vertical, 4)
    }

    private func load() {
        guard let space else { return }
        items = (try? model.store.memoryUnderstanding(spaceID: space)) ?? []
        progress = try? model.store.memoryLearningProgress(spaceID: space)
    }
    private func review(_ item: MemoryUnderstanding, summary: String? = nil, dismiss: Bool = false) {
        model.perform(undo: dismiss ? "Forget Understanding" : "Correct Understanding") {
            try model.store.reviewMemoryUnderstanding(item.id, spaceID: item.spaceId, summary: summary, dismiss: dismiss)
        }
        load()
    }
    private func learn() {
        guard let space, !learning else { return }
        let store = model.store
        learning = true; problem = nil
        Task {
            defer { if self.space == space { learning = false; load() } }
            do { try await MemoryReasoner(store: store, inference: memoryLuna).learn(spaceID: space, batches: 10) }
            catch { if self.space == space { problem = error.localizedDescription } }
        }
    }
    private func ask() {
        guard let space, !asking, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let store = model.store, query = question
        asking = true; problem = nil
        Task {
            defer { if self.space == space { asking = false } }
            do {
                let result = try await MemoryReflector(store: store, inference: memoryLuna).reflect(query, spaceID: space)
                if self.space == space { reflection = result }
            } catch { if self.space == space { problem = error.localizedDescription } }
        }
    }
}
