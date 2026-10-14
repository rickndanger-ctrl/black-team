import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A snapshot of a running download, for a progress bar.
public struct DownloadProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    public var totalBytes: Int64?
    /// Smoothed, so the number in the window does not jump about.
    public var bytesPerSecond: Double
    public var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(total))
    }
    public var secondsRemaining: Double? {
        guard let total = totalBytes, bytesPerSecond > 1 else { return nil }
        return Double(max(0, total - bytesReceived)) / bytesPerSecond
    }
    public init(bytesReceived: Int64, totalBytes: Int64?, bytesPerSecond: Double) {
        self.bytesReceived = bytesReceived; self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond
    }
}

/// Hosts a download may be redirected to. Matching is by suffix on a dot boundary, so
/// "hf.co" allows "cdn-lfs.hf.co" but not "evilhf.co".
public enum DownloadHosts {
    /// github.com redirects release assets to release-assets.githubusercontent.com
    /// (older releases: objects.githubusercontent.com).
    public static let github = ["github.com", "githubusercontent.com"]
    /// huggingface.co redirects to its CDN (seen 2026-10: us.aws.cdn.hf.co; also cdn-lfs*.hf.co, *.xethub.hf.co).
    public static let huggingFace = ["huggingface.co", "hf.co"]
    /// A GitHub source archive (`github.com/<owner>/<repo>/archive/<commit>.tar.gz`) redirects to codeload.github.com and nowhere
    /// else. Narrower than `github`: release-asset hosts and other GitHub subdomains are not allowed for it.
    public static let githubArchive = ["codeload.github.com"]

    public static func host(_ host: String, matches suffixes: [String]) -> Bool {
        let host = host.lowercased()
        return suffixes.contains { raw in
            let suffix = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !suffix.isEmpty && (host == suffix || host.hasSuffix("." + suffix))
        }
    }
}

public struct DownloadRequest: Sendable {
    public var url: URL
    /// Absolute final path. The partial file is `<destination>.part`.
    public var destination: URL
    /// Lower- or upper-case hex. Checked while reading the finished file in small pieces.
    public var expectedSHA256: String?
    public var expectedSize: Int64?
    /// The starting host is always allowed; redirects must land on one of these (suffix match).
    public var allowedHostSuffixes: [String]

    public init(url: URL, destination: URL, expectedSHA256: String? = nil, expectedSize: Int64? = nil, allowedHostSuffixes: [String] = []) {
        self.url = url; self.destination = destination; self.expectedSHA256 = expectedSHA256
        self.expectedSize = expectedSize; self.allowedHostSuffixes = allowedHostSuffixes
    }
}

/// What other areas program against, so tests can swap the network out.
public protocol FileDownloading: AnyObject, Sendable {
    /// Returns the destination. Throws `CancellationError` when cancelled (the `.part` file is kept).
    func download(_ request: DownloadRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> URL
    func cancel()
}

public enum DownloadEvent: Sendable, Equatable {
    case progress(DownloadProgress)
    case finished(URL)
}

/// A resumable HTTPS file downloader. Use one instance per download.
public final class Downloader: FileDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let freeSpace: @Sendable (URL) -> Int64?
    private let lock = NSLock()
    private var running = false
    private var currentJob: DownloadJob?
    private var cancelRequested = false
    /// Tests only (reachable through `@testable`, never set by the app): let the first request go to a plain-HTTP server on
    /// 127.0.0.1, so a real local server can be used. Redirects must still be https.
    var allowsPlainLoopbackForTests = false

    /// `configuration` and `freeSpace` exist for tests (a stub URLProtocol, a pretend disk).
    public init(configuration: URLSessionConfiguration? = nil, freeSpace: (@Sendable (URL) -> Int64?)? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.httpShouldSetCookies = false
        self.configuration = config
        self.freeSpace = freeSpace ?? Downloader.systemFreeSpace
    }

    public static let systemFreeSpace: @Sendable (URL) -> Int64? = { url in
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder = folder.deletingLastPathComponent() }
        #if os(Linux)
        return SystemInfo.diskSpace(at: folder.path).map { Int64($0.available) }
        #else
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map { Int64($0) }
        #endif
    }

    /// Progress as a stream for SwiftUI: `for try await event in downloader.events(for: request)`.
    /// Dropping the stream cancels the download.
    public func events(for request: DownloadRequest) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try await self.download(request) { continuation.yield(.progress($0)) }
                    continuation.yield(.finished(url))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the running download and keeps the `.part` file so it can be resumed.
    public func cancel() {
        lock.lock(); cancelRequested = true; let job = currentJob; lock.unlock()
        job?.cancel()
    }

    public func download(_ request: DownloadRequest, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        let plainLoopback = allowsPlainLoopbackForTests && request.url.scheme?.lowercased() == "http" && request.url.host == "127.0.0.1"
        guard request.url.scheme?.lowercased() == "https" || plainLoopback, request.url.host != nil else {
            throw BlackTeamError("Downloads must use a secure https:// address.")
        }
        try begin()
        defer { end() }

        let fm = FileManager.default
        let folder = request.destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let part = URL(fileURLWithPath: request.destination.path + ".part")

        var existing = Downloader.fileSize(part)
        if let expected = request.expectedSize, existing > expected { try? fm.removeItem(at: part); existing = 0 }

        // Enough room for what is still to come, checked before any bytes move.
        if let expected = request.expectedSize {
            try checkSpace(needed: expected - existing, folder: folder)
        }

        var attempts = 0
        while true {
            attempts += 1
            let offset = Downloader.fileSize(part)
            if let expected = request.expectedSize, offset == expected { break }   // already complete
            let outcome = try await runAttempt(request: request, part: part, offset: offset, progress: progress)
            if outcome == .complete { break }
            // 416 on a part we could not use: it was removed, so start again from zero, once.
            if attempts >= 2 { throw BlackTeamError("The download server would not resume or restart the download. Try again later.") }
        }

        try Task.checkCancellation()
        return try await finalize(request: request, part: part)
    }

    // Plain methods, because NSLock may not be used directly in async code.
    private func begin() throws {
        try lock.withLock {
            if running { throw BlackTeamError("A download is already running.") }
            running = true; cancelRequested = false
        }
    }
    private func end() { lock.withLock { running = false; currentJob = nil } }
    private func register(_ job: DownloadJob) -> Bool { lock.withLock { currentJob = job; return cancelRequested } }

    // MARK: Steps

    private func checkSpace(needed: Int64, folder: URL) throws {
        guard needed > 0, let available = freeSpace(folder) else { return }
        if available < needed {
            throw BlackTeamError("Not enough free disk space: this download needs \(Downloader.format(needed)) and only \(Downloader.format(available)) is free. Free up some space and try again.")
        }
    }

    private func runAttempt(request: DownloadRequest, part: URL, offset: Int64, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> DownloadJob.Outcome {
        let job = DownloadJob(request: request, part: part, offset: offset, progress: progress,
                              spaceCheck: { [freeSpace] needed in
                                  guard needed > 0, let available = freeSpace(request.destination.deletingLastPathComponent()), available < needed else { return nil }
                                  return BlackTeamError("Not enough free disk space: this download needs \(Downloader.format(needed)) and only \(Downloader.format(available)) is free. Free up some space and try again.")
                              })
        let alreadyCancelled = register(job)
        if alreadyCancelled || Task.isCancelled { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await job.run(configuration: configuration)
        } onCancel: { job.cancel() }
    }

    private func finalize(request: DownloadRequest, part: URL) async throws -> URL {
        let fm = FileManager.default
        let size = Downloader.fileSize(part)
        if let expected = request.expectedSize, size != expected {
            try? fm.removeItem(at: part)
            throw BlackTeamError("The downloaded file is the wrong size (\(size) bytes instead of \(expected)), so it was deleted. Please try again.")
        }
        if let expected = request.expectedSHA256?.lowercased(), !expected.isEmpty {
            let actual = try await Task.detached(priority: .utility) { try Downloader.sha256(of: part) }.value
            if actual != expected {
                try? fm.removeItem(at: part)
                throw BlackTeamError("The downloaded file did not match its checksum, so it was deleted. Please try again; if it keeps happening the download may have been tampered with.")
            }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
        if fm.fileExists(atPath: request.destination.path) {
            _ = try fm.replaceItemAt(request.destination, withItemAt: part)   // atomic swap
        } else {
            try fm.moveItem(at: part, to: request.destination)               // rename is atomic on one volume
        }
        return request.destination
    }

    // MARK: Helpers

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One network attempt. The delegate runs on a private serial queue.
final class DownloadJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome { case complete, restart }

    private let request: DownloadRequest
    private let part: URL
    private let offset: Int64
    private let progress: (@Sendable (DownloadProgress) -> Void)?
    private let spaceCheck: (Int64) -> BlackTeamError?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private var continuation: CheckedContinuation<Outcome, Error>?

    // Touched only on the delegate queue.
    private var handle: FileHandle?
    private var received: Int64
    private var total: Int64?
    private var failure: Error?
    private var outcome: Outcome = .complete
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64
    private var lastReport = Date.distantPast
    private var rate: Double = 0

    init(request: DownloadRequest, part: URL, offset: Int64, progress: (@Sendable (DownloadProgress) -> Void)?, spaceCheck: @escaping (Int64) -> BlackTeamError?) {
        self.request = request; self.part = part; self.offset = offset; self.progress = progress; self.spaceCheck = spaceCheck
        self.received = offset; self.lastSampleBytes = offset
        self.total = request.expectedSize
    }

    func run(configuration: URLSessionConfiguration) async throws -> Outcome {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Outcome, Error>) in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            var urlRequest = URLRequest(url: request.url)
            urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")   // byte ranges must mean file bytes
            if offset > 0 { urlRequest.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: urlRequest)
            lock.lock()
            continuation = cont; self.session = session; self.task = task
            let already = cancelled
            lock.unlock()
            if already { session.invalidateAndCancel(); finish(.failure(CancellationError())); return }
            task.resume()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<Outcome, Error>) {
        lock.lock(); let cont = continuation; continuation = nil; let session = self.session; lock.unlock()
        session?.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = newRequest.url, url.scheme?.lowercased() == "https", let host = url.host else {
            failure = BlackTeamError("The download server tried to send the file over an insecure connection, so the download was stopped.")
            completionHandler(nil); task.cancel(); return
        }
        let origin = request.url.host ?? ""
        if host.lowercased() == origin.lowercased() || DownloadHosts.host(host, matches: request.allowedHostSuffixes) {
            completionHandler(newRequest)
        } else {
            failure = BlackTeamError("The download was redirected to an unexpected server (\(host)), so it was stopped.")
            completionHandler(nil)
        }
        if failure != nil { task.cancel() }   // do not wait for the redirect reply's body
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if failure != nil { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            failure = BlackTeamError("The download server sent an unexpected reply."); completionHandler(.cancel); return
        }
        let fm = FileManager.default
        switch http.statusCode {
        case 200:
            // The server ignored the Range header (or there was nothing to resume): start over.
            received = 0; lastSampleBytes = 0
            total = http.expectedContentLength > 0 ? http.expectedContentLength : request.expectedSize
        case 206:
            let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.start == offset else {
                try? fm.removeItem(at: part); outcome = .restart; completionHandler(.cancel); return
            }
            total = range.total ?? request.expectedSize
        case 416:
            // The part may already be the whole file ("bytes */TOTAL"); otherwise it is useless.
            let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            if let total = range?.total ?? request.expectedSize, total == offset { outcome = .complete }
            else { try? fm.removeItem(at: part); outcome = .restart }
            completionHandler(.cancel); return
        default:
            failure = BlackTeamError("The download server replied with an error (HTTP \(http.statusCode)). Please try again later.")
            completionHandler(.cancel); return
        }
        if let total, let expected = request.expectedSize, total != expected {
            failure = BlackTeamError("The file on the server is not the size we expected (\(total) bytes instead of \(expected)), so it was not downloaded.")
            completionHandler(.cancel); return
        }
        if let total, let error = spaceCheck(total - received) { failure = error; completionHandler(.cancel); return }
        do {
            if received == 0 || !fm.fileExists(atPath: part.path) {
                received = 0
                fm.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
                handle = try FileHandle(forWritingTo: part)
            } else {
                handle = try FileHandle(forWritingTo: part)
                try handle?.seekToEnd()
            }
            if received == 0 { try handle?.truncate(atOffset: 0) }
        } catch {
            failure = BlackTeamError("Could not write the download to disk: \(error.localizedDescription)")
            completionHandler(.cancel); return
        }
        lastSampleTime = Date(); lastSampleBytes = received
        report(force: true)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch {
            failure = BlackTeamError("Could not write the download to disk: \(error.localizedDescription)")
            dataTask.cancel(); return
        }
        received += Int64(data.count)
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime)
        if dt >= 0.25 {
            let sample = Double(received - lastSampleBytes) / dt
            rate = rate == 0 ? sample : rate * 0.7 + sample * 0.3   // smoothed
            lastSampleTime = now; lastSampleBytes = received
        }
        report(force: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        if let failure { finish(.failure(failure)); return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                lock.lock(); let wasCancelled = cancelled; lock.unlock()
                if wasCancelled { finish(.failure(CancellationError())); return }
                // Cancelled by us after deciding on a 206/416 reply.
                finish(.success(outcome)); return
            }
            finish(.failure(BlackTeamError("The download was interrupted (\(error.localizedDescription)). It will continue where it stopped when you try again.")))
            return
        }
        report(force: true)
        finish(.success(outcome))   // a reply we cancelled on purpose may complete without an error on Linux
    }

    private func report(force: Bool) {
        guard let progress else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastReport) < 0.1 { return }
        lastReport = now
        progress(DownloadProgress(bytesReceived: received, totalBytes: total, bytesPerSecond: rate))
    }

    /// "bytes 100-199/1000" or "bytes */1000".
    static func parseContentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
        guard let value else { return nil }
        let parts = value.replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let total = Int64(parts[1])
        if parts[0] == "*" { return (-1, total) }
        guard let start = Int64(parts[0].split(separator: "-").first ?? "") else { return nil }
        return (start, total)
    }
}
