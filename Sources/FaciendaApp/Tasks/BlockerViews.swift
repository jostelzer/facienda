import SwiftUI
import FaciendaCore

struct BlockerChecklist: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    @State private var adding = false
    @State private var editing: TaskBlocker?
    private var blockers: [TaskBlocker] { model.blockers.filter { $0.taskId == task.id } }
    private var dependents: [FaciendaTask] {
        let ids = Set(model.blockers.filter { $0.prerequisiteId == task.id }.map(\.taskId))
        return model.tasks.filter { ids.contains($0.id) && $0.state.isOpen }
    }
    private var armed: Bool { model.readinessPlans.first { $0.taskId == task.id }?.armed == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !blockers.isEmpty {
                HStack {
                    Text("\(blockers.filter { $0.isMet(tasks: model.libraryTasks) }.count) of \(blockers.count) ready").fontWeight(.medium)
                    Spacer()
                    if task.state.isOpen { Button { adding = true } label: { Image(systemName: "plus") }.help("Add prerequisite") }
                }
                if task.state == .running && model.pendingDispatch(for: task.id) == nil && blockers.contains(where: { !$0.isMet(tasks: model.libraryTasks) }) {
                    Label("A prerequisite changed during work. Review the chat.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                ForEach(blockers) { blocker in row(blocker) }
                if let date = model.readinessPlans.first(where: { $0.taskId == task.id })?.notBefore, date > Date() {
                    Label("Not before " + date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").foregroundStyle(Palette.muted)
                }
                if task.state.isOpen && task.state != .running {
                    Button(armed ? "Pause automatic start" : "Start when ready", systemImage: armed ? "pause" : "play") { model.setReady(task, armed: !armed) }
                        .buttonStyle(QuietButton(prominent: !armed)).disabled(model.demo || (model.pendingDispatch(for: task.id) != nil && !armed))
                }
            }
            if !dependents.isEmpty {
                DisclosureGroup("Unblocks \(dependents.count)") {
                    ForEach(dependents) { dependent in
                        Button(dependent.displayName) { model.showTask(dependent) }.padding(.vertical, 3)
                    }
                }.foregroundStyle(Palette.muted)
            }
        }.font(.system(size: 12)).buttonStyle(.borderless)
            .sheet(isPresented: $adding) { BlockerEditor(model: model, task: task) }
            .sheet(item: $editing) { BlockerEditor(model: model, task: task, original: $0) }
    }

    private func row(_ blocker: TaskBlocker) -> some View {
        let met = blocker.isMet(tasks: model.libraryTasks)
        let prerequisite = model.libraryTasks.first { $0.id == blocker.prerequisiteId }
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: met ? "checkmark.circle.fill" : (blocker.kind == "person" ? "person.crop.circle" : "circle"))
                .foregroundStyle(met ? Palette.green : Palette.muted).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if let prerequisite {
                    Button(prerequisite.displayName) { model.showTask(prerequisite) }.multilineTextAlignment(.leading)
                    if prerequisite.state == .dropped { Text("Archived · unresolved").foregroundStyle(Palette.muted) }
                } else {
                    Button(blocker.title) { editing = blocker }.multilineTextAlignment(.leading)
                    Text(blocker.criterion).foregroundStyle(Palette.muted)
                    if !blocker.evidence.isEmpty {
                        Text(blocker.evidence).foregroundStyle(Palette.muted).textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        if let url = URL(string: blocker.sourceReference), ["https", "http", "message"].contains(url.scheme ?? "") {
                            // The agent wrote this address, so it is shown, not hidden behind a word.
                            Link(destination: url) { Text(CodexApproval.visible(url.absoluteString)).lineLimit(1).truncationMode(.middle) }
                                .help(CodexApproval.visible(url.absoluteString))
                        } else { Text(CodexApproval.visible(blocker.sourceReference)).lineLimit(2) }
                        if let date = blocker.observedAt {
                            Text(blocker.status == "met" ? "Met" : (blocker.status == "notMet" ? "Not yet" : "Unknown"))
                            Text(date, style: .relative)
                        }
                        if blocker.status == "met" && !met { Text("Recheck needed") }
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            if task.state.isOpen {
                Menu {
                    if blocker.kind != "task" { Button("Edit…") { editing = blocker } }
                    Button("Remove prerequisite") { model.perform(undo: "Remove Prerequisite") { try model.store.removeBlocker(blocker.id, expectedRevision: blocker.revision); model.refresh() } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(.vertical, 3)
    }
}

struct BlockerEditor: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    var original: TaskBlocker? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "task"
    @State private var query = ""
    @State private var chosen: Set<String> = []
    @State private var title = ""
    @State private var source = ""
    @State private var criterion = ""
    @State private var freshness: Double = 0
    @State private var error: String?
    private var candidates: [FaciendaTask] {
        let existing = Set(model.blockers.filter { $0.taskId == task.id }.compactMap(\.prerequisiteId))
        return model.tasks.filter { $0.id != task.id && !existing.contains($0.id) && $0.state != .dropped && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)) }
    }
    private var valid: Bool { kind == "task" ? !chosen.isEmpty : [title, source, criterion].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? "Wait for…" : "Edit condition").font(.title3.weight(.semibold))
            Picker("Kind", selection: $kind) {
                if original == nil { Text("Task").tag("task") }
                Text("Person").tag("person")
                Text("Condition").tag("condition")
            }.pickerStyle(.segmented).labelsHidden()
            if kind == "task" {
                TextField("Find a task", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(candidates) { candidate in
                            Toggle(candidate.displayName, isOn: Binding(get: { chosen.contains(candidate.id) }, set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } }))
                        }
                        if candidates.isEmpty { Text("No matching tasks").foregroundStyle(Palette.muted) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }.frame(height: 210)
            } else {
                TextField(kind == "person" ? "Who are you waiting for?" : "Condition", text: $title)
                TextField("Where to check · conversation, URL…", text: $source)
                TextField("Ready when…", text: $criterion, axis: .vertical).lineLimit(2...4)
                Picker("Evidence stays valid", selection: $freshness) {
                    Text("Once met, stays met").tag(0.0)
                    Text("15 minutes").tag(900.0)
                    Text("1 hour").tag(3600.0)
                    Text("1 day").tag(86400.0)
                }
                Text("Codex checks the source and records evidence. Missing access stays unresolved.").font(.caption).foregroundStyle(Palette.muted)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(original == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid || model.demo)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 470)
            .onAppear { if let original { kind = original.kind; title = original.title; source = original.sourceReference; criterion = original.criterion; freshness = original.freshnessSeconds ?? 0 } }
    }
    private func save() {
        do {
            if kind == "task" { try model.store.addTaskDependencies(taskId: task.id, prerequisiteIDs: Array(chosen)) }
            else { _ = try model.store.setExternalBlocker(taskId: task.id, id: original?.id, expectedRevision: original?.revision ?? 0, kind: kind, title: title, sourceReference: source, criterion: criterion, freshnessSeconds: freshness == 0 ? nil : freshness) }
            model.refresh(); model.showTask(try model.store.task(task.id)); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
