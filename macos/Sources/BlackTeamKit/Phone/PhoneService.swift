import Foundation

/// How phone access reaches the outside world. The defaults are the real ones; tests and the command-line tool replace them.
public struct PhoneOptions: Sendable {
    /// Runs `tailscale`.
    public var runner: PhoneCommandRunner = Tailscale.run
    /// The built web app. Default: `web` inside the app bundle's Resources.
    public var webRoot: String = Bundle.main.resourceURL?.appendingPathComponent("web").path ?? ""
    /// The loopback port the Tailscale route points at. Only tests use another.
    public var port: Int = Phone.localPort
    /// The Linux desktop window's session. Nil on the Mac, where the local address grants nothing.
    public var desktop: DesktopSession?
    public init() {}
}

/// What the interface and the command-line tool show about phone access. Never contains a pairing secret.
public struct PhoneState: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// The Tailscale route is Black Team's own, private, and our server is listening behind it.
    public var connected: Bool
    /// Tailscale's side alone: Black Team's own private route exists (whether or not this process serves it).
    public var routeReady: Bool
    public var serverRunning: Bool
    public var hostname: String
    public var owner: String
    public var url: String
    public var command: String
    /// Why an enabled phone setup is not connected, in words for the person; nil when it just needs reconnecting.
    public var problem: String?
}

public struct PhoneDisableResult: Codable, Equatable, Sendable {
    public var disabled: Bool
    public var warning: String?
}

/// The phone manager, its pairing key and its server, tied to one `Backend`.
final class PhoneService: @unchecked Sendable {
    let manager: PhoneManager
    private let backend: Backend
    private let options: PhoneOptions
    private let lock = NSLock()
    private var keysStore: PhoneKeys?
    private var serverStore: PhoneServer?

    init(backend: Backend, options: PhoneOptions) {
        self.backend = backend; self.options = options
        manager = PhoneManager(configStore: backend.configStore, run: options.runner)
    }

    var keys: PhoneKeys? { lock.lock(); defer { lock.unlock() }; return keysStore }
    var server: PhoneServer? { lock.lock(); defer { lock.unlock() }; return serverStore }
    var serverRunning: Bool { server?.isRunning ?? false }

    /// Opens the key and starts listening on 127.0.0.1. Does nothing when it already listens.
    func start() async throws {
        let existing: PhoneServer? = lock.withLock { serverStore }
        if let existing, existing.isRunning { return }
        let keys: PhoneKeys = try lock.withLock { () throws -> PhoneKeys in
            if let keysStore { return keysStore }
            let made = try PhoneKeys(folder: backend.dataFolder)
            keysStore = made
            return made
        }
        let configStore = backend.configStore
        let manager = self.manager
        let router = PhoneRouter(backend: BackendPhone(backend), config: configStore, keys: keys, webRoot: options.webRoot,
                                 localPort: options.port, desktop: options.desktop, isConnected: { [weak self] in
            // The route must be ours and private, and it must lead to a server that is listening.
            guard let self, self.serverRunning, let status = try? await manager.status() else { return false }
            return status.connected
        })
        let made = PhoneServer(router: router, port: options.port)
        try await made.start()
        lock.withLock { serverStore = made }
    }

    func stop() {
        let current = lock.withLock { () -> PhoneServer? in let value = serverStore; serverStore = nil; return value }
        current?.stop()
    }

    func state(fresh: Bool = false) async throws -> PhoneState {
        let status = try await manager.status(fresh: fresh)
        let saved = try backend.configStore.readPhone()
        let running = serverRunning
        let connected = status.connected && running
        var problem: String?
        if saved.enabled && !connected {
            if !running { problem = "Phone access is on, but its local server is not running. Turn it off and on again, or quit the program using port \(options.port)." }
            else { problem = await diagnose(saved) }
        }
        return PhoneState(enabled: saved.enabled, connected: connected, routeReady: status.connected, serverRunning: running, hostname: saved.hostname, owner: saved.owner,
                          url: saved.enabled ? status.url : "", command: status.command, problem: problem)
    }

    private func diagnose(_ saved: PhoneConfig) async -> String? {
        let me = await manager.detect()
        if !me.installed { return "Tailscale is not installed on this Mac." }
        if !me.online { return "Tailscale is not connected. Open Tailscale and sign in." }
        if me.hostname != saved.hostname || me.owner != saved.owner {
            return "Your Tailscale account or computer has changed. Turn off phone access, then enable it again."
        }
        let output = try? await options.runner("tailscale", ["serve", "status", "--json"], 10)
        guard let output, let json = try? JSONValue.parse(output) else { return nil }
        let route = phoneRouteState(json, hostname: saved.hostname)
        if route.publicRoute || (route.occupied && !route.owned) { return "Port \(Phone.phonePort) is used by another or public route. Black Team will not overwrite it." }
        return nil
    }
}

// MARK: The Backend's phone methods

extension Backend {
    /// Changes how phone access reaches Tailscale and the web app. Call before the first phone method.
    public func configurePhone(_ options: PhoneOptions) { locked { phoneOptions = options; phoneService = nil } }

    func phone() -> PhoneService {
        locked {
            if let phoneService { return phoneService }
            let made = PhoneService(backend: self, options: phoneOptions)
            phoneService = made
            return made
        }
    }

    /// Finds this Mac's Tailscale name and account, and whether Tailscale is installed and online.
    public func phoneDetect() async -> PhoneDetection { await phone().manager.detect() }

    public func phoneState(fresh: Bool = false) async throws -> PhoneState { try await phone().state(fresh: fresh) }

    /// At launch: listens for phones if phone access is on. A server that cannot start is reported, not thrown.
    public func startPhoneAccess() async throws {
        guard try configStore.readPhone().enabled else { return }
        try await phone().start()
    }

    /// Keeps the server in step with the saved setting when something else changed it (the command-line tool turning
    /// phone access off from another process): on means listening, off means not.
    public func syncPhoneAccess() async {
        guard let enabled = try? configStore.readPhone().enabled else { return }
        if enabled { try? await phone().start() } else { stopPhoneAccess() }
    }

    /// "Enable private phone access": starts the local server first (so the route never points at another program),
    /// then detects this Mac and its account and creates Black Team's private route.
    @discardableResult
    public func phoneEnable() async throws -> PhoneState {
        let service = phone()
        try await service.start()
        do { _ = try await service.manager.setup() } catch {
            // Nothing is connected: do not leave a server running for a setup that never saved.
            if !(try configStore.readPhone().enabled) { service.stop() }
            throw error
        }
        return try await service.state(fresh: true)
    }

    /// Stops accepting phone requests first, then removes only Black Team's own route.
    @discardableResult
    public func phoneDisable() async throws -> PhoneDisableResult {
        let service = phone()
        let result = try await service.manager.disable()
        service.stop()
        return PhoneDisableResult(disabled: result.disabled, warning: result.warning)
    }

    /// The link to open on a phone: this Mac's private address with the pairing secret after `#`, which a browser
    /// never sends to a server. Only while phone access is connected. `requireServer: false` is for the command-line
    /// tool, which asks from a separate process while another one serves.
    public func phonePairingLink(requireServer: Bool = true) async throws -> String {
        let service = phone()
        var state = try await service.state(fresh: true)
        if !requireServer && !state.serverRunning {
            state.connected = state.routeReady
        }
        guard state.connected else {
            throw BlackTeamError(state.enabled ? "Phone access is not connected yet. " + (state.problem ?? "Enable private phone access again.") : "Phone access is off. Enable private phone access first.")
        }
        let keys = try service.keys ?? PhoneKeys(folder: dataFolder)
        return state.url + "#pair=" + keys.secret("pair", hostname: state.hostname, owner: state.owner)
    }

    /// Replaces `phone.key`: every paired phone and every link shown so far stops working.
    public func phoneResetPairing() throws { try PhoneKeys.reset(folder: dataFolder) }

    /// Stops the phone server (not the Tailscale route).
    public func stopPhoneAccess() { locked { phoneService }?.stop() }
}

// MARK: What a phone may see

/// `Backend` as the phone router uses it.
final class BackendPhone: PhoneBackend, @unchecked Sendable {
    private let backend: Backend
    init(_ backend: Backend) { self.backend = backend }

    func desktopStatus() async throws -> JSONValue { try await backend.desktopStatusJSON() }
    func dictate() throws { try backend.dictate() }

    func phoneStatus() async throws -> JSONValue {
        let status = try await backend.status()
        // Whitelisted field by field: the phone gets the model's display name and the conversation state, never the
        // saved key, a model or runtime file path, the saved models, the integrations or the hardware report.
        return [
            "access": "phone", "version": .string(status.version), "setupComplete": .bool(status.setupComplete),
            "runtime": .encoded(status.runtime), "threads": .encoded(status.threads), "job": status.job.map { .encoded($0) } ?? .null,
            "agentEnabled": true, "hermesEnabled": false, "projects": .encoded(status.projects), "memory": true, "dictation": false,
            "codeMap": .bool(status.codeMap), "performance": .encoded(status.performance),
            "config": ["model": ["name": .string(status.config.model.name)]], "phone": ["enabled": true],
        ]
    }

    var isBusy: Bool { backend.isBusy }
    func submit(message: String, kind: String, mode: String, requestId: String, threadId: String?, project: String?) throws -> SubmitResult {
        // From a phone: it may continue conversations, but never starts or converts one to cloud, and the same refusals apply.
        try backend.submit(message: message, kind: kind, mode: mode, requestId: requestId, threadId: threadId, project: project, from: .phone)
    }
    /// The phone's web app has no image support and would draw a broken picture, so a conversation reaches it without its
    /// image references: it shows the text of the message. No image data is ever in a conversation, and none is served.
    func thread(_ id: String) -> JSONValue? {
        guard var thread = backend.thread(id) else { return nil }
        let messages = (thread["messages"]?.array ?? []).map { message -> JSONValue in
            var object = message.object ?? [:]
            object["images"] = nil
            return .object(object)
        }
        thread = thread.setting("messages", .array(messages))
        return thread
    }
    func request(_ id: String) -> SubmitResult? { backend.request(id) }
    func cancel() -> CancelResult { backend.cancel() }
    func approve(id: String, digest: String, choice: String) throws { try backend.approve(id: id, digest: digest, choice: choice) }
    func undo(_ id: String?) throws -> UndoResult { try backend.undo(id) }
    func artifactFile(_ id: String) throws -> ArtifactFile { try backend.artifactFile(id) }
    func createProject(name: String) throws -> ProjectSummary { try backend.createProject(name: name) }
    func memoryOverview() throws -> MemoryOverview { try backend.memoryOverview() }
    func memoryNote(_ id: String) throws -> NoteContent { try backend.memoryNote(id) }
    func memorySearch(_ query: String) async throws -> [SearchHit] { try await backend.memorySearch(query) }
    func memorySave(_ id: String, content: String) throws -> NoteContent { try backend.memorySave(id, content: content) }
    func memoryDelete(_ id: String) throws { try backend.memoryDelete(id) }
    func memoryRemember(title: String, text: String, project: String?) throws -> String { try backend.memoryRemember(title: title, text: text, project: project) }
    func memoryTidy() async -> String { await backend.memoryTidy() }
}
