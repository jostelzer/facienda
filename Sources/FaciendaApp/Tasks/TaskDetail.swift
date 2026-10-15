import SwiftUI
import FaciendaCore

/// One task's reading pane: what is under way, its decisions, prerequisites and details, then its actions.
/// There is no reply box: telling the agent something belongs to the task's choices on the board.
struct TaskDetail: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    @State private var editing = false
    @State private var linking = false
    @State private var addingPrerequisite = false
    @State private var parking = false
    @State private var changingCheck = false
    private var plan: CheckPlan? { model.checkPlan(for: task.id) }
    private var links: [ThreadLink] { model.links(for: task.id) }
    private var decisions: [Decision] { model.decisions(for: task.id) }
    private var completion: Decision? { decisions.first { $0.kind == "completion" } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                readingContent.padding(.horizontal, 24).padding(.vertical, 16)
            }
            taskActions.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
        }
            .sheet(isPresented: $addingPrerequisite) { BlockerEditor(model: model, task: task) }
            .sheet(isPresented: $changingCheck) { if let plan { CheckEditor(model: model, plan: plan) } }
            .sheet(isPresented: $editing) { TaskEditor(model: model, original: task) }
            .sheet(isPresented: $linking) { ThreadBrowser(model: model, taskID: task.id).frame(width: 640, height: 560) }
            .task(id: "\(task.id):\(model.connected):\(model.resultLink(for: task)?.id ?? "")") { await model.loadConversation(for: task) }
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
            details
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

    private var details: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 14) {
                detail("Original request", task.title)
                if !task.intention.isEmpty { detail("Context", task.intention) }
                if !task.definitionOfDone.isEmpty { detail("Done when", task.definitionOfDone) }
                if task.state.isOpen { detail("Next action", task.nextAction) }
                ForEach(links) { link in
                    HStack {
                        Button(link.title.isEmpty ? link.provider.name + " chat" : link.title) { model.openThread(link.threadId) }.buttonStyle(.borderless)
                        Spacer()
                        Text(link.lastKnownStatus).foregroundStyle(Palette.muted)
                    }.font(.system(size: 11))
                    .contextMenu {
                        if link.role != "work" && task.state.isOpen {
                            Button("Make this the task's chat") {
                                let chat = link.provider == .claude ? ClaudeDesktop.session(id: link.threadId)?.chat
                                    : ChatCandidate(threadId: link.threadId, provider: .codex, title: link.title)
                                if let chat { model.handOver(chat, taskID: task.id) } else { model.error = "The Claude app no longer has this session." }
                            }
                        }
                    }
                }
                if !model.timeline.isEmpty {
                    DisclosureGroup("Activity") {
                        ForEach(model.timeline.prefix(12)) { event in
                            HStack {
                                Text(event.kind.replacingOccurrences(of: ".", with: " ").capitalized)
                                Spacer()
                                Text(event.at, format: .dateTime.day().month().hour().minute())
                            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.vertical, 3)
                        }
                    }
                }
            }.padding(.top, 10)
        }.font(.system(size: 11)).foregroundStyle(Palette.muted)
    }

    private var taskActions: some View {
        HStack(spacing: 6) {
            if task.state == .inbox && links.isEmpty && model.pendingDispatch(for: task.id) == nil {
                Button("Start", systemImage: "play") { Task { await model.dispatch(task) } }
                    .buttonStyle(QuietButton(prominent: true, compact: true)).disabled(model.demo)
            }
            if task.state.isOpen {
                Button("Mark done", systemImage: "checkmark") { model.complete(task) }
                    .buttonStyle(QuietButton(compact: true))
            }
            if let link = model.resultLink(for: task) ?? links.last {
                Button("Open in \(link.provider.name)", systemImage: "arrow.up.right") { model.openThread(link.threadId) }
                    .buttonStyle(QuietButton(compact: true))
            } else if let pending = model.pendingDispatch(for: task.id), pending.awaitsClaudeSend {
                Button("Open in Claude", systemImage: "arrow.up.right") { model.openInClaude(pending) }
                    .buttonStyle(QuietButton(compact: true))
            }
            // A chat the request or the answer links to: the task can carry on there instead.
            if let chat = model.linkedChats(for: task).first {
                Button(chat.title.isEmpty ? "Continue in linked chat" : "Continue in “\(chat.title)”", systemImage: "arrow.triangle.swap") { model.handOver(chat, taskID: task.id) }
                    .buttonStyle(QuietButton(compact: true)).lineLimit(1).disabled(model.demo)
                    .help("\(chat.provider.name) chat. It becomes this task's chat: your replies and checks go there from now on.")
                    .task(id: chat.threadId) { await model.lookUpLinkedChatTitles(for: task) }
            }
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
                Image(systemName: "ellipsis").frame(width: 24, height: 32)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More task actions")
                .popover(isPresented: $parking) { WaitChoices(model: model, task: task, parked: { _, _ in }) { parking = false }.padding(6).frame(width: 290).background(Palette.paper) }
            Spacer(minLength: 0)
        }
    }

    private func detail(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            ResultText(model: model, text: text)
        }
    }
}

/// A task beside the board, at the window's right edge: its state, name and everything `TaskDetail` holds.
/// The board stays live beside it, so another row's Details swaps the task in place.
struct TaskPanel: View {
    @Bindable var model: AppModel
    let task: FaciendaTask
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TaskStatusBadge(status: model.status(for: task))
                    Spacer(minLength: 0)
                    TaskAgentLabel(model: model, task: task)
                    Text(task.updatedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .help("Last updated " + task.updatedAt.formatted(date: .complete, time: .shortened))
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                        .keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close task")
                }
                Text(task.displayName).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            TaskDetail(model: model, task: task).id(task.id)
        }
        .frame(width: 440).frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.firmLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
        .padding([.vertical, .trailing], 12)
    }
}
