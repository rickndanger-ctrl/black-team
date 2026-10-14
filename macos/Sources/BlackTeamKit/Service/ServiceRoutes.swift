import Foundation

// The HTTP routes of the background service, on the same loopback server and behind the same checks as every other route
// (Phone/PhoneRouter.swift: loopback peer, Host, Origin on changes, and the window's session cookie; a paired phone has its own cookie).
//
//   GET  /api/service/ping        who answers (the window and the command check the version and the secret with it)
//   GET  /api/service             the service's state, settings, helpers and the unit's state
//   POST /api/service/install     turn "keep running in the background" on (writes the per-user unit)
//   POST /api/service/uninstall   turn it off (removes exactly what install wrote)
//   POST /api/service/settings    idle minutes, hours a question waits, runs a day
//   GET  /api/service/logs        the last lines the service wrote
//   POST /api/service/control     one action of the window's control channel (this is how a window attached to the service asks for things)
//   GET  /api/schedules           the schedules (a phone may read them)
//   POST /api/schedules/save | remove | pause | run | parse
//   GET  /api/inbox               what waits for an answer (a phone may read it)
//   POST /api/inbox/answer        {id, choice: "approve" | "deny"} (a phone may answer, as it may answer any approval)
//
// Everything except the three phone routes is the desktop's: a phone is refused with the usual words.

final class ServiceRoutes: @unchecked Sendable {
    let hooks: ServiceHooks
    let backend: Backend

    init(_ hooks: ServiceHooks, _ backend: Backend) { self.hooks = hooks; self.backend = backend }

    static func owns(_ path: String) -> Bool {
        path == "/api/service" || path.hasPrefix("/api/service/") || path == "/api/schedules" || path.hasPrefix("/api/schedules/") || path == "/api/inbox" || path.hasPrefix("/api/inbox/")
    }

    func handle(_ head: HTTPHead, body: Data, who: DesktopAccess) async throws -> HTTPResponse {
        let path = head.path, method = head.method
        do {
            switch (method, path) {
            case ("GET", "/api/schedules"): return .json(200, hooks.schedulesJSON())
            case ("GET", "/api/inbox"): return .json(200, hooks.inboxJSON())
            case ("POST", "/api/inbox/answer"):
                let input = try json(head, body)
                guard let id = input["id"]?.string, let choice = input["choice"]?.string, ["approve", "deny"].contains(choice) else { throw BlackTeamError("Choose Approve or Deny.") }
                // A gate that may use paid agents is answered on the computer, never from a phone.
                if who != .desktop, hooks.inbox.get(id)?.desktopOnly == true { throw HTTPFailure("Answer this one on the computer: it may use paid agents, which a phone cannot start.", 403) }
                try hooks.answer(id, approve: choice == "approve")
                return .json(200, hooks.inboxJSON())
            default: break
            }
            try who.requireDesktopHTTP()
            switch (method, path) {
            case ("GET", "/api/service/ping"):
                return .json(200, ["ok": true, "protocol": .number(Double(ServiceConnection.currentProtocol)), "version": .string(backend.version),
                                   "pid": .number(Double(getpid())), "dataFolder": .string(backend.dataFolder), "mode": .string(hooks.mode.rawValue)])
            case ("GET", "/api/service"): return .json(200, await hooks.stateJSON())
            case ("POST", "/api/service/install"):
                _ = try await hooks.manager.install()
                return .json(200, await hooks.stateJSON())
            case ("POST", "/api/service/uninstall"):
                _ = try await hooks.manager.uninstall()
                return .json(200, await hooks.stateJSON())
            case ("POST", "/api/service/settings"):
                let input = try json(head, body)
                var settings = hooks.settings.read()
                if let value = input["idleMinutes"]?.int { settings.idleMinutes = value }
                if let value = input["approvalHours"]?.int { settings.approvalHours = value }
                if let value = input["maxRunsPerDay"]?.int { settings.maxRunsPerDay = value }
                try hooks.settings.save(settings)
                return .json(200, await hooks.stateJSON())
            case ("GET", "/api/service/logs"):
                let lines = head.queryValue("lines").flatMap { Int($0) } ?? 100
                return .json(200, ["text": .string(await hooks.manager.logs(lines: lines))])
            case ("POST", "/api/service/control"):
                // The window\u{2019}s main process (and nothing in its page) holds the control key from the private connection file.
                guard let key = hooks.controlKey, phoneEqual(head.headers["x-black-team-control"], key) else { throw HTTPFailure("Desktop action is unavailable.", 403) }
                let input = try json(head, body)
                guard let action = input["action"]?.string, input["data"].map({ $0.object != nil || $0 == .null }) ?? true else { throw BlackTeamError("Invalid desktop request.") }
                guard let control = hooks.control else { throw BlackTeamError("The service is not ready.") }
                let result = try await control.handle(action, input["data"].flatMap { $0 == .null ? nil : $0 })
                return .json(200, ["ok": true, "result": result])
            case ("POST", "/api/schedules/save"):
                return .json(200, try hooks.saveSchedule(try json(head, body)))
            case ("POST", "/api/schedules/remove"):
                guard let id = try json(head, body)["id"]?.string else { throw BlackTeamError("That schedule no longer exists.") }
                try hooks.schedules.remove(id)
                return .json(200, hooks.schedulesJSON())
            case ("POST", "/api/schedules/pause"):
                let input = try json(head, body)
                guard let id = input["id"]?.string else { throw BlackTeamError("That schedule no longer exists.") }
                _ = try hooks.schedules.setEnabled(id, !(input["paused"]?.bool ?? true))
                return .json(200, hooks.schedulesJSON())
            case ("POST", "/api/schedules/run"):
                guard let id = try json(head, body)["id"]?.string else { throw BlackTeamError("That schedule no longer exists.") }
                try hooks.runSchedule(id)
                return .json(200, hooks.schedulesJSON())
            case ("POST", "/api/schedules/parse"):
                return .json(200, try hooks.previewWhen(try json(head, body)["text"]?.string ?? ""))
            default:
                throw HTTPFailure("Not found.", 404)
            }
        } catch let failure as HTTPFailure { throw failure }
        catch let known as BlackTeamError { throw HTTPFailure(known.message, 400) }
        catch { throw HTTPFailure("That could not be done.") }
    }

    private func json(_ head: HTTPHead, _ body: Data) throws -> [String: JSONValue] {
        guard (head.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { throw HTTPFailure("Send JSON.", 415) }
        guard let value = try? JSONValue.parse(body), let object = value.object else { throw HTTPFailure("Invalid JSON request.") }
        return object
    }
}
