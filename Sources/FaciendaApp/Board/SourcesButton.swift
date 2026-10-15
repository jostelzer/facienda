import SwiftUI
import FaciendaCore

/// The card's quiet link button: the link symbol and, in words, how many sources the group has, opening a popover with all of them.
/// Work folders come first, then what the tasks read. A proposal waiting for the user shows as a blue dot before the symbol.
/// A group with nothing linked or proposed says "No sources", fainter, so every card offers a place to link its first source.
struct SourcesButton: View {
    @Bindable var model: AppModel
    let group: TaskGroup
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let folders = model.groupFolders[group.id] ?? []
        let sources = model.groupSources[group.id] ?? []
        let linked = folders.count + sources.filter { $0.state == .linked }.count
        let proposed = sources.filter { $0.state == .proposed }.count
        let lit = open || hover
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                if proposed > 0 { Circle().fill(Palette.blue).frame(width: 5, height: 5) }
                Image(systemName: "link").font(.system(size: 11, weight: .medium))
                Text(Self.label(linked: linked, proposed: proposed)).font(.system(size: 12))
            }
            .foregroundStyle(lit ? Palette.ink : Palette.muted)
            .opacity(linked == 0 && proposed == 0 && !lit ? 0.6 : 1)
            .padding(.horizontal, 6).frame(height: 20)
            .background(lit ? Palette.line.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The words line up with the card's edge; only the hover wash reaches past it.
        .padding(.trailing, -6)
        .onHover { hover = $0 }
        .animation(Motion.fade, value: lit)
        .help(Self.summary(linked: linked, proposed: proposed))
        .accessibilityLabel(Self.summary(linked: linked, proposed: proposed))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SourcesPopover(model: model, group: group, folders: folders, sources: sources)
        }
    }

    private static func label(linked: Int, proposed: Int) -> String {
        if linked > 0 { return "\(linked) source\(linked == 1 ? "" : "s")" }
        return proposed > 0 ? "\(proposed) proposed" : "No sources"
    }

    private static func summary(linked: Int, proposed: Int) -> String {
        if linked == 0 && proposed == 0 { return "Nothing linked yet. Click to link a folder or file." }
        var parts = ["\(linked) source\(linked == 1 ? "" : "s")"]
        if proposed > 0 { parts.append("\(proposed) proposed") }
        return parts.joined(separator: ", ")
    }
}

/// Every source of one group: proposals waiting for a decision, where the tasks work, and what they read.
struct SourcesPopover: View {
    @Bindable var model: AppModel
    let group: TaskGroup
    let folders: [String]
    let sources: [GroupSource]
    @State private var renaming: GroupSource?
    @State private var draft = ""

    var body: some View {
        let proposed = sources.filter { $0.state == .proposed }
        let linked = sources.filter { $0.state == .linked }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(folders.count + linked.count == 1 ? "1 source" : "\(folders.count + linked.count) sources").font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu { SourceLinkChoices(model: model, group: group) } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Palette.muted)
                    .help("Link a source to " + group.name)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !proposed.isEmpty {
                        heading("Proposed")
                        ForEach(proposed) { proposal($0) }
                        Divider().padding(.vertical, 5)
                    }
                    ForEach(Array(folders.enumerated()), id: \.element) { index, path in folderRow(path, index: index) }
                    ForEach(linked) { sourceRow($0) }
                    if folders.isEmpty && linked.isEmpty {
                        Text("Nothing linked yet.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }.padding(.bottom, 8)
            }.frame(maxHeight: 420).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 300)
        .alert("Rename source", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") { if let renaming { model.renameSource(renaming, to: draft) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)
    }

    private func proposal(_ source: GroupSource) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(Palette.blue).frame(width: 6, height: 6).padding(.top, 5)
            Image(systemName: Self.symbol(source.kind)).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14).padding(.top, 1)
            // An agent proposed it: the real address always shows, and its note only beside it.
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(Self.address(source)).font(.system(size: 10.5)).foregroundStyle(Palette.ink).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(([origin(source) ?? source.kind.label] + [source.note.map { "“\(CodexApproval.visible($0))”" }].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(2)
                HStack(spacing: 10) {
                    Button("Link") { model.acceptSource(source) }.foregroundStyle(Palette.blue)
                    Button("Dismiss") { model.dismissSource(source) }.foregroundStyle(Palette.muted)
                    Button(source.isWeb ? "Open" : "Show in Finder") { model.openSource(source) }.foregroundStyle(Palette.muted)
                }.buttonStyle(.plain).font(.system(size: 11)).padding(.top, 1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .help(CodexApproval.visible(source.address) + (source.note.map { "\n\nThe agent's note: " + CodexApproval.visible($0) } ?? ""))
    }

    private func folderRow(_ path: String, index: Int) -> some View {
        let primary = index == 0 && folders.count > 1
        let parent = (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return SourceRow(symbol: primary ? "folder.fill" : "folder", title: LinkedFolder.name(of: path),
                         detail: (primary ? "Primary work folder · " : "Work folder · ") + parent) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
        .help(path + "\nTasks in this group work inside it." + (primary ? " New chats start here." : ""))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
            if index > 0 { Button("Make primary") { model.makePrimaryFolder(path, in: group) } }
            Divider()
            Button("Unlink from group") { model.unlinkFolder(path, from: group) }
        }
    }

    private func sourceRow(_ source: GroupSource) -> some View {
        SourceRow(symbol: Self.symbol(source.kind), title: source.title, detail: detail(source)) { model.openSource(source) }
            .help(CodexApproval.visible(source.address))
            .contextMenu {
                Button(source.isWeb ? "Open in Browser" : "Show in Finder") { model.openSource(source) }
                Button(source.isWeb ? "Copy Link" : "Copy Path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.address, forType: .string)
                }
                Button("Rename…") { draft = source.title; renaming = source }
                Divider()
                Button("Unlink from group") { model.unlinkSource(source) }
            }
    }

    private func detail(_ source: GroupSource) -> String {
        var parts = [source.kind.label]
        if let account = source.account { parts.append(account) }
        else if source.isWeb, let host = URL(string: source.address)?.host { parts.append(host.replacingOccurrences(of: "www.", with: "")) }
        if let origin = origin(source) { parts.append(origin) }
        return parts.joined(separator: " · ")
    }

    private func origin(_ source: GroupSource) -> String? {
        source.taskId.flatMap { model.tasksByID[$0] }.map { "from “\($0.displayName)”" }
    }

    /// The address as it is: the full web link, or the path with the home folder as ~.
    static func address(_ source: GroupSource) -> String {
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

/// One source in the popover: its glyph, name and a quiet second line. Hovering shows that a click opens it.
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
                    Text(title).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(hover ? Palette.blue.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// What can be linked to a group: a link or path from the pasteboard, folders worth offering, or one picked by hand.
/// A Google Drive folder links as a source to read; any other folder becomes one the tasks work in.
struct SourceLinkChoices: View {
    @Bindable var model: AppModel
    let group: TaskGroup

    var body: some View {
        // The pasteboard is read on the click, not each time the menu is drawn.
        Button("Paste link or path") { model.linkPastedSource(to: group) }
        Divider()
        let suggestions = model.folderSuggestions(for: group)
        if !suggestions.isEmpty {
            Section("Folders to work in") {
                ForEach(suggestions, id: \.self) { path in
                    let parent = (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    Button(LinkedFolder.name(of: path) + " — " + parent) { model.linkFolder(path, to: group) }
                }
            }
        }
        Button("Choose folder…") { model.chooseFolder(for: group) }
        Button("Choose file…") { model.chooseSourceFile(for: group) }
    }
}
