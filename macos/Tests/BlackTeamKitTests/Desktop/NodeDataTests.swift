import XCTest
@testable import BlackTeamKit

// People update from the Node app (alpha.18) with real data in ~/.local/share/black-team-data. The fixture folder was written by the
// Node modules themselves (Fixtures/make-node-data.cjs). These tests open it with the Swift engine, check that everything is
// seen as the Node app saw it, that opening rewrites nothing, and (where `node` is installed) that the Node modules can still read
// what the Swift engine writes.

/// A copy of the Node-written data folder in a temporary place, with its paths made local.
final class NodeFixture {
    let root: String, data: String, ws: String
    let expected: [String: JSONValue]

    init(_ test: XCTestCase) throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "node-data", withExtension: nil))
        let made = NSTemporaryDirectory() + "bt-nodefx-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        // The real path: on a Mac /var is a link to /private/var, and the engine works with real paths.
        let resolved = realpath(made, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) } ?? made
        let folder = resolved
        root = folder + "/node-data"
        try FileManager.default.copyItem(atPath: source.path, toPath: root)
        data = root + "/data"; ws = root + "/ws"
        try FileManager.default.createDirectory(atPath: ws + "/garden", withIntermediateDirectories: true)
        // Absolute paths were written as @ROOT@; they are this copy's now.
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        for case let relative as String in walker where relative.hasSuffix(".json") || relative.hasSuffix(".md") {
            let file = root + "/" + relative
            guard var text = try? String(contentsOfFile: file, encoding: .utf8), text.contains("@ROOT@") else { continue }
            text = text.replacingOccurrences(of: "@ROOT@", with: root)
            try text.write(toFile: file, atomically: false, encoding: .utf8)
        }
        expected = try XCTUnwrap(try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: root + "/expected.json"))).object)
        test.addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
    }

    func text(_ key: String, _ inner: String) -> String { expected[key]?[inner]?.string ?? "" }
    func id(_ inner: String) -> String { text("threads", inner) }

    func backend(runtime: StubRuntime = StubRuntime(), stream: HTTPStreamFetch? = nil) throws -> Backend {
        if let stream {
            return try Backend(dataFolder: data, version: "1.2.3", runtime: runtime, fetch: { _ in throw URLError(.cannotConnectToHost) }, stream: stream,
                               discover: { noTools }, home: root, keeperInterval: 3600)
        }
        return try Backend(dataFolder: data, version: "1.2.3", runtime: runtime, fetch: { _ in throw URLError(.cannotConnectToHost) },
                           discover: { noTools }, home: root, keeperInterval: 3600)
    }

    /// Every file under the data folder with a fingerprint of its bytes.
    func fingerprint() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: data))
        for case let relative as String in walker {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: data + "/" + relative, isDirectory: &isFolder), !isFolder.boolValue {
                result[relative] = FileManager.default.contents(atPath: data + "/" + relative)
            }
        }
        return result
    }
}

final class NodeDataTests: XCTestCase {
    func testSwiftReadsWhatTheNodeAppSaved() async throws {
        let fx = try NodeFixture(self)
        let backend = try fx.backend()
        let status = try await backend.status()
        // Settings.
        XCTAssertEqual(status.config.model.source, "server")
        XCTAssertEqual(status.config.model.id, "ornith-1.5-ünï")
        XCTAssertEqual(status.config.model.name, "Ornith 1.5 ünï")
        XCTAssertEqual(status.config.model.context, 32768)
        XCTAssertEqual(status.config.workspace, fx.ws)
        XCTAssertTrue(status.setupComplete)
        let phone = try backend.configStore.read().phone
        XCTAssertEqual(phone, PhoneConfig(enabled: true, hostname: fx.text("phone", "hostname"), owner: fx.text("phone", "owner")))
        // Saved models: both are listed, with the keys the Node app computed (a path with accents and quotes), the server one in use.
        let models = backend.savedModels.read()
        XCTAssertEqual(Set(models.map { keyOf($0) }), [fx.text("keys", "server"), fx.text("keys", "gguf")])
        XCTAssertEqual(status.models.first { $0.active }?.key, fx.text("keys", "server"))
        XCTAssertEqual(status.models.first { $0.source == "gguf" }?.location, "model-ü.gguf")
        XCTAssertEqual(backend.savedModels.ignored(), ["0123456789abcdef"])
        // Integrations.
        let integrations = try backend.integrations.read()
        XCTAssertEqual(integrations.harnesses.map(\.id), ["claude"])
        XCTAssertEqual(integrations.harnesses.first?.args, ["--x", "{model}"])
        XCTAssertEqual(integrations.harnesses.first?.preset, "claude")
        XCTAssertEqual(integrations.engine, "black-team")
        // Conversations: all three, newest first, and the Node file and the Swift view hold the same JSON.
        XCTAssertEqual(Set(backend.threads().map(\.id)), Set(["chat", "agent", "cut"].map(fx.id)))
        for name in ["chat", "agent"] {
            let file = try Data(contentsOf: URL(fileURLWithPath: fx.data + "/conversations/\(fx.id(name)).json"))
            XCTAssertEqual(try JSONValue.parse(file), backend.history.get(fx.id(name)), name)
        }
        let chat = try XCTUnwrap(backend.thread(fx.id("chat")))
        XCTAssertEqual(chat["messages"]?[1]?["content"]?.string, "Hi! ☕")
        XCTAssertEqual(chat["messages"]?[1]?["meter"]?["write"]?.int, 14)
        XCTAssertEqual(chat["messages"]?[0]?["recalled"]?[0]?["title"]?.string, "Deploy steps")
        XCTAssertEqual(backend.history.get(fx.id("chat"))?["core"]?.string, "Prefers short answers.")
        XCTAssertEqual(backend.thread(fx.id("agent"))?["kind"]?.string, "agent")
        XCTAssertEqual(backend.thread(fx.id("agent"))?["messages"]?[1]?["artifacts"]?[0]?["name"]?.string, "report ü.txt")
        XCTAssertEqual(backend.request(fx.text("requests", "chat"))?.state, "done")
        // A reply the Node app was still writing is shown as interrupted, as the Node app would have shown it.
        XCTAssertEqual(backend.thread(fx.id("cut"))?["messages"]?[1]?["state"]?.string, "interrupted")
        XCTAssertEqual(backend.request(fx.text("requests", "cut"))?.state, "interrupted")
        // Projects, keeper, memory.
        let project = try XCTUnwrap(status.projects.first)
        XCTAssertEqual(project.id, fx.expected["project"]?.string)
        XCTAssertEqual(project.name, "Garden")
        XCTAssertTrue(project.exists)
        XCTAssertEqual(project.notes, "Projects/garden")
        let overview = try backend.memoryOverview()
        XCTAssertTrue(overview.keeper.actions.first?.text.hasPrefix("Moved 3 older journal entries") ?? false)
        XCTAssertGreaterThan(overview.keeper.actions.first?.at ?? 0, 1_700_000_000_000)   // milliseconds, as the Node app writes
        XCTAssertTrue(overview.notes.map(\.id).contains("Notes/Café ☕"))
        XCTAssertTrue(overview.notes.map(\.id).contains("Projects/garden/Journal"))
        XCTAssertFalse(overview.notes.map(\.id).contains("Notes/Old"))   // in .trash
        XCTAssertTrue(overview.graph.nodes.contains { $0.id == "?Missing note" && $0.missing })
        XCTAssertTrue(overview.graph.edges.contains { $0.from == "Notes/Café ☕" && $0.to == "Notes/Deploy steps" })
        let hits = try await backend.memorySearch("tuesdays")
        XCTAssertEqual(hits.first?.id, "Projects/garden/Watering")
        // Phone pairing: the key is the same file, so the secrets (HMAC of kind, computer and account, non-ASCII) are the Node app's.
        let keys = try PhoneKeys(folder: fx.data)
        XCTAssertEqual(keys.secret("pair", hostname: phone.hostname, owner: phone.owner), fx.text("phone", "pair"))
        XCTAssertEqual(keys.secret("session", hostname: phone.hostname, owner: phone.owner), fx.text("phone", "session"))
        // A file a Code turn published, and an edit it can undo.
        let artifact = try backend.artifactFile(fx.expected["artifact"]?.string ?? "")
        XCTAssertEqual(artifact.name, "report ü.txt")
        XCTAssertEqual(artifact.size, 14)
        let undone = try backend.undo(fx.expected["undoId"]?.string)
        XCTAssertEqual(undone.path, "a.txt")
        XCTAssertEqual(try String(contentsOfFile: fx.ws + "/a.txt", encoding: .utf8), "before\n")
        await backend.shutdown()
    }

    func testOpeningTheFolderRewritesOnlyTheInterruptedConversation() async throws {
        let fx = try NodeFixture(self)
        let before = try fx.fingerprint()
        let backend = try fx.backend()
        _ = try await backend.status()
        _ = try await backend.desktopStatusJSON()
        await backend.shutdown()
        let after = try fx.fingerprint()
        // engine.lock was taken and given back; the cut-off conversation was marked interrupted (as the Node app does on start).
        var changed = Set(after.keys.filter { after[$0] != before[$0] })
        changed.formUnion(before.keys.filter { after[$0] == nil })
        XCTAssertEqual(changed, ["conversations/\(fx.id("cut")).json"])
        // Rewritten in the same format: the Node app reads it back.
        let rewritten = try JSONValue.parse(after["conversations/\(fx.id("cut")).json"]!)
        XCTAssertEqual(rewritten["messages"]?[1]?["state"]?.string, "interrupted")
        XCTAssertEqual(rewritten["requests"]?[0]?["state"]?.string, "interrupted")
        XCTAssertTrue(validThread(rewritten, fx.id("cut")))
    }

    func testTheDesktopStatusHasTheShapeTheWebAppReads() async throws {
        let fx = try NodeFixture(self)
        let backend = try fx.backend()
        let status = try await backend.desktopStatusJSON()
        for key in ["access", "version", "setupComplete", "runtime", "threads", "job", "agentEnabled", "hermesEnabled", "projects", "memory", "dictation", "codeMap",
                    "performance", "config", "models", "serverKeyConfigured", "integrations", "hardware", "phone"] {
            XCTAssertNotNil(status[key], key)
        }
        XCTAssertEqual(status["access"]?.string, "desktop")
        XCTAssertEqual(status["version"]?.string, "1.2.3")
        XCTAssertEqual(status["config"]?["phone"]?["owner"]?.string, "rïck@example.com")
        XCTAssertNil(status["config"]?["model"]?["apiKey"])
        #if os(Linux)
        XCTAssertEqual(status["hardware"]?["platform"]?.string, "linux")
        #endif
        XCTAssertEqual(status["dictation"]?.bool, false)
        // The phone block: a pairing secret follows the address, behind a # the browser never sends.
        XCTAssertEqual(status["phone"]?["url"]?.string, "https://bt-laptop.tail1234.ts.net:8449/#pair=" + fx.text("phone", "pair"))
        XCTAssertEqual(status["phone"]?["enabled"]?.bool, true)
        XCTAssertEqual(status["phone"]?["command"]?.string, "tailscale serve --bg --https=8449 http://127.0.0.1:18199")
        XCTAssertEqual(status["threads"]?.array?.count, 3)
        XCTAssertEqual(status["models"]?.array?.count, 2)
        await backend.shutdown()
    }

    // MARK: What the Swift engine writes, read by the Node modules

    func testTheNodeModulesReadWhatSwiftWrites() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: repository + "/lib/history.cjs") else { throw XCTSkip("The Node modules are not beside this package.") }
        guard let node = ["/usr/bin/node", "/usr/local/bin/node", "/opt/homebrew/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Node is not installed.")
        }
        let fx = try NodeFixture(self)
        let replies = ReplyCounter()
        let backend = try fx.backend(stream: { _ in replies.add(); return sse(answerStream) })
        // Writes of every kind the Swift engine makes: a setup change, a model, an ignore, integrations, a project, a note, a chat turn, a rename.
        _ = try await backend.saveSetup(["model": ["name": "Renamed ünï", "context": 8192]])
        try backend.savedModels.remember(ModelConfig(source: "server", endpoint: "http://127.0.0.1:18082/v1", id: "other", name: "Other"))
        _ = try backend.savedModels.ignore("fedcba9876543210")
        _ = try await backend.saveIntegrations(["dictation": ""])
        let project = try backend.createProject(name: "Orchard")
        _ = try backend.memoryRemember(title: "Pears", text: "Ripe in September", project: project.id)
        let sent = try backend.submit(message: "Swift says hello ☕", kind: "chat", mode: "balanced", requestId: UUID().uuidString.lowercased())
        await backend.waitForIdle()
        XCTAssertEqual(backend.request(sent.id)?.state, "done")
        try backend.renameThread(fx.id("chat"), title: "Renamed chat")
        await backend.shutdown()
        let script = """
        const path = require('node:path');
        const [lib, data] = process.argv.slice(1);
        const need = name => require(path.join(lib, name));
        const config = need('config.cjs').createConfigStore(data).read();
        const saved = need('models.cjs').createSavedModels(data);
        const integrations = need('integrations.cjs').createIntegrations(data).read();
        const history = new (need('history.cjs').History)(data);
        const memory = need('memory.cjs').createMemory({vault: path.join(data, 'vault')});
        const fs = require('node:fs');
        console.log(JSON.stringify({model: config.model.name, context: config.model.context, workspace: config.workspace, phone: config.phone,
          saved: saved.read().map(m => m.name), ignored: saved.ignored(), harnesses: integrations.harnesses.map(h => h.id),
          threads: history.list().map(t => t.title), requests: [...history.requests.values()].map(r => r.state).sort(),
          notes: memory.notes().map(n => n.id).sort(), projects: JSON.parse(fs.readFileSync(path.join(data, 'projects.json'), 'utf8')).map(p => p.name),
          keeper: JSON.parse(fs.readFileSync(path.join(data, 'keeper.json'), 'utf8')).length,
          key: fs.readFileSync(path.join(data, 'phone.key'), 'utf8').length}));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", script, repository + "/lib", fx.data]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors, as: UTF8.self))
        let seen = try JSONValue.parse(output)
        XCTAssertEqual(seen["model"]?.string, "Renamed ünï")
        XCTAssertEqual(seen["context"]?.int, 8192)
        XCTAssertEqual(seen["workspace"]?.string, fx.ws)
        XCTAssertEqual(seen["phone"]?["owner"]?.string, "rïck@example.com")
        XCTAssertEqual(Set(seen["saved"]?.array?.compactMap(\.string) ?? []), ["Renamed ünï", "Qwén 27B Q4", "Other"])
        XCTAssertEqual(Set(seen["ignored"]?.array?.compactMap(\.string) ?? []), ["0123456789abcdef", "fedcba9876543210"])
        XCTAssertEqual(seen["harnesses"]?.array?.compactMap(\.string), ["claude"])
        XCTAssertTrue(seen["threads"]?.array?.compactMap(\.string).contains("Renamed chat") ?? false)
        XCTAssertTrue(seen["threads"]?.array?.compactMap(\.string).contains("Swift says hello ☕") ?? false)
        XCTAssertFalse(seen["requests"]?.array?.compactMap(\.string).contains("running") ?? true)
        XCTAssertTrue(seen["notes"]?.array?.compactMap(\.string).contains("Projects/orchard/Pears") ?? false)
        XCTAssertEqual(Set(seen["projects"]?.array?.compactMap(\.string) ?? []), ["Garden", "Orchard"])
        XCTAssertEqual(seen["keeper"]?.int, 1)
        XCTAssertEqual(seen["key"]?.int, 64)
    }
}

final class ReplyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
}
