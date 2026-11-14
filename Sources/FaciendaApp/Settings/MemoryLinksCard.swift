import SwiftUI
import FaciendaCore

/// Which workspace reads which memory, as two banks: every memory on the left, every workspace on the right in the
/// island's order, a faint dashed line across from each workspace to itself, and a soft curve from a memory to each
/// other workspace that reads it. The island itself stays without lines, so this is the one place every read shows at once.
struct MemoryLinksCard: View {
    let model: AppModel
    let workspaces: WorkspaceController
    /// The workspace under the pointer, and the one clicked to keep its reads lit.
    @State private var hovered: String?
    @State private var pinned: String?
    /// The read whose choices are open.
    @State private var editing: Link?
    /// A memory being carried from the left bank, and the reader on the right it would land on.
    @State private var carried: Carry?
    @State private var target: String?
    @State private var shared = 0

    private static let size: CGFloat = 24, row: CGFloat = 40, top: CGFloat = 44
    private static let space = "memory banks"

    private struct Link: Hashable, Identifiable {
        let source: Workspace, reader: Workspace, understanding: Bool
        var id: String { source.id + ">" + reader.id }
    }
    private struct Carry: Equatable { let source: String; var at: CGPoint }

    private var links: [Link] {
        workspaces.reads.compactMap { read in
            guard let source = workspaces.workspace(ofSpace: read.sourceSpaceId), let reader = workspaces.workspace(ofSpace: read.readerSpaceId) else { return nil }
            return Link(source: source, reader: reader, understanding: read.understanding)
        }
    }
    private var focus: String? { carried == nil ? hovered ?? pinned : nil }

    var body: some View {
        let order = workspaces.ordered, links = links
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Between workspaces")
            Text("Which workspace reads which memory. Reading is one-way and read-only, and never passes on.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            banks(order, links)
                .frame(height: Self.top + CGFloat(max(order.count - 1, 0)) * Self.row + 18)
            caption(order, links)
            legend
            aboutYou(order)
        }
        .task(id: workspaces.current?.memorySpaceId) {
            guard let space = workspaces.current?.memorySpaceId else { return }
            shared = (try? model.store.memoryEntries(spaceID: space, states: [.live]).filter { $0.spaceId == nil }.count) ?? 0
        }
    }

    // MARK: The banks

    private func banks(_ order: [Workspace], _ links: [Link]) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width, inset = min(150, width * 0.3)
            let left = inset, right = width - inset, radius = Self.size / 2
            let rows = Dictionary(order.enumerated().map { ($1.id, Self.top + CGFloat($0) * Self.row) }, uniquingKeysWith: min)
            ZStack(alignment: .topLeading) {
                Eyebrow(text: "Memory of").frame(width: max(left - 18, 0), alignment: .trailing).position(x: (left - 18) / 2, y: 6)
                Eyebrow(text: "Is read by").frame(width: max(width - right - 18, 0), alignment: .leading).position(x: (width + right + 18) / 2, y: 6)
                // Every workspace reads its own memory: a dashed line straight across, beneath the reads between workspaces.
                ForEach(order) { workspace in
                    own(workspace, from: CGPoint(x: left + radius + 6, y: rows[workspace.id] ?? 0), to: CGPoint(x: right - radius - 6, y: rows[workspace.id] ?? 0))
                }
                ForEach(links) { link in
                    curve(link, from: CGPoint(x: left + radius + 6, y: rows[link.source.id] ?? 0), to: CGPoint(x: right - radius - 7, y: rows[link.reader.id] ?? 0))
                }
                if let carried, let y = rows[carried.source] {
                    Path { $0.move(to: CGPoint(x: left, y: y)); $0.addLine(to: carried.at) }
                        .stroke(Palette.ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                        .allowsHitTesting(false)
                }
                ForEach(order) { workspace in
                    let y = rows[workspace.id] ?? 0
                    memory(workspace, lent: links.contains { $0.source == workspace }, order: order, rows: rows, right: right)
                        .position(x: left, y: y)
                    name(workspace, faint: !links.contains { $0.source == workspace })
                        .frame(width: max(left - 18, 0), alignment: .trailing).position(x: (left - 18) / 2, y: y)
                    reader(workspace, reading: links.contains { $0.reader == workspace }, order: order)
                        .position(x: right, y: y)
                    name(workspace, faint: !links.contains { $0.reader == workspace })
                        .frame(width: max(width - right - 18, 0), alignment: .leading).position(x: (width + right + 18) / 2, y: y)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    /// One read: a soft curve from the memory to its reader, doubled when what the memory has understood comes too, with a
    /// chevron at the reader's end. Muted ink only: blue means new and green means running.
    private func curve(_ link: Link, from: CGPoint, to: CGPoint) -> some View {
        let hot = focus == link.source.id || focus == link.reader.id
        let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        return Self.linkPath(from: from, to: to, double: link.understanding)
            .stroke(hot ? Palette.ink : Palette.muted, style: StrokeStyle(lineWidth: hot ? 1.4 : 1.2, lineCap: .round, lineJoin: .round))
            .opacity(focus != nil && !hot ? 0.2 : 1)
            .contentShape(Self.linkPath(from: from, to: to, double: false, chevron: false).strokedPath(StrokeStyle(lineWidth: 14)))
            .pointerStyle(.link)
            .onTapGesture { editing = link }
            .popover(isPresented: Binding(get: { editing?.id == link.id }, set: { if !$0 { editing = nil } }),
                     attachmentAnchor: .rect(.rect(CGRect(origin: middle, size: .zero))), arrowEdge: .bottom) {
                choices(link)
            }
            .accessibilityElement()
            .accessibilityLabel("\(link.reader.name) reads \(link.source.name)" + (link.understanding ? ", and what it has understood" : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editing = link }
    }

    /// A workspace reading its own memory: dashed, fainter than any read, lit with the rest of that workspace's reads.
    private func own(_ workspace: Workspace, from: CGPoint, to: CGPoint) -> some View {
        let hot = focus == workspace.id
        return Path { $0.move(to: from); $0.addLine(to: to) }
            .stroke(hot ? Palette.ink : Palette.muted, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
            .opacity(focus == nil ? 0.5 : hot ? 0.8 : 0.15)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static func linkPath(from: CGPoint, to: CGPoint, double: Bool, chevron: Bool = true) -> Path {
        Path { path in
            let middle = (from.x + to.x) / 2
            for offset: CGFloat in double ? [-1.7, 1.7] : [0] {
                path.move(to: CGPoint(x: from.x, y: from.y + offset))
                path.addCurve(to: CGPoint(x: to.x, y: to.y + offset),
                              control1: CGPoint(x: middle, y: from.y + offset), control2: CGPoint(x: middle, y: to.y + offset))
            }
            if chevron {
                path.move(to: CGPoint(x: to.x - 4, y: to.y - 3.6))
                path.addLine(to: CGPoint(x: to.x + 1, y: to.y))
                path.addLine(to: CGPoint(x: to.x - 4, y: to.y + 3.6))
            }
        }
    }

    /// A memory on the left. Dragging it onto a workspace on the right makes that workspace read it.
    private func memory(_ workspace: Workspace, lent: Bool, order: [Workspace], rows: [String: CGFloat], right: CGFloat) -> some View {
        planet(workspace, size: Self.size)
            .opacity(lent ? 1 : 0.45)
            .onHover { hover(workspace, $0) }
            .onTapGesture { pin(workspace) }
            .pointerStyle(carried == nil ? .grabIdle : .grabActive)
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if carried == nil { editing = nil; withAnimation(Motion.fade) { hovered = nil } }
                    carried = Carry(source: workspace.id, at: value.location)
                    let near = order.first { other in
                        other.id != workspace.id && hypot(value.location.x - right, value.location.y - (rows[other.id] ?? 0)) < Self.size / 2 + 6
                    }
                    if target != near?.id { withAnimation(Motion.fade) { target = near?.id } }
                }
                .onEnded { _ in
                    if let target, let reader = order.first(where: { $0.id == target }), workspaces.read(reader, workspace) == nil {
                        withAnimation(Motion.fade) { workspaces.setRead(reader, workspace, understanding: false); pinned = reader.id }
                    }
                    carried = nil; target = nil
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(workspace.name)’s memory")
            .accessibilityValue(readers(of: workspace))
    }

    /// A reader on the right. Its menu holds the same choices as its tile’s menu on the island.
    private func reader(_ workspace: Workspace, reading: Bool, order: [Workspace]) -> some View {
        planet(workspace, size: Self.size)
            // The reader a carried memory would land on gets a ring.
            .overlay {
                ZStack {
                    Self.tile(Self.size + 6).strokeBorder(Palette.paper, lineWidth: 3).padding(-3)
                    Self.tile(Self.size + 9).strokeBorder(Palette.ink, lineWidth: 1.5).padding(-4.5)
                }
                .opacity(target == workspace.id ? 1 : 0).allowsHitTesting(false)
            }
            .opacity(reading || target == workspace.id ? 1 : 0.45)
            .onHover { hover(workspace, $0) }
            .onTapGesture { pin(workspace) }
            .contextMenu {
                Section("\(workspace.name) reads") {
                    ForEach(order.filter { $0.id != workspace.id }) { other in
                        Toggle(other.name, isOn: Binding(get: { workspaces.read(workspace, other) != nil },
                                                         set: { _ in withAnimation(Motion.fade) { workspaces.toggleRead(workspace, other) } }))
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(workspace.name)
            .accessibilityValue(sources(of: workspace))
    }

    private func name(_ workspace: Workspace, faint: Bool) -> some View {
        Text(workspace.name).font(.system(size: 13, design: .serif)).lineLimit(1).truncationMode(.tail)
            .opacity(faint ? 0.45 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A tile's shape at this size: a rounded square with the island's proportion of corner.
    private static func tile(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: (size * 0.24).rounded(), style: .continuous)
    }

    /// The workspace's painting as a small tile, or its initial until one exists, as on the island.
    private func planet(_ workspace: Workspace, size: CGFloat) -> some View {
        ZStack {
            Palette.line
            if let image = workspaces.coverImages[workspace.id] { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(workspace.name.prefix(1).uppercased()).font(.system(size: size * 0.42, design: .serif)).foregroundStyle(Palette.muted) }
        }
        .frame(width: size, height: size)
        .clipShape(Self.tile(size))
        .overlay { Self.tile(size).strokeBorder(Palette.ink.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.12), radius: size / 6, y: size / 8)
        .contentShape(Self.tile(size))
    }

    private func hover(_ workspace: Workspace, _ inside: Bool) {
        guard carried == nil else { return }
        withAnimation(Motion.fade) { if inside { hovered = workspace.id } else if hovered == workspace.id { hovered = nil } }
    }

    private func pin(_ workspace: Workspace) {
        withAnimation(Motion.fade) { pinned = pinned == workspace.id ? nil : workspace.id }
    }

    // MARK: One read's choices

    private func choices(_ link: Link) -> some View {
        let source = link.source, reader = link.reader
        let understanding = workspaces.read(reader, source)?.understanding ?? false
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                planet(source, size: 20); Text(source.name)
                Text("→").fontWeight(.regular).foregroundStyle(Palette.muted)
                planet(reader, size: 20); Text(reader.name)
            }
            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            option(on: true, "\(source.name)’s entries", detail: "Places, People, Choices and How-tos. Rules and moves stay in \(source.name).")
            Button { withAnimation(Motion.fade) { workspaces.setRead(reader, source, understanding: !understanding) } } label: {
                option(on: understanding, "What \(source.name) has understood", detail: "Marked as inferred in \(reader.name)")
            }
            .buttonStyle(.plain).disabled(workspaces.demo)
            .accessibilityAddTraits(understanding ? .isSelected : [])
            Divider().padding(.top, 4)
            HStack(spacing: 8) {
                Button("\(reader.name) stops reading \(source.name)") {
                    editing = nil
                    withAnimation(Motion.fade) { workspaces.stopReading(reader, source) }
                }.buttonStyle(QuietButton()).disabled(workspaces.demo)
                Spacer(minLength: 0)
                Button("Done") { editing = nil }.buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 4)
        }
        .padding(6).frame(width: 300)
    }

    private func option(on: Bool, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(on ? Palette.ink : .clear)
                .overlay { Circle().strokeBorder(Palette.firmLine, lineWidth: 1.5).opacity(on ? 0 : 1) }
                .overlay { Circle().fill(Palette.paper).frame(width: 6, height: 6).opacity(on ? 1 : 0) }
                .frame(width: 16, height: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
    }

    // MARK: Below the banks

    /// What the lit workspace reads and who reads it, or how many reads there are.
    private func caption(_ order: [Workspace], _ links: [Link]) -> some View {
        Group {
            if let focus, let workspace = order.first(where: { $0.id == focus }) {
                Text("\(Text(workspace.name).fontWeight(.semibold).foregroundStyle(Palette.ink)) \(sentence(workspace, links))")
            } else if links.isEmpty {
                Text("No workspace reads another’s memory yet. Drag a memory on the left onto a workspace on the right.")
            } else {
                Text("\(links.count) \(links.count == 1 ? "read" : "reads") between \(order.count) workspaces. Hover a workspace to see what it reads and who reads it.")
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
        .frame(minHeight: 18, alignment: .leading)
    }

    private func sentence(_ workspace: Workspace, _ links: [Link]) -> String {
        let reads = links.filter { $0.reader == workspace }.map { $0.source.name + ($0.understanding ? " (and what it has understood)" : "") }
        let readBy = links.filter { $0.source == workspace }.map(\.reader.name)
        return (reads.isEmpty ? "reads only its own memory." : "reads \(reads.formatted(.list(type: .and))).")
            + (readBy.isEmpty ? " Nobody reads it." : " \(readBy.formatted(.list(type: .and))) \(readBy.count == 1 ? "reads" : "read") it.")
    }

    private func readers(of workspace: Workspace) -> String {
        let names = workspaces.reads.filter { $0.sourceSpaceId == workspace.memorySpaceId }.compactMap { workspaces.workspace(ofSpace: $0.readerSpaceId)?.name }
        return names.isEmpty ? "Nobody reads it" : "Read by \(names.formatted(.list(type: .and)))"
    }

    private func sources(of workspace: Workspace) -> String {
        let names = workspaces.reads.filter { $0.readerSpaceId == workspace.memorySpaceId }.compactMap { workspaces.workspace(ofSpace: $0.sourceSpaceId)?.name }
        return names.isEmpty ? "Reads only its own memory" : "Reads \(names.formatted(.list(type: .and)))"
    }

    private var legend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 7) {
                Path { $0.move(to: CGPoint(x: 2, y: 5)); $0.addLine(to: CGPoint(x: 28, y: 5)) }
                    .stroke(Palette.muted, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
                    .frame(width: 30, height: 10)
                Text("Its own memory")
            }
            sample(double: false, "Reads its entries")
            sample(double: true, "And what it has understood")
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        .accessibilityElement(children: .combine)
    }

    private func sample(double: Bool, _ text: String) -> some View {
        HStack(spacing: 7) {
            Path { path in
                for y: CGFloat in double ? [3.4, 6.6] : [5] { path.move(to: CGPoint(x: 2, y: y)); path.addLine(to: CGPoint(x: 28, y: y)) }
                path.move(to: CGPoint(x: 13, y: 2)); path.addLine(to: CGPoint(x: 16, y: 5)); path.addLine(to: CGPoint(x: 13, y: 8))
            }
            .stroke(Palette.muted, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: 30, height: 10)
            Text(text)
        }
    }

    /// What the user shared in About you reaches every workspace, so it stands apart from the reads.
    private func aboutYou(_ order: [Workspace]) -> some View {
        HStack(spacing: 10) {
            Text("About you").fontWeight(.semibold).foregroundStyle(Palette.ink)
            Text(shared == 0 ? "Nothing shared with every workspace yet"
                 : "\(shared) \(shared == 1 ? "entry you shared reaches" : "entries you shared reach") every workspace")
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            HStack(spacing: -4) {
                ForEach(order.prefix(8)) { workspace in
                    planet(workspace, size: 14).overlay { Self.tile(17).strokeBorder(Palette.sidebar, lineWidth: 1.5).padding(-1.5) }
                }
            }.accessibilityHidden(true)
        }
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Palette.sidebar, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
