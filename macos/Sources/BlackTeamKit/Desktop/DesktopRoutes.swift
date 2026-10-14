import Foundation

// The HTTP routes the Linux desktop window uses for what it shows and polls beyond the phone's surface: sending with a subscription
// agent or pictures, the privacy question and its answers, rolling back an agent task, pictures, and the room. They exist only on the
// desktop service (the router is given this object only when it has a desktop session); the Mac app's phone server never has them.
//
// Every privacy decision is the Backend's (App/BackendCloud.swift): these routes call `submit`, `submitAgentTask`, `privacyCheck`,
// `agentPrivacyCheck` and `convertToCloud`, passing who is asking, and add no rule of their own except "a phone may not".

/// Pictures uploaded and prepared but not yet sent. Kept in memory only; the files are written by `submit` when the message is sent.
final class StagedImages: @unchecked Sendable {
    static let limit = 8
    static let lifetime: TimeInterval = 30 * 60
    private let lock = NSLock()
    private var items: [(id: String, upload: ImageUpload, at: Date)] = []

    func add(_ upload: ImageUpload, now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
        if items.count >= Self.limit { items.removeFirst(items.count - Self.limit + 1) }
        let id = UUID().uuidString.lowercased()
        items.append((id, upload, now))
        return id
    }

    func get(_ id: String, now: Date = Date()) -> ImageUpload? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.id == id && now.timeIntervalSince($0.at) <= Self.lifetime }?.upload
    }

    func remove(_ ids: [String]) {
        lock.lock(); items.removeAll { ids.contains($0.id) }; lock.unlock()
    }
}

final class DesktopRoutes: @unchecked Sendable {
    let backend: Backend
    let staged = StagedImages()
    /// The biggest picture the window may upload before it is prepared (ImageRules.maxSourceBytes).
    static let imageUploadLimit = ImageRules.maxSourceBytes + 1024

    init(_ backend: Backend) { self.backend = backend }

    // MARK: Entry

    /// Nil when the request is not one of these routes (the router carries on with its own).
    func handle(_ head: HTTPHead, body: Data, access: PhoneAccess) async throws -> HTTPResponse? {
        let path = head.path, method = head.method
        let who: DesktopAccess = access == .desktop ? .desktop : .phone
        if CodeRoutes.claims(path) { return try await CodeRoutes(backend).handle(head, body: body, access: who) }
        switch (method, path) {
        case ("POST", "/api/chat"): return try await mine { try self.chat(try self.json(head, body), who) }
        case ("GET", "/api/privacy"): return try await mine { try self.privacy(head, who) }
        case ("GET", "/api/runtime/approval"):
            // Would starting the model first need a yes to stop another model server? Asking stops nothing.
            try who.requireDesktopHTTP()
            return try await mine { .json(200, ["approval": .encoded(try await self.backend.startApproval())]) }
        case ("POST", "/api/runtime/approve"):
            try who.requireDesktopHTTP()
            return try await mine {
                let input = try self.json(head, body)
                guard let pid = input["pid"]?.double, pid.rounded() == pid, pid > 0, pid < 4_194_305 else { throw BlackTeamError("Choose the model to stop from the question that was asked.") }
                return .json(200, .encoded(try await self.backend.approveStop(pid: Int(pid))))
            }
        case ("POST", "/api/runtime/decline"):
            try who.requireDesktopHTTP()
            return try await mine { await self.backend.declineStop(); return .json(200, ["declined": true]) }
        case ("POST", "/api/privacy/convert"):
            try who.requireDesktopHTTP()
            return try await mine { try self.convert(try self.json(head, body)) }
        case ("POST", "/api/agent/rollback"):
            try who.requireDesktopHTTP()
            return try await mine { try self.rollback(try self.json(head, body)) }
        case ("POST", "/api/image"):
            try who.requireDesktopHTTP(DesktopRefusal.pictures)
            return try await mine { try await self.upload(head, body) }
        case ("POST", "/api/image/discard"):
            try who.requireDesktopHTTP(DesktopRefusal.pictures)
            return try await mine {
                let input = try self.json(head, body)
                if let ids = input["ids"]?.array { self.staged.remove(ids.compactMap { $0.string }) }
                return .json(200, ["discarded": true])
            }
        case ("GET", _) where path.hasPrefix("/api/image/"):
            try who.requireDesktopHTTP(DesktopRefusal.pictures)
            return try await mine { try self.image(String(path.dropFirst("/api/image/".count))) }
        case ("GET", _) where path.hasPrefix("/api/thread/"):
            // The desktop sees pictures and the agent's level; a phone gets the phone view from the router.
            guard who == .desktop else { return nil }
            guard let view = desktopThread(String(path.dropFirst("/api/thread/".count))) else { throw HTTPFailure("Conversation not found.", 404) }
            return .json(200, view)
        default: break
        }
        if path == "/api/room" || path.hasPrefix("/api/room/") {
            try who.requireDesktopHTTP()
            return try await mine { try await self.room(head, body) }
        }
        return nil
    }

    // MARK: Plumbing

    private func json(_ head: HTTPHead, _ body: Data) throws -> [String: JSONValue] {
        guard (head.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { throw HTTPFailure("Send JSON.", 415) }
        guard let value = try? JSONValue.parse(body), let object = value.object else { throw HTTPFailure("Invalid JSON request.") }
        return object
    }

    /// Errors meant for the person (BlackTeamError) keep their words; anything else is not shown.
    private func mine(_ work: () async throws -> HTTPResponse) async throws -> HTTPResponse {
        do { return try await work() }
        catch let failure as HTTPFailure { throw failure }
        catch let known as BlackTeamError { throw HTTPFailure(known.message, PhoneRouter.submitStatus(known.message)) }
        catch { throw HTTPFailure("That could not be done.") }
    }

    private func string(_ input: [String: JSONValue], _ key: String) throws -> String? {
        switch input[key] {
        case .none, .some(.null): return nil
        case .some(.string(let value)): return value
        default: throw BlackTeamError("Invalid request.")
        }
    }

    // MARK: Conversation view

    /// What the desktop reads of a conversation: the phone's view, with pictures kept and the agent's level and project added.
    func desktopThread(_ id: String) -> JSONValue? {
        guard var view = backend.thread(id) else { return nil }
        let saved = backend.history.get(id)
        if let project = saved?["project"]?.string { view = view.setting("project", .string(project)) }
        if saved?["engine"]?.string.flatMap({ AgentService.forEngine($0) }) != nil {
            view = view.setting("agentPermission", .string(AgentPermission.of(thread: saved).rawValue))
        }
        return view
    }

    // MARK: Sending

    /// `POST /api/chat`. The same fields and refusals as the phone route, plus `agent`, `permission` and `images` for the desktop.
    private func chat(_ input: [String: JSONValue], _ who: DesktopAccess) throws -> HTTPResponse {
        func text(_ key: String, fallback: String? = nil) -> String? {
            switch input[key] {
            case .some(.string(let value)): return value.isEmpty ? fallback : value
            case .none, .some(.null), .some(.bool(false)): return fallback
            default: return "\u{0}"
            }
        }
        let message: String
        if case .string(let value)? = input["message"] { message = value } else { message = "" }
        var requestId = ""
        if case .string(let value)? = input["requestId"] { requestId = value }
        let project: String?
        switch input["project"] {
        case .none, .some(.null): project = nil
        case .some(.string(let value)): project = value
        default: project = "\u{0}"
        }
        let origin: SubmitOrigin = who == .desktop ? .mac : .phone
        let threadId = text("threadId")
        let agentName = text("agent")
        let permission = text("permission")
        let hasImages: Bool = { if case .array(let list)? = input["images"] { return !list.isEmpty }; return input["images"] != nil && input["images"] != .null }()

        // A phone may continue conversations; it never picks an agent, a level or pictures.
        if who == .phone {
            if permission != nil { throw HTTPFailure(DesktopRefusal.agentPermission, 403) }
            if hasImages { throw HTTPFailure(DesktopRefusal.pictures, 403) }
        }
        if let agentName {
            guard let service = AgentService.forEngine(agentName) else { throw HTTPFailure("The agent is claude-code or codex.", 400) }
            if who == .phone {
                // The gate's own words: a phone does not start a conversation with an agent, and does not continue one here either.
                let check = backend.agentPrivacyCheck(service: service, threadId: threadId, project: project, viaPhone: true)
                if let refusal = check.refusal { throw HTTPFailure(refusal, 403) }
                throw HTTPFailure(agentConversationRefusal(service), 400)
            }
            if hasImages { throw HTTPFailure(ImageRules.codeRefusal, 400) }
            var level: AgentPermission?
            if let permission {
                guard let known = AgentPermission(rawValue: permission) else { throw HTTPFailure("Permission is ask, edit or auto.", 400) }
                level = known
            }
            do {
                let result = try backend.submitAgentTask(service: service, message: message, requestId: requestId, threadId: threadId, project: project,
                                                         permission: level, from: origin)
                return .json(202, .encoded(result))
            } catch let known as BlackTeamError { throw HTTPFailure(known.message, PhoneRouter.submitStatus(known.message)) }
        }
        if permission != nil { throw HTTPFailure("Permission applies to subscription agents only.", 400) }
        var ids: [String] = []
        if let given = input["images"], given != .null {
            guard let list = given.array else { throw HTTPFailure(ImageRules.invalidAttachment, 400) }
            for item in list {
                guard let id = item.string else { throw HTTPFailure(ImageRules.invalidAttachment, 400) }
                ids.append(id)
            }
        }
        let uploads = try ids.map { id -> ImageUpload in
            guard let upload = staged.get(id) else { throw HTTPFailure("That picture is no longer attached. Attach it again.", 400) }
            return upload
        }
        do {
            let result = try backend.submit(message: message, kind: text("kind", fallback: "chat") ?? "chat", mode: text("mode", fallback: "balanced") ?? "balanced",
                                            requestId: requestId, threadId: threadId, project: project, images: uploads, from: origin)
            staged.remove(ids)
            return .json(202, .encoded(result))
        } catch let known as BlackTeamError { throw HTTPFailure(known.message, PhoneRouter.submitStatus(known.message)) }
    }

    // MARK: Privacy

    static func privacyJSON(_ check: PrivacyCheck) -> JSONValue {
        ["outcome": .string(check.outcome.rawValue), "refused": .bool(check.refused), "message": .string(check.message), "provider": .string(check.provider),
         "modelName": .string(check.modelName), "willLeave": .array(check.willLeave.map { .string($0) }), "localModelName": .string(check.localModelName),
         "localModelKey": .string(check.localModelKey), "convertWarning": .string(check.convertWarning)]
    }

    /// `GET /api/privacy?threadId=&project=&kind=&agent=`: what a send from here would do. The Backend decides again when it is sent.
    private func privacy(_ head: HTTPHead, _ who: DesktopAccess) throws -> HTTPResponse {
        let threadId = head.queryValue("threadId").flatMap { $0.isEmpty ? nil : $0 }
        let project = head.queryValue("project").flatMap { $0.isEmpty ? nil : $0 }
        if let threadId, !History.validID(threadId) { throw HTTPFailure("Invalid conversation ID.", 400) }
        if let project, !History.validID(project) { throw HTTPFailure("Invalid project.", 400) }
        let kind = head.queryValue("kind") ?? "chat"
        guard ["chat", "agent"].contains(kind) else { throw HTTPFailure("Choose Chat or Agent work.", 400) }
        let check: PrivacyCheck
        if let name = head.queryValue("agent"), !name.isEmpty {
            guard let service = AgentService.forEngine(name) else { throw HTTPFailure("The agent is claude-code or codex.", 400) }
            check = backend.agentPrivacyCheck(service: service, threadId: threadId, project: project, viaPhone: who == .phone)
        } else {
            check = backend.privacyCheck(threadId: threadId, project: project, kind: kind, viaPhone: who == .phone)
        }
        return .json(200, Self.privacyJSON(check))
    }

    /// `POST /api/privacy/convert {threadId, provider}`: "Send this conversation to <service>", after the person confirmed by naming it.
    /// The agent (if the conversation belongs to one) is read from the conversation, never taken from the request.
    private func convert(_ input: [String: JSONValue]) throws -> HTTPResponse {
        guard let threadId = try string(input, "threadId"), History.validID(threadId) else { throw BlackTeamError("Conversation not found.") }
        let provider = try string(input, "provider") ?? ""
        let service = AgentService.forEngine(backend.history.get(threadId)?["engine"]?.string)
        if let service { try backend.convertToCloud(threadId: threadId, confirmingProvider: provider, agent: service) }
        else { try backend.convertToCloud(threadId: threadId, confirmingProvider: provider) }
        return .json(200, ["converted": true, "thread": desktopThread(threadId) ?? .null])
    }

    // MARK: Agent tasks

    /// `POST /api/agent/rollback {threadId, runId}`: "Roll back this task".
    private func rollback(_ input: [String: JSONValue]) throws -> HTTPResponse {
        let restored = try backend.rollBack(threadId: try string(input, "threadId") ?? "", runId: try string(input, "runId") ?? "")
        return .json(200, ["restored": .array(restored.restored.map { .string($0) }), "removed": .array(restored.removed.map { .string($0) })])
    }

    // MARK: Pictures

    /// `POST /api/image?name=photo.jpg` with the picture's bytes as the body (any content type, at most 20 MB). The picture is prepared
    /// as `black-team chat --image` does (metadata removed, resized when needed) and kept, unsent, until the message is sent.
    private func upload(_ head: HTTPHead, _ body: Data) async throws -> HTTPResponse {
        if body.isEmpty { throw BlackTeamError(ImageRules.badDataMessage) }
        let name = String((head.queryValue("name") ?? "picture").prefix(200))
        let prepared = try ImagePreparer.prepare(data: body, name: name)
        try ImageRules.validate([prepared])
        guard let size = ImagePreparer.dimensions(of: prepared.data) else { throw BlackTeamError(ImageRules.badDataMessage) }
        let id = staged.add(prepared)
        return .json(200, ["id": .string(id), "name": .string(prepared.name), "bytes": .number(Double(prepared.data.count)),
                           "width": .number(Double(size.width)), "height": .number(Double(size.height))])
    }

    /// `GET /api/image/<conversation id>/<image id>`: a stored picture of a conversation.
    private func image(_ rest: String) throws -> HTTPResponse {
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, History.validID(parts[0]), History.validID(parts[1]) else { throw HTTPFailure("That image is no longer stored.", 404) }
        let file: (data: Data, mime: String)
        do { file = try backend.image(threadId: parts[0], imageId: parts[1]) } catch { throw HTTPFailure("That image is no longer stored.", 404) }
        var response = HTTPResponse(status: 200, body: file.data)
        response.set("Content-Type", file.mime)
        return response
    }

    // MARK: The room

    /// The room as the window reads it: `team` is null until a team run has been started (the Swift type leaves a missing run out).
    static func roomJSON(_ state: RoomState) -> JSONValue {
        var object = JSONValue.encoded(state).object ?? [:]
        if object["team"] == nil { object["team"] = .null }
        return .object(object)
    }

    private func room(_ head: HTTPHead, _ body: Data) async throws -> HTTPResponse {
        let path = head.path
        if head.method == "GET" && path == "/api/room" {
            return .json(200, Self.roomJSON(try backend.room(projectId: head.queryValue("project") ?? "")))
        }
        if head.method == "GET" && path == "/api/room/roster" { return .json(200, ["agents": .encoded(backend.roster())]) }
        guard head.method == "POST" else { throw HTTPFailure("Not found.", 404) }
        let input = try json(head, body)
        let project = try string(input, "project") ?? ""
        func text(_ key: String) throws -> String { try string(input, key) ?? "" }
        func state(_ value: RoomState) -> HTTPResponse { .json(200, Self.roomJSON(value)) }
        switch path {
        case "/api/room/member/add":
            return state(try backend.roomAddMember(projectId: project, name: try text("name"), role: try text("role"), modelKey: try string(input, "modelKey"),
                                                   agent: try string(input, "agent"), permission: try string(input, "permission"), work: try string(input, "work")))
        case "/api/room/member/update":
            return state(try backend.roomUpdateMember(projectId: project, memberId: try text("memberId"), name: try string(input, "name"), role: try string(input, "role"),
                                                      modelKey: try string(input, "modelKey"), permission: try string(input, "permission"), work: try string(input, "work")))
        case "/api/room/member/remove":
            return state(try backend.roomRemoveMember(projectId: project, memberId: try text("memberId")))
        case "/api/room/task/add":
            return state(try backend.roomAddTask(projectId: project, title: try text("title"), detail: try text("detail"), assignee: try string(input, "assignee")))
        case "/api/room/task/update":
            var assignee: String?? = nil
            if let given = input["assignee"] {
                if given == .null { assignee = .some(nil) } else if let id = given.string { assignee = .some(id) } else { throw BlackTeamError("Invalid request.") }
            }
            return state(try backend.roomUpdateTask(projectId: project, taskId: try text("taskId"), title: try string(input, "title"), detail: try string(input, "detail"),
                                                    assignee: assignee))
        case "/api/room/task/delete":
            return state(try backend.roomDeleteTask(projectId: project, taskId: try text("taskId")))
        case "/api/room/task/accept":
            return state(try backend.roomAccept(projectId: project, taskId: try text("taskId")))
        case "/api/room/task/sendback":
            return state(try backend.roomSendBack(projectId: project, taskId: try text("taskId"), note: try text("note")))
        case "/api/room/task/start":
            return state(try await backend.roomStart(projectId: project, taskId: try text("taskId"), from: .mac))
        case "/api/room/handoff/preview":
            let preview = try backend.roomHandOffPreview(projectId: project, taskId: try text("taskId"), to: try text("to"), title: try string(input, "title"),
                                                         detail: try string(input, "detail"), includeResult: input["includeResult"]?.bool ?? true)
            return .json(200, .encoded(preview))
        case "/api/room/handoff":
            return state(try backend.roomHandOff(projectId: project, taskId: try text("taskId"), to: try text("to"), title: try text("title"), detail: try text("detail"),
                                                 includeResult: input["includeResult"]?.bool ?? true, digest: try text("digest")))
        case "/api/room/roster/create":
            return .json(200, ["agents": .encoded(try backend.rosterCreate(name: try text("name"), role: try text("role"), modelKey: try string(input, "modelKey"),
                                                                        agent: try string(input, "agent"), permission: try string(input, "permission"),
                                                                        work: try string(input, "work")))])
        case "/api/room/roster/remove":
            return .json(200, ["agents": .encoded(try backend.rosterRemove(id: try text("rosterId")))])
        case "/api/room/roster/add":
            return state(try backend.roomAddFromRoster(projectId: project, rosterId: try text("rosterId")))
        case "/api/room/roster/save":
            return .json(200, ["agents": .encoded(try backend.roomSaveToRoster(projectId: project, memberId: try text("memberId")))])
        case "/api/room/team/preview":
            let lead = try string(input, "leadId")
            let driven = input["driven"]?.bool ?? backend.roomCanDrive(projectId: project, leadId: lead)
            return .json(200, .encoded(try backend.roomTeamPreview(projectId: project, goal: try text("goal"), leadId: lead,
                                                                  reviewerId: try string(input, "reviewerId"), driven: driven)))
        case "/api/room/team/run":
            let lead = try string(input, "leadId")
            let driven = input["driven"]?.bool ?? backend.roomCanDrive(projectId: project, leadId: lead)
            return .json(200, .encoded(try backend.roomTeamRun(projectId: project, goal: try text("goal"), leadId: lead,
                                                              reviewerId: try string(input, "reviewerId"), digest: try text("digest"), from: .mac, driven: driven)))
        case "/api/room/team/stop":
            return state(try backend.roomTeamStop(projectId: project))
        default:
            throw HTTPFailure("Not found.", 404)
        }
    }
}

extension DesktopAccess {
    /// For routes: a phone is refused with 403 and the words above.
    func requireDesktopHTTP(_ message: String = DesktopRefusal.desktopOnly) throws {
        if self != .desktop { throw HTTPFailure(message, 403) }
    }
}
