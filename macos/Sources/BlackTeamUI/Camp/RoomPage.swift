import SwiftUI
import BlackTeamKit

// The Room page (Room.jsx): a team of local and cloud agents working on one project. State and calls are in RoomModel.swift.

/// What the Add row offers: an installed agent, or a saved model.
enum RoomPick: Hashable {
    case agent(AgentService)
    case model(String)
}

private extension TeamPhase {
    /// The phase in words, as the run card shows it while a run is going.
    var words: String {
        switch self {
        case .planning: return "Planning"
        case .working: return "Working"
        case .reviewing: return "Reviewing"
        case .reporting: return "Writing the report"
        case .done, .stopped, .failed: return ""
        }
    }
}

/// A select: the system menu drawn in the same chrome as the text fields.
struct RoomSelect<Value: Hashable, Options: View>: View {
    let label: String
    let selection: Binding<Value>
    @ViewBuilder let options: () -> Options
    @Environment(\.btTheme) private var theme

    var body: some View {
        Picker(label, selection: selection, content: options)
            .labelsHidden()
            .pickerStyle(.menu)
            .font(BTFont.body(12.5))
            .padding(.horizontal, 8)
            .frame(minWidth: 120, maxWidth: 240)
            .frame(height: Theme.control)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
            .accessibilityLabel(label)
    }
}

struct RoomPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var room: RoomModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        Group {
            if model.projects.isEmpty {
                Text("Start a project in the sidebar first; a room belongs to a project.").btBody(12.5, 1.6, theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    projectRow
                    if let error = room.error { BTBanner(kind: .error, message: error).padding(.bottom, 16) }
                    if let state = room.room {
                        RoomTeamCard(model: model, room: room, state: state)
                        RoomRunCard(model: model, room: room, state: state)
                        if let run = state.team { RoomLogCard(run: run) }
                        RoomBoardCard(model: model, room: room, state: state)
                    }
                }
            }
        }
        .task {
            room.load(model)
            for await _ in model.backend.changes() { room.load(model) }
        }
    }

    private var projectRow: some View {
        HStack(spacing: 10) {
            Text("Project").btBody(12, 1.5, theme.muted)
            RoomSelect(label: "Project", selection: Binding(get: { room.projectId ?? "" }, set: { room.select($0, model) })) {
                ForEach(model.projects, id: \.id) { Text($0.name).tag($0.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Team

/// TEAM: who is on the team, and the row that adds a member.
struct RoomTeamCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var room: RoomModel
    let state: RoomState
    @State private var pick: RoomPick?
    @State private var role = ""
    @State private var permission = AgentPermission.edit
    @State private var work = "code"
    @Environment(\.btTheme) private var theme

    private var agents: [AgentService] { AgentService.allCases.filter { model.agentsInstalled.contains($0) } }
    private var models: [SavedModelSummary] { model.status?.models ?? [] }
    private var options: [RoomPick] { agents.map { .agent($0) } + models.map { .model($0.key) } }
    private var chosen: RoomPick? { pick.flatMap { options.contains($0) ? $0 : nil } ?? options.first }
    private var choosesAgent: Bool { if case .agent? = chosen { return true }; return false }
    private var pickBinding: Binding<RoomPick> { Binding(get: { chosen ?? .model("") }, set: { pick = $0 }) }

    var body: some View {
        WorkCard(label: "TEAM", title: "Who is on this team") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.members, id: \.id) { member in
                    RoomMemberRow(member: member, disabled: room.busy) {
                        Task { await room.removeMember(model, memberId: member.id) }
                    }
                }
                addRow
            }
            .padding(.top, 10)
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a member").btBody(12, 1.5, theme.ink).padding(.top, 18)
            HStack(spacing: 8) {
                RoomSelect(label: "New member", selection: pickBinding) {
                    ForEach(agents, id: \.self) { Text($0.displayName).tag(RoomPick.agent($0)) }
                    ForEach(models, id: \.key) { Text($0.name).tag(RoomPick.model($0.key)) }
                }
                BTTextField("Role, for example builder or reviewer", text: $role, size: 12.5).frame(maxWidth: .infinity)
                if choosesAgent {
                    RoomSelect(label: "Member permission", selection: $permission) {
                        ForEach(AgentPermission.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                } else {
                    RoomSelect(label: "Member work", selection: $work) {
                        Text("Code").tag("code")
                        Text("Chat").tag("chat")
                    }
                }
                Button("Add") { Task { if await addMember() { role = "" } } }
                    .buttonStyle(.btPrimary)
                    .disabled(room.busy || chosen == nil)
            }
        }
    }

    private func addMember() async -> Bool {
        switch chosen {
        case .agent(let service)?:
            return await room.addMember(model, name: service.displayName, role: role, modelKey: nil, agent: service.engine,
                                        permission: permission.rawValue, work: nil)
        case .model(let key)?:
            guard let saved = models.first(where: { $0.key == key }) else { return false }
            return await room.addMember(model, name: saved.name, role: role, modelKey: key, agent: nil, permission: nil, work: work)
        case nil:
            return false
        }
    }
}

/// One member: its name and role, where it runs, and why it cannot be used now.
struct RoomMemberRow: View {
    let member: RoomMemberView
    let disabled: Bool
    let remove: () -> Void
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(member.name).font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink)
                    if !member.role.isEmpty { Text(member.role).font(BTFont.body(12)).foregroundStyle(theme.muted) }
                }
                if !member.usable { Text(member.reason).btBody(11.5, 1.5, theme.muted) }
            }
            Spacer(minLength: 0)
            BTStatusPill(text: tag, kind: member.kind == "cloud" ? .warn : .neutral, compact: true)
            Button("Remove", action: remove).buttonStyle(.btQuiet).disabled(disabled)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private var tag: String { member.kind == "cloud" ? "Cloud \u{00B7} \(member.provider)" : "Local" }
}

// MARK: - Team run

/// TEAM RUN: the goal, the lead and reviewer, the agreement to confirm, and the run's progress and report.
struct RoomRunCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var room: RoomModel
    let state: RoomState
    @State private var goal = ""
    @State private var lead: String?
    @State private var reviewer = ""
    @Environment(\.btTheme) private var theme

    private var leadId: String {
        if let lead, state.members.contains(where: { $0.id == lead }) { return lead }
        return state.members.first { $0.agent == "claude-code" }?.id ?? state.members.first?.id ?? ""
    }
    private var reviewerId: String? { state.members.contains { $0.id == reviewer } ? reviewer : nil }
    private var canRun: Bool {
        !room.running && !room.busy && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !leadId.isEmpty
    }

    var body: some View {
        WorkCard(label: "TEAM RUN", title: "Give the team a goal") {
            VStack(alignment: .leading, spacing: 12) {
                goalField
                HStack(spacing: 8) {
                    RoomSelect(label: "Lead", selection: Binding(get: { leadId }, set: { lead = $0 })) {
                        ForEach(state.members, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    RoomSelect(label: "Reviewer", selection: $reviewer) {
                        Text("No reviewer").tag("")
                        ForEach(state.members, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Spacer(minLength: 0)
                    Button("Run team") { Task { await room.previewTeam(model, goal: goal, leadId: leadId, reviewerId: reviewerId) } }
                        .buttonStyle(.btPrimary)
                        .disabled(!canRun)
                }
                if room.running, let run = state.team { progress(run) }
                if let preview = room.teamPreview, !room.running { agreement(preview) }
                if let run = state.team { outcome(run) }
            }
            .padding(.top, 4)
        }
    }

    private var goalField: some View {
        TextEditor(text: $goal)
            .font(BTFont.body(13))
            .foregroundStyle(theme.ink)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 84)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line2, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if goal.isEmpty { Text("What should the team do?").btBody(13, 1.5, theme.faint).padding(13).allowsHitTesting(false) }
            }
            .onChange(of: goal) { value in
                if value.count > TeamLimits.goal { goal = String(value.prefix(TeamLimits.goal)) }
            }
            .accessibilityLabel("Goal")
    }

    private func progress(_ run: TeamRun) -> some View {
        HStack(spacing: 12) {
            Text(run.phase.words).font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink)
            Spacer(minLength: 0)
            Button("Stop") { Task { await room.stopTeam(model) } }.buttonStyle(.btSecondary)
        }
    }

    private func agreement(_ preview: TeamPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.agreement)
                .btBody(12, 1.6, theme.ink)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
            HStack(spacing: 8) {
                Button("Start this run") { Task { await room.startTeam(model) } }.buttonStyle(.btPrimary).disabled(room.busy)
                Button("Cancel") { room.cancelTeam() }.buttonStyle(.btSecondary)
            }
        }
    }

    @ViewBuilder private func outcome(_ run: TeamRun) -> some View {
        switch run.phase {
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                Text("Report").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink)
                MarkdownView(run.report)
            }
        case .stopped:
            if !run.message.isEmpty { BTBanner(kind: .notice, message: run.message) }
        case .failed:
            if !run.message.isEmpty { BTBanner(kind: .error, message: run.message) }
        case .planning, .working, .reviewing, .reporting:
            EmptyView()
        }
    }
}

// MARK: - Team conversation

/// TEAM: what the team is doing, oldest first, newest at the bottom.
struct RoomLogCard: View {
    let run: TeamRun
    @Environment(\.btTheme) private var theme

    var body: some View {
        WorkCard(label: "TEAM", title: "What the team is doing") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(run.log.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(entry.memberName.uppercased()).font(BTFont.mono(10)).tracking(0.6).foregroundStyle(theme.ink2)
                            BTStatusPill(text: entry.kind, compact: true)
                        }
                        MarkdownView(entry.text)
                    }
                }
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - Board

/// BOARD: the four columns of tasks, and the row that adds one.
struct RoomBoardCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var room: RoomModel
    let state: RoomState
    @State private var title = ""
    @State private var assignee = ""
    @Environment(\.btTheme) private var theme

    private let columns: [RoomStatus] = [.todo, .doing, .review, .done]

    var body: some View {
        WorkCard(label: "BOARD", title: "Tasks") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(columns, id: \.self) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(heading(status)).font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink)
                            ForEach(state.tasks.filter { $0.status == status }, id: \.id) { task in
                                RoomTaskCard(model: model, room: room, state: state, task: task)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                addRow
            }
            .padding(.top, 14)
        }
    }

    private func heading(_ status: RoomStatus) -> String {
        switch status {
        case .todo: return "To do"
        case .doing: return "Doing"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var addRow: some View {
        HStack(spacing: 8) {
            BTTextField("Task title", text: $title, size: 12.5).frame(maxWidth: .infinity)
            RoomSelect(label: "Assignee", selection: $assignee) {
                Text("Unassigned").tag("")
                ForEach(state.members, id: \.id) { Text($0.name).tag($0.id) }
            }
            Button("Add") {
                Task {
                    if await room.addTask(model, title: trimmedTitle, assignee: assignee.isEmpty ? nil : assignee) { title = "" }
                }
            }
            .buttonStyle(.btPrimary)
            .disabled(room.running || room.busy || trimmedTitle.isEmpty)
        }
        .padding(.top, 6)
    }
}

/// One task: a small card that opens in place to its detail, result, note and the actions for its status.
struct RoomTaskCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var room: RoomModel
    let state: RoomState
    let task: RoomTask
    @State private var open = false
    @State private var sendingBack = false
    @State private var note = ""
    @State private var handOpen = false
    @State private var receiver = ""
    @Environment(\.btTheme) private var theme

    private var assigneeName: String {
        task.assignee.flatMap { id in state.members.first { $0.id == id }?.name } ?? "Unassigned"
    }
    private var others: [RoomMemberView] { state.members.filter { $0.id != task.assignee } }
    private var previewing: HandOffPreview? { room.handOff?.taskId == task.id ? room.handOff : nil }
    private var locked: Bool { room.running || room.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: { summary }
                .buttonStyle(.plain)
                .accessibilityLabel(task.title)
            if open { details }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title).font(BTFont.body(12, .semibold)).foregroundStyle(theme.ink).frame(maxWidth: .infinity, alignment: .leading)
            Text(assigneeName).btBody(11, 1.4, theme.muted)
            if let changed = task.changed { Text("\(changed) files changed").font(BTFont.mono(10)).foregroundStyle(theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !task.detail.isEmpty { Text(task.detail).btBody(11.5, 1.6, theme.muted).textSelection(.enabled) }
            if !task.result.isEmpty { MarkdownView(task.result) }
            if !task.note.isEmpty { Text("Note: \(task.note)").btBody(11.5, 1.6, theme.ink2).textSelection(.enabled) }
            actions
            if let preview = previewing { handOffBox(preview) }
        }
        .padding(.top, 10)
    }

    @ViewBuilder private var actions: some View {
        if task.status == .todo, task.assignee != nil {
            Button("Start") { Task { await room.start(model, taskId: task.id) } }
                .buttonStyle(.btPrimary)
                .disabled(locked)
        }
        if task.status == .review {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Accept") { Task { await room.accept(model, taskId: task.id) } }.buttonStyle(.btPrimary).disabled(locked)
                    if !sendingBack {
                        Button("Send back") { sendingBack = true; handOpen = false }.buttonStyle(.btSecondary).disabled(locked)
                    }
                    Button("Hand to\u{2026}") { handOpen.toggle() }.buttonStyle(.btSecondary).disabled(locked)
                }
                if sendingBack { sendBackRow }
                if handOpen, previewing == nil { handPicker }
            }
        }
    }

    private var sendBackRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            BTTextField("Note for the member", text: $note, size: 12.5)
            HStack(spacing: 8) {
                Button("Send back") {
                    Task {
                        if await room.sendBack(model, taskId: task.id, note: note) { sendingBack = false; note = "" }
                    }
                }
                .buttonStyle(.btPrimary)
                .disabled(locked)
                Button("Cancel") { sendingBack = false; note = "" }.buttonStyle(.btSecondary)
            }
        }
    }

    private var handPicker: some View {
        RoomSelect(label: "Hand to", selection: Binding(get: { receiver }, set: { receiver = $0 })) {
            Text("Choose a member").tag("")
            ForEach(others, id: \.id) { Text($0.name).tag($0.id) }
        }
        .onChange(of: receiver) { id in
            if !id.isEmpty { Task { await room.previewHandOff(model, taskId: task.id, to: id) } }
        }
    }

    private func handOffBox(_ preview: HandOffPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.text)
                .font(BTFont.mono(11))
                .foregroundStyle(theme.ink2)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
            if preview.leavesThisMac {
                Text("This leaves this Mac and goes to \(preview.provider).").btBody(11.5, 1.5, theme.warn)
            }
            HStack(spacing: 8) {
                Button("Hand over") {
                    Task {
                        await room.handOver(model)
                        handOpen = false
                        receiver = ""
                    }
                }
                .buttonStyle(.btPrimary)
                .disabled(locked)
                Button("Cancel") {
                    room.cancelHandOff()
                    handOpen = false
                    receiver = ""
                }
                .buttonStyle(.btSecondary)
            }
        }
    }
}
