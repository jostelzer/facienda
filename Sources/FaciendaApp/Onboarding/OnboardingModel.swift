import SwiftUI
import Observation
import FaciendaCore

/// First-run setup: the data folder, then Codex, then Claude. The database itself always lives in Facienda's own folder.
@MainActor @Observable final class OnboardingModel {
    let libraryURL: URL
    /// The connection the finished workspace keeps, shared with every later workspace.
    let codex: CodexConnection?
    /// Facienda's one folder: every task's own folder, and the library in its hidden `.facienda` folder.
    var dataFolder: URL
    /// The first workspace. It is named, not asked for: the user can rename it any time.
    var name = "Base Camp"
    var step = 0
    var model: AppModel?
    var busy = false
    var error: String?
    var accountReady: Bool { model?.connected == true && model?.accountReady == true }

    init(libraryURL: URL = LibraryHome.databaseURL, codex: CodexConnection? = nil) {
        self.libraryURL = libraryURL
        self.codex = codex
        dataFolder = LibraryHome.savedDataFolder ?? LibraryHome.defaultDataFolder
        if FileManager.default.fileExists(atPath: libraryURL.path), let store = try? LibraryHome.open(at: libraryURL) {
            dataFolder = store.workFolder
            if let workspace = try? store.defaultWorkspace() { name = workspace.name }
        }
    }
    var existingLibrary: Bool { FileManager.default.fileExists(atPath: libraryURL.path) }
    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Facienda’s data folder"
        panel.prompt = "Choose folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: dataFolder.path) ? dataFolder : dataFolder.deletingLastPathComponent()
        if await panel.begin() == .OK, let selected = panel.url { dataFolder = selected; error = nil }
    }
    func useFolder() {
        do {
            let store = try LibraryHome.setUp(workspaceName: name, dataFolder: dataFolder)
            model = try AppModel(store: store, codex: codex)
            dataFolder = store.workFolder
            error = nil; step = 1
        } catch { self.error = error.localizedDescription }
    }
    func checkCodex() async {
        guard let model, !busy else { return }
        busy = true; error = nil; model.error = nil
        defer { busy = false }
        await model.connect()
        if !model.connected { error = model.connection }
    }

}
