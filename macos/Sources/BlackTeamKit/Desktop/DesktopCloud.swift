import Foundation

// The control channel's actions for cloud models and subscription agents. Each one calls the Backend method the Mac app calls, with the
// same checks and wording; none of them decides anything about privacy (App/BackendCloud.swift does, for every send).
//
//   cloud-discover  ask a service which models it offers (also how a connection is tested)   Backend.discoverCloud
//   cloud-save      save a cloud model with its own key and make it the one in use            Backend.saveSetup
//   project-cloud   allow or stop cloud models in one project                                 Backend.setProjectCloud
//   agents-status   which subscription agents are installed, and the version check            Backend.agentInstalled / agentUpdateStatus
//   agent-signin    open the agent's own sign-in in the person's terminal                     Backend.openAgentSignIn
//   agent-update    open the agent's own update in the person's terminal                      Backend.openAgentUpdate
//
// A key travels one way: in `cloud-save` / `cloud-discover` from the window to the engine. No answer, status, log or error carries it.

extension DesktopControl {
    private func agent(_ input: [String: JSONValue]) throws -> AgentService {
        guard let service = AgentService.forEngine(input["engine"]?.string) else { throw BlackTeamError("The agent is claude-code or codex.") }
        return service
    }

    static func agentJSON(_ service: AgentService, installed: Bool, update: AgentUpdateStatus? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["engine": .string(service.engine), "name": .string(service.displayName), "provider": .string(service.provider),
                                           "program": .string(service.program), "installed": .bool(installed)]
        if let update {
            object["installedVersion"] = update.installed.map { .string($0) } ?? .null
            object["latestVersion"] = update.latest.map { .string($0) } ?? .null
            object["updateAvailable"] = .bool(update.updateAvailable)
        }
        return .object(object)
    }

    func cloudRead(_ action: String, _ input: [String: JSONValue], _ unsupported: ([String], String) throws -> Void) async throws -> JSONValue {
        switch action {
        case "cloud-discover":
            try unsupported(["endpoint", "apiKey"], "Unsupported cloud setting.")
            // No key sent (or null): the saved one is used when the address is still the saved model's own host. A key that is not text is refused.
            var key: String?
            if let given = input["apiKey"], given != .null { key = given.string ?? "\u{1}" }
            let found = try await backend.discoverCloud(endpoint: input["endpoint"]?.string ?? "", apiKey: key)
            let models = found.models.map { model -> JSONValue in
                ["id": .string(model.id), "context": model.context.map { .number(Double($0)) } ?? .null, "free": .bool(model.free),
                 "tools": model.tools.map { .bool($0) } ?? .null, "freeAgent": .bool(model.freeAgent)]
            }
            return ["endpoint": .string(found.endpoint), "host": .string(found.host), "models": .array(models)]
        default:   // agents-status
            try unsupported(["engine", "versions"], "Unsupported agent setting.")
            let services = input["engine"] == nil ? AgentService.allCases : [try agent(input)]
            let check = input["versions"]?.bool ?? true
            var rows: [JSONValue] = []
            for service in services {
                let installed = backend.agentInstalled(service)
                // The version check runs the tool's `--version` and asks the registry; only for a tool that is installed, and only when asked.
                let update = installed && check ? await backend.agentUpdateStatus(service: service) : nil
                rows.append(Self.agentJSON(service, installed: installed, update: update))
            }
            return ["agents": .array(rows)]
        }
    }

    func cloudChange(_ action: String, _ input: [String: JSONValue], _ unsupported: ([String], String) throws -> Void) async throws -> JSONValue {
        switch action {
        case "cloud-save":
            try unsupported(["endpoint", "id", "apiKey", "name", "context", "workspace"], "Unsupported cloud setting.")
            // Exactly what the Mac's cloud form saves. Without `apiKey` the saved key is kept when the host is unchanged, else cleared.
            var model: [String: JSONValue] = ["source": "cloud"]
            for field in ["endpoint", "id", "apiKey", "context"] { if let value = input[field] { model[field] = value } }
            let id = input["id"]?.string ?? ""
            let name = input["name"]?.string.map { EText.trim($0) } ?? ""
            model["name"] = .string(String((name.isEmpty ? id : name).prefix(120)))
            var form: [String: JSONValue] = ["model": .object(model)]
            if let workspace = input["workspace"] { form["workspace"] = workspace }
            let saved = try await backend.saveSetup(.object(form))
            var object: [String: JSONValue] = ["saved": .bool(saved.saved), "cloud": .encoded(try await backend.status().cloud)]
            if let warning = saved.warning { object["warning"] = .string(warning) }
            return .object(object)
        case "project-cloud":
            try unsupported(["id", "allowed", "confirmed"], "Unsupported project setting.")
            guard let id = input["id"]?.string, let allowed = input["allowed"]?.bool else { throw BlackTeamError("Choose a project and whether it may use cloud models.") }
            return .encoded(try backend.setProjectCloud(id, allowed: allowed, confirmed: input["confirmed"]?.bool ?? false))
        case "agent-signin":
            try unsupported(["engine"], "Unsupported agent setting.")
            let service = try agent(input)
            try await backend.openAgentSignIn(service: service)
            return ["opened": true, "name": .string(service.displayName)]
        default:   // agent-update
            try unsupported(["engine"], "Unsupported agent setting.")
            let service = try agent(input)
            try await backend.openAgentUpdate(service: service)
            return ["opened": true, "name": .string(service.displayName)]
        }
    }
}
