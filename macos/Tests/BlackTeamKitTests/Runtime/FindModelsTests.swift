import XCTest
@testable import BlackTeamKit

/// A file with a valid GGUF header that is large on paper and a few bytes on disk.
@discardableResult
private func gguf(_ file: String, bytes: Int = 300 * 1024 * 1024) -> String {
    try! FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var header = [UInt8](repeating: 0, count: 24)
    header[0...3] = [0x47, 0x47, 0x55, 0x46]; header[4] = 3
    FileManager.default.createFile(atPath: file, contents: Data(header))
    let handle = FileHandle(forWritingAtPath: file)!
    try! handle.truncate(atOffset: UInt64(bytes))
    try! handle.close()
    return file
}

private func entries(_ list: [(Int, [String])]) -> () -> AnySequence<ProcessEntry> { { AnySequence(list.map { ProcessEntry(pid: $0.0, argv: $0.1) }) } }

final class FindModelsTests: XCTestCase {
    func testReadsThePortAndModelOfModelServersThisUserIsRunning() {
        let list = entries([
            (100, ["/opt/llama/bin/llama-server", "-m", "/models/a.gguf", "--host", "127.0.0.1", "--port", "18081"]),
            (101, ["llama-server", "--model=/models/b.gguf", "--port=18080"]),
            (102, ["/usr/bin/python3", "server.py", "--port", "9999"]),
            (103, ["llama-server", "--port", "not-a-port"]),
            (104, ["llama-server", "-m", "/models/c.gguf"]),
        ])
        let found = runningServers(processes: list, executablePath: { $0 == 100 ? "/opt/llama/bin/llama-server" : nil })
        XCTAssertEqual(found.map { [String($0.port), $0.file, $0.executable] },
                       [["18081", "/models/a.gguf", "/opt/llama/bin/llama-server"], ["18080", "/models/b.gguf", ""], ["8080", "/models/c.gguf", ""]])
        XCTAssertEqual(runningServers(processes: entries([])), [])
    }

    func testFindsRunningServersAndModelFilesAndLeavesHelperFilesOut() async throws {
        let dir = makeTemporaryFolder(self), home = dir + "/home"
        let loaded = gguf(home + "/models/ornith/Ornith-35B-Q4.gguf")
        gguf(home + "/models/qwen/Qwen-27B-Q4.gguf")
        gguf(home + "/models/qwen/mmproj-F16.gguf")
        gguf(home + "/models/qwen/mtp-Qwen-27B.gguf")
        gguf(home + "/models/split/Big-00002-of-00003.gguf")
        gguf(home + "/Downloads/tiny.gguf", bytes: 1024 * 1024)
        FileManager.default.createFile(atPath: home + "/Downloads/notes.gguf", contents: Data("not a model at all, just text padding".utf8))
        let data = home + "/Library/Application Support/Black Team"
        gguf(data + "/models/Own-8B-Q8_0.gguf")
        let asked = RuntimeBox<[String]>([])
        let fetch: HTTPFetch = { request in
            let url = request.url!
            asked.update { $0.append(url.absoluteString) }
            func ok(_ text: String) -> (Data, HTTPURLResponse) { (Data(text.utf8), response(url)) }
            switch url.absoluteString {
            case "http://127.0.0.1:18081/v1/models": return ok(#"{"data":[{"id":"\#(loaded)"}]}"#)
            case "http://127.0.0.1:18081/props": return ok(#"{"default_generation_settings":{"n_ctx":65536}}"#)
            case "http://127.0.0.1:11434/v1/models": return ok(#"{"data":[{"id":"llama3:8b"},{"id":"qwen:7b"}]}"#)
            case "http://127.0.0.1:11434/props": return (Data("no".utf8), response(url, 404))
            default: throw URLError(.cannotConnectToHost)
            }
        }
        let found = await findModels(home: home, fetch: fetch, processes: entries([(7, ["/opt/llama-server", "-m", loaded, "--port", "18081"])]),
                                     executablePath: { _ in nil }, runtime: "/usr/bin/llama-server",
                                     memory: MemoryFigures(total: 64 << 30, free: 32 << 30), dataFolder: data)
        XCTAssertEqual(found.servers.map { [$0.provider, $0.name, String($0.context), String($0.contextKnown)] },
                       [["Ollama", "llama3:8b", "4096", "false"], ["Ollama", "qwen:7b", "4096", "false"], ["llama.cpp", "Ornith-35B-Q4", "65536", "true"]])
        // The model a server already has loaded is not offered a second time as a file.
        XCTAssertEqual(found.files.map { [$0.name, $0.runtime, String($0.context), String($0.tooBig)] },
                       [["Own-8B-Q8_0", "/usr/bin/llama-server", "32768", "false"], ["Qwen-27B-Q4", "/usr/bin/llama-server", "32768", "false"]])
        let qwen = found.files[1]
        XCTAssertEqual([(qwen.mmproj as NSString).lastPathComponent, (qwen.draft as NSString).lastPathComponent], ["mmproj-F16.gguf", "mtp-Qwen-27B.gguf"])
        XCTAssertTrue(found.looked.ports.contains(18081) && found.looked.ports.contains(1234))
        XCTAssertEqual(found.looked.folders, [home + "/models", home + "/Downloads", data + "/models"])
        XCTAssertTrue(asked.value.allSatisfy { $0.hasPrefix("http://127.0.0.1:") }, "only loopback addresses are contacted")
        XCTAssertEqual(found.looked.ports, found.looked.ports.sorted())
    }

    func testAnEmptyComputerGivesAnEmptyAnswerNotAnError() async {
        let dir = makeTemporaryFolder(self)
        let found = await findModels(home: dir, fetch: { _ in throw URLError(.cannotConnectToHost) }, processes: entries([]), dataFolder: dir + "/data")
        XCTAssertEqual(found.servers, [])
        XCTAssertEqual(found.files, [])
        XCTAssertEqual(found.runtime, "")
        XCTAssertEqual(found.looked.folders, [])
    }

    func testARunningLlamaServerIsAnEngineForOtherFiles() async {
        let dir = makeTemporaryFolder(self), home = dir + "/home"
        gguf(home + "/Downloads/Other-7B-Q4_K_M.gguf")
        let found = await findModels(home: home, fetch: { _ in throw URLError(.cannotConnectToHost) },
                                     processes: entries([(9, ["llama-server", "--port", "9100"])]), executablePath: { _ in "/opt/bin/llama-server" }, dataFolder: dir + "/data")
        XCTAssertEqual(found.runtime, "/opt/bin/llama-server")
        XCTAssertEqual(found.files.map(\.runtime), ["/opt/bin/llama-server"])
        XCTAssertTrue(found.looked.ports.contains(9100))
    }

    func testCompanionsAndDescriptions() {
        let dir = makeTemporaryFolder(self)
        let file = gguf(dir + "/Model-8B-Q4_K_M.gguf")
        XCTAssertEqual(companionsFor(file), Companions(mmproj: "", draft: ""))
        gguf(dir + "/Model-mmproj-F16.gguf"); gguf(dir + "/b-draft.gguf"); gguf(dir + "/a-mtp.gguf")
        XCTAssertEqual(companionsFor(file), Companions(mmproj: dir + "/Model-mmproj-F16.gguf", draft: dir + "/a-mtp.gguf"))
        // With no readable metadata the name comes from the file; context follows the memory left.
        let described = describeFile(file, bytes: 5 << 30, memory: MemoryFigures(total: 64 << 30, free: 32 << 30))
        XCTAssertEqual(described.name, "Model-8B-Q4_K_M")
        XCTAssertNil(described.trainingContext)
        XCTAssertEqual(described.context, 32768)
    }

    func testTheScanStaysWithinItsBounds() {
        let dir = makeTemporaryFolder(self), home = dir + "/home"
        gguf(home + "/models/a/b/c/d/e/f/TooDeep.gguf")          // depth 6: beyond the limit of 5
        gguf(home + "/models/a/b/c/d/e/Deep-Enough.gguf")
        let scan = ggufFiles(home: home, dataFolder: dir + "/data")
        XCTAssertEqual(scan.files.map { ($0.file as NSString).lastPathComponent }, ["Deep-Enough.gguf"])
        for index in 0..<70 { gguf(home + "/Downloads/m\(index).gguf") }
        XCTAssertEqual(ggufFiles(home: home, dataFolder: dir + "/data").files.count, 60)
    }
}
