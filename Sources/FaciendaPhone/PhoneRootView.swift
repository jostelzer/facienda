import SwiftUI
import SwiftData
import CloudKit
import CoreData
import FaciendaCompanion

private enum PhoneTab: Hashable { case capture, processing, tasks }

enum PhoneStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.60, green: 0.73, blue: 0.64, alpha: 1)
            : UIColor(red: 0.24, green: 0.39, blue: 0.32, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
}

struct PhoneRootView: View {
    let cloudEnabled: Bool
    let demo: Bool
    @Query private var requests: [CompanionRequest]
    @Query private var tasks: [CompanionTask]
    @Query private var workspaceRecords: [CompanionWorkspace]
    @AppStorage private var selectedWorkspaceID: String
    @State private var selected: PhoneTab = .capture
    @State private var showingConnection = false
    @State private var syncErrors: [NSPersistentCloudKitContainer.EventType: String] = [:]
    @State private var syncActivities: Set<NSPersistentCloudKitContainer.EventType> = []
    @State private var lastDownload: Date?
    @State private var lastUpload: Date?
    private var syncError: String? { syncErrors[.setup] ?? syncErrors[.import] ?? syncErrors[.export] }
    @State private var showingWorkspaces = false
    @State private var processingPath = NavigationPath()
    @State private var tasksPath = NavigationPath()

    init(cloudEnabled: Bool, demo: Bool) {
        self.cloudEnabled = cloudEnabled; self.demo = demo
        _selectedWorkspaceID = AppStorage(wrappedValue: "", demo ? "previewSelectedWorkspaceID" : "selectedWorkspaceID")
    }

    private var workspaces: [CompanionWorkspace] { CompanionWorkspace.unique(workspaceRecords) }
    private var workspace: CompanionWorkspace? {
        workspaces.first { $0.workspaceID == selectedWorkspaceID } ?? workspaces.first { $0.isDefault } ?? workspaces.first
    }
    private var items: [CompanionItem] {
        CompanionItem.merged(tasks: tasks, requests: requests, cloudEnabled: cloudEnabled,
                             workspaceID: workspace?.workspaceID, includeUnassigned: workspace?.isDefault == true)
    }

    var body: some View {
        TabView(selection: $selected) {
            Tab("New task", systemImage: "plus", value: .capture) {
                NavigationStack {
                    CaptureView(cloudEnabled: cloudEnabled, workspaceID: workspace?.workspaceID ?? "", workspaceName: workspace?.name ?? "", workspaceNeedsConnection: cloudEnabled && workspace?.ready == false) { selected = .processing }
                        .id(workspace?.workspaceID ?? "")
                        .toolbar { connectionButton }
                }
            }
            Tab("In progress", systemImage: "circle.dotted", value: .processing) {
                NavigationStack(path: $processingPath) {
                    TaskListView(title: "In progress", items: items.filter { $0.category == .processing }, allItems: items, emptyTitle: "A little less on your mind.", emptyDetail: "Add a task and your Mac will take it from here.", symbol: "circle.dotted")
                        .toolbar { connectionButton }
                }
            }
            Tab("Tasks", systemImage: "tray", value: .tasks) {
                NavigationStack(path: $tasksPath) {
                    TaskBrowserView(items: items)
                        .id(workspace?.workspaceID ?? "")
                        .toolbar { connectionButton }
                }
            }
        }
        .tint(PhoneStyle.accent)
        .onChange(of: workspaces.map(\.workspaceID), initial: true) { _, _ in
            if let workspace, !workspaces.contains(where: { $0.workspaceID == selectedWorkspaceID }) { selectedWorkspaceID = workspace.workspaceID }
        }
        .onChange(of: workspace?.workspaceID) { _, _ in
            processingPath = NavigationPath(); tasksPath = NavigationPath()
        }
        .task(id: workspace?.workspaceID) {
            // Keep the pre-workspace capture draft accessible after the first catalog sync.
            if !demo, let workspace, workspace.isDefault,
               let legacy = UserDefaults.standard.string(forKey: "captureDraft"), !legacy.isEmpty {
                let key = "captureDraft:" + workspace.workspaceID
                let existing = UserDefaults.standard.string(forKey: key) ?? ""
                UserDefaults.standard.set(existing.isEmpty ? legacy : existing + "\n" + legacy, forKey: key)
                UserDefaults.standard.removeObject(forKey: "captureDraft")
            }
        }
        .sheet(isPresented: $showingConnection) {
            ConnectionView(cloudEnabled: cloudEnabled, demo: demo, syncError: syncError, downloading: syncActivities.contains(.import), uploading: syncActivities.contains(.export), lastDownload: lastDownload, lastUpload: lastUpload)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingWorkspaces) {
            PhoneWorkspacesView(selectedID: $selectedWorkspaceID, cloudEnabled: cloudEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            guard let completedAt = event.endDate else {
                syncActivities.insert(event.type)
                return
            }
            syncActivities.remove(event.type)
            if let error = event.error { syncErrors[event.type] = error.localizedDescription }
            else {
                syncErrors.removeValue(forKey: event.type)
                if event.type == .import { lastDownload = completedAt }
                if event.type == .export { lastUpload = completedAt }
            }
        }
    }

    @ToolbarContentBuilder private var connectionButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(workspaces, id: \.workspaceID) { entry in
                    Button { selectedWorkspaceID = entry.workspaceID } label: {
                        if entry.workspaceID == workspace?.workspaceID { Label(entry.name, systemImage: "checkmark") }
                        else { Text(entry.name) }
                    }
                }
                if !workspaces.isEmpty { Divider() }
                Button("Manage workspaces…", systemImage: "square.stack.3d.up") { showingWorkspaces = true }
            } label: {
                HStack(spacing: 5) {
                    Text(workspace?.name ?? "Workspaces").lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(maxWidth: 180)
            }.accessibilityLabel("Switch workspace").accessibilityIdentifier("workspaceSwitcher")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingConnection = true } label: {
                Image(systemName: syncError == nil ? "icloud" : "icloud.slash")
            }.accessibilityLabel("iCloud connection")
        }
    }
}

private struct ConnectionView: View {
    let cloudEnabled: Bool
    let demo: Bool
    let syncError: String?
    let downloading: Bool
    let uploading: Bool
    let lastDownload: Date?
    let lastUpload: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var accountMessage = "Checking iCloud…"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                Image(systemName: cloudEnabled ? "icloud" : "iphone").font(.largeTitle).foregroundStyle(PhoneStyle.accent)
                Text(demo ? "Preview" : cloudEnabled ? "Your Mac, in your pocket." : "Saved on this iPhone.")
                    .font(.title2.weight(.semibold))
                Text(demo ? "These are example tasks. Preview mode never sends work to your Mac." : cloudEnabled ? "Tasks sync through your private iCloud account. Enable iPhone companion in Facienda’s Mac settings, and use the same Apple account on both devices." : "This simulator uses local storage. iCloud syncing is enabled in a signed iPhone build.")
                    .foregroundStyle(.secondary)
                if cloudEnabled {
                    Label(accountMessage, systemImage: "person.crop.circle")
                    VStack(alignment: .leading, spacing: 12) {
                        if downloading { Label("Downloading tasks…", systemImage: "icloud.and.arrow.down") }
                        else if let lastDownload { Text("Last download: " + lastDownload.formatted(date: .abbreviated, time: .shortened)) }
                        else { Text("Waiting for the first iCloud download…") }
                        if uploading { Label("Uploading changes…", systemImage: "icloud.and.arrow.up") }
                        else if let lastUpload { Text("Last upload: " + lastUpload.formatted(date: .abbreviated, time: .shortened)) }
                        Text("A task is delivered when its status changes from Waiting for Mac. iCloud may take time to sync.").foregroundStyle(.secondary)
                    }.font(.callout)
                    Text("Run Codex setup once per workspace on your Mac. New tasks from this iPhone can then run automatically.").font(.callout).foregroundStyle(.secondary)
                    Text("Your Mac must be awake with Facienda and its Codex runner available. Requests stay saved while it’s away.").font(.callout).foregroundStyle(.secondary)
                }
                if let syncError { Text(syncError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
                .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task {
                    guard cloudEnabled else { return }
                    do {
                        let status = try await CKContainer(identifier: CompanionStorage.containerID).accountStatus()
                        accountMessage = status == .available ? "iCloud account connected" : "Sign in to iCloud in Settings to sync tasks."
                    } catch { accountMessage = error.localizedDescription }
                }
        }
    }
}
