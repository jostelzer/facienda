import SwiftUI
import FaciendaCore

/// Sets when the agent next checks a waiting task, and the limits it picks later dates within.
struct CheckEditor: View {
    @Bindable var model: AppModel
    let plan: CheckPlan
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var deadline: Date
    @State private var pinned: Bool
    @State private var hours: Double
    init(model: AppModel, plan: CheckPlan) {
        self.model = model; self.plan = plan
        _date = State(initialValue: max(plan.nextCheck, Date()))
        _deadline = State(initialValue: max(plan.deadline, Date().addingTimeInterval(86400)))
        _pinned = State(initialValue: plan.pinned)
        _hours = State(initialValue: plan.minimumInterval / 3600)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Next check").font(.system(size: 20, weight: .semibold))
            DatePicker("When", selection: $date)
            Toggle("Keep this date", isOn: $pinned)
            Text("After this check, Codex can choose the next date within these limits.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack { Text("At least hours apart"); TextField("Hours", value: $hours, format: .number).frame(width: 70) }
            DatePicker("Review by", selection: $deadline)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Save") {
                    model.controlCheck(plan, paused: false, pinned: pinned, date: date, interval: hours * 3600, deadline: deadline)
                    if model.error == nil { dismiss() }
                }.buttonStyle(QuietButton(prominent: true)).disabled(date < Date() || deadline <= date || hours < 1.0 / 60)
            }
        }.padding(24).frame(width: 440).background(Palette.paper)
    }
}
