import XCTest
@testable import BlackTeamKit

private struct Files {
    var dir: String, model: String, runtime: String, stateDir: String
    var store: ConfigStore
    var config: JSONValue
}

private func machO(cpu: UInt32 = MachOCPU.current, fileType: UInt32 = 2) -> Data {
    var bytes = [UInt8](repeating: 0, count: 64)
    func put(_ value: UInt32, at: Int) { for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xff) } }
    put(0xfeedfacf, at: 0); put(cpu, at: 4); put(fileType, at: 12)
    return Data(bytes)
}

private func fat(_ cpus: [UInt32]) -> Data {
    var bytes = [UInt8](repeating: 0, count: max(64, 8 + 20 * cpus.count + 8))
    func big(_ value: UInt32, at: Int) { for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(3 - i))) & 0xff) } }
    big(0xcafebabe, at: 0); big(UInt32(cpus.count), at: 4)
    for (i, cpu) in cpus.enumerated() { big(cpu, at: 8 + 20 * i) }
    return Data(bytes)
}

final class ConfigTests: XCTestCase {
    private func fixture() throws -> Files {
        let dir = makeTemporaryFolder(self)
        let model = dir + "/test model.gguf", runtime = dir + "/llama-server", stateDir = dir + "/state"
        var header = Data("GGUF".utf8); header.append(contentsOf: [3, 0, 0, 0]); header.append(Data(count: 56))
        try header.write(to: URL(fileURLWithPath: model))
        try Data(nativeProgramHeader()).write(to: URL(fileURLWithPath: runtime))
        chmod(runtime, 0o700)
        let store = try ConfigStore(stateDir: stateDir, defaultWorkspace: dir + "/default-workspace")
        let config: JSONValue = ["model": ["name": "Test model", "file": .string(model), "runtime": .string(runtime)], "workspace": .string(dir)]
        return Files(dir: dir, model: model, runtime: runtime, stateDir: stateDir, store: store, config: config)
    }

    func testDefaultsUseThisUserAndReadingCreatesNoState() throws {
        let f = try fixture()
        let real = try ConfigStore(stateDir: f.stateDir)
        XCTAssertEqual(try real.read().schemaVersion, 1)
        XCTAssertEqual(try real.read().workspace, NSHomeDirectory() + "/Black Team")
        XCTAssertEqual(try real.read().phone, PhoneConfig())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.stateDir))
        var copy = try real.read(); copy.model.name = "mutated"
        XCTAssertEqual(try real.read().model.name, "Local model")
        XCTAssertThrowsError(try ConfigStore(stateDir: "relative"))
    }

    func testAtomicSavesKeepPrivateModesAndMergeOnlyApprovedSettings() throws {
        let f = try fixture()
        try f.store.save(f.config)
        FileManager.default.createFile(atPath: f.stateDir + "/secret-token", contents: Data("untouched".utf8), attributes: [.posixPermissions: 0o600])
        try f.store.save(["model": ["context": 8192], "phone": ["owner": "Owner"]])
        XCTAssertEqual(try f.store.read().model.file, f.model)
        XCTAssertEqual(try f.store.read().model.context, 8192)
        XCTAssertEqual(try f.store.read().phone.owner, "Owner")
        XCTAssertEqual(mode(f.stateDir), 0o700)
        XCTAssertEqual(mode(f.stateDir + "/config.json"), 0o600)
        XCTAssertEqual(try String(contentsOfFile: f.stateDir + "/secret-token", encoding: .utf8), "untouched")
        let before = try String(contentsOfFile: f.stateDir + "/config.json", encoding: .utf8)
        let inputs: [JSONValue] = [["apiKey": "no"], ["model": ["host": "0.0.0.0"]], ["phone": ["token": "no"]], ["__proto__": ["polluted": true]], ["schemaVersion": 2]]
        for input in inputs {
            XCTAssertThrowsError(try f.store.save(input)) { XCTAssertTrue(($0 as! BlackTeamError).message.contains("Unsupported"), "\(input)") }
        }
        XCTAssertEqual(try String(contentsOfFile: f.stateDir + "/config.json", encoding: .utf8), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.stateDir).sorted(), ["config.json", "secret-token"])
        // The file is the same JSON shape as on Linux.
        let json = try JSONValue.parse(before)
        XCTAssertEqual(Set(json.object!.keys), ["schemaVersion", "model", "workspace", "phone"])
        XCTAssertEqual(json["model"]?["gpuLayers"]?.int, 0)
    }

    func testCorruptOversizedAndFutureFilesAreRejectedWithoutReplacement() throws {
        let f = try fixture()
        try f.store.save(f.config)
        for text in ["{", #"{"schemaVersion":2}"#, String(repeating: " ", count: 70000)] {
            try text.write(toFile: f.stateDir + "/config.json", atomically: false, encoding: .utf8)
            XCTAssertThrowsError(try f.store.read())
            XCTAssertThrowsError(try f.store.save(["model": ["name": "changed"]]))
            XCTAssertEqual(try String(contentsOfFile: f.stateDir + "/config.json", encoding: .utf8), text)
        }
    }

    func testLimitsAndWorkspaceAreValidatedBeforeWriting() throws {
        let f = try fixture()
        let inputs: [JSONValue] = [
            ["model": ["context": 0]], ["model": ["context": "4096"]], ["model": ["threads": 0]], ["model": ["gpuLayers": -1]],
            ["model": ["name": ""]], ["model": ["runtime": "./llama-server"]], ["workspace": .string(f.dir + "/absent")], ["workspace": "."],
            ["phone": ["enabled": "yes"]], ["phone": ["hostname": "https://example.com"]], ["model": ["name": "line\nbreak"]],
        ]
        for input in inputs { XCTAssertThrowsError(try f.store.save(input), "\(input)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.stateDir))
    }

    func testModelAndRuntimeValidation() throws {
        let f = try fixture()
        XCTAssertEqual(try validateModelFiles(ModelConfig(file: f.model, runtime: f.runtime)).model?.version, 3)
        let link = f.dir + "/linked.gguf"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f.model)
        XCTAssertEqual(try inspectModel(link).realPath, realpathString(f.model))
        let bad = f.dir + "/bad.gguf"
        try "not a model".write(toFile: bad, atomically: true, encoding: .utf8)
        func message(_ body: () throws -> Void) -> String { do { try body(); return "" } catch { return (error as! BlackTeamError).message } }
        XCTAssertTrue(message { _ = try inspectModel(bad) }.contains("truncated"))
        try Data(count: 64).write(to: URL(fileURLWithPath: bad))
        XCTAssertTrue(message { _ = try inspectModel(bad) }.contains("invalid or unsupported header"))
        XCTAssertTrue(message { _ = try inspectModel(f.dir) }.contains("not a regular file"))
        XCTAssertTrue(message { _ = try inspectModel(f.dir + "/missing") }.contains("ENOENT"))
        XCTAssertTrue(message { _ = try inspectRuntime("/bin/sh") }.contains("Choose the llama-server"))
        #if os(Linux)
        XCTAssertTrue(message { _ = try inspectRuntime("/bin/sh") }.contains("Linux llama.cpp release"))
        XCTAssertGreaterThan(try inspectRuntime(f.runtime).bytes, 0)
        // The wrong machine, a relocatable object, a 32-bit or big-endian file, or an unknown header is refused.
        func elf(machine: UInt16 = ELFMachine.current, type: UInt8 = 2, bits: UInt8 = 2, order: UInt8 = 1) -> Data {
            var bytes = nativeProgramHeader()
            bytes[16] = type; bytes[4] = bits; bytes[5] = order
            bytes[18] = UInt8(machine & 0xff); bytes[19] = UInt8(machine >> 8)
            return Data(bytes)
        }
        let otherMachine: UInt16 = ELFMachine.current == 62 ? 183 : 62
        try elf(machine: otherMachine).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native Linux \(ELFMachine.name)"))
        try elf(type: 1).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native Linux"))
        try elf(bits: 1).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native Linux"))
        try elf(order: 2).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native Linux"))
        try Data(count: 64).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native Linux"))
        try elf(type: 3).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertGreaterThan(try inspectRuntime(f.runtime).bytes, 0, "a position-independent executable is accepted")
        try machO().write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native Linux"), "a Mac program is not a Linux one")
        #else
        XCTAssertTrue(message { _ = try inspectRuntime("/bin/sh") }.contains("macOS llama.cpp release"))
        XCTAssertGreaterThan(try inspectRuntime(f.runtime).bytes, 0)
        // The wrong architecture, wrong file type or an unknown header is refused; a universal binary is accepted when it holds this Mac's.
        let other = MachOCPU.current == MachOCPU.arm64 ? MachOCPU.x86_64 : MachOCPU.arm64
        try machO(cpu: other).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native macOS"))
        try machO(fileType: 1).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native macOS"))
        try Data(count: 64).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native macOS"))
        try fat([other, MachOCPU.current]).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertGreaterThan(try inspectRuntime(f.runtime).bytes, 0)
        try fat([other]).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertTrue(message { _ = try inspectRuntime(f.runtime) }.contains("native macOS"))
        try fat([other, other, MachOCPU.current]).write(to: URL(fileURLWithPath: f.runtime))
        XCTAssertGreaterThan(try inspectRuntime(f.runtime).bytes, 0, "an architecture after the first two is found too")
        XCTAssertNoThrow(try inspectRuntime(f.runtime, cpuType: other))
        #endif
    }

    func testUnreadableModelsAndNonExecutableRuntimesAreRejected() throws {
        let f = try fixture()
        chmod(f.model, 0o000)
        XCTAssertThrowsError(try inspectModel(f.model)) { XCTAssertTrue(($0 as! BlackTeamError).message.contains("EACCES")) }
        chmod(f.model, 0o600)
        chmod(f.runtime, 0o600)
        XCTAssertThrowsError(try inspectRuntime(f.runtime)) { XCTAssertTrue(($0 as! BlackTeamError).message.contains("EACCES")) }
    }

    func testConfigSymlinksAreReadableButSavingReplacesOnlyTheLink() throws {
        let f = try fixture()
        let saved = try f.store.save(f.config)
        let external = f.dir + "/external.json"
        try JSONEncoder().encode(saved).write(to: URL(fileURLWithPath: external))
        try FileManager.default.removeItem(atPath: f.stateDir + "/config.json")
        try FileManager.default.createSymbolicLink(atPath: f.stateDir + "/config.json", withDestinationPath: external)
        XCTAssertEqual(try f.store.read().model.name, "Test model")
        try f.store.save(["model": ["name": "New model"]])
        XCTAssertEqual(try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: external)))["model"]?["name"]?.string, "Test model")
        XCTAssertFalse(CoreFS.isSymlink(f.stateDir + "/config.json"))
    }

    func testServerModelsNeedNoFiles() throws {
        let f = try fixture()
        let saved = try f.store.save(["workspace": .string(f.dir), "model": ["source": "server", "endpoint": "http://localhost:1234/v1", "id": "my-model", "apiKey": "fixture-key"]])
        XCTAssertEqual(saved.model.id, "my-model")
        XCTAssertEqual(mode(f.stateDir + "/config.json"), 0o600)
        XCTAssertTrue(try validateModelFiles(saved.model).server)
        XCTAssertThrowsError(try validateModelFiles(ModelConfig(source: "server", endpoint: "http://localhost:1234/v1", id: " ")))
    }

    func testMemoryEstimatesAndHardwareWorkBeforeStateExists() async throws {
        let f = try fixture()
        let GiB = 1024 * 1024 * 1024
        let warning = estimateMemory(7 * GiB, totalBytes: 8 * GiB, freeBytes: 4 * GiB)
        XCTAssertTrue(warning.exceedsTotal); XCTAssertTrue(warning.exceedsFree)
        XCTAssertTrue(warning.note.contains("does not guarantee"))
        XCTAssertNil(estimateMemory(GiB, totalBytes: 16 * GiB, freeBytes: 8 * GiB).warning)
        XCTAssertEqual(estimateMemory(40 * GiB, totalBytes: 100 * GiB, freeBytes: 100 * GiB).headroomBytes, 10 * GiB)
        let hardware = await hardwareReport(stateDir: f.stateDir)
        XCTAssertGreaterThan(hardware.cpu.cores, 0)
        XCTAssertGreaterThan(hardware.memory.total, 0)
        #if os(Linux)
        XCTAssertEqual(hardware.platform, "linux")
        #else
        XCTAssertEqual(hardware.platform, "darwin")
        #endif
        XCTAssertEqual(hardware.memory.free, hardware.memory.available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.stateDir))
        XCTAssertGreaterThanOrEqual(hardware.disk?.available ?? 0, 0)
    }

    func testEnsureWorkspaceCreatesOnlyTheDefaultOne() throws {
        let dir = makeTemporaryFolder(self)
        let standard = dir + "/Black Team"
        XCTAssertEqual(try ensureWorkspace(standard, defaultWorkspace: standard), standard)
        XCTAssertEqual(mode(standard), 0o700)
        XCTAssertThrowsError(try ensureWorkspace(dir + "/elsewhere", defaultWorkspace: standard))
    }

    func testAppPaths() {
        #if os(Linux)
        XCTAssertEqual(AppPaths.dataFolder(environment: [:], home: "/home/x"), "/home/x/.local/share/black-team-data")
        XCTAssertEqual(AppPaths.dataFolder(environment: ["XDG_DATA_HOME": "/srv/share"], home: "/home/x"), "/srv/share/black-team-data")
        XCTAssertEqual(AppPaths.dataFolder(environment: ["XDG_DATA_HOME": "relative"], home: "/home/x"), "/home/x/.local/share/black-team-data")
        XCTAssertEqual(AppPaths.dataFolder(environment: ["BLACK_TEAM_DATA": "/tmp/clean/", "XDG_DATA_HOME": "/srv/share"], home: "/home/x"), "/tmp/clean")
        XCTAssertEqual(AppPaths.dataFolder(environment: ["BLACK_TEAM_DATA": "relative"], home: "/home/x"), "/home/x/.local/share/black-team-data")
        XCTAssertEqual(AppPaths.defaultWorkspace(home: "/home/x"), "/home/x/Black Team")
        #else
        XCTAssertEqual(AppPaths.dataFolder(environment: [:], home: "/Users/x"), "/Users/x/Library/Application Support/Black Team")
        XCTAssertEqual(AppPaths.dataFolder(environment: ["BLACK_TEAM_DATA": "/tmp/clean/"], home: "/Users/x"), "/tmp/clean")
        XCTAssertEqual(AppPaths.dataFolder(environment: ["BLACK_TEAM_DATA": "relative"], home: "/Users/x"), "/Users/x/Library/Application Support/Black Team")
        XCTAssertEqual(AppPaths.defaultWorkspace(home: "/Users/x"), "/Users/x/Black Team")
        #endif
    }

    private func realpathString(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
