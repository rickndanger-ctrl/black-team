import SwiftUI
import BlackTeamKit

// The Room page's state: which project is shown, its room, the previews waiting for a yes, and the last error.
// Every call goes to the Backend on the main actor, as AppModel's own calls do. Errors stay here and show on the page.

@MainActor
final class RoomModel: ObservableObject {
    /// The project whose room is shown.
    @Published private(set) var projectId: String?
    @Published private(set) var room: RoomState?
    @Published var error: String?
    /// True while one call to the Backend is in flight.
    @Published private(set) var busy = false
    /// The team run's agreement, waiting for "Start this run".
    @Published var teamPreview: TeamPreview?
    /// The hand-off preview, waiting for "Hand over".
    @Published var handOff: HandOffPreview?

    /// A team run is going: planning, working, reviewing or reporting.
    var running: Bool { room?.team.map { !$0.phase.finished } ?? false }

    /// Reads the shown project's room. The first project is shown until another is chosen.
    func load(_ app: AppModel) {
        let ids = app.projects.map(\.id)
        let id = projectId.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        if projectId != id { projectId = id }
        guard let id else {
            if room != nil { room = nil }
            return
        }
        do {
            let next = try app.backend.room(projectId: id)
            if next != room { room = next }
        } catch {
            room = nil
            self.error = plainMessage(error)
        }
    }

    func select(_ id: String, _ app: AppModel) {
        guard id != projectId else { return }
        projectId = id
        teamPreview = nil
        handOff = nil
        error = nil
        load(app)
    }

    /// One call to the Backend. Its error shows on the page, and the room is read again either way.
    private func call<T>(_ app: AppModel, _ work: (String) async throws -> T) async -> T? {
        guard !busy, let id = projectId else { return nil }
        busy = true
        error = nil
        defer {
            busy = false
            load(app)
        }
        do { return try await work(id) } catch {
            self.error = plainMessage(error)
            return nil
        }
    }

    // MARK: Team

    func addMember(_ app: AppModel, name: String, role: String, modelKey: String?, agent: String?, permission: String?, work: String?) async -> Bool {
        await call(app) { id in
            try app.backend.roomAddMember(projectId: id, name: name, role: role, modelKey: modelKey, agent: agent, permission: permission, work: work)
        } != nil
    }

    func removeMember(_ app: AppModel, memberId: String) async {
        _ = await call(app) { id in try app.backend.roomRemoveMember(projectId: id, memberId: memberId) }
    }

    func previewTeam(_ app: AppModel, goal: String, leadId: String, reviewerId: String?) async {
        if let next = await call(app, { id in try app.backend.roomTeamPreview(projectId: id, goal: goal, leadId: leadId, reviewerId: reviewerId) }) {
            teamPreview = next
        }
    }

    /// Starts the run that was previewed. The digest makes the Backend refuse if the team or the plan changed since.
    func startTeam(_ app: AppModel) async {
        guard let preview = teamPreview else { return }
        let started = await call(app) { id in
            try app.backend.roomTeamRun(projectId: id, goal: preview.goal, leadId: preview.leadId, reviewerId: preview.reviewerId, digest: preview.digest)
        }
        if started != nil { teamPreview = nil }
    }

    func cancelTeam() {
        teamPreview = nil
    }

    func stopTeam(_ app: AppModel) async {
        _ = await call(app) { id in try app.backend.roomTeamStop(projectId: id) }
    }

    // MARK: Board

    func addTask(_ app: AppModel, title: String, assignee: String?) async -> Bool {
        await call(app) { id in try app.backend.roomAddTask(projectId: id, title: title, detail: "", assignee: assignee) } != nil
    }

    func start(_ app: AppModel, taskId: String) async {
        _ = await call(app) { id in try await app.backend.roomStart(projectId: id, taskId: taskId) }
    }

    func accept(_ app: AppModel, taskId: String) async {
        _ = await call(app) { id in try app.backend.roomAccept(projectId: id, taskId: taskId) }
    }

    func sendBack(_ app: AppModel, taskId: String, note: String) async -> Bool {
        await call(app) { id in try app.backend.roomSendBack(projectId: id, taskId: taskId, note: note) } != nil
    }

    func previewHandOff(_ app: AppModel, taskId: String, to receiverId: String) async {
        if let next = await call(app, { id in try app.backend.roomHandOffPreview(projectId: id, taskId: taskId, to: receiverId) }) {
            handOff = next
        }
    }

    /// Hands over the previewed text. The arguments are the preview's own, so what is sent is what was shown.
    func handOver(_ app: AppModel) async {
        guard let preview = handOff else { return }
        let done = await call(app) { id in
            try app.backend.roomHandOff(projectId: id, taskId: preview.taskId, to: preview.receiverId, title: preview.title, detail: preview.detail,
                                        includeResult: preview.includesResult, digest: preview.digest)
        }
        if done != nil { handOff = nil }
    }

    func cancelHandOff() {
        handOff = nil
    }
}
