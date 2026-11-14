import SwiftUI
import FaciendaCore

/// Today's list, beside the map in Goals: what the user picked for the day, under the goal it serves, and at the foot
/// what serves no goal, which is written right here. A row is one mark and its words, with nothing counted. The mark
/// ticks it by hand; play and ✕ show under the pointer.
struct TodayList: View {
    @Bindable var goals: GoalsModel
    let workspaces: WorkspaceController
    /// The minigoal under the pointer, shared with the map: a row lights its line there, and the other way round.
    @Binding var hovered: String?
    /// Where the keys go, shared with the map's lines to write on, so only one of them is open at a time.
    var writing: FocusState<String?>.Binding
    /// The row whose words are still on their way from the map. It keeps their room and shows them once they land.
    let arriving: String?
    /// A row on its way tells where its words belong.
    let landed: (String, CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    /// The row the pointer is on here, which shows its play and ✕.
    @State private var over: String?

    static let width: CGFloat = 320
    /// The key of the line to write on at the list's foot.
    static let field = "today"

    var body: some View {
        let sections = goals.todaySections
        VStack(spacing: 0) {
            Text("Today").font(.system(size: 22, weight: .medium, design: .serif))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20).frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sections.count == 1 { hint }
                    ForEach(sections) { section in
                        heading(section.goal)
                        ForEach(section.rows) { row in self.row(row) }
                        if section.goal == nil { adder }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
        }
        .background(Palette.paper)
        // What changes on its own, such as work coming back, moves at the page's pace; a pick keeps the pace it set.
        .transaction(value: sections) { if $0.animation == nil { $0.animation = reduceMotion ? Motion.fade : Motion.move } }
    }

    private var hint: some View {
        Text("Click a minigoal on the map to pick it.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 0, trailing: 12))
            .transition(.opacity)
    }

    /// A goal's name with its picture, small, as the note's headings were.
    private func heading(_ goal: Goal?) -> some View {
        HStack(spacing: 6) {
            if let goal {
                ZStack {
                    Palette.line
                    if let image = goals.cover(goal) { Image(nsImage: image).resizable().scaledToFill() }
                }
                .frame(width: 10, height: 10).clipShape(Circle())
            }
            Text(goal?.text ?? "No goal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 4, trailing: 12))
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        .transition(.opacity)
    }

    private func row(_ row: GoalsModel.TodayRow) -> some View {
        let item = row.entry?.line
        let tools = over == row.id || goals.aim?.lineID == row.id
        // Done by its work, there is nothing to tick.
        let worked = row.isDone && !row.isTicked
        return HStack(spacing: 6) {
            Button { tick(row) } label: { TaskDot(kind: row.mark).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(worked)
                .help(worked ? "Its work is done" : row.isTicked ? "Not done after all" : "Done")
                .accessibilityLabel(row.isTicked ? "Not done after all" : "Done")
            Text(row.text).font(.system(size: 13)).foregroundStyle(row.isDone ? Palette.muted : Palette.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(GoalsView.roomSpace)) } action: { if arriving == row.id { landed(row.id, $0) } }
                .opacity(arriving == row.id ? 0 : 1)
            HStack(spacing: 0) {
                if let item, !row.isDone { play(item) }
                Button { takeOff(row) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Take it off today").accessibilityLabel("Take it off today")
            }
            .opacity(tools ? 1 : 0).allowsHitTesting(tools)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5).frame(minHeight: 32)
        .background { if hovered == row.id || goals.aim?.lineID == row.id { RoundedRectangle(cornerRadius: 12).fill(Palette.selected.opacity(0.6)) } }
        .overlay(alignment: .leading) { if row.isNew { Circle().fill(Palette.blue).frame(width: 6, height: 6).offset(x: 2) } }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = row.id; over = row.id } else { if hovered == row.id { hovered = nil }; if over == row.id { over = nil } }
        }
        .contextMenu {
            if let item, !row.isDone { Button("Add detail…", systemImage: "text.badge.plus") { goals.detail(item) }.disabled(goals.place(of: item) == nil) }
            Button(row.isTicked ? "Not done after all" : "Done", systemImage: row.isTicked ? "circle" : "checkmark") { tick(row) }.disabled(worked)
            Button("Take off today", systemImage: "xmark") { takeOff(row) }
        }
        .transition(.opacity)
    }

    /// Play puts the minigoal in the bar, as on the map. One with no place yet asks where first.
    @ViewBuilder private func play(_ item: GoalItem) -> some View {
        let glyph = Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.blue).frame(width: 22, height: 22).contentShape(Rectangle())
        if goals.launching.contains(item.line.id) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 22, height: 22)
        } else if let place = goals.place(of: item) {
            Button { goals.detail(item) } label: { glyph }.buttonStyle(.plain)
                .help("Start it in " + place.place.label).accessibilityLabel("Start it")
        } else {
            Menu { PlaceChoices(goals: goals, workspaces: workspaces, item: item) { goals.detail(item, at: $0) } } label: { glyph }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Start it: choose where").accessibilityLabel("Start it")
        }
    }

    /// The line to write on for what serves no goal. Return adds it and the line stays, for the next one.
    private var adder: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).frame(width: 22, height: 22)
            TextField("Add…", text: $draft).textFieldStyle(.plain).font(.system(size: 13))
                .focused(writing, equals: Self.field)
                .onSubmit(add)
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(minHeight: 32)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.move) { goals.addToday(text) }
        draft = ""; writing.wrappedValue = Self.field
    }

    private func tick(_ row: GoalsModel.TodayRow) { withAnimation(reduceMotion ? Motion.fade : Motion.move) { goals.tick(row) } }
    private func takeOff(_ row: GoalsModel.TodayRow) { withAnimation(reduceMotion ? Motion.fade : Motion.move) { goals.takeOff(row) } }
}

extension GoalsModel.TodayRow {
    /// How it stands, as one glyph: done, else what its work most needs from the user, else planned.
    var mark: TaskDot.Kind {
        if isDone { return .done }
        let states = Set(entry?.work.compactMap { $0.task?.state } ?? [])
        return [TaskState.needsMe, .running, .waiting, .scheduled].first(where: states.contains).flatMap(TaskDot.Kind.init(state:)) ?? .notStarted
    }
}
