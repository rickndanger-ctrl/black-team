import Foundation

// The routes the window uses for a Code run's controls and for skills: pause and resume, the ceilings and switches, and the skills list on
// the Memory page. Desktop only. Every rule is the Backend's (App/BackendCode.swift) or the SkillStore's; this adds none.

final class CodeRoutes: @unchecked Sendable {
    let backend: Backend
    init(_ backend: Backend) { self.backend = backend }

    static func claims(_ path: String) -> Bool {
        path == "/api/pause" || path == "/api/resume" || path.hasPrefix("/api/code/") || path == "/api/skills" || path.hasPrefix("/api/skills/")
    }

    private func input(_ head: HTTPHead, _ body: Data) throws -> [String: JSONValue] {
        guard (head.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { throw HTTPFailure("Send JSON.", 415) }
        guard let value = try? JSONValue.parse(body), let object = value.object else { throw HTTPFailure("Invalid JSON request.") }
        return object
    }

    private func workspace(_ head: HTTPHead) -> String? {
        guard let id = head.queryValue("thread"), let thread = backend.thread(id) else { return nil }
        if let project = backend.projects.first(where: { $0.id == thread["project"]?.string }) { return project.workspace }
        return try? backend.configStore.read().workspace
    }

    func handle(_ head: HTTPHead, body: Data, access: DesktopAccess) async throws -> HTTPResponse? {
        guard Self.claims(head.path) else { return nil }
        try access.requireDesktopHTTP()
        do {
            switch (head.method, head.path) {
            case ("POST", "/api/pause"): return .json(200, ["paused": .bool(backend.pause())])
            case ("POST", "/api/resume"): return .json(200, ["resumed": .bool(backend.resume())])
            case ("GET", "/api/code/settings"): return .json(200, backend.codeSettingsView(thread: head.queryValue("thread")))
            case ("POST", "/api/code/settings"): return .json(200, try backend.changeCodeSettings(try input(head, body)))
            case ("GET", "/api/skills"): return .json(200, backend.skillsView(workspace: workspace(head)))
            case ("GET", "/api/skills/view"):
                let name = head.queryValue("name") ?? ""
                return .json(200, ["name": .string(name), "text": .string(try backend.skills.text(name, workspace: workspace(head)))])
            case ("POST", "/api/skills/save"):
                let given = try input(head, body)
                try backend.skills.write(given["name"]?.string ?? "", text: given["text"]?.string ?? "")
                return .json(200, backend.skillsView())
            case ("POST", "/api/skills/remove"):
                try backend.skills.remove(try input(head, body)["name"]?.string ?? "")
                return .json(200, backend.skillsView())
            case ("POST", "/api/skills/enable"):
                let given = try input(head, body)
                guard let on = given["on"]?.bool else { throw BlackTeamError("Say whether the skill is on or off.") }
                try backend.skills.setEnabled(given["name"]?.string ?? "", on)
                return .json(200, backend.skillsView())
            default: throw HTTPFailure("Not found.", 404)
            }
        } catch let failure as HTTPFailure {
            throw failure
        } catch let known as BlackTeamError {
            throw HTTPFailure(known.message, PhoneRouter.submitStatus(known.message))
        }
    }
}
