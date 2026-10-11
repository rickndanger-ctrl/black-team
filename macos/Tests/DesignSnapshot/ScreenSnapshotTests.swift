import XCTest
import SwiftUI
import AppKit
import BlackTeamKit
@testable import BlackTeamUI

// Renders each main screen, in the states a person meets, to PNGs so the look can be judged without
// a person at the Mac. Each model is built on a throwaway data folder. Not part of Package.swift:
// screens.sh adds this folder to a scratch copy on the mini.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    // MARK: Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T {
        try! JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private func makeModel() async throws -> AppModel {
        let folder = NSTemporaryDirectory() + "bt-snap-\(UUID().uuidString.prefix(8))"
        let backend = try Backend(dataFolder: folder, version: "0.1.0-alpha.10")
        let model = AppModel(backend: backend, live: false)
        await model.refresh()
        return model
    }

    private let modelId = "/home/rickom1/models/ornith15-35b-a3b/Ornith-1.5-35B-Q4_K_M.gguf"

    /// The same figures the Linux capture showed, so the two screens can be laid side by side.
    private func linuxFigures(_ model: AppModel) {
        model.status?.hardware.platform = "darwin"
        model.status?.hardware.arch = "arm64"
        model.status?.hardware.cpu = decode(CPUInfo.self, #"{"name":"Intel Core i7-10810U","threads":12,"cores":6,"sockets":1,"mhz":752}"#)
        model.status?.hardware.memory = decode(MemoryInfo.self, #"{"total":50038000000,"available":15461882265,"free":15461882265,"used":34576117735,"swapTotal":0,"swapUsed":0}"#)
        model.status?.hardware.disk = decode(DiskInfo.self, #"{"path":"/","total":25016000000,"free":23086000000,"available":23086000000}"#)
        model.status?.performance = decode(PerformanceSummary.self, #"""
        {"cpu":11,"cores":6,"load":2.1,"memory":{"total":50038000000,"free":15461882265,"used":34576117735,"swapTotal":0,"swapUsed":0},"temperature":45,
         "model":{"pid":1,"resident":27058293964,"swapped":0}}
        """#)
    }

    /// The model the Linux capture used: a local server, added from the first-run list.
    private func readyModel(running: Bool = true, withSidebar: Bool = false) async throws -> AppModel {
        let model = try await makeModel()
        model.status?.setupComplete = true
        model.status?.config.model.name = "Ornith-1.5-35B-Q4_K_M"
        model.status?.config.model.file = ""
        model.status?.config.model.id = modelId
        model.status?.config.model.endpoint = "http://127.0.0.1:18081/v1"
        model.status?.config.model.source = "server"
        model.status?.config.model.context = 65536
        model.status?.config.model.threads = 6
        model.status?.config.model.gpuLayers = 0
        model.status?.runtime.ready = running
        model.status?.runtime.state = running ? "ready" : "off"
        model.status?.runtime.name = "Ornith-1.5-35B-Q4_K_M"
        model.status?.models = decode([SavedModelSummary].self, """
        [{"key":"266db82788c0cbee","name":"Ornith-1.5-35B-Q4_K_M","source":"server","context":65536,"active":true,"where":"127.0.0.1:18081"}]
        """)
        linuxFigures(model)
        if withSidebar { addProject(model) }
        var found = model.backend.discoverApps()
        found.apps = [FoundApp(id: "claude", name: "Claude Code", executable: "claude", preset: true), FoundApp(id: "codex", name: "Codex", executable: "codex", preset: true),
                      FoundApp(id: "pi", name: "Pi", executable: "pi", preset: true), FoundApp(id: "opencode", name: "OpenCode", executable: "opencode", preset: true),
                      FoundApp(id: "hermes", name: "Hermes Terminal", executable: "hermes", preset: false)]
        model.installed = found
        return model
    }

    /// The project and both conversations the Linux capture had by then, with the project open.
    private func addProject(_ model: AppModel) {
        model.status?.threads = threadsJSON(code: true)
        model.status?.projects = decode([ProjectSummary].self, """
        [{"id":"p1","name":"scratch","workspace":"/home/rickom1/Black Team/scratch","exists":true,"notes":"Projects/scratch"}]
        """)
        model.projectId = "p1"
    }

    private var out: String { ProcessInfo.processInfo.environment["BT_SNAP_DIR"] ?? NSTemporaryDirectory() }

    private func render(_ name: String, theme: ThemeSetting = .covert, height: CGFloat = 800, model: AppModel) throws {
        Fonts.register()
        let view = MainShell(model: model)
            .environment(\.btFlatLayout, true)
            .frame(width: 1280)
            .frame(height: height, alignment: .top)
            .blackTeamTheme(forcing: theme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return XCTFail("render failed: \(name)") }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bt-screen-\(name).png")
        try png.write(to: url)
        print("SNAPSHOT \(url.path)")
    }

    private let foundReport = """
    {"servers":[{"server":{"source":"server","provider":"llama.cpp","endpoint":"http://127.0.0.1:18081/v1","id":"/home/rickom1/models/ornith15-35b-a3b/Ornith-1.5-35B-Q4_K_M.gguf","name":"Ornith-1.5-35B-Q4_K_M","context":65536,"contextKnown":true},"key":"s:a","saved":false,"ignored":false}],
     "files":[],"runtime":"","looked":{"ports":[1234,1337,5001,8000,8080,11434,18081],"folders":[]}}
    """

    // MARK: First run

    func testFirstRun() async throws {
        let model = try await makeModel()
        linuxFigures(model)
        model.starter.load(model.backend)
        model.finder.report = decode(FoundModelsReport.self, foundReport)
        model.finder.picked = ["s:a"]
        try render("01-first-run-step1", height: 1750, model: model)
    }

    func testStep2() async throws {
        let model = try await readyModel(running: false)
        model.welcome = .agents
        try render("02-first-run-step2", height: 1655, model: model)
    }

    // MARK: Workspace

    func testWorkspace() async throws {
        let model = try await readyModel(running: false)
        model.status?.performance.model = nil
        model.status?.performance.memory.free = 16_200_000_000
        try render("03-workspace-stopped", height: 1519, model: model)
        for theme in [ThemeSetting.light, .ghost] { try render("04-workspace-theme-\(theme.rawValue)", theme: theme, height: 800, model: model) }
        let ready = try await readyModel(withSidebar: true)
        try render("05-workspace-ready", height: 1519, model: ready)

        let stopped = try await readyModel(running: false, withSidebar: true)
        stopped.status?.performance.model = nil
        stopped.notice = "Model stopped."
        try render("40-workspace-notice", height: 800, model: stopped)
    }

    // MARK: Chat and Code

    private func chatThread() -> JSONValue {
        let reply = """
        Sure, here's a quick example:

        ```python
        def hello():
            print("Hello, world!")
        hello()
        ```
        """
        return [
            "id": "4b7b7cb3-ba2a-4532-b280-d0229f3e892e", "title": "Reply with one short sentence and a three-line code block.", "kind": "chat",
            "messages": [
                ["id": "m1", "role": "user", "content": "Reply with one short sentence and a three-line code block.", "state": "done"],
                ["id": "m2", "role": "assistant", "content": .string(reply), "state": "done", "model": "Ornith-1.5-35B-Q4_K_M",
                 "finishReason": "stop",
                 "meter": ["write": 10, "used": 505, "budget": 64384, "window": 65536],
                 "context": ["measuredInputTokens": 505, "context": 65536, "maxTokens": 1024, "omittedMessages": 0, "method": "estimated-bytes", "inputBudget": 64384, "safetyMargin": 128, "decision": "keep"]],
            ],
        ]
    }

    private let chatId = "4b7b7cb3-ba2a-4532-b280-d0229f3e892e"
    private let codeId = "7c1d0b1e-2f3a-4c55-9a77-5d8e1c2b3a44"

    private func threadsJSON(code: Bool) -> [ThreadSummary] {
        decode([ThreadSummary].self, """
        [\(code ? #"{"id":"\#(codeId)","title":"Create hello.txt containing hi","updated":"2026-10-11T22:50:00.000Z","kind":"agent","project":"p1"},"# : "")\
        {"id":"\(chatId)","title":"Reply with one short sentence and a three-line code block.","updated":"2026-10-11T22:46:45.703Z","kind":"chat"}]
        """)
    }

    func testChat() async throws {
        let model = try await readyModel()
        model.page = .conversation
        try render("06-chat-empty", model: model)
        for theme in [ThemeSetting.light, .ghost] { try render("07-chat-empty-theme-\(theme.rawValue)", theme: theme, model: model) }

        model.status?.threads = threadsJSON(code: false)
        model.threadId = chatId
        model.thread = chatThread()
        model.status?.job = decode(JobSummary.self, """
        {"id":"r1","threadId":"\(chatId)","kind":"chat","state":"done","progress":"Response complete",
         "context":{"measuredInputTokens":505,"context":65536,"maxTokens":1024,"omittedMessages":0,"method":"estimated-bytes","inputBudget":64384,"safetyMargin":128,"decision":"keep"},
         "meter":{"write":10,"used":505,"budget":64384,"window":65536}}
        """)
        try render("10-chat-done", model: model)
        for theme in [ThemeSetting.light, .ghost] { try render("12-chat-done-theme-\(theme.rawValue)", theme: theme, model: model) }
    }

    func testCode() async throws {
        let model = try await readyModel()
        model.page = .conversation
        model.newKind = .agent
        model.status?.threads = threadsJSON(code: false)
        try render("13-code-empty", model: model)

        model.status?.threads = threadsJSON(code: false)
        model.status?.projects = decode([ProjectSummary].self, """
        [{"id":"p1","name":"scratch","workspace":"/home/rickom1/Black Team/scratch","exists":true,"notes":"Projects/scratch"}]
        """)
        model.projectId = "p1"
        try render("15-code-empty-in-project", model: model)
        model.status?.threads = threadsJSON(code: true)

        model.threadId = codeId
        model.thread = [
            "id": .string(codeId), "title": "Create hello.txt containing hi", "kind": "agent", "project": "p1",
            "messages": [
                ["id": "u", "role": "user", "content": "Create hello.txt containing hi", "state": "done"],
                ["id": "a", "role": "assistant", "state": "done", "model": "Ornith-1.5-35B-Q4_K_M",
                 "content": "Created `hello.txt` containing \"hi\" and verified its contents.",
                 "meter": ["read": 41, "write": 10, "used": 3900, "budget": 64384, "window": 65536],
                 "events": [
                    ["type": "tool_use", "name": "write", "output": "{\"path\":\"hello.txt\"}"],
                    ["type": "tool_result", "name": "write", "output": "Wrote hello.txt", "error": false,
                     "change": ["id": "c1", "path": "hello.txt", "created": true, "added": 1, "removed": 0, "diff": "--- /dev/null\n+++ b/hello.txt\n@@ -0,0 +1 @@\n+hi"]],
                    ["type": "tool_use", "name": "read", "output": "{\"path\":\"hello.txt\"}"],
                    ["type": "tool_result", "name": "read", "output": "hi", "error": false],
                 ]],
            ],
        ]
        model.status?.job = decode(JobSummary.self, """
        {"id":"r2","threadId":"\(codeId)","kind":"agent","state":"done","progress":"Agent task complete",
         "meter":{"read":41,"write":10,"used":3900,"budget":64384,"window":65536}}
        """)
        try render("17-code-done", model: model)
    }

    // MARK: Memory

    func testMemory() async throws {
        let model = try await readyModel(withSidebar: true)
        let backend = model.backend
        // The project notes Code wrote for the scratch project, as in the Linux capture.
        _ = try backend.memorySave("Projects/scratch/Overview", content: "# scratch\n\nJournal: [[Projects/scratch/Journal]]\n")
        _ = try backend.memorySave("Projects/scratch/Journal", content: "# Journal\n\n- Created hello.txt.\n")
        model.page = .memory
        await model.memory.load(model)
        try render("20-memory-intro", height: 917, model: model)

        _ = try backend.memorySave("Core", content: "# Core\n\nRick likes short answers. Working on [[webshop]] and [[Swift notes]].\n")
        await model.memory.load(model)
        await model.memory.open("Core")
        try render("24-memory-core-saved", height: 800, model: model)

        _ = try backend.memorySave("Swift notes", content: "# Swift notes\n\nClosures capture by reference. See [[Core]].\n")

        await model.memory.load(model)
        await model.memory.open("Swift notes")
        try render("26-memory-notes-editor", height: 800, model: model)
        model.memory.tab = .graph
        try render("27-memory-graph", height: 917, model: model)
        model.memory.tab = .projects
        try render("28-memory-projects", height: 800, model: model)
    }

    // MARK: Settings

    func testSettings() async throws {
        let model = try await readyModel(withSidebar: true)
        model.page = .settings
        model.settingsSection = .model
        try render("30-settings-model", height: 1565, model: model)
        model.settingsSection = .agents
        try render("30-settings-agents", height: 1373, model: model)
        model.settingsSection = .data
        try render("30-settings-data", height: 800, model: model)
    }
}
