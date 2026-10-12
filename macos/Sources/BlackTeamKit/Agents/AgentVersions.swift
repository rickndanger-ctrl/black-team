import Foundation

/// What the person is told about a subscription agent's version. `installed` and `latest` are nil when unknown.
public struct AgentUpdateStatus: Equatable, Sendable {
    public let installed: String?
    public let latest: String?
    /// True only when both versions are known and the latest is newer than the installed one.
    public let updateAvailable: Bool

    public init(installed: String?, latest: String?) {
        self.installed = installed
        self.latest = latest
        updateAvailable = AgentVersions.isNewer(latest, than: installed)
    }
}

/// Finds the installed version of a subscription agent and the latest published one. Nothing here updates anything.
/// Every failure is "unknown": the person is never shown an error for a version check.
public enum AgentVersions {
    /// How long a check is kept before the registry is asked again.
    public static let cacheInterval: TimeInterval = 12 * 60 * 60
    /// The most output read from `--version`.
    static let versionLimit = 4096
    /// The longest `--version` may take.
    static let versionTimeout: TimeInterval = 5
    /// The largest registry response read.
    static let registryLimit = 256 * 1024

    /// The npm registry entry that names the newest published version of the tool.
    static func registryURL(_ service: AgentService) -> URL {
        let package = service == .claudeCode ? "@anthropic-ai/claude-code" : "@openai/codex"
        return URL(string: "https://registry.npmjs.org/\(package)/latest")!
    }

    /// The first `x.y.z` in a tool's `--version` output, e.g. "codex-cli 0.162.1" or "2.1.289 (Claude Code)".
    public static func parseVersion(_ output: String) -> String? {
        output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(output[$0]) }
    }

    /// The version the installed tool reports, or nil when it is not installed, does not answer within 5 seconds, or says none.
    /// `executable` defaults to the copy the person's shell finds first.
    public static func installedVersion(service: AgentService, executable: String? = nil) async -> String? {
        guard let path = executable ?? AgentTools.locate(service.program) else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            process.environment = AgentTools.environment()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + versionTimeout, execute: limit)
            var data = Data()
            while data.count < versionLimit {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data += chunk
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            limit.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return parseVersion(String(decoding: data.prefix(versionLimit), as: UTF8.self))
        }.value
    }

    /// The newest version the registry lists for the tool, or nil on any failure: a network error, a redirect (not
    /// followed), a response that is not 200, a body over 256 KB, or JSON without a version.
    public static func latestVersion(service: AgentService, fetch: HTTPFetch = LocalHTTP.fetch) async -> String? {
        var request = URLRequest(url: registryURL(service))
        request.timeoutInterval = 10
        guard let result = try? await fetch(request), result.1.statusCode == 200, result.0.count <= registryLimit else { return nil }
        guard let version = (try? JSONValue.parse(result.0))?["version"]?.string, parseVersion(version) == version else { return nil }
        return version
    }

    /// True when `latest` is a newer x.y.z than `installed`. False when either is unknown or they are equal.
    public static func isNewer(_ latest: String?, than installed: String?) -> Bool {
        guard let latest, let installed, let wanted = parts(latest), let have = parts(installed) else { return false }
        return have.lexicographicallyPrecedes(wanted)
    }

    private static func parts(_ version: String) -> [Int]? {
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
}

/// The last check of each tool, kept for `AgentVersions.cacheInterval` in memory and in `agent-versions.json`.
final class AgentVersionStore: @unchecked Sendable {
    struct Check: Equatable {
        var checked: Date
        var latest: String?
    }

    private let lock = NSLock()
    private let file: String
    private var checks: [String: Check]?

    init(dataFolder: String) { file = dataFolder + "/agent-versions.json" }

    /// The latest version from a check made within the last 12 hours, or else a new check (which is kept, even when it failed).
    func latest(service: AgentService, now: Date, fetch: HTTPFetch) async -> String? {
        if let fresh = freshCheck(service, now: now) { return fresh.latest }
        let latest = await AgentVersions.latestVersion(service: service, fetch: fetch)
        record(service, Check(checked: now, latest: latest))
        return latest
    }

    private func freshCheck(_ service: AgentService, now: Date) -> Check? {
        lock.lock(); defer { lock.unlock() }
        if checks == nil { checks = loadChecks() }
        guard let check = checks?[service.rawValue], check.checked <= now, now.timeIntervalSince(check.checked) < AgentVersions.cacheInterval else {
            return nil
        }
        return check
    }

    private func record(_ service: AgentService, _ check: Check) {
        lock.lock(); defer { lock.unlock() }
        if checks == nil { checks = loadChecks() }
        checks?[service.rawValue] = check
        var object: [String: JSONValue] = [:]
        for (name, item) in checks ?? [:] {
            var entry: [String: JSONValue] = ["checked": .number(item.checked.timeIntervalSince1970)]
            if let latest = item.latest { entry["latest"] = .string(latest) }
            object[name] = .object(entry)
        }
        // Keeping the last check is a convenience: a failed save only means the next launch checks again.
        try? privateDirectory((file as NSString).deletingLastPathComponent)
        try? writeJSON(file, JSONValue.object(object))
    }

    private func loadChecks() -> [String: Check] {
        guard let data = FileManager.default.contents(atPath: file), let json = try? JSONValue.parse(data), let object = json.object else { return [:] }
        var result: [String: Check] = [:]
        for (name, item) in object {
            guard AgentService(rawValue: name) != nil, let seconds = item["checked"]?.double else { continue }
            result[name] = Check(checked: Date(timeIntervalSince1970: seconds), latest: item["latest"]?.string)
        }
        return result
    }
}

/// One store per data folder, so every Backend that uses a folder shares its in-memory checks.
enum AgentVersionStores {
    private static let lock = NSLock()
    private static var stores: [String: AgentVersionStore] = [:]

    static func store(dataFolder: String) -> AgentVersionStore {
        lock.lock(); defer { lock.unlock() }
        if let existing = stores[dataFolder] { return existing }
        let made = AgentVersionStore(dataFolder: dataFolder)
        stores[dataFolder] = made
        return made
    }
}
