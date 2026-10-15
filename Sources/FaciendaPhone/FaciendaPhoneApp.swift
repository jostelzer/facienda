import SwiftUI
import SwiftData
import FaciendaCompanion

@main struct FaciendaPhoneApp: App {
    private let container: ModelContainer?
    private let startupError: String?
    private let cloudEnabled: Bool
    private let demo: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        demo = arguments.contains("--demo")
        VoiceCapture.removeLeftovers()
        if arguments.contains("--ui-testing") {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key == "captureDraft" || key.hasPrefix("captureDraft:") || key == "selectedWorkspaceID" {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #if targetEnvironment(simulator)
        cloudEnabled = false
        #else
        cloudEnabled = !demo && !arguments.contains("--ui-testing")
        #endif
        do {
            let testing = arguments.contains("--ui-testing")
            container = try CompanionStorage.makeContainer(cloudEnabled: cloudEnabled, inMemory: demo || testing)
            startupError = nil
            if demo, let container { Self.seed(container.mainContext) }
        } catch { container = nil; startupError = error.localizedDescription }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                PhoneRootView(cloudEnabled: cloudEnabled, demo: demo)
                    .modelContainer(container)
                    .task {
                        if cloudEnabled { UIApplication.shared.registerForRemoteNotifications() }
                    }
            } else {
                ContentUnavailableView("Couldn’t open Facienda", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(startupError ?? "Please try opening the app again."))
            }
        }
    }

    private static func seed(_ context: ModelContext) {
        let personal = CompanionWorkspace(id: "demo-personal", name: "Personal")
        personal.isDefault = true; personal.ready = true; personal.syncedAt = Date()
        let work = CompanionWorkspace(id: "demo-work", name: "Work")
        work.ready = true; work.syncedAt = Date()
        context.insert(personal); context.insert(work)
        UserDefaults.standard.set(personal.workspaceID, forKey: "previewSelectedWorkspaceID")
        context.insert(CompanionTask(id: "demo-research", title: "Find a quieter kitchen extractor", detail: "Comparing noise levels, dimensions, and prices.", section: "processing", status: "Working"))
        context.insert(CompanionTask(id: "demo-notes", title: "Organize the workshop notes", detail: "Turning your notes into a useful plan.", section: "processing", status: "Queued", updatedAt: Date().addingTimeInterval(-300), workspaceID: work.workspaceID))
        context.insert(CompanionTask(id: "demo-waiting", title: "Follow up on the camera repair", detail: "Waiting for the repair shop’s estimate.", section: "waiting", status: "Waiting for repair shop"))
        context.insert(CompanionTask(id: "demo-review", title: "Choose a weekend walking route", detail: "Three options are ready to review on your Mac.", section: "review", status: "For review", updatedAt: Date().addingTimeInterval(-600)))
        context.insert(CompanionTask(id: "demo-scheduled", title: "Check next week’s weather", detail: "Scheduled for Monday morning.", section: "scheduled", status: "Monday at 9:00", updatedAt: Date().addingTimeInterval(-900)))
        context.insert(CompanionTask(id: "demo-done", title: "Prepare the workshop checklist", detail: "The checklist is ready on your Mac.", section: "done", status: "Done", updatedAt: Date().addingTimeInterval(-1200)))
        try? context.save()
    }
}
