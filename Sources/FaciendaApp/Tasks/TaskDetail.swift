import SwiftUI
import FaciendaCore

/// What an opened task holds under the agent's answer: what is under way, its decisions, prerequisites and files.
/// What to do next is not here: that is the dock under it, and the task's bar holds the rest. The request, the model
/// and the activity list once sat in a Details fold here; the chat above already reads as the request, and the user
/// found the fold noise.
struct TaskDetail: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    @State private var changingCheck = false
    private var plan: CheckPlan? { model.checkPlan(for: task.id) }
    private var decisions: [Decision] { model.decisions(for: task.id) }

    var body: some View {
        readingContent
            .sheet(isPresented: $changingCheck) { if let plan { CheckEditor(model: model, plan: plan) } }
    }
    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            delivery
            ForEach(model.codexApprovals[task.id] ?? []) { CodexApprovalCard(model: model, approval: $0) }
            ForEach(decisions.filter { $0.kind != "completion" }) { DecisionCard(model: model, decision: $0) }
            if model.blockers.contains(where: { $0.taskId == task.id || $0.prerequisiteId == task.id }) {
                DisclosureGroup("Prerequisites") {
                    BlockerChecklist(model: model, task: task).padding(.top, 12)
                }.font(.system(size: 12, weight: .medium))
                    .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            }
            if let attachments = task.attachments, !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Attachments")
                    // The copy sits in the task's folder, which its agent can write, so it is only shown in Finder, never opened from here.
                    ForEach(attachments) { attachment in
                        Button { model.revealAttachment(attachment) } label: {
                            Label(attachment.name, systemImage: "paperclip").font(.system(size: 12))
                        }.buttonStyle(.borderless).help("Show in Finder: " + attachment.path)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            }
            if let plan, plan.lastOutcome != "All conditions met" {
                checkCard(plan)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A start that is still on its way: recovery, the handoff to Claude, or a run in progress.
    @ViewBuilder private var delivery: some View {
        if let recovery = model.recoveryDispatch(for: task.id) {
            DeliveryRecovery(model: model, item: recovery)
        } else if let pending = model.pendingDispatch(for: task.id) {
            if pending.awaitsClaudeSend || model.status(for: task) == .waitingForClaude {
                ClaudeHandoff(model: model, item: pending)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.taskStatus(task)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    if ["queued", "claimed"].contains(pending.state) { Button("Cancel run") { model.cancelStart(pending.id) }.buttonStyle(.borderless) }
                }
                if let reason = model.deferReason(pending) {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                if pending.agent == .claude, pending.threadId != nil, model.claudeRunner?.isAwake() != true {
                    Text("The Claude runner is asleep, so this waits until it wakes. Open the runner in Settings, or answer in the Claude app directly.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    /// When the agent looks next, and why.
    private func checkCard(_ plan: CheckPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.paused ? "Checks paused" : "Next check · " + plan.nextCheck.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium))
            Text(plan.reason).font(.system(size: 12)).foregroundStyle(Palette.muted)
            if let outcome = plan.lastOutcome { Text(outcome).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            HStack {
                Button("Check now") { model.controlCheck(plan, paused: false, pinned: false, date: Date(), deadline: max(plan.deadline, Date().addingTimeInterval(86400))) }
                Button("Change…") { changingCheck = true }
                Button(plan.paused ? "Resume" : "Pause") { model.controlCheck(plan, paused: !plan.paused, pinned: plan.pinned, date: max(plan.nextCheck, Date()), deadline: max(plan.deadline, Date().addingTimeInterval(86400))) }
            }.buttonStyle(.borderless).font(.system(size: 12)).disabled(!task.state.isOpen || model.demo)
        }.calloutCard()
    }
}

/// The rest of what can be done with a task, behind the ⋯ in its bar.
struct TaskMenu: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    @State private var editing = false
    @State private var linking = false
    @State private var addingPrerequisite = false
    @State private var parking = false
    private var completion: Decision? { model.decisions(for: task.id).first { $0.kind == "completion" } }

    var body: some View {
        Menu {
            Button("Edit task…") { editing = true }
            if task.state.isOpen { Button("Archive task") { model.archive(task) } }
            else { Button("Restore task") { model.perform { _ = try model.store.update(task.id) { $0.state = .inbox; $0.returnAt = Date() }; model.refresh(); model.showTask(try model.store.task(task.id)) } } }
            if task.state.isOpen { Button(model.wait(for: task) == nil ? "Wait until…" : "Change the wait…") { parking = true } }
            if task.state.isOpen, model.wait(for: task) != nil { Button("Wake now") { model.wake(task) } }
            if let completion { Button("Keep open") { model.answer(completion, text: "Keep open") } }
            Divider()
            if task.state.isOpen { Button("Add prerequisite…", systemImage: "link") { addingPrerequisite = true } }
            if task.state.isOpen { Button("Continue in another chat…") { linking = true } }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More task actions")
            .popover(isPresented: $parking) { WaitChoices(model: model, task: task, parked: { _, _ in }) { parking = false }.padding(6).frame(width: 290).background(Palette.paper) }
            .sheet(isPresented: $addingPrerequisite) { BlockerEditor(model: model, task: task) }
            .sheet(isPresented: $editing) { TaskEditor(model: model, original: task) }
            .sheet(isPresented: $linking) { ThreadBrowser(model: model, taskID: task.id).frame(width: 640, height: 560) }
    }
}
