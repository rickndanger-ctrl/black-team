import XCTest
@testable import BlackTeamKit

final class RuntimeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

/// A model file (a GGUF header) and a llama-server that looks like a native executable to the checks.
struct RuntimeFixture {
    let dir: String, model: String, runtime: String, stateDir: String
    let store: ConfigStore
    var config: Config

    init(_ test: XCTestCase) throws {
        dir = makeTemporaryFolder(test)
        model = dir + "/test model.gguf"
        runtime = dir + "/llama-server"
        stateDir = dir + "/state"
        var header = [UInt8](repeating: 0, count: 64)
        header[0...3] = [0x47, 0x47, 0x55, 0x46]; header[4] = 3
        FileManager.default.createFile(atPath: model, contents: Data(header))
        var exe = [UInt8](repeating: 0, count: 64)
        exe[0...3] = [0xcf, 0xfa, 0xed, 0xfe]
        let cpu = MachOCPU.current
        for index in 0..<4 { exe[4 + index] = UInt8((cpu >> (8 * UInt32(index))) & 0xff) }
        exe[12] = 2
        FileManager.default.createFile(atPath: runtime, contents: Data(exe), attributes: [.posixPermissions: 0o700])
        store = try ConfigStore(stateDir: stateDir)
        config = Config(model: ModelConfig(name: "Test model", file: model, runtime: runtime), workspace: dir)
    }
}

final class FakeChild: ModelProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var sent: [Int32] = []
    private let exitsOn: Set<Int32>
    let onExit: @Sendable (ProcessExit) -> Void
    init(pid: Int32 = 4242, exitsOn: Set<Int32> = [SIGTERM, SIGKILL], onExit: @escaping @Sendable (ProcessExit) -> Void) {
        self.pid = pid; self.exitsOn = exitsOn; self.onExit = onExit
    }
    var signals: [Int32] { lock.lock(); defer { lock.unlock() }; return sent }
    func send(signal: Int32) {
        lock.lock(); sent.append(signal); lock.unlock()
        if exitsOn.contains(signal) { DispatchQueue.global().async { self.onExit(ProcessExit(signal: signal)) } }
    }
}

struct Spawned { let launch: ProcessLaunch; let child: FakeChild }

func response(_ url: URL, _ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

func waitUntil(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
    return await condition()
}
