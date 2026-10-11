import SwiftUI
import AppKit
import BlackTeamKit

public enum AppPage: String { case workspace, conversation, memory, settings }
public enum SettingsSection: String, CaseIterable { case model, agents, data }
enum Welcome { case models, agents }

/// The words in the composer, kept per conversation so they survive moving around the app.
struct Draft: Equatable {
    var message = ""
    var mode = "balanced"
}

final class DraftStore: ObservableObject {
    @Published private var items: [String: Draft] = [:]
    static let defaultModeKey = "black-team-default-mode"

    static var defaultMode: String {
        let stored = UserDefaults.standard.string(forKey: defaultModeKey) ?? "balanced"
        return ["fast", "balanced", "deep", "extended"].contains(stored) ? stored : "balanced"
    }

    func draft(_ key: String) -> Draft { items[key] ?? Draft(message: "", mode: Self.defaultMode) }
    func set(_ key: String, message: String) { var d = draft(key); d.message = message; items[key] = d }
    func set(_ key: String, mode: String) { var d = draft(key); d.mode = mode; items[key] = d }
    func clear(_ key: String) { var d = draft(key); d.message = ""; items[key] = d }
}

/// A message that may already be saved: retried with the same request id so it is never sent twice.
struct PendingRequest: Equatable {
    var id: String
    var message: String
    var mode: String
    var kind: ChatKind
    var threadId: String?
    var project: String?
}

func plainMessage(_ error: Error) -> String {
    if let known = error as? BlackTeamError { return known.message }
    return error.localizedDescription
}

/// The app's one model: it owns the Backend, keeps a status snapshot and the open conversation fresh from the
/// Backend's change stream, and holds navigation, drafts and the errors to show. Every Backend call goes through it.
@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    let backend: Backend
    public let version: String
    let drafts = DraftStore()
    let starter = StarterDownload()
    let finder = ModelFinder()
    let memory = MemoryModel()
    let updates = RuntimeUpdates()

    @Published var status: BackendStatus?
    @Published var statusFailure: String?
    @Published var page: AppPage = .workspace
    @Published var threadId: String?
    @Published var thread: JSONValue?
    @Published var newKind: ChatKind = .chat
    @Published var projectId: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var sending = false
    @Published var pending: PendingRequest?
    @Published var chatKey = 0
    @Published var settingsSection: SettingsSection = .model
    @Published var welcome: Welcome?
    @Published var manualSetup = false
    @Published var installed: DiscoveryResult?
    @Published var startupNotice: String?

    private var welcomeDecided = false
    private var loops: [Task<Void, Never>] = []
    private var refreshing = false
    private var refreshAgain = false
    private var lastStatusAt = Date.distantPast
    private var statusScheduled = false

    // MARK: Start

    /// The real app: opens the data folder (BLACK_TEAM_DATA, or Application Support) and starts watching it.
    public convenience init() {
        let (backend, notice) = AppModel.openBackend()
        self.init(backend: backend, live: true)
        startupNotice = notice
    }

    /// `live: false` builds a model that does not watch anything, for the snapshot tests.
    init(backend: Backend, live: Bool) {
        self.backend = backend
        self.version = backend.version
        if live { start() }
    }

    private static func openBackend() -> (Backend, String?) {
        let version = (Bundle.main.object(forInfoDictionaryKey: "BlackTeamVersion") as? String) ?? "0.1.0-dev"
        do { return (try Backend(dataFolder: AppPaths.dataFolder(), version: version), nil) }
        catch {
            // A full disk or a locked folder must not stop the window from opening.
            let temp = NSTemporaryDirectory() + "black-team-\(UUID().uuidString.prefix(8))"
            let backend = try! Backend(dataFolder: temp, version: version)
            return (backend, "Black Team could not open its data folder (\(plainMessage(error))), so this session is temporary and will not be saved.")
        }
    }

    private func start() {
        let backend = self.backend
        loops.append(Task { [weak self] in
            await self?.refresh()
            for await _ in backend.changes() { await self?.changed() }
        })
        // The hardware readout moves on its own, so it is read now and then even when nothing happens.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refresh()
            }
        })
    }

    /// Ends the model server and every process Black Team started. Called when the app quits.
    public func shutdown() async {
        loops.forEach { $0.cancel() }
        loops = []
        await backend.shutdown()
    }

    // MARK: Reading the Backend

    private func changed() async {
        updateThread()
        let elapsed = Date().timeIntervalSince(lastStatusAt)
        if elapsed >= 0.4 { await refresh() }
        else if !statusScheduled {
            statusScheduled = true
            try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000))
            statusScheduled = false
            await refresh()
        }
    }

    private func updateThread() {
        guard let id = threadId else { return }
        let next = backend.thread(id)
        if next != thread { thread = next }
    }

    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        repeat {
            refreshAgain = false
            do {
                let next = try await backend.status()
                lastStatusAt = Date()
                if next != status { status = next }
                statusFailure = nil
                if !welcomeDecided { welcomeDecided = true; if !next.setupComplete { welcome = .models } }
            } catch { statusFailure = plainMessage(error) }
            updateThread()
        } while refreshAgain
        refreshing = false
    }

    // MARK: What the screens ask

    var setupComplete: Bool { status?.setupComplete ?? false }
    var modelName: String { status?.config.model.name ?? status?.runtime.name ?? "Black Team" }
    var threads: [ThreadSummary] { status?.threads ?? [] }
    var projects: [ProjectSummary] { status?.projects ?? [] }
    var activeProject: ProjectSummary? { projects.first { $0.id == projectId } }
    var messages: [ChatMessage] { ChatMessage.messages(of: thread) }
    var activeJob: Bool { status?.job?.state == "running" }
    var locked: Bool { sending || pending != nil }

    var currentKind: ChatKind {
        if let kind = thread?["kind"]?.string, let known = ChatKind(rawValue: kind) { return known }
        return pending?.kind ?? newKind
    }

    /// The key of the draft for what is on screen: one per conversation, one per kind of new conversation.
    var draftKey: String { threadId ?? "new-\(currentKind.rawValue)\(projectId.map { "-" + $0 } ?? "")" }

    /// What the assistant is doing right now in the visible conversation, for the avatar and its label.
    var activity: ResponseActivity? {
        let activityThread = thread.flatMap { json -> ActivityThread? in
            guard let id = json["id"]?.string else { return nil }
            return ActivityThread(id: id, messages: ChatMessage.messages(of: json).map { ActivityMessage(id: $0.id, role: $0.role, state: $0.state) })
        }
        let job = status?.job.map { ActivityJob(threadId: $0.threadId, state: $0.state, kind: $0.kind, hasApproval: $0.approval != nil, progress: $0.progress) }
        return ResponseActivity.current(thread: activityThread, threadId: threadId, job: job, connection: "online")
    }

    /// The speed meter: the live job's, or the latest one saved in this conversation.
    var meter: SpeedInfo? {
        if let job = status?.job, job.threadId == threadId, threadId != nil, let live = SpeedInfo(job.meter) { return live }
        return messages.last(where: { $0.meter != nil })?.meter
    }

    // MARK: Navigation

    func navigate(_ next: AppPage) {
        page = next
        error = nil
        notice = nil
    }

    func showSettings(_ section: SettingsSection = .model) {
        settingsSection = section
        navigate(.settings)
    }

    func openThread(_ id: String?) {
        if locked { page = .conversation; return }
        threadId = id
        thread = id.flatMap { backend.thread($0) }
        page = .conversation
        error = nil
        chatKey += 1
    }

    func startChat(_ kind: ChatKind) {
        if locked { page = .conversation; return }
        newKind = kind
        openThread(nil)
    }

    /// The Chat and Code rows and the mode switch: show the open conversation if it is of that kind, else start one.
    func showMode(_ kind: ChatKind) {
        if page == .conversation, currentKind == kind { return }
        if page != .conversation, currentKind == kind, (threadId != nil || newKind == kind) {
            page = .conversation; error = nil; notice = nil
            return
        }
        startChat(kind)
    }

    func openConversation(_ item: ThreadSummary) {
        projectId = item.project
        openThread(item.id)
    }

    /// Opening a project returns to its latest conversation, or starts one in its folder.
    func openProject(_ project: ProjectSummary) {
        if locked { page = .conversation; return }
        projectId = project.id
        if let latest = threads.first(where: { $0.project == project.id }) { openThread(latest.id) } else { startChat(.agent) }
    }

    func leaveProject() {
        projectId = nil
        startChat(currentKind)
    }

    func createProject(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let made = try backend.createProject(name: trimmed)
            await refresh()
            projectId = made.id
            startChat(.agent)
            notice = "Created \(made.name) in \(made.workspace)."
        } catch { self.error = plainMessage(error) }
    }

    func rename(_ id: String, to title: String) async {
        do { try backend.renameThread(id, title: title); await refresh() } catch { self.error = plainMessage(error) }
    }

    // MARK: Actions

    /// Runs one setup action: errors and notices appear in place, never as an alert.
    @discardableResult
    func action<T>(success: String? = nil, _ work: () async throws -> T) async -> T? {
        if busy { return nil }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            let result = try await work()
            if let success { notice = success }
            await refresh()
            return result
        } catch {
            self.error = plainMessage(error)
            await refresh()
            return nil
        }
    }

    func switchModel(_ key: String) async {
        if let result = await action({ try await backend.switchTo(key: key) }) { notice = "Now using \(result.name). Your next message starts it." }
    }

    func forgetModel(_ key: String) async {
        await action(success: "Removed from your list. Nothing was deleted from your computer.") { try await backend.forget(key: key) }
    }

    func startModel() async {
        let server = status?.config.model.source == "server"
        await action(success: server ? "Connecting to your local server." : "Starting your local model.") { try await backend.startModel() }
    }

    func stopModel() async {
        await action(success: "Model stopped.") { try await backend.stopModel() }
    }

    func saveModel(_ form: JSONValue) async {
        if let flag = await action(success: "Model saved. Send a message to begin.", { try await backend.saveSetup(form) }) {
            if let warning = flag.warning { notice = warning }
            manualSetup = false
            if welcome != nil { welcome = .agents } else { startChat(.chat) }
        }
    }

    func addModels(_ items: [JSONValue]) async -> Bool {
        let result = await action { try await backend.add(models: items) }
        guard result != nil else { return false }
        await refresh()
        return true
    }

    func scanApps() async {
        let backend = self.backend
        installed = await Task.detached { backend.discoverApps() }.value
    }

    func connect(app: FoundApp) async {
        await action(success: "\(app.name) connected. Open it from here any time.") { try await backend.connect(harness: app.id) }
    }

    func open(harness: HarnessEntry) async {
        await action(success: "\(harness.name) opened with \(modelName).") { try await backend.launch(harness: harness.id) }
    }

    func saveIntegrations(_ settings: IntegrationSettings) async -> Bool {
        let value = (try? JSONValue.parse(JSONEncoder().encode(settings))) ?? JSONValue.null
        return await action(success: "Agent connections saved.") { try await backend.saveIntegrations(value) } != nil
    }

    func openDataFolder() {
        do { NSWorkspace.shared.open(URL(fileURLWithPath: try backend.dataFolderPath())) } catch { self.error = plainMessage(error) }
    }

    func openHelp(_ topic: String) {
        do { if let url = URL(string: try backend.helpLink(topic: topic)) { NSWorkspace.shared.open(url) } } catch { self.error = plainMessage(error) }
    }

    /// Asks the person for a file or folder with the system chooser.
    func choose(_ kind: String) -> String? {
        do { return FileChooser.choose(try backend.pickerRequest(kind)) } catch { self.error = plainMessage(error); return nil }
    }

    // MARK: Conversations

    /// Sends a message. `false` leaves the words in the composer so nothing is lost.
    @discardableResult
    func send(_ text: String, mode: String) -> Bool {
        if sending { return false }
        sending = true
        error = nil
        defer { sending = false }
        let payload = pending ?? PendingRequest(id: UUID().uuidString.lowercased(), message: text, mode: mode, kind: currentKind,
                                                threadId: threadId, project: threadId == nil ? projectId : nil)
        pending = payload
        do {
            let result = try backend.submit(message: payload.message, kind: payload.kind.rawValue, mode: payload.mode, requestId: payload.id,
                                            threadId: payload.threadId, project: payload.project)
            pending = nil
            let key = draftKey
            threadId = result.threadId
            thread = backend.thread(result.threadId)
            drafts.clear(key)
            Task { await refresh() }
            return true
        } catch {
            // A message the Backend already saved is recovered, not sent twice.
            if let saved = backend.request(payload.id) {
                pending = nil
                threadId = saved.threadId
                thread = backend.thread(saved.threadId)
                drafts.clear(draftKey)
                Task { await refresh() }
                return true
            }
            if error is BlackTeamError { pending = nil }
            self.error = error is BlackTeamError ? plainMessage(error) : "The message could not be sent. Retry it to recover the same response."
            return false
        }
    }

    /// Sends the last question again after a failed or stopped reply.
    func retryLast() {
        guard let last = messages.last(where: { $0.isUser }) else { return }
        send(last.content, mode: drafts.draft(draftKey).mode)
    }

    func cancel() {
        _ = backend.cancel()
        Task { await refresh() }
    }

    func approve(_ choice: String) {
        guard let approval = status?.job?.approval else { return }
        do { try backend.approve(id: approval.id, digest: approval.digest, choice: choice) } catch { self.error = plainMessage(error) }
        Task { await refresh() }
    }

    func undo(_ id: String) -> Bool {
        do {
            let result = try backend.undo(id)
            notice = result.removed ? "Removed \(result.path), which this edit had created." : "Put \(result.path) back as it was."
            return true
        } catch { self.error = plainMessage(error); return false }
    }

    func remember(_ message: ChatMessage) {
        let title = String(message.content.replacingOccurrences(of: "[#*_`>\\[\\]]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(48))
        do {
            let id = try backend.memoryRemember(title: title.isEmpty ? "Saved reply" : title, text: String(message.content.prefix(4000)), project: projectId)
            notice = "Saved to memory as \(id). Open Memory to rename or edit it."
        } catch { self.error = plainMessage(error) }
    }

    func reveal(_ file: PublishedFile) {
        do { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: try backend.artifactFile(file.id).path)]) }
        catch { self.error = plainMessage(error) }
    }

    /// Saves a published file under its own name in Downloads and opens it.
    func open(file: PublishedFile) {
        do {
            let source = URL(fileURLWithPath: try backend.artifactFile(file.id).path)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            var target = downloads.appendingPathComponent(file.name)
            var n = 1
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (file.name as NSString).deletingPathExtension, ext = (file.name as NSString).pathExtension
                target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try FileManager.default.copyItem(at: source, to: target)
            NSWorkspace.shared.open(target)
        } catch { self.error = (error as? BlackTeamError)?.message ?? "That file could not be opened." }
    }
}

/// What the menu bar and the app delegate call.
extension AppModel {
    public func showAbout() { AboutPanel.show(version: version, runtime: status?.downloadedRuntime?.tag) }
    public func openSettings() { showSettings(.model) }
    public func newChat() { startChat(.chat) }
    public func newCodeConversation() { startChat(.agent) }
    public func stopResponse() { cancel() }
    public var canStopResponse: Bool { activeJob }
    public func goToWorkspace() { navigate(.workspace) }
    public func goToChat() { showMode(.chat) }
    public func goToCode() { showMode(.agent) }
    public func goToMemory() { navigate(.memory) }
}
