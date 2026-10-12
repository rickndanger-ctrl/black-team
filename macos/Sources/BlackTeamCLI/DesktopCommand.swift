import Foundation
import BlackTeamKit
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

// black-team desktop-service --web <dist folder> --version <app version> [--port <n>] [--data <folder>] [--scripts <folder>]
//
// --scripts is the app's scripts folder (it holds agent-runner.py). Without it Hermes is not available, as on the Mac.
//
// What the Linux Electron app starts instead of lib/. Standard output carries the control channel and nothing else: first
// {"ready":true,"origin":...,"bootstrapURL":...,"dataFolder":...} (or {"ready":false,"error":...} and exit status 1), then one reply
// line per request line {"id":n,"action":"...","data":{...}} -> {"id":n,"ok":true,"result":...} or {"id":n,"ok":false,"error":"..."}.
// Logs go to standard error. The service stops, model server included, at end of standard input, SIGTERM or SIGINT.

/// Writes whole lines to standard output, one at a time, ignoring a reader that has gone.
final class ControlOutput: @unchecked Sendable {
    private let lock = NSLock()
    func line(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let bytes = Array((text + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
            if written < 0 { if errno == EINTR { continue }; return }
            offset += written
        }
    }
}

/// Ends the service once, from whichever of end of input and the signals comes first.
final class ServiceStop: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func run(_ service: DesktopService) {
        lock.lock(); let first = !started; started = true; lock.unlock()
        guard first else { return }
        Task {
            await service.shutdown()
            exit(0)
        }
    }
}

@MainActor func runDesktopService(_ given: [String]) async -> Int32 {
    let output = ControlOutput()
    func stop(_ message: String, code: Int32) -> Int32 {
        output.line(JSONValue.object(["ready": false, "error": .string(message)]).text())
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return code
    }
    var web: String?, version: String?, port = Phone.localPort, data = AppPaths.dataFolder(), scripts: String?
    var rest = given[...]
    while let flag = rest.popFirst() {
        guard let value = rest.popFirst() else { return stop("\(flag) needs a value.", code: 2) }
        switch flag {
        case "--web": web = value
        case "--version": version = value
        case "--port": guard let number = Int(value), (0...65535).contains(number) else { return stop("--port needs a number from 0 to 65535.", code: 2) }; port = number
        case "--data": guard value.hasPrefix("/") else { return stop("--data needs an absolute folder.", code: 2) }; data = value
        case "--scripts":
            guard value.hasPrefix("/"), FileManager.default.fileExists(atPath: value + "/agent-runner.py") else {
                return stop("--scripts needs an absolute folder that holds agent-runner.py.", code: 2)
            }
            scripts = value
        default: return stop("Unknown option: \(flag)", code: 2)
        }
    }
    guard let web, web.hasPrefix("/") else { return stop("desktop-service needs --web <absolute folder of the built web app>.", code: 2) }
    // A reader that has gone must not end the service with a signal: writes just fail.
    signal(SIGPIPE, SIG_IGN)
    let service: DesktopService
    do {
        service = try DesktopService(options: DesktopServiceOptions(web: web, version: version ?? programVersion, port: port, dataFolder: data, scripts: scripts))
        output.line(try await service.start())
    } catch {
        return stop(describe(error), code: 1)
    }
    let ending = ServiceStop()
    var sources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { ending.run(service) }
        source.resume()
        sources.append(source)
    }
    // Each request is answered on its own, so a slow action (stopping a model) does not hold up the status the window polls.
    // Read with read(2), not readLine: a thread blocked in stdio holds the lock exit() needs, and a signal would then never finish.
    let reader = Thread {
        var pending = [UInt8](), chunk = [UInt8](repeating: 0, count: 65536)
        func answer(_ bytes: [UInt8]) {
            let line = String(decoding: bytes, as: UTF8.self)
            Task { if let reply = await service.respond(toLine: line) { output.line(reply) } }
        }
        while true {
            let count = read(0, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            for byte in chunk[0..<count] {
                if byte == 10 { answer(pending); pending.removeAll(keepingCapacity: true) } else { pending.append(byte) }
            }
            // A line that never ends is not a request; do not let it grow without bound.
            if pending.count > 16 * 1024 * 1024 { pending.removeAll() }
        }
        if !pending.isEmpty { answer(pending) }
        ending.run(service)
    }
    reader.name = "black-team.control-input"
    reader.start()
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000); _ = sources.count }
}
