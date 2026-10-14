import Foundation

// A background service must not sit on a laptop's memory. When the model has had nothing to do for a while (no job, no scheduled run
// going or waiting its turn, no conversation lately, no open window), it is stopped to free its memory. The next message, run or
// "start model" starts it again; nothing else is needed. A model that is running a job is never stopped.

public final class IdleUnloader: @unchecked Sendable {
    /// A window that has asked for anything this recently counts as open.
    public static let windowGrace: TimeInterval = 20

    private let backend: Backend
    private let scheduler: Scheduler?
    private let settings: @Sendable () -> ServiceSettings
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastBusy: Date
    private var lastWindow: Date?
    private var unloadedAt: Date?
    private var loop: Task<Void, Never>?

    public init(backend: Backend, scheduler: Scheduler?, settings: @escaping @Sendable () -> ServiceSettings, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend; self.scheduler = scheduler; self.settings = settings; self.now = now
        lastBusy = now()
    }

    /// A window (not the command) just talked to the service.
    public func noteWindow() { lock.lock(); lastWindow = now(); lock.unlock() }

    /// The last time a window talked to the service.
    var windowSeenAt: Date? { lock.lock(); defer { lock.unlock() }; return lastWindow }

    /// When the model was last unloaded to free memory, if it is still unloaded.
    public var unloaded: Date? { lock.lock(); defer { lock.unlock() }; return unloadedAt }

    public func start(every seconds: TimeInterval = 30) {
        lock.lock(); defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.tick()
            }
        }
    }

    public func stop() { lock.lock(); let task = loop; loop = nil; lock.unlock(); task?.cancel() }

    /// One look. Returns true when it stopped the model.
    @discardableResult
    public func tick() async -> Bool {
        let moment = now()
        let state = await backend.runtime.status()
        let up = state.state == .ready || state.state == .starting
        let window: Bool = lock.withLock {
            if up { unloadedAt = nil }
            return lastWindow.map { moment.timeIntervalSince($0) < Self.windowGrace } ?? false
        }
        // Nothing is loaded, or something is using it: the idle clock starts again from now.
        let working = backend.modelSlotBusy || state.busy || (scheduler?.hasWork ?? false) || window
        if !up || working { lock.withLock { lastBusy = moment }; return false }
        let minutes = settings().idleMinutes
        guard minutes > 0 else { return false }
        // The latest sign of anything happening: a job that ended, a scheduled run that ended, or a tick that saw work.
        let busyAt = lock.withLock { lastBusy }
        let latest = [busyAt, backend.locked { backend.lastActivity }, scheduler?.lastWorkAt ?? .distantPast].max() ?? busyAt
        guard moment.timeIntervalSince(latest) >= Double(minutes) * 60 else { return false }
        do { try await backend.runtime.stop(force: false) } catch { return false }
        lock.withLock { unloadedAt = moment }
        backend.changed()
        return true
    }
}
