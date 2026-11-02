import SwiftUI
import FaciendaCore

/// On a group's card only when the group works somewhere other than its workspace's usual place: the folders it chose, or
/// "Own folders" where the workspace has one folder the group stays out of. A click opens the same choices as the card's menu.
struct WorkPlaceChip: View {
    @Bindable var model: AppModel
    let group: TaskGroup
    @State private var hover = false

    var body: some View {
        let folders = model.groupFolders[group.id] ?? []
        let label = folders.isEmpty ? "Own folders" : folders.map(LinkedFolder.name(of:)).joined(separator: " · ")
        Menu { WorkPlaceChoices(model: model, group: group) } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(hover ? Palette.ink : Palette.muted)
            .padding(.horizontal, 7).frame(height: 20)
            .background(hover ? Palette.line.opacity(0.6) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        // The words line up with the card's edge; only the hover wash reaches past it.
        .padding(.trailing, -7)
        .onHover { hover = $0 }
        .animation(Motion.fade, value: hover)
        .help(folders.isEmpty ? "Each task in this group works in its own folder." : "Tasks in this group work in " + folders.joined(separator: ", "))
    }
}

/// Where a group's tasks work, as menu items. With one workspace folder: in it, or each in its own folder. With several,
/// the group picks the ones it works in; none picked, each task has its own folder. Linking a new folder is at the end.
struct WorkPlaceChoices: View {
    @Bindable var model: AppModel
    let group: TaskGroup

    var body: some View {
        let folders = model.workspaceFolders
        let chosen = model.groupFolders[group.id] ?? []
        if folders.count == 1 {
            Toggle(LinkedFolder.name(of: folders[0]), isOn: Binding(get: { chosen == folders }, set: { if $0 { model.setWorkPlace(.workspace, for: group) } }))
            Toggle("Own folder for each task", isOn: Binding(get: { chosen.isEmpty }, set: { if $0 { model.setWorkPlace(.own, for: group) } }))
        } else {
            ForEach(folders, id: \.self) { path in
                Toggle(LinkedFolder.name(of: path), isOn: Binding(get: { chosen.contains(path) }, set: { _ in model.toggleWorkFolder(path, for: group) }))
            }
            Toggle("Own folder for each task", isOn: Binding(get: { chosen.isEmpty }, set: { if $0 { model.setWorkPlace(.workspace, for: group) } }))
        }
        Divider()
        Button("Link a folder…") { model.chooseFolder(for: group) }
    }
}

/// The workspace's places on its Memory page: the folders its tasks work in, what they read, what agents proposed, a few
/// at a time, then a way to link more.
struct PlacesList: View {
    @Bindable var model: AppModel
    @State private var renaming: WorkspaceSource?
    @State private var describing: WorkspaceSource?
    @State private var draft = ""
    @State private var proposalLimit = 3

    var body: some View {
        let linked = model.workspaceSources.filter { $0.state == .linked }
        let proposed = model.workspaceSources.filter { $0.state == .proposed }
        VStack(alignment: .leading, spacing: 2) {
            if !model.workspaceFolders.isEmpty {
                heading("Work in")
                ForEach(Array(model.workspaceFolders.enumerated()), id: \.element) { index, path in folderRow(path, index: index) }
            }
            if !linked.isEmpty {
                heading("Read")
                ForEach(linked) { sourceRow($0) }
            }
            if !proposed.isEmpty {
                heading("Proposed")
                ForEach(proposed.prefix(proposalLimit)) { SourceProposalRow(model: model, source: $0) }
                if proposed.count > proposalLimit {
                    Button("Show \(min(12, proposed.count - proposalLimit)) more") { proposalLimit += 12 }.buttonStyle(QuietButton(compact: true))
                }
            }
            Menu { PlaceLinkChoices(model: model) } label: { Label("Link a folder or document", systemImage: "plus") }
                .menuStyle(.button).buttonStyle(QuietButton()).fixedSize().padding(.top, 6)
        }
        .alert("Rename source", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") { if let renaming { model.renameSource(renaming, to: draft) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("What is inside?", isPresented: Binding(get: { describing != nil }, set: { if !$0 { describing = nil } })) {
            TextField("When tasks should read it", text: $draft)
            Button("Save") { if let describing { model.setSourceAbout(describing, draft) }; describing = nil }
            Button("Cancel", role: .cancel) { describing = nil }
        } message: { Text("Agents are told this line with the address.") }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.top, 6).padding(.bottom, 1)
    }

    private func folderRow(_ path: String, index: Int) -> some View {
        let parent = (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let users = model.groups.filter { model.groupFolders[$0.id]?.contains(path) == true }.map(\.name)
        let primary = index == 0 && model.workspaceFolders.count > 1
        let detail = [primary ? "Primary" : nil, parent, users.isEmpty ? nil : users.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ")
        return SourceRow(symbol: primary ? "folder.fill" : "folder", title: LinkedFolder.name(of: path), detail: detail) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
        .help(path + (model.workspaceFolders.count == 1 ? "\nEvery task works inside it unless its group says otherwise." : "\nGroups that chose it work inside it."))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
            if index > 0 { Button("Make primary") { model.makePrimaryFolder(path) } }
            Divider()
            Button("Unlink from workspace") { model.unlinkFolder(path) }
        }
    }

    private func sourceRow(_ source: WorkspaceSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceRow(symbol: SourceProposalRow.symbol(source.kind), title: source.title, detail: SourceProposalRow.detail(source, model: model)) { model.openSource(source) }
            if let about = source.about {
                Text(about).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.leading, 30).padding(.bottom, 3)
            }
        }
        .help(CodexApproval.visible(source.address))
        .contextMenu {
            Button(source.isWeb ? "Open in Browser" : "Show in Finder") { model.openSource(source) }
            Button(source.isWeb ? "Copy Link" : "Copy Path") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.address, forType: .string)
            }
            Button("Rename…") { draft = source.title; renaming = source }
            Button("Say what is inside…") { draft = source.about ?? ""; describing = source }
            Divider()
            Button("Unlink from workspace") { model.unlinkSource(source) }
        }
    }
}

/// An agent's or Facienda's proposal for the workspace to read. The real address always shows, and the agent's note only beside it.
struct SourceProposalRow: View {
    @Bindable var model: AppModel
    let source: WorkspaceSource

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(Palette.blue).frame(width: 6, height: 6).padding(.top, 5)
            Image(systemName: Self.symbol(source.kind)).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(Self.address(source)).font(.system(size: 11)).foregroundStyle(Palette.ink).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(([Self.origin(source, model: model) ?? source.kind.label] + [source.note.map { "“\(CodexApproval.visible($0))”" }].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                HStack(spacing: 6) {
                    Button("Link") { model.acceptSource(source) }
                    Button("Dismiss") { model.dismissSource(source) }
                    Button(source.isWeb ? "Open" : "Show in Finder") { model.openSource(source) }
                }.buttonStyle(QuietButton(compact: true)).padding(.top, 3)
            }
        }
        .padding(.vertical, 5)
        .help(CodexApproval.visible(source.address) + (source.note.map { "\n\nThe agent's note: " + CodexApproval.visible($0) } ?? ""))
    }

    static func detail(_ source: WorkspaceSource, model: AppModel) -> String {
        var parts = [source.kind.label]
        if let account = source.account { parts.append(account) }
        else if source.isWeb, let host = URL(string: source.address)?.host { parts.append(host.replacingOccurrences(of: "www.", with: "")) }
        if let origin = origin(source, model: model) { parts.append(origin) }
        return parts.joined(separator: " · ")
    }

    static func origin(_ source: WorkspaceSource, model: AppModel) -> String? {
        source.taskId.flatMap { model.tasksByID[$0] }.map { "from “\($0.displayName)”" }
    }

    /// The address as it is: the full web link, or the path with the home folder as ~.
    static func address(_ source: WorkspaceSource) -> String {
        CodexApproval.visible(source.isWeb ? source.address : (source.address as NSString).abbreviatingWithTildeInPath)
    }

    static func symbol(_ kind: SourceKind) -> String {
        switch kind {
        case .folder: "folder"
        case .driveFolder: "folder.badge.person.crop"
        case .sheet: "tablecells"
        case .doc: "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .file: "doc"
        case .link: "globe"
        }
    }
}

/// One place: its glyph, name and a quiet second line. Hovering shows that a click opens it.
private struct SourceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hover ? Palette.blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hover = $0 }
    }
}

/// What can be linked to the workspace: a link or path from the pasteboard, a folder to work in, or one to read.
/// A Google Drive folder always links as one to read: anything written there syncs to other people at once.
struct PlaceLinkChoices: View {
    @Bindable var model: AppModel

    var body: some View {
        // The pasteboard is read on the click, not each time the menu is drawn.
        Button("Paste link or path") { model.linkPastedWorkspaceSource() }
        Divider()
        let suggestions = model.folderSuggestions()
        if !suggestions.isEmpty {
            Section("Folders to work in") {
                ForEach(suggestions, id: \.self) { path in
                    let parent = (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    Button(LinkedFolder.name(of: path) + " — " + parent) { model.linkFolder(path) }
                }
            }
        }
        Button("Choose folder to work in…") { model.chooseFolder() }
        Button("Choose folder to read…") { model.chooseWorkspaceSourceFolder() }
        Button("Choose file to read…") { model.chooseWorkspaceSourceFile() }
    }
}
