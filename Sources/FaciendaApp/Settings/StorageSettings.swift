import SwiftUI
import FaciendaCore

/// What Facienda keeps on this Mac and where, with a way to clear what tasks left behind.
/// Tasks, results and chats are never cleared here: only the files tasks made in their own folders.
struct StorageSettings: View {
    @Bindable var model: AppModel
    @State private var artifacts: [TaskArtifacts] = []
    @State private var others: [(name: String, detail: String, bytes: Int64)] = []
    @State private var free: Int64?
    @State private var measuring = false
    @State private var retention: Int?
    @State private var clearing: TaskArtifacts?
    @State private var clearingFinished = false
    @State private var removingSpeech = false
    @State private var error: String?

    private static let speechFolder = LibraryHome.supportDirectory.appending(path: "Speech", directoryHint: .isDirectory)
    private var finished: [TaskArtifacts] { artifacts.filter { $0.state.map { !$0.isOpen } ?? true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            workFolderSection.settingsCard()
            tasksSection.settingsCard()
            othersSection.settingsCard()
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true) }
        }
        .task { retention = try? model.store.artifactRetentionDays(); await measure() }
        .alert("Clear this task’s folder?", isPresented: Binding(presenting: $clearing), presenting: clearing) { item in
            Button("Move to Trash", role: .destructive) { clear([item]) }
        } message: { item in
            Text("The files in “\(item.title)”’s folder (\(Self.size(item.bytes))) go to the Trash. The task, its results and its chats stay.")
        }
        .alert("Clear finished tasks’ folders?", isPresented: $clearingFinished) {
            Button("Move to Trash", role: .destructive) { clear(finished) }
        } message: {
            Text("\(finished.count) \(finished.count == 1 ? "folder" : "folders") (\(Self.size(finished.reduce(0) { $0 + $1.bytes }))) go to the Trash. Open tasks keep theirs. Empty the Trash to free the space.")
        }
        .alert("Remove the dictation model?", isPresented: $removingSpeech) {
            Button("Move to Trash", role: .destructive) { removeSpeechModel() }
        } message: {
            Text("Dictation downloads it again the next time you use it.")
        }
    }

    private var workFolderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "DATA FOLDER")
            Text("Each task gets a folder here for what it makes; clearing one never loses the task or its chat. Facienda’s own data is in the hidden .facienda folder, with a daily copy kept in Application Support.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text(model.store.workFolder.path).font(.system(size: 12)).textSelection(.enabled)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.workFolder]) }.buttonStyle(QuietButton())
                Spacer()
                if let free {
                    Label("\(Self.size(free)) free on this disk", systemImage: free < DiskUsage.lowSpaceThreshold ? "exclamationmark.triangle" : "internaldrive")
                        .font(.system(size: 12)).foregroundStyle(free < DiskUsage.lowSpaceThreshold ? Palette.amber : Palette.muted)
                }
            }
            if let free, free < DiskUsage.lowSpaceThreshold {
                Text("Your disk is nearly full, so Facienda holds new task starts until there is at least \(Self.size(DiskUsage.lowSpaceThreshold)) free.")
                    .font(.system(size: 12)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "TASK FOLDERS")
                Spacer()
                if measuring { ProgressView().controlSize(.small) }
                else { Text(Self.size(artifacts.reduce(0) { $0 + $1.bytes })).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
            Picker("Clear finished tasks’ folders", selection: Binding(get: { retention }, set: { setRetention($0) })) {
                Text("When I choose").tag(Int?.none)
                Text("After a day").tag(Int?.some(1))
                Text("After a week").tag(Int?.some(7))
                Text("After a month").tag(Int?.some(30))
            }.frame(maxWidth: 380).disabled(model.demo)
            Text("Cleared folders go to the Trash. A task that starts again gets an empty folder.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            if artifacts.isEmpty, !measuring {
                Text("No task has left files behind.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            ForEach(artifacts.prefix(12)) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 13)).lineLimit(1)
                        Text(item.state.map { $0.isOpen ? "Open" : "Finished" } ?? "Task removed").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Text(Self.size(item.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.folder)]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                    Button { clearing = item } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Move this folder to the Trash").disabled(model.demo)
                }
            }
            if artifacts.count > 12 {
                Text("And \(artifacts.count - 12) smaller folders.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if !finished.isEmpty {
                Button("Clear finished tasks’ folders…") { clearingFinished = true }.buttonStyle(QuietButton()).disabled(model.demo)
            }
        }
    }

    private var othersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "FACIENDA’S OWN FILES")
            ForEach(others, id: \.name) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 13))
                        Text(item.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(Self.size(item.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    if item.name == "Dictation model", item.bytes > 0 {
                        Button { removingSpeech = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove the dictation model")
                    }
                }
            }
        }
    }

    private func measure() async {
        measuring = true
        let store = model.store
        let speech = Self.speechFolder
        let measured = await Task.detached(priority: .utility) { () -> ([TaskArtifacts], [(String, String, Int64)], Int64?) in
            let artifacts = (try? store.artifacts()) ?? []
            let others: [(String, String, Int64)] = [
                ("Library", "Tasks, decisions, memory and pictures, in the hidden .facienda folder.", DiskUsage.size(of: store.libraryDirectory)),
                ("Library copies", "The newest seven daily copies, outside the data folder.", DiskUsage.size(of: LibraryHome.backupDirectory)),
                ("Chat search index", "Rebuilt from your chats. Turning chat search off removes it.", DiskUsage.size(of: ChatIndex.defaultURL) + DiskUsage.size(of: URL(fileURLWithPath: ChatIndex.defaultURL.path + "-wal"))),
                ("Dictation model", "Downloaded for dictation on this Mac.", DiskUsage.size(of: speech)),
                ("Memory models", "Compiled for built-in memory. Older versions are removed automatically.", DiskUsage.size(of: MemoryModels.defaultCache)),
            ]
            return (artifacts, others, DiskUsage.available(at: store.workFolder))
        }.value
        artifacts = measured.0
        others = measured.1.map { (name: $0.0, detail: $0.1, bytes: $0.2) }
        free = measured.2
        measuring = false
    }

    private func clear(_ items: [TaskArtifacts]) {
        do { for item in items { try model.store.clearArtifacts(item) }; error = nil }
        catch { self.error = error.localizedDescription }
        Task { await measure() }
    }

    private func setRetention(_ days: Int?) {
        do { try model.store.setArtifactRetentionDays(days); retention = days; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func removeSpeechModel() {
        do { try FileManager.default.trashItem(at: Self.speechFolder, resultingItemURL: nil); error = nil }
        catch { self.error = error.localizedDescription }
        Task { await measure() }
    }

    static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}
