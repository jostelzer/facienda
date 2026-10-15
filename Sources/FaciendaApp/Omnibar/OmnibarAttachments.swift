import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Pasting, dropping or picking files into a field that writes the omnibar's text: the top bar and a group's sheet.
    func takesAttachments(_ omnibar: OmnibarModel, focus: FocusState<Bool>.Binding, dropping: Binding<Bool>? = nil) -> some View {
        modifier(AttachmentInput(omnibar: omnibar, focus: focus, dropping: dropping))
    }
}

private struct AttachmentInput: ViewModifier {
    let omnibar: OmnibarModel
    let focus: FocusState<Bool>.Binding
    let dropping: Binding<Bool>?
    @State private var pasteMonitor: Any?

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.contains(where: \.isFileURL) else { return false }
                omnibar.attach(urls); focus.wrappedValue = true
                return true
            } isTargeted: { dropping?.wrappedValue = $0 }
            // The text field takes only text, so ⌘V with a picture or copied files would do nothing.
            .onAppear {
                let focus = focus, omnibar = omnibar
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard focus.wrappedValue, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers?.lowercased() == "v", omnibar.pasteAttachments() else { return event }
                    return nil
                }
            }
            .onDisappear {
                if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
                pasteMonitor = nil
            }
    }
}

/// The paperclip beside the mic: picks images, video, audio or documents for the next task.
struct AttachButton: View {
    let omnibar: OmnibarModel
    var picked: () -> Void = {}
    @State private var importing = false

    var body: some View {
        Button { importing = true } label: {
            Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(omnibar.attachments.isEmpty ? Palette.muted : Palette.blue)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Attach images, video, audio or documents · or paste or drop them here")
        .accessibilityLabel("Attach files")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): omnibar.attach(urls); picked()
            case let .failure(error): omnibar.model.error = error.localizedDescription
            }
        }
    }
}

/// The files waiting to go with the next task.
struct AttachmentRow: View {
    let omnibar: OmnibarModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(omnibar.attachments, id: \.self) { url in
                    AttachmentChip(url: url) { omnibar.attachments.removeAll { $0 == url } }
                }
            }
        }.frame(height: 32)
    }
}

/// A file waiting to go with the next task: a thumbnail for pictures, the file's icon otherwise.
private struct AttachmentChip: View {
    let url: URL
    var remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFill().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                .buttonStyle(.plain).help("Remove attachment").accessibilityLabel("Remove " + url.lastPathComponent)
        }
        .padding(.leading, 5).padding(.trailing, 7).frame(height: 30)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
        .help(url.path)
        .task(id: url) {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
            let url = url
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }
}
