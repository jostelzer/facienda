import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Pasting, dropping or picking files into a field that writes the omnibar's text: the top bar and a group's sheet.
    func takesAttachments(_ omnibar: OmnibarModel, focus: FocusState<Bool>.Binding, dropping: Binding<Bool>? = nil) -> some View {
        modifier(AttachmentInput(focused: { focus.wrappedValue }, dropping: dropping) { urls, dropped in
            omnibar.attach(urls)
            if dropped { focus.wrappedValue = true }
        })
    }

    /// The same for a field with a list of its own, such as the answer field of an opened task. `focused` says whether
    /// ⌘V is meant for it; `attach` also hears whether the files were dropped, so it can take the keyboard.
    func takesAttachments(focused: @escaping () -> Bool, dropping: Binding<Bool>? = nil, attach: @escaping (_ urls: [URL], _ dropped: Bool) -> Void) -> some View {
        modifier(AttachmentInput(focused: focused, dropping: dropping, attach: attach))
    }
}

private struct AttachmentInput: ViewModifier {
    let focused: () -> Bool
    let dropping: Binding<Bool>?
    let attach: (_ urls: [URL], _ dropped: Bool) -> Void
    @State private var pasteMonitor: Any?

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.contains(where: \.isFileURL) else { return false }
                attach(urls, true)
                return true
            } isTargeted: { dropping?.wrappedValue = $0 }
            // The text field takes only text, so ⌘V with a picture or copied files would do nothing.
            .onAppear {
                let focused = focused, attach = attach
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard focused(), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                    let files = OmnibarModel.pastedFiles()
                    guard !files.isEmpty else { return event }
                    attach(files, false)
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
        AttachmentChips(urls: omnibar.attachments) { url in omnibar.attachments.removeAll { $0 == url } }
    }
}

/// Files waiting to be sent, in one line that scrolls sideways.
struct AttachmentChips: View {
    let urls: [URL]
    var remove: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(urls, id: \.self) { url in AttachmentChip(url: url) { remove(url) } }
            }
        }.frame(height: 32)
    }
}

/// A file waiting to be sent: a thumbnail for pictures, the file's icon otherwise.
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
