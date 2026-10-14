import Foundation
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// What the "keep Black Team running in the background" switch writes: one per-user unit that starts `black-team service run` at login
// (a systemd user unit on Linux, a launchd agent on a Mac). Nothing here needs administrator rights, and nothing is written until the
// person turns the switch on. `ServiceManager` writes the file and asks systemd or launchd to know about it; uninstalling removes exactly
// what installing wrote (a small record of it is kept in the data folder).

public enum ServicePlatform: String, Codable, Sendable {
    case systemd, launchd
    public static var current: ServicePlatform {
        #if os(macOS)
        return .launchd
        #else
        return .systemd
        #endif
    }
}

public struct ServiceUnit: Equatable, Sendable {
    /// Every file this program writes for the service starts or ends with this, so it is never mistaken for someone else's.
    public static let marker = "black-team-managed-v1"
    public static let systemdName = "black-team.service"
    public static let launchdLabel = "com.blackteam.service"

    /// The program to run, as an absolute path.
    public var program: String
    /// Its arguments after the program name, for example `service run`. Never evaluated by a shell.
    public var arguments: [String]
    /// The PATH the service runs with, so the tools it finds (llama.cpp, rtk, graphify) are found here too.
    public var path: String
    /// Where a launchd agent writes its log (systemd's goes to the journal).
    public var logFile: String

    public init(program: String, arguments: [String] = ["service", "run"], path: String, logFile: String = "") {
        self.program = program; self.arguments = arguments; self.path = path; self.logFile = logFile
    }

    /// The unit for the program running now. `data` is added only when it is not the default folder.
    public static func forThisProgram(executable: String, dataFolder: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                                      home: String = NSHomeDirectory()) throws -> ServiceUnit {
        guard executable.hasPrefix("/") else { throw BlackTeamError("Black Team could not tell where this program is.") }
        var arguments = ["service", "run"]
        if let dataFolder, dataFolder != AppPaths.dataFolder(environment: [:], home: home) { arguments += ["--data", dataFolder] }
        // Keep the places already on PATH that are absolute; add the usual per-user places a service does not get on its own.
        var folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.contains(" ") }
        for folder in [home + "/.local/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !folders.contains(folder) { folders.append(folder) }
        let log = ServicePlatform.current == .launchd ? home + "/Library/Logs/Black Team/service.log" : ""
        return ServiceUnit(program: stableProgramPath(executable), arguments: arguments, path: folders.joined(separator: ":"), logFile: log)
    }

    /// A packaged install keeps each version in `releases/<version>` and points `current` at the one in use. The unit names `current`, so
    /// an update does not leave it pointing at a release that is gone.
    public static func stableProgramPath(_ resolved: String) -> String {
        guard let range = resolved.range(of: "/releases/") else { return resolved }
        let root = String(resolved[..<range.lowerBound])
        let rest = resolved[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return resolved }
        let current = root + "/current"
        guard CoreFS.isSymlink(current) else { return resolved }
        return current + String(rest[slash...])
    }

    // MARK: systemd

    /// One word of an ExecStart line: quoted, with the characters systemd would otherwise read (backslash, quote, `%` and `$`) escaped.
    static func systemdWord(_ word: String) throws -> String {
        if word.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { throw BlackTeamError("A path for the background service contains a character that cannot be used.") }
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "$", with: "$$")
        return "\"" + escaped + "\""
    }

    public func systemdText() throws -> String {
        let command = try ([program] + arguments).map(Self.systemdWord).joined(separator: " ")
        let environment = try Self.systemdWord("PATH=" + path)
        return """
        # \(Self.marker)
        # Written by `black-team service install`. `black-team service uninstall` removes it.
        [Unit]
        Description=Black Team background service
        Documentation=https://github.com/rickndanger-ctrl/black-team/blob/main/docs/SERVICE.md

        [Service]
        Type=simple
        ExecStart=\(command)
        Environment=\(environment)
        Restart=on-failure
        RestartSec=15
        TimeoutStopSec=30
        SyslogIdentifier=black-team
        UMask=0077
        # Hardening that leaves the tools a Code run uses alone: no new privileges (no setuid programs gain rights), and the
        # service cannot change its own personality, take realtime scheduling or create setuid files. The files in the home folder stay open
        # to it, because that is the work it does.
        NoNewPrivileges=yes
        LockPersonality=yes
        RestrictRealtime=yes
        RestrictSUIDSGID=yes

        [Install]
        WantedBy=default.target

        """
    }

    // MARK: launchd

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public func launchdText() throws -> String {
        for word in [program] + arguments + [path, logFile] where word.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            throw BlackTeamError("A path for the background service contains a character that cannot be used.")
        }
        let items = ([program] + arguments).map { "        <string>\(Self.xml($0))</string>" }.joined(separator: "\n")
        var logs = ""
        if !logFile.isEmpty {
            logs = """

                <key>StandardOutPath</key>
                <string>\(Self.xml(logFile))</string>
                <key>StandardErrorPath</key>
                <string>\(Self.xml(logFile))</string>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <!-- \(Self.marker): written by `black-team service install`; `black-team service uninstall` removes it. -->
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.launchdLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(items)
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(Self.xml(path))</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ThrottleInterval</key>
            <integer>15</integer>
            <key>ProcessType</key>
            <string>Background</string>
            <key>Umask</key>
            <integer>63</integer>\(logs)
        </dict>
        </plist>

        """
    }

    public func text(for platform: ServicePlatform) throws -> String {
        platform == .systemd ? try systemdText() : try launchdText()
    }
}

// MARK: Running systemctl and launchctl

public struct ServiceCommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public init(status: Int32, output: String = "") { self.status = status; self.output = output }
}

/// Runs a program with arguments (never through a shell). Tests replace it with a fake `systemctl`.
public typealias ServiceCommandRunner = @Sendable (_ program: String, _ arguments: [String]) async -> ServiceCommandResult

public enum ServiceCommand {
    /// Finds the program on PATH and runs it, waiting at most 20 seconds.
    public static let run: ServiceCommandRunner = { program, arguments in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [program] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: ServiceCommandResult(status: 127, output: "\(program) could not be started.")); return }
                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { process.waitUntilExit(); finished.signal() }
                if finished.wait(timeout: .now() + 20) == .timedOut {
                    process.terminate()
                    continuation.resume(returning: ServiceCommandResult(status: 124, output: "\(program) took too long."))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ServiceCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

// MARK: Installing

public struct ServiceUnitState: Equatable, Sendable {
    /// This computer can keep a service (systemd with a user session, or launchd).
    public var supported: Bool
    public var installed: Bool
    public var enabled: Bool
    public var active: Bool
    public var path: String

    public var json: JSONValue {
        ["supported": .bool(supported), "installed": .bool(installed), "enabled": .bool(enabled), "active": .bool(active), "path": .string(path)]
    }
}

/// What the one-approval setup plan needs from the service: whether it is on, and turning it on.
public protocol ServiceInstalling: Sendable {
    func isInstalled() -> Bool
    func install() async throws -> String
}

public final class ServiceManager: @unchecked Sendable, ServiceInstalling {
    public let platform: ServicePlatform
    public let home: String
    public let dataFolder: String
    private let runner: ServiceCommandRunner
    private let uid: UInt32

    /// What install wrote, so uninstall removes exactly that and nothing else.
    private struct Record: Codable, Equatable {
        var platform: ServicePlatform
        var files: [String]
        /// Folders that did not exist before and were made for the unit; removed (only if empty) when it goes.
        var folders: [String]
    }

    /// The home folder the unit goes under: `$HOME` when it is an absolute folder (as systemd and the other tools read it; `NSHomeDirectory()` on
    /// Linux ignores it), else the account\u{2019}s home.
    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["HOME"], home.hasPrefix("/"), home.count > 1, !home.contains("\n") { return home.hasSuffix("/") ? String(home.dropLast()) : home }
        return NSHomeDirectory()
    }

    public init(platform: ServicePlatform = .current, home: String = ServiceManager.defaultHome(), dataFolder: String = AppPaths.dataFolder(),
                runner: @escaping ServiceCommandRunner = ServiceCommand.run, uid: UInt32 = UInt32(getuid())) {
        self.platform = platform; self.home = home; self.dataFolder = dataFolder; self.runner = runner; self.uid = uid
    }

    public var unitPath: String {
        platform == .systemd ? home + "/.config/systemd/user/" + ServiceUnit.systemdName
                             : home + "/Library/LaunchAgents/" + ServiceUnit.launchdLabel + ".plist"
    }
    private var recordFile: String { dataFolder + "/service-install.json" }
    private var domain: String { "gui/\(uid)" }
    private var target: String { "gui/\(uid)/\(ServiceUnit.launchdLabel)" }

    private func systemctl(_ arguments: String...) async -> ServiceCommandResult { await runner("systemctl", ["--user"] + arguments) }
    private func launchctl(_ arguments: String...) async -> ServiceCommandResult { await runner("launchctl", arguments) }

    public func isInstalled() -> Bool {
        guard let text = try? String(contentsOfFile: unitPath, encoding: .utf8) else { return false }
        return text.contains(ServiceUnit.marker)
    }

    // MARK: Install and uninstall

    /// Writes the unit and tells the system about it (enables it for the next login). Does not start it. Safe to repeat.
    /// A file already at that path that this program did not write is never replaced.
    @discardableResult
    public func install(_ unit: ServiceUnit) async throws -> String {
        let text = try unit.text(for: platform)
        let fm = FileManager.default
        if fm.fileExists(atPath: unitPath) {
            let existing = (try? String(contentsOfFile: unitPath, encoding: .utf8)) ?? ""
            if !existing.contains(ServiceUnit.marker) {
                throw BlackTeamError("A different file is already at \(unitPath). Black Team will not replace it.")
            }
        }
        if platform == .systemd {
            // systemd needs a user session; without one nothing can be enabled.
            let probe = await systemctl("--version")
            if probe.status != 0 { throw BlackTeamError("This computer cannot keep a background service: systemctl is not available for your user.") }
        }
        var record = readRecord() ?? Record(platform: platform, files: [], folders: [])
        let directory = (unitPath as NSString).deletingLastPathComponent
        var missing: [String] = []
        var walk = directory
        while !fm.fileExists(atPath: walk), walk.count > 1 { missing.insert(walk, at: 0); walk = (walk as NSString).deletingLastPathComponent }
        for folder in missing { try fm.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
        if platform == .launchd, !logParent(unit).isEmpty {
            var logMissing: [String] = []
            var logWalk = logParent(unit)
            while !fm.fileExists(atPath: logWalk), logWalk.count > 1 { logMissing.insert(logWalk, at: 0); logWalk = (logWalk as NSString).deletingLastPathComponent }
            for folder in logMissing { try fm.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
            for folder in logMissing where !record.folders.contains(folder) { record.folders.append(folder) }
        }
        for folder in missing where !record.folders.contains(folder) { record.folders.append(folder) }
        if !record.files.contains(unitPath) { record.files.append(unitPath) }
        // The record first, so a failure half way still lets uninstall find what was written.
        try privateDirectory(dataFolder)
        try writeJSON(recordFile, record)
        let current = try? String(contentsOfFile: unitPath, encoding: .utf8)
        if current != text { try CoreFS.writeAtomic(unitPath, Data(text.utf8), temporary: "\(unitPath).\(CoreFS.hex(8)).tmp") }
        switch platform {
        case .systemd:
            _ = await systemctl("daemon-reload")
            let enabled = await systemctl("enable", ServiceUnit.systemdName)
            if enabled.status != 0 { throw BlackTeamError("The background service was written but could not be turned on: \(firstLine(enabled.output))") }
        case .launchd:
            // Already loaded is fine: bootstrap reports an error then.
            _ = await launchctl("bootstrap", domain, unitPath)
            _ = await launchctl("enable", target)
        }
        return unitPath
    }

    public func install() async throws -> String {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        // The unit runs `<program> service run`; only the `black-team` program does that (the Mac app is a different program).
        guard ["black-team", "black-team-cli"].contains((executable as NSString).lastPathComponent) else {
            throw BlackTeamError("Turn this on from the black-team command: black-team service install")
        }
        let environment = ProcessInfo.processInfo.environment
        let explicit = environment["BLACK_TEAM_DATA"] != nil ? dataFolder : nil
        return try await install(try ServiceUnit.forThisProgram(executable: executable, dataFolder: explicit, environment: environment, home: home))
    }

    private func logParent(_ unit: ServiceUnit) -> String { unit.logFile.isEmpty ? "" : (unit.logFile as NSString).deletingLastPathComponent }

    /// Stops and removes the unit, and the folders install made if they are empty. Returns false when nothing was installed.
    @discardableResult
    public func uninstall() async throws -> Bool {
        let record = readRecord()
        let present = isInstalled()
        if !present && record == nil { return false }
        switch platform {
        case .systemd:
            _ = await systemctl("disable", "--now", ServiceUnit.systemdName)
        case .launchd:
            _ = await launchctl("bootout", target)
        }
        let fm = FileManager.default
        // Only a file this program wrote is removed.
        for file in (record?.files ?? [unitPath]) where file == unitPath {
            if let text = try? String(contentsOfFile: file, encoding: .utf8), text.contains(ServiceUnit.marker) { try? fm.removeItem(atPath: file) }
        }
        if platform == .systemd { _ = await systemctl("daemon-reload") }
        // The deepest first, so a folder is empty by the time its parent is looked at.
        for folder in (record?.folders ?? []).sorted(by: { $0.count > $1.count }) {
            if let entries = try? fm.contentsOfDirectory(atPath: folder), entries.isEmpty { try? fm.removeItem(atPath: folder) }
        }
        try? fm.removeItem(atPath: recordFile)
        return true
    }

    private func readRecord() -> Record? {
        guard let data = FileManager.default.contents(atPath: recordFile) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func firstLine(_ text: String) -> String { text.split(separator: "\n").first.map(String.init) ?? "" }

    // MARK: Start, stop, state

    public func start() async throws {
        guard isInstalled() else { throw BlackTeamError("The background service is not turned on. Turn it on first.") }
        let result = platform == .systemd ? await systemctl("start", ServiceUnit.systemdName) : await launchctl("kickstart", target)
        if result.status != 0 { throw BlackTeamError("The background service could not start: \(firstLine(result.output))") }
    }

    public func stop() async throws {
        guard isInstalled() else { throw BlackTeamError("The background service is not turned on.") }
        let result = platform == .systemd ? await systemctl("stop", ServiceUnit.systemdName) : await launchctl("kill", "SIGTERM", target)
        if result.status != 0 { throw BlackTeamError("The background service could not be stopped: \(firstLine(result.output))") }
    }

    public func restart() async throws {
        guard isInstalled() else { throw BlackTeamError("The background service is not turned on. Turn it on first.") }
        let result = platform == .systemd ? await systemctl("restart", ServiceUnit.systemdName) : await launchctl("kickstart", "-k", target)
        if result.status != 0 { throw BlackTeamError("The background service could not restart: \(firstLine(result.output))") }
    }

    public func state() async -> ServiceUnitState {
        let installed = isInstalled()
        switch platform {
        case .systemd:
            let probe = await systemctl("--version")
            guard probe.status == 0 else { return ServiceUnitState(supported: false, installed: installed, enabled: false, active: false, path: unitPath) }
            guard installed else { return ServiceUnitState(supported: true, installed: false, enabled: false, active: false, path: unitPath) }
            let enabled = await systemctl("is-enabled", ServiceUnit.systemdName)
            let active = await systemctl("is-active", ServiceUnit.systemdName)
            return ServiceUnitState(supported: true, installed: true, enabled: enabled.output.hasPrefix("enabled"), active: active.output.hasPrefix("active"), path: unitPath)
        case .launchd:
            guard installed else { return ServiceUnitState(supported: true, installed: false, enabled: false, active: false, path: unitPath) }
            let loaded = await launchctl("print", target)
            return ServiceUnitState(supported: true, installed: true, enabled: loaded.status == 0, active: loaded.status == 0 && loaded.output.contains("state = running"), path: unitPath)
        }
    }

    /// The last lines the service wrote.
    public func logs(lines: Int = 100) async -> String {
        let count = max(1, min(lines, 2000))
        switch platform {
        case .systemd:
            let result = await runner("journalctl", ["--user", "-u", ServiceUnit.systemdName, "-n", String(count), "--no-pager", "-o", "short-iso"])
            return result.status == 0 ? result.output : "No log is available yet."
        case .launchd:
            let file = home + "/Library/Logs/Black Team/service.log"
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return "No log is available yet." }
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
        }
    }
}
