import Foundation

// The phone half of lib/server.cjs: `authorize` and the routes a paired phone may call. There is no desktop
// session here (the Mac's own windows call the Backend directly), so anything that is not a valid phone,
// pairing or unpaired request is refused the way server.cjs refuses an unauthorised one.

/// What `PhoneRouter` needs from the app. `Backend` is the real one (through `BackendPhone`); tests use a fake.
public protocol PhoneBackend: AnyObject, Sendable {
    /// The reduced status a phone may see: no keys, no model file paths, no desktop configuration.
    func phoneStatus() async throws -> JSONValue
    var isBusy: Bool { get }
    func submit(message: String, kind: String, mode: String, requestId: String, threadId: String?, project: String?) throws -> SubmitResult
    func thread(_ id: String) -> JSONValue?
    func request(_ id: String) -> SubmitResult?
    func cancel() -> CancelResult
    func approve(id: String, digest: String, choice: String) throws
    func undo(_ id: String?) throws -> UndoResult
    func artifactFile(_ id: String) throws -> ArtifactFile
    func createProject(name: String) throws -> ProjectSummary
    func memoryOverview() throws -> MemoryOverview
    func memoryNote(_ id: String) throws -> NoteContent
    func memorySearch(_ query: String) async throws -> [SearchHit]
    func memorySave(_ id: String, content: String) throws -> NoteContent
    func memoryDelete(_ id: String) throws
    func memoryRemember(title: String, text: String, project: String?) throws -> String
    func memoryTidy() async -> String
    /// The full status the desktop window reads (`status('desktop')`). Only the Linux desktop service has one.
    func desktopStatus() async throws -> JSONValue
    /// Toggles the system dictation tool. Only the Linux desktop window may.
    func dictate() throws
}

extension PhoneBackend {
    func desktopStatus() async throws -> JSONValue { try await phoneStatus() }
    func dictate() throws { throw BlackTeamError("No system dictation tool is set up on this computer.") }
}

enum PhoneAccess: Equatable { case pairing, phone, unpaired, bootstrap, desktop }

final class PhoneRouter: @unchecked Sendable {
    static let cookieName = "black_team_phone"
    private let backend: PhoneBackend
    private let config: PhoneConfigStoring
    private let keys: PhoneKeys
    private let isConnected: @Sendable () async -> Bool
    private let files: PhoneStaticFiles
    /// The Linux desktop window's session (lib/server.cjs `bootstrapKey` / `sessionKey`). Nil on the Mac, where the local address grants nothing.
    private let desktop: DesktopSession?
    /// The routes only the Linux desktop service has (cloud, agents, room, pictures). Nil on the Mac and in the terminal program.
    private let desktopRoutes: DesktopRoutes?
    private let lock = NSLock()
    private var _localPort: Int

    var localPort: Int {
        get { lock.lock(); defer { lock.unlock() }; return _localPort }
        set { lock.lock(); _localPort = newValue; lock.unlock() }
    }

    /// `isConnected` says the Tailscale route is Black Team's own, private, and points at a server that is running.
    init(backend: PhoneBackend, config: PhoneConfigStoring, keys: PhoneKeys, webRoot: String, localPort: Int = Phone.localPort,
         desktop: DesktopSession? = nil, desktopRoutes: DesktopRoutes? = nil, isConnected: @escaping @Sendable () async -> Bool) {
        self.backend = backend; self.config = config; self.keys = keys; self.isConnected = isConnected; self.desktop = desktop
        self.desktopRoutes = desktop == nil ? nil : desktopRoutes
        files = PhoneStaticFiles(folder: webRoot); _localPort = localPort
    }

    // MARK: Security headers

    static func secured(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        response.set("Cache-Control", "no-store")
        response.set("X-Content-Type-Options", "nosniff")
        response.set("X-Frame-Options", "DENY")
        response.set("Referrer-Policy", "no-referrer")
        response.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        response.set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
        return response
    }

    // MARK: authorize

    /// Port of `authorize`. `peer` is the address the TCP connection came from.
    func authorize(_ head: HTTPHead, peer: String?) async throws -> PhoneAccess {
        guard let peer, ["127.0.0.1", "::1", "::ffff:127.0.0.1"].contains(peer) else { throw HTTPFailure("Local access only.", 403) }
        let host = (head.headers["host"] ?? "").lowercased()
        let port = localPort
        let local = host == "127.0.0.1:\(port)"
        let phone = (try? config.readPhone()) ?? PhoneConfig()
        // A saved phone setup without a computer name or an owner can never match anything.
        let usable = phone.enabled && !phone.hostname.isEmpty && !phone.owner.isEmpty
        let remote = usable && host == "\(phone.hostname):\(Phone.phonePort)"
        if !local && !remote { throw HTTPFailure("Unrecognized Black Team address.", 403) }
        let expectedOrigin = local ? "http://127.0.0.1:\(port)" : "https://\(phone.hostname):\(Phone.phonePort)"
        let origin = head.headers["origin"]
        if let origin, !origin.isEmpty, origin != expectedOrigin { throw HTTPFailure("Origin is not allowed.", 403) }
        if !["GET", "HEAD"].contains(head.method) && origin != expectedOrigin { throw HTTPFailure("A same-origin request is required.", 403) }
        // The Mac has no desktop browser session: the local address grants nothing. The Linux desktop service has one:
        // the window opens /bootstrap?key= once and keeps a session cookie.
        if local, let desktop {
            if head.path == "/bootstrap" && head.method == "GET" && phoneEqual(head.queryValue("key"), desktop.bootstrapKey) { return .bootstrap }
            if phoneEqual(Self.cookie(head, named: DesktopSession.cookieName), desktop.sessionKey) { return .desktop }
        }
        if remote, phoneEqual(head.headers["tailscale-user-login"], phone.owner), await isConnected() {
            if phoneEqual(Self.cookie(head), keys.secret("session", hostname: phone.hostname, owner: phone.owner)) { return .phone }
            if head.path == "/api/pair" && head.method == "POST" { return .pairing }
            if !head.path.hasPrefix("/api/") && head.method == "GET" { return .unpaired }
        }
        throw HTTPFailure("Open Black Team on this computer, or connect Companion using its saved Tailscale account.", 401)
    }

    /// The first `black_team_phone=` cookie, as server.cjs reads it.
    static func cookie(_ head: HTTPHead, named name: String? = nil) -> String? {
        let prefix = (name ?? cookieName) + "="
        return (head.headers["cookie"] ?? "").split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// How much body a route reads (server.cjs `bodyJSON`): 64 KiB, and 900 KiB for saving a memory note.
    func bodyLimit(_ head: HTTPHead) -> Int {
        if desktopRoutes != nil && head.path == "/api/image" { return DesktopRoutes.imageUploadLimit }
        return head.path == "/api/memory/save" ? 900 * 1024 : 65536
    }

    // MARK: Whole request (used by the server and by tests)

    /// `readBody` is called only after the request is authorised and its declared size is within the route's limit,
    /// so an unauthorised caller never gets its body read.
    func respond(_ head: HTTPHead, peer: String?, readBody: () async throws -> Data) async -> HTTPResponse {
        do {
            let access = try await authorize(head, peer: peer)
            // A picture upload is big; only the desktop\u{2019}s may be read at all.
            if desktopRoutes != nil, head.path == "/api/image", head.method == "POST", access != .desktop { throw HTTPFailure(DesktopRefusal.pictures, 403) }
            if head.contentLength > bodyLimit(head) { throw HTTPFailure("Request is too large.", 413) }
            let body = head.method == "POST" ? try await readBody() : Data()
            return Self.secured(try await handle(head, body: body, access: access))
        } catch let failure as HTTPFailure {
            return Self.secured(.error(failure.status, failure.message))
        } catch {
            return Self.secured(.error(500, "Black Team could not complete this request. Check the desktop app."))
        }
    }

    func respond(_ head: HTTPHead, body: Data = Data(), peer: String?) async -> HTTPResponse {
        await respond(head, peer: peer, readBody: { body })
    }

    // MARK: Routes

    private func bodyJSON(_ head: HTTPHead, _ body: Data) throws -> [String: JSONValue] {
        guard (head.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { throw HTTPFailure("Send JSON.", 415) }
        if body.count > bodyLimit(head) { throw HTTPFailure("Request is too large.", 413) }
        guard let value = try? JSONValue.parse(body), let object = value.object else { throw HTTPFailure("Invalid JSON request.") }
        return object
    }

    /// Plain errors from memory, projects and undo are messages meant for the person; anything else is not shown.
    private func mine<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch let failure as HTTPFailure { throw failure }
        catch let known as BlackTeamError { throw HTTPFailure(known.message) }
        catch { throw HTTPFailure("That could not be done.") }
    }

    private func mineAsync<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let failure as HTTPFailure { throw failure }
        catch let known as BlackTeamError { throw HTTPFailure(known.message) }
        catch { throw HTTPFailure("That could not be done.") }
    }

    private func handle(_ head: HTTPHead, body: Data, access: PhoneAccess) async throws -> HTTPResponse {
        let path = head.path, method = head.method
        if path == "/api/pair" && method == "POST" && (access == .pairing || access == .phone) {
            let input = try bodyJSON(head, body)
            let phone = try config.readPhone()
            guard phoneEqual(input["key"]?.string, keys.secret("pair", hostname: phone.hostname, owner: phone.owner)) else {
                throw HTTPFailure("Open the current pairing link from your Black Team desktop app.", 401)
            }
            var response = HTTPResponse.json(200, ["paired": true])
            response.set("Set-Cookie", "\(Self.cookieName)=\(keys.secret("session", hostname: phone.hostname, owner: phone.owner)); Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000")
            return response
        }
        if access == .bootstrap, let desktop {
            var response = HTTPResponse(status: 303)
            response.set("Set-Cookie", "\(DesktopSession.cookieName)=\(desktop.sessionKey); Path=/; HttpOnly; SameSite=Strict")
            response.set("Location", "/")
            return response
        }
        // Everything below needs a paired phone. An unpaired visitor gets the page shell and nothing else.
        if access == .unpaired {
            if path.hasPrefix("/api/") || !["GET", "HEAD"].contains(method) { throw HTTPFailure("Not found.", 404) }
            return try served(head)
        }
        guard access == .phone || access == .desktop else { throw HTTPFailure("Not found.", 404) }
        if let desktopRoutes, let answer = try await desktopRoutes.handle(head, body: body, access: access) { return answer }

        if path == "/api/approval" && method == "POST" {
            let input = try bodyJSON(head, body)
            guard let id = input["id"]?.string, let digest = input["digest"]?.string, let choice = input["choice"]?.string else {
                // Nothing is active that matches a missing or malformed answer.
                throw HTTPFailure(backend.isBusy ? "No matching active approval." : "No active approval.", 409)
            }
            do { try backend.approve(id: id, digest: digest, choice: choice) }
            catch let known as BlackTeamError { throw HTTPFailure(known.message, 409) }
            return .json(200, ["sent": true])
        }
        if path.hasPrefix("/api/file/") && method == "GET" { return try artifact(String(path.dropFirst("/api/file/".count))) }
        if path == "/api/status" && method == "GET" { return .json(200, access == .desktop ? try await backend.desktopStatus() : try await backend.phoneStatus()) }
        if path == "/api/project-create" && method == "POST" {
            let input = try bodyJSON(head, body)
            let made = try mine { try backend.createProject(name: input["name"]?.string ?? "") }
            return .json(200, .encoded(made))
        }
        if path == "/api/undo" && method == "POST" {
            let input = try bodyJSON(head, body)
            if backend.isBusy { throw HTTPFailure("Wait for the running task to finish, or stop it, before undoing an edit.", 409) }
            let undone = try mine { try backend.undo(input["id"]?.string) }
            return .json(200, ["path": .string(undone.path), "removed": .bool(undone.removed)])
        }
        if path == "/api/dictate" && method == "POST" {
            _ = try bodyJSON(head, body)
            if access != .desktop { throw HTTPFailure("Use your phone keyboard\u{2019}s microphone to dictate.", 403) }
            do { try backend.dictate() } catch let known as BlackTeamError { throw HTTPFailure(known.message, 404) }
            return .json(200, ["toggled": true])
        }
        if path.hasPrefix("/api/memory") { return try await memoryRoute(head, body) }
        if path.hasPrefix("/api/thread/") && method == "GET" {
            guard let thread = backend.thread(String(path.dropFirst("/api/thread/".count))) else { throw HTTPFailure("Conversation not found.", 404) }
            return .json(200, thread)
        }
        if path.hasPrefix("/api/request/") && method == "GET" {
            guard let saved = backend.request(String(path.dropFirst("/api/request/".count))) else { throw HTTPFailure("Request not found.", 404) }
            return .json(200, .encoded(saved))
        }
        if path == "/api/chat" && method == "POST" { return try chat(try bodyJSON(head, body)) }
        if path == "/api/cancel" && method == "POST" { _ = try bodyJSON(head, body); return .json(200, .encoded(backend.cancel())) }
        if path.hasPrefix("/api/") || !["GET", "HEAD"].contains(method) { throw HTTPFailure("Not found.", 404) }
        return try served(head)
    }

    private func served(_ head: HTTPHead) throws -> HTTPResponse { try files.response(for: head.path) }

    // MARK: Pieces

    private static let artifactEscape: CharacterSet = {
        // encodeURIComponent leaves letters, digits and - _ . ! ~ * ' ( ) as they are.
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    }()

    private func artifact(_ id: String) throws -> HTTPResponse {
        let file: ArtifactFile
        do { file = try backend.artifactFile(id) } catch { throw HTTPFailure("File not found.", 404) }
        guard file.size <= 1 << 30, let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe) else { throw HTTPFailure("File not found.", 404) }
        var response = HTTPResponse(status: 200, body: data)
        response.set("Content-Type", "application/octet-stream")
        response.set("Content-Disposition", "attachment; filename*=UTF-8''" + (file.name.addingPercentEncoding(withAllowedCharacters: Self.artifactEscape) ?? "file"))
        return response
    }

    private func chat(_ input: [String: JSONValue]) throws -> HTTPResponse {
        // The same defaults and the same refusals of wrong types as server.cjs `submit`. A phone can name a
        // project but never a folder: `workspace` in the request is not read.
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
        let result: SubmitResult
        do {
            result = try backend.submit(message: message, kind: text("kind", fallback: "chat") ?? "chat", mode: text("mode", fallback: "balanced") ?? "balanced",
                                        requestId: requestId, threadId: text("threadId"), project: project)
        } catch let known as BlackTeamError { throw HTTPFailure(known.message, Self.submitStatus(known.message)) }
        return .json(202, .encoded(result))
    }

    static func submitStatus(_ message: String) -> Int {
        if message == "Black Team is closing." { return 503 }
        if message == "Conversation not found." { return 404 }
        for prefix in ["A response is already running.", "Request ID was already used", "Complete model setup", "Start a new conversation to change",
                       "This conversation uses Hermes", "Code is unavailable"] where message.hasPrefix(prefix) { return 409 }
        return 400
    }

    private func memoryRoute(_ head: HTTPHead, _ body: Data) async throws -> HTTPResponse {
        let path = head.path, method = head.method
        if path == "/api/memory" && method == "GET" { return .json(200, .encoded(try mine { try backend.memoryOverview() })) }
        if path == "/api/memory/note" && method == "GET" { return .json(200, .encoded(try mine { try backend.memoryNote(head.queryValue("id") ?? "") })) }
        if path == "/api/memory/search" && method == "GET" {
            let query = head.queryValue("q") ?? ""
            let hits = try await mineAsync { try await backend.memorySearch(query) }
            return .json(200, ["hits": .encoded(hits)])
        }
        if method == "POST" {
            let input = try bodyJSON(head, body)
            switch path {
            case "/api/memory/save":
                return .json(200, .encoded(try mine { try backend.memorySave(input["id"]?.string ?? "", content: input["content"]?.string ?? "") }))
            case "/api/memory/delete":
                try mine { try backend.memoryDelete(input["id"]?.string ?? "") }
                return .json(200, ["removed": true])
            case "/api/memory/remember":
                let id = try mine { try backend.memoryRemember(title: input["title"]?.string ?? "", text: input["text"]?.string ?? "", project: input["project"]?.string) }
                return .json(200, ["id": .string(id)])
            case "/api/memory/tidy":
                if backend.isBusy { return .json(200, ["message": "A task is running. Tidy memory when it finishes."]) }
                return .json(200, ["message": .string(await backend.memoryTidy())])
            default: break
            }
        }
        throw HTTPFailure("Not found.", 404)
    }
}
