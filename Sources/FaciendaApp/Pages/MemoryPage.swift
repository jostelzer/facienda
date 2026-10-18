import SwiftUI
import FaciendaCore

/// The workspace's current knowledge and proposals, with moves first. Every user change uses the shared undo stack.
struct MemoryPage: View {
    @Bindable var model: AppModel
    @State private var entries: [MemoryEntry] = []
    @State private var moves: [MemoryMove] = []
    @State private var sharedMoves: [MemoryMove] = []
    @State private var sections: [MemorySection] = []
    @State private var routines: [MemoryRoutine] = []
    @State private var deliveries: [MemoryDelivery] = []
    @State private var query = ""
    @State private var editing: String?
    @State private var draft = ""
    @State private var subject = ""
    @State private var fields = ""
    @State private var newShelf: MemoryShelf = .choices
    @State private var history: [MemoryEntryVersion] = []
    @State private var historyID: String?
    @State private var migrationRunning = false
    @State private var migrated = false
    @State private var proposalLimit = 12
    private var space: String? { model.memorySpace?.id }
    init(model: AppModel) {
        self.model = model
        if model.demo, let space = model.memorySpace?.id {
            _entries = State(initialValue: (try? model.store.memoryEntries(spaceID: space)) ?? [])
            _moves = State(initialValue: (try? model.store.memoryMoves(spaceID: space)) ?? [])
            _sections = State(initialValue: (try? model.store.memorySections(spaceID: space)) ?? [])
            _routines = State(initialValue: (try? model.store.memoryRoutines(spaceID: space)) ?? [])
            _deliveries = State(initialValue: (try? model.store.memoryDeliveries(spaceID: space)) ?? [])
        }
    }
    private var proposals: [MemoryEntry] { entries.filter { $0.state == .proposed } }
    private var live: [MemoryEntry] {
        entries.filter { $0.state == .live && (query.isEmpty || ($0.subject + " " + $0.text).localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                MemoryUnderstandingView(model: model)
                movesShelf
                proposalsShelf
                if !model.demo && !migrated && !model.memories.isEmpty { oldMemory }
                HStack {
                    TextField("Find a memory", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Spacer()
                    Menu {
                        ForEach(MemoryShelf.allCases, id: \.self) { shelf in Button(shelf.title) { newShelf = shelf; editing = "new"; draft = ""; subject = ""; fields = "" } }
                    } label: { Label("Write a memory", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                }
                if editing == "new" { editor(nil) }
                MemoryShelfLayout { shelfCards([.rules, .places, .people, .choices, .howtos]) }
                ForEach(sections.filter { $0.state == .live }) { section in sectionCard(section) }
                card("About you", hint: "Only what you explicitly share here reaches every workspace.") {
                    ForEach(live.filter { $0.spaceId == nil }) { entry in entryRow(entry) }
                    if !live.contains(where: { $0.spaceId == nil }) { empty("Share an accepted entry using its menu.") }
                }
                card("Routines", hint: "A sequence of your moves. Each step waits for you; only local reminders may run automatically.") {
                    ForEach(routines.filter { $0.state == .live }) { routine in routineRow(routine) }
                    if editing == "newroutine" {
                        MemoryRoutineEditor(routine: nil, moves: moves.filter { $0.stage == .accepted }, save: { name, steps in
                            change("Add Routine") { try model.store.saveMemoryRoutine(UUID().uuidString, spaceID: space!, name: name, steps: steps) }; editing = nil
                        }, cancel: { editing = nil })
                    } else {
                        Button("Add a routine…") { editing = "newroutine" }.buttonStyle(QuietButton())
                    }
                }
                card("What agents were told", hint: "The actual memory context supplied at the start of a task and when a tool matched an entry.") {
                    if deliveries.isEmpty { empty("Context will appear here after a task starts.") }
                    ForEach(deliveries.prefix(12)) { delivery in
                        DisclosureGroup("\(delivery.kind) · \(delivery.at.formatted(.dateTime.day().month().hour().minute()))") {
                            Text(delivery.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }.font(.system(size: 12))
                    }
                }
                if migrated {
                    Button("Restore the earlier memory") { change("Restore Earlier Memory") { try model.store.undoMemoryMigration(spaceID: space!) } }.buttonStyle(QuietButton())
                        .help("Restores archived notes and learned items. Entries you accepted or edited stay; secret redaction stays too.")
                }
            }.frame(maxWidth: 1240).padding(.horizontal, IslandFrame.inset).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.workspaceID) { load() }
        .onChange(of: model.memorySyncing) { _, busy in if !busy { load() } }
        .onChange(of: model.memories) { _, _ in load() }
        .onExitCommand { editing = nil }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "Memory of this workspace")
                Text("What \(model.workspace?.name ?? "this workspace") remembers").font(.system(size: 26, design: .serif))
                Text("\(live.count) current entries · \(proposals.count) \(proposals.count == 1 ? "proposal" : "proposals") · learning \(model.memorySettings?.enabled == true ? "on" : "off")").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button("Memory settings…") { model.openSettings(.memory) }.buttonStyle(QuietButton())
        }
    }

    private var movesShelf: some View {
        card("Your next moves", hint: "When a familiar situation returns, these are your own words to use again. Keeping one never sends it.") {
            if editing == "newmove" {
                MemoryMoveEditor(situations: (try? model.store.moveSituations(spaceID: space!)) ?? [], save: { situation, text, own in
                    change("Add Move") { try model.store.writeMemoryMove(spaceID: space!, situationID: situation, text: text, isYourStep: own) }; editing = nil
                }, cancel: { editing = nil })
            } else { Button("Write a move…") { editing = "newmove" }.buttonStyle(QuietButton()) }
            if moves.isEmpty { empty("After you repeat a response three times, it appears here for you to keep.") }
            ForEach(moves.filter { $0.stage != .noticed }) { move in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text((try? model.store.situationName(move.situationId)) ?? "After a similar result").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text(move.text).font(.system(size: 16, design: .serif))
                            Text("\(move.seen) times · offered \(move.offered) · used \(move.used)" + (move.isYourStep ? " · your part" : "")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if move.stage == .offered {
                            Button("Keep as a move") { change("Keep Move") { try model.store.acceptMove(move.id, spaceID: space!) } }.buttonStyle(QuietButton())
                        }
                        Menu {
                            Button("Edit…") { editing = move.id; draft = move.text }
                            Button("Make a rule…") {
                                newShelf = .rules; editing = "new"; subject = "After " + ((try? model.store.situationName(move.situationId)) ?? "this situation")
                                draft = "\(subject): \(move.text)"; fields = "mode = Always"
                            }
                            Button(move.isYourStep ? "Make it a message" : "This is my own step") { change("Change Move") { try model.store.acceptMove(move.id, spaceID: space!, isYourStep: !move.isYourStep) } }
                            Button("Forget") { change("Forget Move") { try model.store.setMoveArchived(move.id, spaceID: space!, archived: true) } }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if editing == move.id { TextField("Your words", text: $draft, axis: .vertical).onSubmit { change("Edit Move") { try model.store.editMove(move.id, spaceID: space!, text: draft) }; editing = nil } }
                }.padding(.vertical, 7)
            }
            if moves.contains(where: { $0.stage == .noticed }) { empty("\(moves.filter { $0.stage == .noticed }.count) patterns noticed; waiting to see them again.") }
            ForEach(live.filter { $0.shelf == .moves && $0.spaceId != nil }) { entry in entryRow(entry) }
        }
    }

    private var proposalsShelf: some View {
        card("Proposals", hint: "Nothing here applies until you accept it. Edit the words first if you like.") {
            if proposals.isEmpty && sharedMoves.isEmpty && sections.allSatisfy({ $0.state != .proposed }) && routines.allSatisfy({ $0.state != .proposed }) && model.workspaceSources.allSatisfy({ $0.state != .proposed }) { empty("All caught up.") }
            ForEach(proposals.prefix(proposalLimit)) { entry in entryRow(entry) }
            if proposals.count > proposalLimit { Button("Show \(min(12, proposals.count - proposalLimit)) more") { proposalLimit += 12 }.buttonStyle(QuietButton()) }
            ForEach(sharedMoves) { move in
                HStack {
                    VStack(alignment: .leading) { Text(move.text); Text("A pattern across workspaces. Share in About you?").font(.caption).foregroundStyle(Palette.muted) }
                    Spacer()
                    Button("Share move") { change("Share Move") { try model.store.acceptMove(move.id, spaceID: space!) } }
                    Button("Dismiss") { change("Dismiss Move") { try model.store.setMoveArchived(move.id, spaceID: space!, archived: true) } }
                }.buttonStyle(QuietButton())
            }
            ForEach(sections.filter { $0.state == .proposed }) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text("A section for \(section.entryIds.count) entries").font(.system(size: 14, weight: .medium))
                    Text("Shared fields: \(section.fields.joined(separator: ", "))").font(.caption).foregroundStyle(Palette.muted)
                    if editing == section.id {
                        TextField("Name this section", text: $draft).onSubmit { change("Keep Section") { try model.store.acceptMemorySection(section.id, spaceID: space!, name: draft) }; editing = nil }
                    } else {
                        HStack { Button("Name and keep…") { editing = section.id; draft = section.name }; Button("Dismiss") { change("Dismiss Section") { try model.store.foldMemorySection(section.id, spaceID: space!) } } }.buttonStyle(QuietButton())
                    }
                }.padding(.vertical, 6)
            }
            ForEach(routines.filter { $0.state == .proposed }) { routine in routineRow(routine) }
            ForEach(model.workspaceSources.filter { $0.state == .proposed }) { source in
                HStack { Text(source.title); Spacer(); Button("Link") { model.acceptSource(source) }; Button("Dismiss") { model.dismissSource(source) } }.buttonStyle(QuietButton())
            }
        }
    }

    @ViewBuilder private func entryRow(_ entry: MemoryEntry) -> some View {
        if editing == entry.id { editor(entry) }
        else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.subject).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                        Text(entry.text).font(.system(size: 15, design: .serif)).textSelection(.enabled).onTapGesture { begin(entry) }
                        if entry.state == .proposed, let old = entries.first(where: { $0.id == entry.replacesId }) {
                            Text("Current: \(old.text)").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                        if !entry.fields.isEmpty { Text(entry.fields.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted) }
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("Edit…") { begin(entry) }
                        Button("Earlier wording") { historyID = historyID == entry.id ? nil : entry.id; history = (try? model.store.memoryEntryHistory(entry.id, spaceID: space!)) ?? [] }
                        if entry.state == .live && entry.spaceId != nil { Button("Share in About you") { change("Share Memory") { try model.store.shareMemoryEntry(entry.id, spaceID: space!) } } }
                        Button(entry.state == .proposed ? "Dismiss" : "Forget") { change("Forget Memory") { try model.store.forgetMemoryEntry(entry.id, spaceID: space!) } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                DisclosureGroup(entry.origin == .you ? "From you · sources" : "Proposed · sources") {
                    Text(entry.reason).font(.caption).foregroundStyle(Palette.muted)
                    ForEach(entry.sources, id: \.self) { source in
                        Text(source).font(.caption).textSelection(.enabled)
                        if source.hasPrefix("archive:"), let archived = try? model.store.archivedMemorySource(source, spaceID: space!), let text = archived["text"].string { Text(text).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    }
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                if historyID == entry.id {
                    ForEach(history) { version in Text(version.snapshot.text).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    if history.isEmpty { empty("This is the first wording.") }
                }
                if entry.state == .proposed {
                    HStack { Button("Accept") { change("Accept Memory") { try model.store.acceptMemoryEntry(entry.id, spaceID: space!) } }; Button("Edit…") { begin(entry) } }.buttonStyle(QuietButton())
                }
            }.padding(.vertical, 8)
        }
    }

    private func editor(_ entry: MemoryEntry?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
            TextField("What to remember", text: $draft, axis: .vertical).lineLimit(2...12).textFieldStyle(.roundedBorder)
            TextField("Optional fields, one per line: name = value", text: $fields, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder).font(.caption)
            HStack {
                Button("Save") {
                    change("Edit Memory") {
                        let values = fields.split(separator: "\n").compactMap { line -> (String, String)? in
                            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            return parts.count == 2 && !parts[0].isEmpty ? (parts[0], parts[1]) : nil
                        }
                        let parsed = Dictionary(values, uniquingKeysWith: { _, last in last })
                        if let entry { try model.store.editMemoryEntry(entry.id, spaceID: space!, text: draft, subject: subject, fields: parsed) }
                        else { _ = try model.store.writeMemoryEntry(.init(spaceID: space!, shelf: newShelf, subject: subject, text: draft, origin: .you, sources: ["Written by you"], fields: parsed)) }
                    }
                    editing = nil
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subject.isEmpty)
                Button("Cancel") { editing = nil }
            }.buttonStyle(QuietButton())
        }.padding(10).background(Palette.selected.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionCard(_ section: MemorySection) -> some View {
        card(section.name, hint: section.fields.joined(separator: " · ")) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Subject"); ForEach(section.fields.prefix(5), id: \.self) { Text($0.capitalized) } }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                ForEach(live.filter { $0.sectionId == section.id }) { entry in
                    GridRow {
                        Button(entry.subject) { begin(entry) }.buttonStyle(.plain).foregroundStyle(Palette.blue)
                        ForEach(section.fields.prefix(5), id: \.self) { Text(entry.fields[$0] ?? "—") }
                    }.font(.system(size: 12))
                }
            }.padding(.vertical, 5)
            ForEach(live.filter { $0.sectionId == section.id }) { entry in entryRow(entry) }
            Menu {
                Button("Rename…") { editing = section.id; draft = section.name }
                ForEach(section.fields, id: \.self) { field in Button("Rename ‘\(field)’…") { editing = "field:" + section.id + ":" + field; draft = field } }
                Button("Fold back into shelves") { change("Fold Section") { try model.store.foldMemorySection(section.id, spaceID: space!) } }
                ForEach(sections.filter { $0.state == .live && $0.id != section.id }) { target in
                    Button("Merge into \(target.name)") { change("Merge Sections") { try model.store.foldMemorySection(section.id, spaceID: space!, into: target.id) } }
                }
                ForEach(model.store.libraryWorkspacesForMemory(excluding: model.workspaceID), id: \.id) { workspace in
                    Button("Share with \(workspace.name)") { change("Share Section") { try model.store.shareMemorySection(section.id, spaceID: space!, to: workspace.memorySpaceId) } }
                }
            } label: { Text("Section…") }.menuStyle(.borderlessButton).fixedSize()
            if editing == section.id { TextField("Section name", text: $draft).onSubmit { change("Rename Section") { try model.store.acceptMemorySection(section.id, spaceID: space!, name: draft) }; editing = nil } }
            ForEach(section.fields, id: \.self) { field in
                if editing == "field:" + section.id + ":" + field {
                    TextField("Field name", text: $draft).onSubmit { change("Rename Field") { try model.store.renameMemorySectionField(section.id, spaceID: space!, from: field, to: draft) }; editing = nil }
                }
            }
        }
    }

    private func routineRow(_ routine: MemoryRoutine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing == routine.id {
                MemoryRoutineEditor(routine: routine, moves: moves.filter { $0.stage == .accepted }, save: { name, steps in
                    change("Edit Routine") { try model.store.saveMemoryRoutine(routine.id, spaceID: space!, name: name, steps: steps, state: routine.state) }; editing = nil
                }, cancel: { editing = nil })
            } else {
            Text(routine.name).font(.system(size: 14, weight: .semibold))
            ForEach(Array(routine.steps.enumerated()), id: \.offset) { index, step in
                HStack {
                    Text("\(index + 1). \(step.text)").font(.system(size: 13))
                    Spacer()
                    Picker("Mode", selection: Binding(get: { step.mode }, set: { mode in
                        var steps = routine.steps; steps[index].mode = mode
                        change("Change Routine") { try model.store.saveMemoryRoutine(routine.id, spaceID: space!, name: routine.name, steps: steps, state: routine.state) }
                    })) {
                        Text("Ask").tag(MemoryRoutine.Step.Mode.ask)
                        Text("One click").tag(MemoryRoutine.Step.Mode.oneClick)
                        if step.canBeAutomatic { Text("Automatic").tag(MemoryRoutine.Step.Mode.automatic) }
                    }.labelsHidden().frame(width: 110)
                }
            }
            HStack {
                if routine.state == .proposed { Button("Keep routine") { change("Keep Routine") { try model.store.saveMemoryRoutine(routine.id, spaceID: space!, name: routine.name, steps: routine.steps) } } }
                Button("Edit…") { editing = routine.id }
                Button("Forget") { change("Forget Routine") { try model.store.saveMemoryRoutine(routine.id, spaceID: space!, name: routine.name, steps: routine.steps, state: .archived) } }
            }.buttonStyle(QuietButton())
            }
        }.padding(.vertical, 7)
    }

    private var linkedPlaces: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.workspaceSources.filter { $0.state == .linked }) { source in
                Button { model.openSource(source) } label: { Label(source.title, systemImage: "link") }.buttonStyle(.plain).foregroundStyle(Palette.blue)
                if let about = source.about { Text(about).font(.caption).foregroundStyle(Palette.muted) }
            }
            Button("Link a folder or document…") { model.linkPastedWorkspaceSource() }.buttonStyle(QuietButton())
        }
    }

    private var oldMemory: some View {
        card("Your earlier memory", hint: "Review a distilled version in Proposals. Originals are archived; backups and chat transcripts retain their earlier contents.") {
            Text("\(model.memories.count) notes are available to migrate.").font(.system(size: 12))
            Button(migrationRunning ? "Preparing proposals…" : "Migrate earlier memory") {
                guard let space else { return }
                migrationRunning = true
                Task {
                    defer { migrationRunning = false; model.refresh(); load() }
                    do { _ = try await MemoryMigration(store: model.store, inference: memoryLuna).run(spaceID: space) }
                    catch { model.error = error.localizedDescription }
                }
            }.buttonStyle(QuietButton()).disabled(migrationRunning)
        }
    }

    private func hint(_ shelf: MemoryShelf) -> String {
        switch shelf { case .rules: "Always, ask first, and never. Your standing instructions."; case .places: "Where to work, read, put results, or leave alone."; case .people: "Who people are, in the words you gave us."; case .choices: "Your current choices, with earlier wording kept."; case .howtos: "Useful steps you can repeat."; case .moves: "What you usually do next." }
    }
    private func shelfCards(_ shelves: [MemoryShelf]) -> some View {
            ForEach(shelves, id: \.self) { shelf in
                card(shelf.title, hint: hint(shelf)) {
                    ForEach(live.filter { $0.shelf == shelf && $0.spaceId != nil && $0.sectionId == nil }) { entry in entryRow(entry) }
                    if !live.contains(where: { $0.shelf == shelf && $0.spaceId != nil && $0.sectionId == nil }) { empty("Nothing here yet.") }
                    if shelf == .places { linkedPlaces }
                }
            }
    }
    private func begin(_ entry: MemoryEntry) { editing = entry.id; draft = entry.text; subject = entry.subject; fields = entry.fields.sorted(by: { $0.key < $1.key }).map { "\($0.key) = \($0.value)" }.joined(separator: "\n") }
    private func change(_ name: String, _ action: () throws -> Void) {
        guard space != nil else { return }
        model.perform(undo: name) { try action(); model.refresh(); load() }
    }
    private func load() {
        guard let space else { entries = []; moves = []; sections = []; routines = []; deliveries = []; return }
        model.perform {
            entries = try model.store.memoryEntries(spaceID: space); moves = try model.store.memoryMoves(spaceID: space)
            sharedMoves = try model.store.sharedMoveProposals()
            sections = try model.store.memorySections(spaceID: space); routines = try model.store.memoryRoutines(spaceID: space)
            deliveries = try model.store.memoryDeliveries(spaceID: space); migrated = try model.store.memoryWasMigrated(space)
        }
    }
    private func empty(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 3) }
    private func card<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 19, design: .serif))
            Text(hint).font(.system(size: 12)).foregroundStyle(Palette.muted)
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }
}

/// Each column flows independently, so a long Places shelf does not leave holes beside the shorter shelves.
private struct MemoryShelfLayout: Layout {
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = width >= 800 ? 2 : 1, gap: CGFloat = 20
        let columnWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        var heights = Array(repeating: CGFloat.zero, count: columns)
        return subviews.enumerated().map { index, view in
            let column = index % columns, size = view.sizeThatFits(.init(width: columnWidth, height: nil))
            let frame = CGRect(x: CGFloat(column) * (columnWidth + gap), y: heights[column], width: columnWidth, height: size.height)
            heights[column] += size.height + gap
            return frame
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        return .init(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }
}

private extension FaciendaStore {
    func libraryWorkspacesForMemory(excluding id: String?) -> [Workspace] { ((try? library.workspaces()) ?? []).filter { $0.id != id } }
}
