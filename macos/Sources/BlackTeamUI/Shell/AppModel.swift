import SwiftUI
import AppKit
import BlackTeamKit

/// The two windows: the Command center ("Black Team") and Camp ("Black Team Camp").
public enum CommandPage: String { case overview, diagnostics }
public enum CampPage: String { case chat, memory, plugins, dsh, servers }

/// One line of "Recent activity": a launch or a model start or stop in this session.
struct ActivityEvent: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var time: String
}

/// A saved model as the Command center's cards show it.
struct ModelCardInfo: Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var active: Bool
    /// ready, starting, error or off
    var state: String
    /// A cloud model: the card says "Cloud" where a local one says Ready or Off.
    var cloud = false
    var provider = ""
}

/// A card in "Choose your harness".
struct HarnessCardInfo: Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var kind: String
    var builtIn: Bool
}

/// The words in the composer, kept per conversation so they survive moving around the app.
struct Draft: Equatable {
    var message = ""
    var mode = "balanced"
    /// Prepared pictures, held in memory until the message is sent (they are lost when the app closes).
    var images: [DraftImage] = []
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
    func set(_ key: String, images: [DraftImage]) { var d = draft(key); d.images = images; items[key] = d }
    func clear(_ key: String) { var d = draft(key); d.message = ""; d.images = []; items[key] = d }
}

/// A message that may already be saved: retried with the same request id so it is never sent twice.
struct PendingRequest: Equatable {
    var id: String
    var message: String
    var mode: String
    var kind: ChatKind
    var threadId: String?
    var project: String?
    var images: [DraftImage] = []
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
    static let launched = Date()

    let backend: Backend
    public let version: String
    let drafts = DraftStore()
    let starter = StarterDownload()
    let finder = ModelFinder()
    let memory = MemoryModel()
    let phone = PhoneModel()
    /// Set by the windows so the model can bring the other one forward.
    public var openCamp: () -> Void = {}
    public var openCommand: () -> Void = {}

    @Published var status: BackendStatus?
    @Published var statusFailure: String?
    @Published var commandPage: CommandPage = .overview
    @Published var campPage: CampPage = .chat
    @Published var showConfig = false
    @Published var selectedHarness = "chat"
    @Published var events: [ActivityEvent] = []
    @Published var log: [String] = []
    @Published var launching = false
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
    @Published var installed: DiscoveryResult?
    @Published var startupNotice: String?
    /// Pictures are being prepared, or the vision file is being fetched.
    @Published var preparing = false
    @Published var visionInstall = VisionInstall()
    /// What would happen if the open conversation (or the new one) were sent from here: the notice before a first cloud send.
    @Published var privacyNow = PrivacyCheck()
    /// Set when a send was refused for privacy; the screen shows it with its choices where errors appear.
    @Published var refusal: PrivacyCheck?
    let imageCache = NSCache<NSString, NSImage>()

    private var lastRuntimeError = ""
    private var loops: [Task<Void, Never>] = []
    private var refreshing = false
    private var refreshAgain = false
    private var lastStatusAt = Date.distantPast
    private var statusScheduled = false

    // MARK: Start

    /// The real app: opens the data folder (BLACK_TEAM_DATA, or Application Support) and starts watching it.
    public convenience init() {
        _ = AppModel.launched
        let (backend, notice) = AppModel.openBackend()
        self.init(backend: backend, live: true)
        startupNotice = notice
    }

    /// `live: false` builds a model that does not watch anything, for the snapshot tests.
    init(backend: Backend, live: Bool) {
        self.backend = backend
        self.version = backend.version
        phone.autoRefresh = live
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
        // Phone access listens from launch if it was left on. A port that is taken is shown on the Servers page.
        loops.append(Task { [weak self] in
            do { try await backend.startPhoneAccess() } catch { self?.phone.error = plainMessage(error) }
        })
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
        updatePrivacy()
        guard let id = threadId else { return }
        let next = backend.thread(id)
        if next != thread { thread = next }
    }

    /// Asks the Backend what a send from here would do. The Backend decides again when a message is really sent.
    func updatePrivacy() {
        guard status != nil else { return }
        let next = backend.privacyCheck(threadId: threadId, project: threadId == nil ? projectId : nil, kind: currentKind.rawValue)
        if next != privacyNow { privacyNow = next }
        if refusal != nil, !next.refused { refusal = nil }
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
                let failure = next.runtime.error ?? ""
                if failure != lastRuntimeError { lastRuntimeError = failure; if !failure.isEmpty { note("\(modelName): \(failure)") } }
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

    // MARK: Where words go

    var cloud: CloudStatus { status?.cloud ?? CloudStatus() }
    var cloudSelected: Bool { cloud.selected }

    /// Whether the open conversation (or, for a new one, the model that would start it) leaves this Mac, and for where.
    var leavesThisMac: (cloud: Bool, provider: String) {
        if let thread, thread["privacy"]?.string == "cloud" { return (true, thread["provider"]?.string ?? "") }
        if thread != nil { return (false, "") }
        return (cloudSelected, cloud.provider)
    }

    /// Tokens used so far in the open cloud conversation.
    var usage: CloudUsage? {
        guard thread?["privacy"]?.string == "cloud", let saved = thread?["usage"] else { return nil }
        return CloudUsage(json: saved)
    }
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

    func showCamp(_ next: CampPage) {
        campPage = next
        error = nil
        notice = nil
    }

    func showCommand(_ next: CommandPage) {
        commandPage = next
        error = nil
        notice = nil
    }

    func openThread(_ id: String?) {
        if locked { campPage = .chat; return }
        threadId = id
        thread = id.flatMap { backend.thread($0) }
        campPage = .chat
        error = nil
        refusal = nil
        updatePrivacy()
        chatKey += 1
    }

    func startChat(_ kind: ChatKind) {
        if locked { campPage = .chat; return }
        newKind = kind
        openThread(nil)
    }

    /// The mode switch: show the open conversation if it is of that kind, else start one.
    func showMode(_ kind: ChatKind) {
        if campPage == .chat, currentKind == kind { return }
        if campPage != .chat, currentKind == kind, (threadId != nil || newKind == kind) {
            campPage = .chat; error = nil; notice = nil
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
        if locked { campPage = .chat; return }
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
            note("Error: \(plainMessage(error))")
            await refresh()
            return nil
        }
    }

    func switchModel(_ key: String) async {
        if let result = await action({ try await backend.switchTo(key: key) }) {
            updatePrivacy()
            let cloudNow = status?.cloud.selected == true
            notice = cloudNow ? "Now using \(result.name). Conversations with it leave this Mac." : "Now using \(result.name). Your next message starts it."
            record("Switched to \(result.name)")
        }
    }

    func forgetModel(_ key: String) async {
        await action(success: "Removed from your list. Nothing was deleted from your computer.") { try await backend.forget(key: key) }
    }

    func startModel() async {
        let server = status?.config.model.source == "server"
        let name = modelName
        if await action(success: server ? "Connecting to your local server." : "Starting your local model.", { try await backend.startModel() }) != nil {
            record("Started \(name)")
        }
    }

    func stopModel() async {
        let name = modelName
        if await action(success: "Model stopped.", { try await backend.stopModel() }) != nil { record("Stopped \(name)") }
    }

    /// The Camp "Servers & access" cards act on any saved model: it becomes the model in use first.
    func setServer(_ key: String, on: Bool) async {
        if status?.models.first(where: { $0.active })?.key != key {
            guard await action({ try await backend.switchTo(key: key) }) != nil else { return }
        }
        if on { await startModel() } else { await stopModel() }
    }

    /// "Open agent workspace": the model becomes the one in use, then Code opens in Camp.
    func openAgentWorkspace(_ key: String) async {
        if status?.models.first(where: { $0.active })?.key != key {
            guard await action({ try await backend.switchTo(key: key) }) != nil else { return }
        }
        startChat(.agent)
        openCamp()
        record("Opened Black Team Code with \(modelName)")
    }

    func saveModel(_ form: JSONValue) async {
        if let flag = await action(success: "Model saved. Send a message to begin.", { try await backend.saveSetup(form) }) {
            if let warning = flag.warning { notice = warning }
            showConfig = false
            record("Saved \(modelName)")
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
        if await action(success: "\(harness.name) opened with \(modelName).", { try await backend.launch(harness: harness.id) }) != nil {
            record("\(harness.name) opened with \(modelName)")
        }
    }

    func openDataFolder() {
        do { NSWorkspace.shared.open(URL(fileURLWithPath: try backend.dataFolderPath())) } catch { self.error = plainMessage(error) }
    }

    /// Adds a line to "Recent activity" and to the diagnostics log.
    func record(_ text: String) {
        events.insert(ActivityEvent(text: text, time: Date().formatted(date: .omitted, time: .shortened)), at: 0)
        if events.count > 6 { events.removeLast(events.count - 6) }
        note(text)
    }

    func note(_ text: String) {
        let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute().second())
        log.append("\(stamp) \(text)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
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
    func send(_ text: String, mode: String, images given: [DraftImage]? = nil) -> Bool {
        if sending { return false }
        sending = true
        error = nil
        defer { sending = false }
        let images = given ?? pending?.images ?? drafts.draft(draftKey).images
        if currentKind == .agent, !images.isEmpty { error = ImageRules.codeRefusal; return false }
        // A private conversation is not sent to a cloud model, and a local-only project does not use one. The Backend refuses it too;
        // asking first lets the screen offer the choices instead of an error.
        if pending == nil {
            let check = backend.privacyCheck(threadId: threadId, project: threadId == nil ? projectId : nil, kind: currentKind.rawValue)
            if check.refused { refusal = check; return false }
        }
        refusal = nil
        let payload = pending ?? PendingRequest(id: UUID().uuidString.lowercased(), message: text, mode: mode, kind: currentKind,
                                                threadId: threadId, project: threadId == nil ? projectId : nil, images: images)
        pending = payload
        do {
            let result = try backend.submit(message: payload.message, kind: payload.kind.rawValue, mode: payload.mode, requestId: payload.id,
                                            threadId: payload.threadId, project: payload.project, images: payload.images.map(\.upload))
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
            let check = backend.privacyCheck(threadId: payload.threadId, project: payload.project, kind: payload.kind.rawValue)
            if check.refused { refusal = check; return false }
            self.error = error is BlackTeamError ? plainMessage(error) : "The message could not be sent. Retry it to recover the same response."
            return false
        }
    }

    /// Sends the last question again after a failed or stopped reply.
    func retryLast() {
        guard let last = messages.last(where: { $0.isUser }) else { return }
        // The pictures of that message are read back from their files, so a retry sends them again.
        let images = last.images.compactMap { ref in
            (try? backend.image(threadId: threadId ?? "", imageId: ref.id)).map { DraftImage(ImageUpload(name: ref.name, data: $0.data)) }
        }
        send(last.content, mode: drafts.draft(draftKey).mode, images: images)
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
    public func newConversation() { startChat(currentKind); openCamp() }
    public func stopResponse() { cancel() }
    public var canStopResponse: Bool { activeJob }
    public func showAbout() { AboutPanel.show(version: version, runtime: status?.downloadedRuntime?.tag) }
}

/// The standard About panel, with the version and the runtime in the credits.
enum AboutPanel {
    @MainActor static func show(version: String, runtime: String?) {
        let credits = NSAttributedString(string: "Private AI. Total control.\nLocal by default. A cloud model is used only when you choose one." + (runtime.map { "\nllama.cpp build \($0)" } ?? ""),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Black Team", .applicationVersion: version, .version: "", .credits: credits,
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: Choices after a privacy refusal

extension AppModel {
    /// "Start a new cloud conversation": the words stay in the box and go to a fresh conversation, which the pre-send notice describes.
    func startNewCloudConversation() {
        let old = drafts.draft(draftKey)
        refusal = nil
        startChat(currentKind)
        drafts.set(draftKey, message: old.message)
        drafts.set(draftKey, mode: old.mode)
        updatePrivacy()
    }

    /// "Switch back to <local model>": the model changes, the words stay in the box.
    func switchBackToLocal(_ check: PrivacyCheck) async {
        guard !check.localModelKey.isEmpty else { return }
        await switchModel(check.localModelKey)
        refusal = nil
    }

    /// "Send this conversation to <service>", after the person has read the confirmation that names the service. The whole conversation
    /// so far goes with the next message, which is sent right away.
    func sendToCloud(_ check: PrivacyCheck) {
        guard let id = threadId else { return }
        do {
            try backend.convertToCloud(threadId: id, confirmingProvider: check.provider)
            thread = backend.thread(id)
            refusal = nil
            updatePrivacy()
            let draft = drafts.draft(draftKey)
            send(draft.message.trimmingCharacters(in: .whitespacesAndNewlines), mode: draft.mode)
        } catch { self.error = plainMessage(error) }
    }

    /// A project row's menu: cloud models are refused in a project until it is allowed here, once, on purpose.
    func setProjectCloud(_ project: ProjectSummary, allowed: Bool) async {
        await action(success: allowed ? "\(project.name) may now use cloud models. Conversations in it that use one leave this Mac."
                                       : "\(project.name) is local only again.") {
            _ = try backend.setProjectCloud(project.id, allowed: allowed, confirmed: allowed)
        }
        updatePrivacy()
    }
}
