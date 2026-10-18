import SwiftUI
import FaciendaCore

struct MemoryMoveEditor: View {
    let situations: [MemorySituation]
    let save: (String, String, Bool) -> Void
    let cancel: () -> Void
    @State private var situation = "build"
    @State private var words = ""
    @State private var ownStep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("When", selection: $situation) {
                ForEach(situations) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 400)
            TextField("Your words", text: $words, axis: .vertical).textFieldStyle(.roundedBorder)
            Toggle("This is my own step", isOn: $ownStep).font(.caption)
            HStack {
                Button("Keep move") { save(situation, words, ownStep) }.disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", action: cancel)
            }.buttonStyle(QuietButton())
        }.padding(.vertical, 8)
    }
}

struct MemoryRoutineEditor: View {
    let moves: [MemoryMove]
    let save: (String, [MemoryRoutine.Step]) -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var steps: [MemoryRoutine.Step]

    init(routine: MemoryRoutine?, moves: [MemoryMove], save: @escaping (String, [MemoryRoutine.Step]) -> Void, cancel: @escaping () -> Void) {
        self.moves = moves; self.save = save; self.cancel = cancel
        _name = State(initialValue: routine?.name ?? "")
        _steps = State(initialValue: routine?.steps ?? [.init(text: "")])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Routine name", text: $name).textFieldStyle(.roundedBorder)
            ForEach(steps.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(index + 1).").foregroundStyle(Palette.muted)
                        TextField("Step", text: $steps[index].text, axis: .vertical).textFieldStyle(.roundedBorder)
                        Button { steps.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move up")
                        Button { steps.remove(at: index) } label: { Image(systemName: "minus") }.disabled(steps.count == 1).help("Remove step")
                    }
                    HStack {
                        Picker("Step", selection: Binding(get: { steps[index].action }, set: { action in
                            steps[index].action = action
                            if !steps[index].canBeAutomatic && steps[index].mode == .automatic { steps[index].mode = .ask }
                        })) {
                            Text("Message to the agent").tag(MemoryRoutine.Step.Action.message)
                            Text("My own step").tag(MemoryRoutine.Step.Action.yourStep)
                            Text("Local reminder").tag(MemoryRoutine.Step.Action.reminder)
                        }.labelsHidden()
                        Picker("Mode", selection: $steps[index].mode) {
                            Text("Ask").tag(MemoryRoutine.Step.Mode.ask)
                            Text("One click").tag(MemoryRoutine.Step.Mode.oneClick)
                            if steps[index].canBeAutomatic { Text("Automatic").tag(MemoryRoutine.Step.Mode.automatic) }
                        }.labelsHidden()
                    }.frame(maxWidth: 450)
                }
            }
            HStack {
                Menu("Add step") {
                    Button("Write a step") { steps.append(.init(text: "")) }
                    ForEach(moves) { move in Button(move.text) { steps.append(.init(moveId: move.id, text: move.text, action: move.isYourStep ? .yourStep : .message)) } }
                }.disabled(steps.count >= 12).fixedSize()
                Spacer()
                Button("Save") { save(name, steps) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || steps.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                Button("Cancel", action: cancel)
            }.buttonStyle(QuietButton())
        }.padding(.vertical, 8)
    }
}
