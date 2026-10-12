import Foundation

// Port of lib/phone.cjs: finds Tailscale, and manages the one `tailscale serve` route Black Team owns
// (HTTPS 8449 -> http://127.0.0.1:18199). It never overwrites another app's route and never touches Funnel.

public enum Phone {
    public static let localPort = 18199
    public static let phonePort = 8449
    public static let target = "http://127.0.0.1:\(localPort)"
    public static let command = "tailscale serve --bg --https=\(phonePort) \(target)"
}

/// What a Tailscale command can fail with. `notFound` is the JavaScript's `ENOENT`: the tool is not installed.
public struct PhoneCommandError: Error, Equatable, Sendable {
    public var notFound: Bool
    public var message: String
    public init(notFound: Bool = false, message: String = "") { self.notFound = notFound; self.message = message }
}

/// Runs `executable` (always "tailscale"; the default runner finds the real file) and returns its output.
public typealias PhoneCommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> String

/// Where the phone settings live. `ConfigStore` is the real one; tests use a fake.
public protocol PhoneConfigStoring: AnyObject, Sendable {
    func readPhone() throws -> PhoneConfig
    func savePhone(_ phone: PhoneConfig) throws
}

extension ConfigStore: PhoneConfigStoring {
    public func readPhone() throws -> PhoneConfig { try read().phone }
    public func savePhone(_ phone: PhoneConfig) throws {
        try save(["phone": ["enabled": .bool(phone.enabled), "hostname": .string(phone.hostname), "owner": .string(phone.owner)]])
    }
}

public struct PhoneDetection: Codable, Equatable, Sendable {
    public var installed: Bool
    public var online: Bool
    public var hostname: String
    public var owner: String
    public var error: String?
}

public struct PhoneStatus: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var connected: Bool
    public var url: String
    public var command: String
}

public struct PhoneRouteState: Equatable, Sendable {
    public var owned: Bool
    public var publicRoute: Bool
    public var occupied: Bool
}

/// JavaScript truthiness for the few values `tailscale serve status --json` holds.
private func truthy(_ value: JSONValue?) -> Bool {
    switch value {
    case .none, .some(.null): return false
    case .some(.bool(let flag)): return flag
    case .some(.number(let number)): return number != 0
    case .some(.string(let text)): return !text.isEmpty
    default: return true
    }
}

private let hostnamePattern = try! NSRegularExpression(pattern: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.[a-z0-9-]+\.ts\.net\z"#)
private let ownerForbidden = try! NSRegularExpression(pattern: #"[\s\x00-\x1f\x7f]"#)

/// Accepts a private Tailscale DNS name and a plain account login, and nothing else.
public func validatePhone(enabled: Bool, hostname rawHostname: String, owner rawOwner: String) throws -> PhoneConfig {
    var hostname = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if hostname.hasSuffix(".") { hostname.removeLast() }
    let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
    func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    if !hostname.isEmpty && !matches(hostnamePattern, hostname) { throw BlackTeamError("Use this computer\u{2019}s private Tailscale hostname.") }
    if !owner.isEmpty && (owner.utf16.count > 120 || matches(ownerForbidden, owner)) { throw BlackTeamError("Use your Tailscale account login.") }
    if enabled && (hostname.isEmpty || owner.isEmpty) { throw BlackTeamError("Detect this computer and its Tailscale owner first.") }
    return PhoneConfig(enabled: enabled, hostname: hostname, owner: owner)
}

/// What `tailscale serve status --json` says about port 8449 for this computer.
public func phoneRouteState(_ status: JSONValue, hostname: String) -> PhoneRouteState {
    let port = String(Phone.phonePort)
    let key = "\(hostname):\(port)"
    let web = status["Web"]?[key]
    let tcp = status["TCP"]?[port]
    let handlers = web?["Handlers"]?.object ?? [:]
    let owned = handlers["/"]?["Proxy"]?.string == Phone.target && handlers.count == 1 && tcp?["HTTPS"]?.bool == true
    let publicRoute = status["AllowFunnel"]?[key]?.bool == true
    let occupied = truthy(tcp) || truthy(web) || (status["Web"]?.object ?? [:]).keys.contains { $0.hasSuffix(":\(port)") }
    return PhoneRouteState(owned: owned, publicRoute: publicRoute, occupied: occupied)
}

public actor PhoneManager {
    private let store: PhoneConfigStoring
    private let run: PhoneCommandRunner
    private let clock: @Sendable () -> Date
    private var cache: (key: PhoneConfig, at: Date, value: PhoneStatus)?

    public init(configStore: PhoneConfigStoring, run: @escaping PhoneCommandRunner = Tailscale.run, clock: @escaping @Sendable () -> Date = { Date() }) {
        store = configStore; self.run = run; self.clock = clock
    }

    private func command(_ arguments: [String]) async throws -> String { try await run("tailscale", arguments, 10) }

    private func json(_ arguments: [String]) async throws -> JSONValue { try JSONValue.parse(try await command(arguments)) }

    public func detect() async -> PhoneDetection {
        do {
            let state = try await json(["status", "--json"])
            let me = state["Self"]
            let userID = me?["UserID"].flatMap { value -> String? in value.int.map(String.init) ?? value.string }
            var hostname = me?["DNSName"]?.string ?? ""
            if hostname.hasSuffix(".") { hostname.removeLast() }
            return PhoneDetection(installed: true, online: state["BackendState"]?.string == "Running" && me?["Online"]?.bool != false,
                                  hostname: hostname.lowercased(), owner: userID.flatMap { state["User"]?[$0]?["LoginName"]?.string } ?? "", error: nil)
        } catch {
            return PhoneDetection(installed: !((error as? PhoneCommandError)?.notFound ?? false), online: false, hostname: "", owner: "",
                                  error: "Tailscale is unavailable. Install it and sign in, then detect again.")
        }
    }

    public func status(fresh: Bool = false) async throws -> PhoneStatus {
        let phone = try store.readPhone()
        if !fresh, let cache, cache.key == phone, clock().timeIntervalSince(cache.at) < 5 { return cache.value }
        var connected = false
        if phone.enabled {
            let me = await detect()
            if me.online && me.hostname == phone.hostname && me.owner == phone.owner {
                // An unavailable route is disconnected, never assumed private.
                if let state = try? await json(["serve", "status", "--json"]) {
                    let route = phoneRouteState(state, hostname: phone.hostname)
                    connected = route.owned && !route.publicRoute
                }
            }
        }
        let value = PhoneStatus(enabled: phone.enabled, connected: connected, url: phone.enabled ? "https://\(phone.hostname):\(Phone.phonePort)/" : "", command: Phone.command)
        cache = (phone, clock(), value)
        return value
    }

    public func setup() async throws -> PhoneStatus {
        let me = await detect()
        if !me.installed || !me.online { throw BlackTeamError("Install Tailscale on this computer and sign in, then try again.") }
        let next = try validatePhone(enabled: true, hostname: me.hostname, owner: me.owner)
        let previous = try store.readPhone()
        if previous.enabled && (previous.hostname != next.hostname || previous.owner != next.owner) {
            throw BlackTeamError("Your Tailscale account or computer has changed. Turn off the existing phone setup before connecting this account.")
        }
        try store.savePhone(next)
        // A failed route setup remains retryable and never claims to be connected.
        return try await connect()
    }

    public func connect() async throws -> PhoneStatus {
        let current = try store.readPhone()
        let phone = try validatePhone(enabled: current.enabled, hostname: current.hostname, owner: current.owner)
        if !phone.enabled { throw BlackTeamError("Save and enable Companion first.") }
        let me = await detect()
        if !me.online || me.hostname != phone.hostname || me.owner != phone.owner {
            throw BlackTeamError("Tailscale must be online with the saved computer and owner. Detect and save again.")
        }
        let route = phoneRouteState(try await json(["serve", "status", "--json"]), hostname: phone.hostname)
        if route.publicRoute || (route.occupied && !route.owned) { throw BlackTeamError("Port \(Phone.phonePort) is used by another or public route. Black Team will not overwrite it.") }
        if !route.owned { _ = try await command(["serve", "--bg", "--https=\(Phone.phonePort)", "--yes", Phone.target]) }
        cache = nil
        let result = try await status(fresh: true)
        if !result.connected { throw BlackTeamError("Companion route could not be verified. Check Tailscale Serve configuration.") }
        return result
    }

    public struct Disabled: Equatable, Sendable { public var disabled = true; public var warning: String? }

    public func disable() async throws -> Disabled {
        // Stop accepting remote requests even if Tailscale is offline or route cleanup fails.
        var phone = try store.readPhone()
        phone.enabled = false
        try store.savePhone(phone)
        cache = nil
        do { _ = try await disconnect(); return Disabled() }
        catch { return Disabled(warning: "Phone access is off. Its Tailscale route could not be removed; check Tailscale when it is available.") }
    }

    public func disconnect() async throws -> PhoneStatus {
        let phone = try store.readPhone()
        let route = phoneRouteState(try await json(["serve", "status", "--json"]), hostname: phone.hostname)
        if route.occupied && (!route.owned || route.publicRoute) { throw BlackTeamError("Port \(Phone.phonePort) no longer belongs exclusively to Black Team. Adjust it in Tailscale.") }
        if route.owned { _ = try await command(["serve", "--https=\(Phone.phonePort)", "off"]) }
        cache = nil
        return try await status(fresh: true)
    }
}

// MARK: Finding and running Tailscale on a Mac

public enum Tailscale {
    /// The Tailscale app's own command-line tool first (neither the App Store nor the standalone app puts it on the PATH),
    /// then `tailscale` from Homebrew, /usr/local and the PATH.
    public static func candidates(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var list = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        for folder in (path ?? "").split(separator: ":") where folder.hasPrefix("/") { list.append(String(folder) + "/tailscale") }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    public static func locate(path: String? = ProcessInfo.processInfo.environment["PATH"],
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates(path: path).first(where: isExecutable)
    }

    /// Runs the command with no shell, a time limit and a 1 MB output limit.
    public static let run: PhoneCommandRunner = { _, arguments, timeout in
        guard let executable = locate() else { throw PhoneCommandError(notFound: true, message: "Tailscale is not installed.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: PhoneCommandError(notFound: (error as NSError).code == NSFileNoSuchFileError, message: "Tailscale could not start."))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                var data = Data(), tooLarge = false
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > 1024 * 1024 { tooLarge = true; process.terminate(); break }
                }
                process.waitUntilExit()
                timer.cancel()
                if tooLarge || process.terminationStatus != 0 {
                    continuation.resume(throwing: PhoneCommandError(message: tooLarge ? "Tailscale printed too much." : "Tailscale exited with status \(process.terminationStatus)."))
                } else {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        }
    }
}
