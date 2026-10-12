import XCTest
import SwiftUI
import AppKit
import BlackTeamKit
@testable import BlackTeamUI

// Renders the Command center and Camp, in the states of the daily app's reference screenshots, to PNGs named like them
// (a0-command-center-full.png, b6-chat-done.png, ...) so the two sets can be laid side by side. Each model is built on a
// throwaway data folder. Not part of Package.swift: screens.sh adds this folder to a scratch copy on the mini.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    // MARK: State

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T {
        try! JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private let chatId = "4b7b7cb3-ba2a-4532-b280-d0229f3e892e"
    private let codeId = "7c1d0b1e-2f3a-4c55-9a77-5d8e1c2b3a44"

    private func makeModel() async throws -> AppModel {
        let folder = NSTemporaryDirectory() + "bt-snap-\(UUID().uuidString.prefix(8))"
        let backend = try Backend(dataFolder: folder, version: "0.1.0-alpha.10")
        let model = AppModel(backend: backend, live: false)
        await model.refresh()
        return model
    }

    /// Ornith 1.5 running and Qwen 3.8 off, the machine figures of the capture, and the conversations in the sidebar.
    private func dailyModel(cpu: Int = 11, used: Int = 34_790_000_000, running: Bool = true, qwenFirst: Bool = false) async throws -> AppModel {
        let model = try await makeModel()
        model.pace = "fast"
        model.status?.setupComplete = true
        model.status?.config.model.name = "Ornith 1.5"
        model.status?.config.model.source = "gguf"
        model.status?.config.workspace = "/home/rickom1/Projects/Companion-work"
        model.status?.runtime.ready = running
        model.status?.runtime.state = running ? "ready" : "off"
        model.status?.runtime.name = "Ornith 1.5"
        model.status?.models = decode([SavedModelSummary].self, """
        [{"key":"ornith","name":"Ornith 1.5","source":"gguf","context":65536,"active":true,"where":"Ornith-1.5-35B-A3B-Q4_K_M.gguf"},
         {"key":"qwen","name":"Qwen 3.8","source":"gguf","context":65536,"active":false,"where":"Qwen3.8-27B-UD-Q4_K_XL.gguf"}]
        """)
        model.status?.hardware.platform = "darwin"
        model.status?.performance = decode(PerformanceSummary.self, """
        {"cpu":\(cpu),"cores":6,"load":2.1,"memory":{"total":50038000000,"free":15248000000,"used":\(used),"swapTotal":0,"swapUsed":0},"temperature":45}
        """)
        model.status?.threads = decode([ThreadSummary].self, """
        [{"id":"\(chatId)","title":"What\u{2019}s in this image?","updated":"2026-10-11T22:50:00.000Z","kind":"chat"},
         {"id":"t2","title":"What color and shape is in the attached image? Answer briefl","updated":"2026-10-11T22:49:00.000Z","kind":"chat"},
         {"id":"t3","title":"What color and shape is shown in this image? Answer briefly.","updated":"2026-10-11T22:48:00.000Z","kind":"chat"},
         {"id":"t4","title":"Hello","updated":"2026-10-11T22:47:00.000Z","kind":"agent"},
         {"id":"t5","title":"Hello","updated":"2026-10-11T22:46:00.000Z","kind":"agent"},
         {"id":"t6","title":"Verify your real file and terminal tools. In the workspace c","updated":"2026-10-11T22:45:00.000Z","kind":"agent"},
         {"id":"t7","title":"Integration test using synthetic evidence only. Call jev_dec","updated":"2026-10-11T22:44:00.000Z","kind":"agent"},
         {"id":"\(codeId)","title":"Create companion-check.txt in the current workspace containi","updated":"2026-10-11T22:43:00.000Z","kind":"agent"},
         {"id":"t9","title":"Hello","updated":"2026-10-11T22:42:00.000Z","kind":"chat"},
         {"id":"t10","title":"Reply exactly: Companion ready.","updated":"2026-10-11T22:41:00.000Z","kind":"chat"}]
        """)
        var found = model.backend.discoverApps()
        found.apps = [FoundApp(id: "dsh", name: "DeepSeek Harness", executable: "dsh", preset: true), FoundApp(id: "codex", name: "Codex", executable: "codex", preset: true),
                      FoundApp(id: "claude", name: "Claude Code", executable: "claude", preset: true)]
        model.installed = found
        return model
    }

    private func open(_ model: AppModel, thread id: String, kind: String, messages: [JSONValue]) {
        model.threadId = id
        model.thread = ["id": .string(id), "title": "t", "kind": .string(kind), "messages": .array(messages)]
        model.newKind = kind == "agent" ? .agent : .chat
        model.campPage = .chat
    }

    private func user(_ text: String, _ id: String) -> JSONValue { ["id": .string(id), "role": "user", "content": .string(text), "state": "done"] }
    private func reply(_ text: String, _ id: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var m: [String: JSONValue] = ["id": .string(id), "role": "assistant", "content": .string(text), "state": "done", "model": "Ornith 1.5"]
        for (k, v) in extra { m[k] = v }
        return .object(m)
    }
    private func tool(_ name: String, _ input: String, _ output: String) -> [JSONValue] {
        [["type": "tool_use", "name": .string(name), "output": .string(input)], ["type": "tool_result", "name": .string(name), "output": .string(output), "error": false]]
    }

    // MARK: Rendering

    private enum Window { case command, camp }

    private func render(_ name: String, _ window: Window, height: CGFloat, theme: ThemeSetting = .covert, model: AppModel) throws {
        Fonts.register()
        let content: AnyView = window == .command ? AnyView(CommandShell(model: model)) : AnyView(CampShell(model: model))
        let view = content
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

    // MARK: Command center

    func testCommandCenter() async throws {
        let model = try await dailyModel()
        model.commandPage = .overview
        try render("a0-command-center-full", .command, height: 2400, model: model)

        let diagnostics = try await dailyModel(cpu: 17, used: 35_000_000_000)
        diagnostics.commandPage = .diagnostics
        let lines = (0..<30).map { i -> String in
            let t = 24 * 60 + 51 + i
            return "Oct 11 16:\(String(format: "%02d", t / 60 % 60 + 0 == 0 ? 24 : 24)):\(String(format: "%02d", 51 + i % 9)) omarchy llama-server[14585]: INFO [             slots_idle] all slots are idle | tid=\"140320634919168\" timestamp=\(1791761091 + i)"
        }
        diagnostics.log = lines
        try render("a1-diagnostics-full", .command, height: 2400, model: diagnostics)
    }

    // MARK: Camp

    func testCampChat() async throws {
        let empty = try await dailyModel()
        empty.campPage = .chat
        try render("b0-chat-empty", .camp, height: 800, model: empty)
        try render("b0-chat-empty-full", .camp, height: 2200, model: empty)

        let code = try await dailyModel()
        code.newKind = .agent
        code.campPage = .chat
        try render("b5-code-empty", .camp, height: 800, model: code)

        let chat = try await dailyModel()
        open(chat, thread: "t10", kind: "chat", messages: [user("Reply exactly: Companion ready.", "u1"), reply("Companion ready.", "a1")])
        try render("b6-chat-done", .camp, height: 1600, model: chat)

        let image = try await dailyModel()
        open(image, thread: chatId, kind: "chat", messages: [
            user("What\u{2019}s in this image?", "u1"),
            reply("""
            This is the logo of **SEAT**, the Spanish automobile manufacturer.

            The image shows SEAT's current logo, which features:

            - A **stylized "S"** formed with angular, 3D-like metallic shapes in the center
            - Enclosed within a **metallic ring/circle**
            - A dark/black background with dramatic lighting that gives the emblem a sleek, modern, chrome finish

            This logo was introduced in 2020 as part of the brand's redesign. The "S" is abstractly integrated into the circular emblem, giving it a more contemporary and dynamic look compared to SEAT's older logos.

            SEAT is a well-known European car brand, part of the Volkswagen Group, and is headquartered in Martorell, Spain.
            """, "a1", extra: ["context": ["measuredInputTokens": 16436, "context": 65536, "maxTokens": 2048, "omittedMessages": 0, "method": "measured"]]),
        ])
        try render("b9-chat-image", .camp, height: 1600, model: image)
    }

    func testCampCode() async throws {
        let first = try await dailyModel()
        let files: [JSONValue] = [["id": "f1", "name": "companion-check.txt", "size": 0]]
        open(first, thread: codeId, kind: "agent", messages: [
            user("Create companion-check.txt in the current workspace containing exactly: Agent tools are working. Then attach it using companion_files publish.", "u0"),
            reply("Created `companion-check.txt` and attached it.", "a0", extra: ["events": .array(tool("write_file", "{}", "ok")), "artifacts": .array(files)]),
            user("Read companion-check.txt again and report its exact contents. Do not change anything.", "u1"),
            reply("The exact contents of `companion-check.txt` are:\n\n```\nAgent tools are working.\n```\n\nOne line, 24 bytes (including the trailing newline). Nothing was changed.", "a1",
                  extra: ["events": .array(tool("read_file", "{}", "Agent tools are working."))]),
            user("Read companion-check.txt and attach it again using companion_files publish. Reply briefly. Do not send it to a device.", "u2"),
            reply("Re-published `companion-check.txt` to Companion. Not sent to any device.", "a2",
                  extra: ["events": .array(tool("read_file", "{}", "Agent tools are working.") + tool("companion_files", "{}", "published")), "artifacts": .array(files)]),
        ])
        try render("b7-code-done", .camp, height: 1600, model: first)

        let second = try await dailyModel()
        let table = """
        All done. Smoke test passed \u{2014} every tool verified with real output.

        ## Results

        | Step | Tool | Result |
        | --- | --- | --- |
        | Create folder | `terminal` | `cabinet-readiness-20261010/` created at `/home/rickom1/Projects/Companion-work/`; existing `companion-check.txt` left untouched |
        | Write check.py | `write_file` | 13 bytes written, lint OK, verified on disk |
        | Run & capture | `terminal` | `python3 cabinet-readiness-20261010/check.py > result.txt` \u{2192} **exit_code=0** |
        | Verify output | `read_file` | result.txt contains `4` (1 line, 2 bytes) \u{2713} |
        | Publish | `companion_files` (publish) | Attached as `result.txt` (id `b7f19a362a9f4285baa656b54bb1a625`, 2 bytes) |

        **Actual command output:** `4`

        result.txt is now attached in Companion for private download \u{2014} **not** sent to any device, as requested. No JEV/Laya used.
        """
        var events = [JSONValue]()
        for name in ["terminal", "write_file", "terminal", "read_file", "companion_files"] { events += tool(name, "{}", "ok").prefix(1) }
        events += tool("terminal", "{}", "ok").suffix(1) + tool("terminal", "{}", "ok").suffix(1)
        open(second, thread: "t6", kind: "agent", messages: [
            user("Verify your real file and terminal tools. In the workspace create a new folder cabinet-readiness-20261010 (do not overwrite existing files). Write check.py containing print(2 + 2), run it with python3 using your terminal tool and capture its output to result.txt. Read result.txt to verify it contains 4, then publish result.txt with companion_files so it is attached. Do not send it to any device. Report actual command output. This is a tiny smoke test; no JEV or Laya needed.", "u1"),
            reply(table, "a1", extra: ["events": .array(events), "artifacts": [["id": "f2", "name": "result.txt", "size": 0]]]),
        ])
        try render("b8-code-done-2", .camp, height: 1600, model: second)
    }

    func testCampPages() async throws {
        let memory = try await dailyModel()
        memory.campPage = .memory
        await memory.memory.load(memory)
        try render("b1-memory-full", .camp, height: 2200, model: memory)

        let plugins = try await dailyModel()
        plugins.campPage = .plugins
        try render("b2-plugins-full", .camp, height: 2200, model: plugins)

        let sessions = try await dailyModel()
        sessions.campPage = .dsh
        try render("b3-dsh-full", .camp, height: 2200, model: sessions)

        let servers = try await dailyModel()
        servers.campPage = .servers
        phoneReady(servers)
        try render("b4-servers-full", .camp, height: 2200, model: servers)
    }

    // MARK: Phone access (a made-up link and secret: nothing here is a real pairing link)

    private let fakeLink = "https://my-mac.tail1234.ts.net:8449/#pair=" + String(repeating: "0f1e2d3c", count: 8)

    private func phoneState(_ json: String) -> PhoneState { decode(PhoneState.self, json) }

    private func phoneReady(_ model: AppModel) {
        model.phone.autoRefresh = false
        model.phone.state = phoneState("""
        {"enabled":true,"connected":true,"routeReady":true,"serverRunning":true,"hostname":"my-mac.tail1234.ts.net","owner":"me@example.test","url":"https://my-mac.tail1234.ts.net:8449/","command":"tailscale serve"}
        """)
        model.phone.link = fakeLink
    }

    private func phoneOff(_ model: AppModel, installed: Bool = true, online: Bool = true) {
        model.phone.autoRefresh = false
        model.phone.state = phoneState("""
        {"enabled":false,"connected":false,"routeReady":false,"serverRunning":false,"hostname":"","owner":"","url":"","command":"tailscale serve"}
        """)
        model.phone.detection = decode(PhoneDetection.self, "{\"installed\":\(installed),\"online\":\(online),\"hostname\":\"\",\"owner\":\"\"}")
    }

    func testPhoneStates() async throws {
        func page(_ prepare: (AppModel) -> Void) async throws -> AppModel {
            let model = try await dailyModel()
            model.campPage = .servers
            prepare(model)
            return model
        }
        try render("x1-phone-off", .camp, height: 1300, model: try await page { phoneOff($0) })
        try render("x2-phone-no-tailscale", .camp, height: 1300, model: try await page { phoneOff($0, installed: false, online: false) })
        try render("x3-phone-signed-out", .camp, height: 1300, model: try await page { phoneOff($0, online: false) })
        try render("x4-phone-public-route", .camp, height: 1300, model: try await page {
            $0.phone.autoRefresh = false
            $0.phone.state = phoneState("""
            {"enabled":true,"connected":false,"routeReady":false,"serverRunning":true,"hostname":"my-mac.tail1234.ts.net","owner":"me@example.test","url":"https://my-mac.tail1234.ts.net:8449/","command":"x","problem":"Port 8449 is used by another or public route. Black Team will not overwrite it."}
            """)
        })
        try render("x5-phone-error", .camp, height: 1300, model: try await page {
            phoneOff($0)
            $0.phone.error = "Install Tailscale on this computer and sign in, then try again."
        })
        try render("x6-phone-ready-notice", .camp, height: 1300, model: try await page {
            phoneReady($0)
            $0.phone.notice = "Private phone access is ready. Scan the QR code on your phone."
        })
        try render("x7-phone-port-busy", .camp, height: 1300, model: try await page {
            $0.phone.autoRefresh = false
            $0.phone.state = phoneState("""
            {"enabled":true,"connected":false,"routeReady":true,"serverRunning":false,"hostname":"my-mac.tail1234.ts.net","owner":"me@example.test","url":"x","command":"x","problem":"Phone access is on, but its local server is not running. Turn it off and on again, or quit the program using port 18199."}
            """)
        })
    }

    // MARK: States the reference does not show

    func testNewMac() async throws {
        let model = try await makeModel()
        model.starter.load(model.backend)
        try render("x0-new-mac", .command, height: 1800, model: model)
    }
}
