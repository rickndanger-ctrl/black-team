import XCTest
@testable import BlackTeamKit

// An organization through the real Backend, the real Code engine with a scripted model server (local and cloud), a real temporary git
// repository for the branch-per-ticket rule, and the room's usual fakes. No paid tokens: the "cloud" is the scripted server.

/// What the scripted people do. Each stage's prompt starts with "Stage: <name>", so the script answers by stage.
final class OrgScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _verdicts: [String: [String]] = [:]
    private var _replies: [String: String] = [:]
    private var _prompts: [(stage: String, role: String, cloud: Bool, text: String)] = []
    var hold: Hold?
    let overlap = Overlap()

    func reply(_ stage: String, _ text: String) { lock.lock(); _replies[stage] = text; lock.unlock() }
    /// The verdicts a stage gives in turn ("revise", "accept"); the last one repeats.
    func verdicts(_ stage: String, _ list: [String]) { lock.lock(); _verdicts[stage] = list; lock.unlock() }
    var prompts: [(stage: String, role: String, cloud: Bool, text: String)] { lock.lock(); defer { lock.unlock() }; return _prompts }
    func prompts(_ stage: String) -> [String] { prompts.filter { $0.stage == stage }.map(\.text) }

    private func nextVerdict(_ stage: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var list = _verdicts[stage], !list.isEmpty else { return nil }
        let v = list.count > 1 ? list.removeFirst() : list[0]
        _verdicts[stage] = list
        return v
    }

    func note(stage: String, role: String, cloud: Bool, text: String) { lock.lock(); _prompts.append((stage, role, cloud, text)); lock.unlock() }

    func answer(stage: String, role: String) -> String {
        lock.lock(); let custom = _replies["\(stage)/\(role)"] ?? _replies[stage]; lock.unlock()
        if let custom { return custom }
        switch stage {
        case "Intake": return "SUMMARY: Add a feature file.\nTOUCHES_UI: no\nSIZE: normal\nACCEPTANCE CRITERIA:\n1. feature.txt exists with the word done."
        case "Spec": return "# Spec\n## Goal\nAdd feature.txt.\n## Acceptance criteria\n1. feature.txt exists with the word done."
        case "Design": return "# Design\nA calm page.\n```html\n<!doctype html><title>Mock</title><h1>Feature</h1>\n```\n```css\n:root { --accent: #4a6; }\n```"
        case "Plan": return #"{"tasks":[{"title":"Write feature.txt","detail":"Create feature.txt"},{"title":"Write notes.txt","detail":"Create notes.txt"}]}"#
        case "Review":
            let v = nextVerdict("Review") ?? "accept"
            return v == "accept" ? "Looks right.\n{\"verdict\":\"accept\",\"reason\":\"\"}" : "Missing a test.\n{\"verdict\":\"revise\",\"reason\":\"Add a test for feature.txt in tests/\"}"
        case "QA":
            let v = nextVerdict("QA") ?? "pass"
            return v == "pass" ? "1. met: feature.txt exists.\n{\"verdict\":\"pass\",\"reason\":\"\"}" : "Criterion 1 not met.\n{\"verdict\":\"fail\",\"reason\":\"feature.txt is empty\"}"
        case "Ship": return role == "Docs writer" ? "# Docs\nFeature file added." : "# Release notes\nAdded feature.txt."
        default: return "Done."
        }
    }
}

final class OrgTests: XCTestCase {
    let secret = "sk-cloud-test-key-1234567890abcdef"
    let host = "api.cloud-test.com"
    let vaultCore = "Vault-Secret-Alpha: the owner keeps rare coins."

    struct Rig {
        var fixture: BackendFixture
        var backend: Backend
        var project: ProjectSummary
        var localKey: String
        var cloudKey: String
        var script: OrgScript
        var seen: Seen
        var pid: String { project.id }
        var folder: String { project.workspace }
    }

    func git(_ args: [String], in dir: String) -> String { OrgGit.run(args, in: dir).output.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `repo`: make the project folder a git repository with one commit on `main`.
    func rig(cloudAllowed: Bool = true, repo: Bool = true) async throws -> Rig {
        let fixture = try BackendFixture(self)
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        try vault.write("Core", "# Core\n\n\(vaultCore)\n")
        fixture.memory = vault
        let script = OrgScript(), seen = Seen()
        let host = self.host
        let model: HTTPStreamFetch = { request in
            let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
            let cloud = request.url?.host == host
            seen.add(body.setting("cloud", .bool(cloud)))
            script.overlap.enter(); defer { script.overlap.leave() }
            if let hold = script.hold { try await hold.wait() }
            let messages = body["messages"]?.array ?? []
            let user = messages.last { $0["role"]?.string == "user" }?["content"]?.string ?? ""
            let usage = cloud ? #""usage":{"prompt_tokens":1000,"completion_tokens":100}"# : #""usage":{"prompt_tokens":500,"completion_tokens":50}"#
            func say(_ text: String) -> (HTTPURLResponse, HTTPLines) {
                let chunk = JSONValue.object(["choices": [["delta": ["content": .string(text)]]]]).text()
                return sse("data: \(chunk)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\(usage)}\n\ndata: [DONE]\n\n")
            }
            guard let at = user.range(of: "Stage: ") else { return say("Done.") }
            let stage = String(user[at.upperBound...].prefix { $0.isLetter })
            let roleName = ["Docs writer", "Release manager", "Product manager", "Lead", "Engineer", "QA", "Reviewer", "Designer", "Architect"].first { user.contains("You are the \($0) of") } ?? ""
            _ = stage
            // The Code engine asks twice when a tool is used; the second request (with the tool's result) is the same stage run.
            if !messages.contains(where: { $0["role"]?.string == "tool" }) { script.note(stage: stage, role: roleName, cloud: cloud, text: user) }
            // A Build stage writes a file with the Code engine's own tool, then reports.
            if stage == "Build", !messages.contains(where: { $0["role"]?.string == "tool" }) {
                let file = user.contains("Your task (2 of") ? "notes.txt" : "feature.txt"
                let args = JSONValue.object(["path": .string(file), "content": "done\n"]).text()
                let chunk = JSONValue.object(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call-1", "function": ["name": "write", "arguments": .string(args)]]]]]]]).text()
                return sse("data: \(chunk)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\(usage)}\n\ndata: [DONE]\n\n")
            }
            if stage == "Build" { return say("Wrote the file and checked it.") }
            return say(script.answer(stage: stage, role: roleName))
        }
        // Chat roles (product, designer, docs, release) go through the chat path, Code roles through the engine; both are scripted.
        fixture.reply = model
        fixture.realEngine = try Engine(stateDir: fixture.stateDir, vault: vault, fetch: model, home: fixture.files.dir, useRtk: false)
        try fixture.rewriteConfig { $0.model.context = 65536 }
        let requests = fixture.requests
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.realEngine, memory: vault,
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            stream: { request in requests.add(request); return try await fixture.reply(request) },
            contextPlanner: { messages, context, mode, _, _, _ in
                PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, terminal: { _, _ in }, home: fixture.files.dir + "/home", keeperInterval: 3600)
        fixture.backends.append(backend)
        addTeardownBlock { await backend.shutdown() }
        let project = try backend.createProject(name: "Org Work")
        if cloudAllowed { _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true) }
        let localKey = try XCTUnwrap(backend.savedModels.list().first { !$0.isCloud }).key
        _ = try await backend.saveSetup(["model": ["source": "cloud", "endpoint": .string("https://\(host)/v1"), "id": "big-model", "apiKey": .string(secret),
                                                    "name": "Cloud Big", "context": .number(100_000)]])
        let cloudKey = try XCTUnwrap(backend.savedModels.list().first { $0.isCloud }).key
        _ = try await backend.switchTo(key: localKey)
        if repo {
            XCTAssertTrue(OrgGit.run(["init", "-q", "-b", "main"], in: project.workspace).ok)
            try "# Org Work\n".write(toFile: project.workspace + "/README.md", atomically: true, encoding: .utf8)
            _ = OrgGit.run(["add", "-A"], in: project.workspace)
            XCTAssertTrue(OrgGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "first"], in: project.workspace).ok)
        }
        return Rig(fixture: fixture, backend: backend, project: project, localKey: localKey, cloudKey: cloudKey, script: script, seen: seen)
    }

    /// Makes an organization of `template` with every role on the local model, and confirms nothing (all local).
    @discardableResult
    func make(_ r: Rig, _ template: String = "software", lead: String? = nil, gates: [String]? = nil) async throws -> OrgState {
        var state = try r.backend.orgCreate(projectId: r.pid, template: template, local: r.localKey, leadModel: lead)
        if let gates { state = try r.backend.orgUpdate(projectId: r.pid, gates: gates) }
        return state
    }

    func start(_ r: Rig) throws {
        let a = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertEqual(a.problems, [])
        _ = try r.backend.orgStart(projectId: r.pid, digest: a.digest)
        r.backend.orgStopLoop()   // tests step by hand
    }

    func ticket(_ r: Rig, _ id: String) throws -> OrgTicket { try XCTUnwrap(r.backend.orgTicket(r.pid, id)) }
    func firstTicket(_ r: Rig) throws -> OrgTicket { try XCTUnwrap(r.backend.orgTickets(r.pid).first) }

    /// Steps until the ticket is not `ready` any more (it waits at a gate, is blocked, or is done), within a bound.
    @discardableResult
    func drive(_ r: Rig, _ id: String, limit: Int = 30) async throws -> OrgTicket {
        for _ in 0..<limit {
            let t = try ticket(r, id)
            if t.state != "ready" && t.state != "running" { return t }
            let ran = try await r.backend.orgStep(projectId: r.pid)
            if !ran { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        return try ticket(r, id)
    }

    func add(_ r: Rig, _ title: String, body: String = "", ui: Bool? = nil, source: String = "person") throws -> OrgTicket {
        try r.backend.ticketAdd(projectId: r.pid, title: title, body: body, source: source, ui: ui).tickets.last!
    }

    // MARK: Roles and templates

    func testTemplatesMakeTheRightRolesAndEverythingIsEditable() async throws {
        let r = try await rig()
        let software = try r.backend.orgCreate(projectId: r.pid, template: "software", local: r.localKey)
        XCTAssertEqual(software.organization?.roles.map(\.kind), ["lead", "product", "designer", "architect", "engineer", "reviewer", "qa", "docs", "release"])
        XCTAssertEqual(software.organization?.gates, ["spec", "ship"], "approve the spec and approve shipping by default")
        XCTAssertTrue(software.roles.allSatisfy { $0.usable && $0.status == "idle" }, "\(software.roles.map(\.reason))")
        XCTAssertTrue(software.organization!.roles.allSatisfy { !$0.charter.isEmpty && $0.modelKey == r.localKey })
        XCTAssertTrue(software.git)
        await fail({ _ = try r.backend.orgCreate(projectId: r.pid, template: "studio") }, contains: "already has an organization")
        _ = try r.backend.orgRemove(projectId: r.pid)
        let studio = try r.backend.orgCreate(projectId: r.pid, template: "studio", local: r.localKey)
        XCTAssertEqual(studio.organization?.roles.map(\.kind), ["lead", "designer", "reviewer"])
        _ = try r.backend.orgRemove(projectId: r.pid)
        let small = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey)
        XCTAssertEqual(small.organization?.roles.map(\.kind), ["lead", "engineer", "reviewer"])
        // Add a second engineer (it takes the first one's model), edit a charter and a note, remove it.
        var state = try r.backend.orgAddRole(projectId: r.pid, kind: "engineer", name: "Engineer 2")
        let second = try XCTUnwrap(state.organization?.roles.last)
        XCTAssertEqual(second.name, "Engineer 2"); XCTAssertEqual(second.modelKey, r.localKey); XCTAssertFalse(second.charter.isEmpty)
        var edited = second
        edited.charter = "Build only the web parts."; edited.skills = ["Use the project's test runner."]; edited.price = OrgPrice(inPerMillion: 3, outPerMillion: 15)
        edited.budget = OrgBudget(paidTokensPerDay: 5000, moneyPerDay: 1.5)
        state = try r.backend.orgSaveRole(projectId: r.pid, role: edited)
        XCTAssertEqual(state.organization?.roles.last, edited)
        await fail({ var bad = edited; bad.modelKey = "nope"; _ = try r.backend.orgSaveRole(projectId: r.pid, role: bad) }, contains: "not in your list")
        state = try r.backend.orgRemoveRole(projectId: r.pid, roleId: second.id)
        XCTAssertEqual(state.organization?.roles.count, 3)
        let lead = try XCTUnwrap(state.organization?.roles.first)
        await fail({ _ = try r.backend.orgRemoveRole(projectId: r.pid, roleId: lead.id) }, contains: "needs its lead")
        await fail({ _ = try r.backend.orgUpdate(projectId: r.pid, gates: ["nonsense"]) }, contains: "A gate is one of")
    }

    func testStorageHoldsNoSecretsAndSurvivesDamage() async throws {
        let r = try await rig()
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        _ = try add(r, "Something")
        let dir = OrgStore.folder(r.backend.dataFolder, r.pid)
        var found = 0
        for name in try FileManager.default.subpathsOfDirectory(atPath: dir) where !name.hasSuffix("/") {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            found += 1
            let text = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertFalse(text.contains(secret), "\(name) must hold no API key")
            let mode = CoreFS.stat(path).mode & 0o777
            XCTAssertEqual(mode, 0o600, "\(name) is private")
        }
        XCTAssertGreaterThan(found, 1)
        XCTAssertEqual(CoreFS.stat(dir).mode & 0o777, 0o700)
        // A damaged file is no organization, never a crash.
        try "not json".write(toFile: dir + "/org.json", atomically: true, encoding: .utf8)
        XCTAssertNil(r.backend.orgLoad(r.pid))
        XCTAssertNil(try r.backend.orgState(projectId: r.pid).organization)
    }

    // MARK: A ticket through every stage

    func testATicketGoesThroughEveryStageWithAnArtifactEachAndNeverTouchesTheOwnersBranch() async throws {
        let r = try await rig()
        try await make(r)
        try start(r)
        let before = (head: git(["rev-parse", "HEAD"], in: r.folder), branch: git(["branch", "--show-current"], in: r.folder), status: git(["status", "--porcelain"], in: r.folder))
        XCTAssertEqual(before.branch, "main"); XCTAssertEqual(before.status, "")
        let t = try add(r, "Add the feature page", body: "A new screen for features.", ui: true)
        XCTAssertEqual(t.label, "T-1"); XCTAssertEqual(t.stage, .intake)

        // Intake, then the spec: the owner must approve the spec.
        var now = try await drive(r, t.id)
        XCTAssertEqual(now.state, "gate"); XCTAssertEqual(now.gate?.kind, "approval"); XCTAssertEqual(now.gate?.stage, "spec")
        XCTAssertEqual(now.artifacts.map(\.name), ["intake.md", "spec.md"])
        XCTAssertEqual(now.gate?.artifact, "spec.md")
        // The gate is in the Inbox, with the artifact to read.
        let waiting = r.backend.orgInbox().waiting()
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].kind, "gate"); XCTAssertEqual(waiting[0].ticketId, t.id); XCTAssertEqual(waiting[0].artifact, "spec.md"); XCTAssertEqual(waiting[0].gateKind, "approval")
        XCTAssertTrue(waiting[0].question.contains("Approve the spec for T-1"))
        // Nothing runs while it waits.
        let ranWhileWaiting = try await r.backend.orgStep(projectId: r.pid)
        XCTAssertFalse(ranWhileWaiting)

        _ = try r.backend.ticketApprove(projectId: r.pid, ticketId: t.id)
        XCTAssertTrue(r.backend.orgInbox().waiting().isEmpty, "answering settles the Inbox item")
        now = try await drive(r, t.id)
        XCTAssertEqual(now.state, "gate"); XCTAssertEqual(now.gate?.stage, "ship")
        XCTAssertEqual(Set(now.artifacts.map(\.name)), ["intake.md", "spec.md", "design.md", "mockup.html", "tokens.css", "plan.md", "build.md", "diff.patch", "review.md", "qa.md", "docs.md", "release-notes.md"])
        // The stages ran in order, each by its own role.
        let order = r.script.prompts.map(\.stage)
        XCTAssertEqual(order, ["Intake", "Spec", "Design", "Plan", "Build", "Build", "Review", "QA", "Ship", "Ship"])
        XCTAssertEqual(r.script.prompts.map(\.role), ["Lead", "Product manager", "Designer", "Architect", "Engineer", "Engineer", "Reviewer", "QA", "Docs writer", "Release manager"])
        // Design files are real files, on the ticket's branch.
        let branch = try XCTUnwrap(now.branch)
        XCTAssertEqual(branch, "black-team/t1-add-the-feature-page")
        let work = try XCTUnwrap(now.work)
        XCTAssertEqual(try String(contentsOfFile: work + "/design/mockup.html", encoding: .utf8), "<!doctype html><title>Mock</title><h1>Feature</h1>")
        XCTAssertTrue(try String(contentsOfFile: work + "/design/tokens.css", encoding: .utf8).contains("--accent"))
        XCTAssertEqual(try String(contentsOfFile: work + "/feature.txt", encoding: .utf8), "done\n")
        let files = git(["ls-tree", "-r", "--name-only", branch], in: r.folder).split(separator: "\n").map(String.init)
        XCTAssertTrue(files.contains("design/mockup.html") && files.contains("design/tokens.css") && files.contains("feature.txt") && files.contains("notes.txt"), "\(files)")
        XCTAssertTrue(files.contains(".black-team/tickets/T-1/spec.md"), "artifacts are also stored in the project, on the ticket's branch: \(files)")
        XCTAssertGreaterThanOrEqual(Int(git(["rev-list", "--count", "\(try XCTUnwrap(now.base))..\(branch)"], in: r.folder)) ?? 0, 3)
        // The owner's branch, commit and folder are exactly as they were.
        XCTAssertEqual(git(["rev-parse", "HEAD"], in: r.folder), before.head)
        XCTAssertEqual(git(["branch", "--show-current"], in: r.folder), "main")
        XCTAssertEqual(git(["status", "--porcelain"], in: r.folder), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.folder + "/feature.txt"))
        XCTAssertEqual(git(["rev-parse", "main"], in: r.folder), before.head)
        // The diff artifact is the real diff of the branch.
        let diff = try XCTUnwrap(r.backend.ticketDetail(projectId: r.pid, ticketId: t.id).artifacts["diff.patch"])
        XCTAssertTrue(diff.contains("+++ b/feature.txt") && diff.contains("+done"))
        // Shipping needs the owner; approving marks it ready to merge and merges nothing.
        let release = try XCTUnwrap(r.backend.ticketDetail(projectId: r.pid, ticketId: t.id).artifacts["release-notes.md"])
        XCTAssertTrue(release.contains("git merge black-team/t1-add-the-feature-page") && release.contains("has not merged it"))
        _ = try r.backend.ticketApprove(projectId: r.pid, ticketId: t.id)
        now = try ticket(r, t.id)
        XCTAssertEqual(now.state, "done")
        XCTAssertTrue(now.history.last?.text.contains("merging it is up to you") == true)
        XCTAssertEqual(git(["rev-parse", "main"], in: r.folder), before.head, "approving shipping does not merge")
        // The work of each role is in the room's work log and the ledger.
        let ledger = try r.backend.orgState(projectId: r.pid).ledger
        XCTAssertEqual(ledger.paidTokens, 0); XCTAssertGreaterThanOrEqual(ledger.localTokens, 10 * 550)
        XCTAssertTrue(ledger.summary.hasPrefix("Local agents did ") && ledger.summary.contains("tokens of work today; paid agents used 0."), ledger.summary)
        XCTAssertEqual(Set(ledger.lines.map(\.roleName)), ["Lead", "Product manager", "Designer", "Architect", "Engineer", "Reviewer", "QA", "Docs writer", "Release manager"])
    }

    func testStagesSkipWhenNotNeededAndASmallTeamRunsTheShortPath() async throws {
        let r = try await rig()
        try await make(r, "small", gates: [])
        r.script.reply("Intake", "SUMMARY: tiny.\nTOUCHES_UI: no\nSIZE: small\nACCEPTANCE CRITERIA:\n1. feature.txt exists")
        try start(r)
        let t = try add(r, "Tiny change")
        let done = try await drive(r, t.id)
        XCTAssertEqual(done.state, "done")
        // No product manager, designer, architect or QA: the lead's intake is the spec, the plan is skipped (small), review runs.
        XCTAssertEqual(r.script.prompts.map(\.stage), ["Intake", "Build", "Review", "Ship"])
        XCTAssertTrue(done.history.contains { $0.text.contains("Spec skipped") } && done.history.contains { $0.text.contains("Design skipped") }
                      && done.history.contains { $0.text.contains("Plan skipped") } && done.history.contains { $0.text.contains("QA skipped") })
    }

    func testReviewFailureSendsItBackToBuildWithTheFindingsAndThenEscalatesToTheOwner() async throws {
        let r = try await rig()
        try await make(r, gates: [])
        try start(r)
        r.script.verdicts("Review", ["revise", "accept"])
        let t = try add(r, "Build the thing")
        var now = try await drive(r, t.id)
        XCTAssertEqual(now.state, "done")
        XCTAssertEqual(r.script.prompts.map(\.stage).filter { $0 == "Build" || $0 == "Review" }, ["Build", "Build", "Review", "Build", "Review"])
        // The second Build got the reviewer's findings, and only the fix task.
        let fix = r.script.prompts("Build").last ?? ""
        XCTAssertTrue(fix.contains("Add a test for feature.txt in tests/") && fix.contains("Fix what Reviewer found"), fix)
        XCTAssertEqual(now.sendBacks["review"], 1)
        XCTAssertTrue(now.history.contains { $0.text.contains("Sent back to Build (1 of 2)") })
        XCTAssertEqual(now.artifacts.filter { $0.name.hasPrefix("review") }.map(\.name), ["review.md", "review-2.md"])

        // A reviewer that never accepts: after two send-backs the owner decides.
        let r2 = try await rig()
        try await make(r2, gates: [])
        try start(r2)
        r2.script.verdicts("Review", ["revise"])
        let t2 = try add(r2, "Stubborn")
        now = try await drive(r2, t2.id)
        XCTAssertEqual(now.state, "gate"); XCTAssertEqual(now.gate?.kind, "escalation"); XCTAssertEqual(now.sendBacks["review"], 2)
        XCTAssertEqual(r2.script.prompts.map(\.stage).filter { $0 == "Review" }.count, 3)
        XCTAssertTrue(now.gate?.question.contains("Approve to accept it as it is") == true)
        // Sending it back with the owner's own note goes to Build, with the note.
        _ = try r2.backend.ticketSendBack(projectId: r2.pid, ticketId: t2.id, note: "Use the other approach.")
        XCTAssertEqual(try ticket(r2, t2.id).stage, .build); XCTAssertEqual(try ticket(r2, t2.id).state, "ready")
        XCTAssertEqual(try ticket(r2, t2.id).findings, "Use the other approach.")
        // Approving accepts it as it is and moves on to QA.
        let r3 = try await rig()
        try await make(r3, gates: [])
        try start(r3)
        r3.script.verdicts("Review", ["revise"])
        let t3 = try add(r3, "Stubborn too")
        _ = try await drive(r3, t3.id)
        XCTAssertEqual(try ticket(r3, t3.id).gate?.kind, "escalation")
        _ = try r3.backend.ticketApprove(projectId: r3.pid, ticketId: t3.id)
        XCTAssertEqual(try ticket(r3, t3.id).stage, .qa); XCTAssertEqual(try ticket(r3, t3.id).state, "ready")
    }

    func testQAFailureSendsItBackToBuildAndPassingMovesOn() async throws {
        let r = try await rig()
        try await make(r, gates: [])
        try start(r)
        r.script.verdicts("QA", ["fail", "pass"])
        let t = try add(r, "Needs tests")
        let now = try await drive(r, t.id)
        XCTAssertEqual(now.state, "done")
        XCTAssertEqual(r.script.prompts.map(\.stage).filter { ["Build", "Review", "QA"].contains($0) }, ["Build", "Build", "Review", "QA", "Build", "Review", "QA"])
        XCTAssertTrue((r.script.prompts("Build").last ?? "").contains("feature.txt is empty"))
        XCTAssertEqual(now.sendBacks["qa"], 1)
        XCTAssertEqual(now.artifacts.filter { $0.name.hasPrefix("qa") }.map(\.name), ["qa.md", "qa-2.md"])
        // A QA reply with no verdict does not pass.
        let r2 = try await rig()
        try await make(r2, gates: [])
        try start(r2)
        r2.script.reply("QA", "I ran things. Looks good to me.")
        let t2 = try add(r2, "No verdict")
        let stuck = try await drive(r2, t2.id)
        XCTAssertEqual(stuck.state, "gate"); XCTAssertEqual(stuck.gate?.kind, "escalation")
    }

    func testASpecQuestionGoesToThePersonAndTheAnswerComesBack() async throws {
        let r = try await rig()
        try await make(r)
        try start(r)
        r.script.reply("Spec", "QUESTION: Should it work offline?")
        let t = try add(r, "Sync notes")
        var now = try await drive(r, t.id)
        XCTAssertEqual(now.state, "gate"); XCTAssertEqual(now.gate?.kind, "question"); XCTAssertEqual(now.gate?.question, "Should it work offline?")
        let item = try XCTUnwrap(r.backend.orgInbox().waiting().first)
        XCTAssertEqual(item.gateKind, "question")
        // Approving a question is not an answer.
        await fail({ _ = try r.backend.ticketApprove(projectId: r.pid, ticketId: t.id) }, contains: "asked you a question")
        let hooks = ServiceHooks.local(r.backend)
        XCTAssertThrowsError(try hooks.answer(item.id, approve: true))
        r.script.reply("Spec", "# Spec\n## Acceptance criteria\n1. Works offline.")
        _ = try r.backend.ticketAnswer(projectId: r.pid, ticketId: t.id, answer: "Yes, offline too.")
        XCTAssertTrue(r.backend.orgInbox().waiting().isEmpty)
        now = try await drive(r, t.id)
        XCTAssertEqual(now.gate?.kind, "approval"); XCTAssertEqual(now.gate?.stage, "spec")
        let specPrompts = r.script.prompts("Spec")
        XCTAssertEqual(specPrompts.count, 2)
        XCTAssertTrue(specPrompts[1].contains("Yes, offline too.") && specPrompts[1].contains("Should it work offline?"))
    }

    func testGatesAnsweredFromTheInboxResumeOrSendBack() async throws {
        let r = try await rig()
        try await make(r)
        try start(r)
        let hooks = ServiceHooks.local(r.backend)
        let t = try add(r, "Gate me")
        _ = try await drive(r, t.id)
        let spec = try XCTUnwrap(hooks.inbox.waiting().first)
        XCTAssertEqual(hooks.inboxJSON()["waiting"]?.int, 1)
        // Deny: the spec is written again with the owner's reason in mind.
        try hooks.answer(spec.id, approve: false)
        var now = try ticket(r, t.id)
        XCTAssertEqual(now.state, "ready"); XCTAssertEqual(now.stage, .spec)
        XCTAssertEqual(hooks.inbox.get(spec.id)?.state, "denied")
        now = try await drive(r, t.id)
        XCTAssertEqual(now.gate?.stage, "spec")
        let again = try XCTUnwrap(hooks.inbox.waiting().first)
        XCTAssertNotEqual(again.id, spec.id)
        // Approve from the Inbox: the pipeline resumes.
        try hooks.answer(again.id, approve: true)
        XCTAssertEqual(hooks.inbox.get(again.id)?.state, "approved")
        now = try await drive(r, t.id)
        XCTAssertEqual(now.gate?.stage, "ship")
        XCTAssertEqual(r.script.prompts.map(\.stage).filter { $0 == "Spec" }.count, 2)
        // A gate survives a restart: settling "everything waiting" (what the scheduler does on start) leaves it alone.
        try hooks.inbox.settleAll(as: "ended")
        XCTAssertEqual(hooks.inbox.waiting().count, 1)
    }

    // MARK: Running continuously

    func testContinuousPickupWaitsForTheOneModelSlotAndRunsTicketsOneAtATime() async throws {
        let r = try await rig()
        try await make(r, "small", gates: [])
        let a = try r.backend.orgAgreement(projectId: r.pid)
        _ = try r.backend.orgStart(projectId: r.pid, digest: a.digest)
        r.backend.orgStopLoop()
        r.backend.orgStartLoop(every: 0.02)
        // Somebody else holds the model with a chat: the organization does not start a stage behind its back.
        let hold = Hold()
        let answer = r.fixture.reply
        r.fixture.reply = { request in try await hold.wait(); return try await answer(request) }
        _ = try r.backend.submit(message: "hello there", kind: "chat", requestId: UUID().uuidString.lowercased())
        let one = try add(r, "First ticket"), two = try add(r, "Second ticket")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(r.script.prompts.count, 0, "the chat holds the slot; the organization waits its turn")
        XCTAssertEqual(try ticket(r, one.id).state, "ready")
        hold.release()
        try await waitFor("both tickets done") { try self.ticket(r, one.id).state == "done" && self.ticket(r, two.id).state == "done" }
        XCTAssertEqual(r.script.overlap.most, 1, "never two model calls at once")
        // One ticket at a time: the first is finished before the second starts.
        let stages = r.script.prompts.map { $0.text.contains("T-1") ? "T-1" : "T-2" }
        XCTAssertEqual(stages, stages.sorted(), "\(stages)")
        r.backend.orgStopLoop()
    }

    func testPausingStopsTheStageThatRunsAndTheTicketWaitsAgain() async throws {
        let r = try await rig()
        try await make(r, "small", gates: [])
        try start(r)
        let hold = Hold()
        r.script.hold = hold
        let t = try add(r, "Interrupted")
        let step = Task { try await r.backend.orgStep(projectId: r.pid) }
        try await waitFor("the stage to start") { try self.ticket(r, t.id).state == "running" && r.script.overlap.most >= 1 }
        XCTAssertEqual(try r.backend.orgState(projectId: r.pid).roles.filter { $0.status == "working" }.map(\.role.kind), ["lead"])
        _ = try r.backend.orgPause(projectId: r.pid)
        _ = try await step.value
        XCTAssertEqual(try ticket(r, t.id).state, "ready")
        XCTAssertTrue(try r.backend.orgLoad(r.pid)!.paused)
        let ranWhilePaused = try await r.backend.orgStep(projectId: r.pid)
        XCTAssertFalse(ranWhilePaused)
        r.script.hold = nil
        _ = try r.backend.orgResume(projectId: r.pid)
        XCTAssertFalse(try r.backend.orgLoad(r.pid)!.paused)
    }

    func testAStageThatWasRunningWhenBlackTeamQuitRunsAgain() async throws {
        let r = try await rig()
        try await make(r, "small")
        let t = try add(r, "Left running")
        _ = try r.backend.orgTicketMutate(r.pid, t.id) { $0.state = "running" }
        r.backend.orgHousekeeping(r.pid)
        XCTAssertEqual(try ticket(r, t.id).state, "ready")
        XCTAssertTrue(try ticket(r, t.id).history.last?.text.contains("Black Team stopped during this stage") == true)
    }

    func testALargeTicketIsSplitByTheLead() async throws {
        let r = try await rig()
        try await make(r, "small", gates: [])
        try start(r)
        r.script.reply("Intake", "SUMMARY: big.\nTOUCHES_UI: no\nSIZE: large\nACCEPTANCE CRITERIA:\n1. all\nSPLIT: {\"tickets\":[{\"title\":\"Part one\",\"body\":\"first\"},{\"title\":\"Part two\",\"body\":\"second\"}]}")
        let t = try add(r, "Everything at once")
        _ = try await r.backend.orgStep(projectId: r.pid)
        let all = r.backend.orgTickets(r.pid)
        XCTAssertEqual(all.map(\.title), ["Everything at once", "Part one", "Part two"])
        XCTAssertEqual(all[0].state, "done"); XCTAssertEqual(all[0].children.count, 2)
        XCTAssertEqual(all[1].source, "lead"); XCTAssertEqual(all[1].parent, t.id); XCTAssertEqual(all[1].state, "ready")
    }

    // MARK: Budgets and the ledger

    func testACeilingPausesTheOrganizationAndLeavesANoteInTheInbox() async throws {
        let r = try await rig()
        // The lead is a "paid" cloud model: 1,100 tokens a run, at prices the person typed in.
        var state = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        var lead = try XCTUnwrap(state.organization?.roles.first)
        lead.price = OrgPrice(inPerMillion: 10, outPerMillion: 20)
        state = try r.backend.orgSaveRole(projectId: r.pid, role: lead)
        state = try r.backend.orgUpdate(projectId: r.pid, gates: [], budget: OrgBudget(paidTokensPerDay: 2000, moneyPerDay: nil))
        try start(r)
        let t = try add(r, "Costly")
        let ran = try await r.backend.orgStep(projectId: r.pid)       // intake: 1,100 paid tokens
        XCTAssertTrue(ran)
        XCTAssertFalse(try r.backend.orgLoad(r.pid)!.paused)
        _ = try await r.backend.orgStep(projectId: r.pid)             // ship by the lead later; build first (local)
        _ = try await drive(r, t.id, limit: 6)
        let org = try XCTUnwrap(r.backend.orgLoad(r.pid))
        XCTAssertTrue(org.paused, "the ceiling was reached")
        XCTAssertTrue(org.pausedReason.contains("reached its ceiling for today") && org.pausedReason.contains("of 2,000 tokens"), org.pausedReason)
        let note = try XCTUnwrap(r.backend.orgInbox().waiting().first { $0.kind == "note" })
        XCTAssertTrue(note.question.contains("Nothing more runs until you raise the ceiling"))
        let ranPaused = try await r.backend.orgStep(projectId: r.pid)
        XCTAssertFalse(ranPaused)
        await fail({ _ = try r.backend.orgResume(projectId: r.pid) }, contains: "reached its ceiling")
        // Raising the ceiling lets it resume; the note clears with a tap.
        _ = try r.backend.orgUpdate(projectId: r.pid, budget: OrgBudget(paidTokensPerDay: 1_000_000, moneyPerDay: nil))
        _ = try r.backend.orgResume(projectId: r.pid)
        r.backend.orgStopLoop()
        try ServiceHooks.local(r.backend).answer(note.id, approve: true)
        XCTAssertNil(r.backend.orgInbox().waiting().first { $0.kind == "note" && $0.id == note.id })
        let done = try await drive(r, t.id)
        XCTAssertEqual(done.state, "done")
        // The ledger says who did what, paid and local, and the money at the person's own prices.
        let ledger = try r.backend.orgState(projectId: r.pid).ledger
        XCTAssertGreaterThan(ledger.paidTokens, 2000 - 1100); XCTAssertGreaterThan(ledger.localTokens, 0)
        let lines = Dictionary(uniqueKeysWithValues: ledger.lines.map { ($0.roleName, $0) })
        XCTAssertEqual(lines["Lead"]?.paid, true); XCTAssertEqual(lines["Engineer"]?.paid, false); XCTAssertEqual(lines["Reviewer"]?.paid, false)
        XCTAssertEqual(lines["Lead"]?.money ?? 0, Double(lines["Lead"]!.runs) * (1000 * 10 + 100 * 20) / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(lines["Engineer"]?.money, 0)
        XCTAssertTrue(ledger.summary.contains("paid agents used") && ledger.summary.contains("Paid work cost about"), ledger.summary)
        r.backend.orgStopLoop()
    }

    func testAMoneyCeilingUsesThePricesThePersonEnteredAndNoPriceMeansNoMoney() async throws {
        let r = try await rig()
        var state = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        var lead = try XCTUnwrap(state.organization?.roles.first)
        state = try r.backend.orgUpdate(projectId: r.pid, gates: [], budget: OrgBudget(paidTokensPerDay: nil, moneyPerDay: 0.01))
        try start(r)
        _ = try add(r, "Priced")
        _ = try await r.backend.orgStep(projectId: r.pid)
        XCTAssertFalse(try r.backend.orgLoad(r.pid)!.paused, "no price entered: money is not counted, never guessed")
        XCTAssertEqual(try r.backend.orgState(projectId: r.pid).ledger.money, 0)
        lead.price = OrgPrice(inPerMillion: 1000, outPerMillion: 1000)     // 1,100 tokens -> 1.10
        _ = try r.backend.orgSaveRole(projectId: r.pid, role: lead)
        _ = try add(r, "Priced two")
        _ = try await drive(r, try XCTUnwrap(r.backend.orgTickets(r.pid).first).id, limit: 4)
        let org = try XCTUnwrap(r.backend.orgLoad(r.pid))
        XCTAssertTrue(org.paused && org.pausedReason.contains("money ceiling"), org.pausedReason)
        r.backend.orgStopLoop()
    }

    func testTheStandUpReportSaysWhatMovedWhatIsBlockedWhatWaitsAndWhatWasSpent() async throws {
        let r = try await rig()
        try await make(r)
        try start(r)
        let waiting = try add(r, "Waits for me")
        _ = try await drive(r, waiting.id)                     // at the spec gate
        let blocked = try add(r, "Gets stuck")
        _ = try r.backend.orgTicketMutate(r.pid, blocked.id) { $0.state = "blocked"; $0.note = "The branch could not be made." }
        let queued = try add(r, "Next in line")
        let text = try r.backend.orgStandupMake(projectId: r.pid)
        XCTAssertTrue(text.hasPrefix("# Stand-up \u{00B7} "), text)
        XCTAssertTrue(text.contains("## What moved") && text.contains("T-1 Waits for me") && text.contains("Waiting for you"))
        XCTAssertTrue(text.contains("- T-1 Waits for me: Approve the spec for T-1"), text)
        XCTAssertTrue(text.contains("- T-2 Gets stuck: The branch could not be made."))
        XCTAssertTrue(text.contains("- \(queued.label) Next in line: Intake"))
        XCTAssertTrue(text.contains("Local agents did 1,100 tokens of work today; paid agents used 0."), text)
        XCTAssertTrue(text.contains("- Lead (local): 550 tokens, 1 run"), text)
        // It is a file and a note in the Inbox when the schedule makes it.
        let day = r.backend.orgDay()
        XCTAssertEqual(try String(contentsOfFile: OrgStore.folder(r.backend.dataFolder, r.pid) + "/standups/\(day).md", encoding: .utf8), text)
        // Due on its schedule: the loop makes it once and sets the next time.
        _ = try r.backend.orgMutate(r.pid) { $0.standupAt = "daily at 9:00"; $0.standupNext = Date().addingTimeInterval(-60).timeIntervalSince1970 }
        r.backend.orgHousekeeping(r.pid)
        XCTAssertTrue(r.backend.orgInbox().waiting().contains { $0.kind == "note" && $0.scheduleName.hasSuffix("stand-up") })
        XCTAssertGreaterThan(try XCTUnwrap(r.backend.orgLoad(r.pid)?.standupNext), Date().timeIntervalSince1970)
    }

    func testARoutineMakesATicketOnItsScheduleOnceWhileItIsOpen() async throws {
        let r = try await rig()
        try await make(r, "small")
        try start(r)
        _ = try r.backend.orgAddRoutine(projectId: r.pid, title: "Check dependencies", body: "Look for outdated ones.", when: "weekdays at 9:00")
        _ = try r.backend.orgMutate(r.pid) { $0.routines[0].next = Date().addingTimeInterval(-5).timeIntervalSince1970 }
        r.backend.orgHousekeeping(r.pid)
        r.backend.orgHousekeeping(r.pid)
        let all = r.backend.orgTickets(r.pid)
        XCTAssertEqual(all.map(\.title), ["Check dependencies"]); XCTAssertEqual(all[0].source, "schedule")
        _ = try r.backend.orgMutate(r.pid) { $0.routines[0].next = Date().addingTimeInterval(-5).timeIntervalSince1970 }
        r.backend.orgHousekeeping(r.pid)
        XCTAssertEqual(r.backend.orgTickets(r.pid).count, 1, "its last ticket is still open, so no pile-up")
        await fail({ _ = try r.backend.orgAddRoutine(projectId: r.pid, title: "x", when: "whenever") }, contains: "Say when like this")
    }

    // MARK: What leaves this computer

    func testTheAgreementNamesTheServicesAndMemoryStaysOutWhenAnyRoleIsPaid() async throws {
        let r = try await rig()
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey)
        let local = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertFalse(local.leavesThisMac); XCTAssertTrue(local.memoryUsed); XCTAssertEqual(local.services, [])
        XCTAssertTrue(local.text.contains("Every role runs on this computer, so nothing leaves it."), local.text)
        XCTAssertTrue(local.text.contains("your own branch and folder are never changed") && local.text.contains("nothing is merged unless you do it"))
        _ = try r.backend.orgRemove(projectId: r.pid)
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        let paid = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertTrue(paid.leavesThisMac); XCTAssertFalse(paid.memoryUsed); XCTAssertEqual(paid.services, [host])
        XCTAssertTrue(paid.text.contains("Lead (\(host))") && paid.text.contains("is sent to that service") && paid.text.contains("Your memory is not used"), paid.text)
        XCTAssertNotEqual(paid.digest, local.digest)
        // A wrong or stale digest does not start it; a phone cannot start it.
        await fail({ _ = try r.backend.orgStart(projectId: r.pid, digest: local.digest) }, contains: "Read it again")
        await fail({ _ = try r.backend.orgStart(projectId: r.pid, digest: paid.digest, from: .phone) }, contains: "from the computer")
        // Running with a paid lead: the vault stays out of every stage, local roles included.
        _ = try r.backend.orgUpdate(projectId: r.pid, gates: [])
        _ = try r.backend.orgStart(projectId: r.pid, digest: paid.digest)
        r.backend.orgStopLoop()
        let t = try add(r, "Private")
        _ = try await drive(r, t.id)
        XCTAssertGreaterThan(r.seen.count, 3)
        XCTAssertFalse(r.seen.all.contains { String(describing: $0).contains("rare coins") }, "the vault stays out when any role is paid")
        XCTAssertTrue(r.seen.all.contains { $0["cloud"] == true } && r.seen.all.contains { $0["cloud"] == false })
    }

    func testAProjectThatIsLocalOnlyRefusesPaidRolesInTheAgreement() async throws {
        let r = try await rig(cloudAllowed: false)
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        let a = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertTrue(a.problems.contains { $0.contains("local only") }, "\(a.problems)")
        await fail({ _ = try r.backend.orgStart(projectId: r.pid, digest: a.digest) }, contains: "local only")
        XCTAssertFalse(try r.backend.orgLoad(r.pid)!.running)
    }

    func testAnUnsetRoleOrOneThatCannotBuildStopsTheStart() async throws {
        let r = try await rig()
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small")
        var a = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertTrue(a.problems.contains("Lead has no model or agent yet."))
        _ = try r.backend.orgRemove(projectId: r.pid)
        let state = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey)
        var engineer = try XCTUnwrap(state.organization?.roles.first { $0.kind == "engineer" })
        engineer.work = "chat"
        _ = try r.backend.orgSaveRole(projectId: r.pid, role: engineer)
        a = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertTrue(a.problems.contains { $0.contains("does chat work and cannot read or change files") }, "\(a.problems)")
        engineer.work = "code"; engineer.access = .read
        _ = try r.backend.orgSaveRole(projectId: r.pid, role: engineer)
        a = try r.backend.orgAgreement(projectId: r.pid)
        XCTAssertTrue(a.problems.contains { $0.contains("can only read files") }, "\(a.problems)")
    }

    func testAServiceTheOwnerHasNotAgreedToNeedsAYesBeforeTheTicketGoesThere() async throws {
        let r = try await rig()
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey)
        _ = try r.backend.orgUpdate(projectId: r.pid, gates: [])
        try start(r)                                           // agreed while every role was local
        // Later the reviewer is moved to the paid model. Continuous pickup stops until the agreement is read again.
        var reviewer = try XCTUnwrap(r.backend.orgLoad(r.pid)?.roles.first { $0.kind == "reviewer" })
        reviewer.modelKey = r.cloudKey
        _ = try r.backend.orgSaveRole(projectId: r.pid, role: reviewer)
        let org = try XCTUnwrap(r.backend.orgLoad(r.pid))
        XCTAssertFalse(org.running); XCTAssertTrue(org.pausedReason.contains("not agreed to"), org.pausedReason)
        // Stepping by hand still cannot send a ticket there without a yes.
        let t = try add(r, "Goes to the reviewer")
        for _ in 0..<6 { _ = try await r.backend.orgStep(projectId: r.pid, force: true) }
        let now = try ticket(r, t.id)
        XCTAssertEqual(now.state, "gate", "stage \(now.stage) state \(now.state) \(now.note)"); XCTAssertEqual(now.gate?.kind, "privacy"); XCTAssertEqual(now.gate?.service, host)
        XCTAssertTrue(now.gate?.question.contains("would be sent to \(host)") == true)
        XCTAssertFalse(r.seen.all.contains { $0["cloud"] == true }, "nothing went to the service")
        let item = try XCTUnwrap(r.backend.orgInbox().waiting().first)
        XCTAssertEqual(item.gateKind, "privacy"); XCTAssertEqual(item.desktopOnly, true)
        _ = try r.backend.ticketApprove(projectId: r.pid, ticketId: t.id)
        XCTAssertEqual(try r.backend.orgLoad(r.pid)?.confirmed, [host])
        _ = try await r.backend.orgStep(projectId: r.pid, force: true)
        XCTAssertTrue(r.seen.all.contains { $0["cloud"] == true }, "after the yes it goes")
        // Refusing blocks the ticket with the reason.
        let u = try add(r, "Second one")
        _ = try r.backend.orgMutate(r.pid) { $0.confirmed = [] }
        for _ in 0..<14 { _ = try await r.backend.orgStep(projectId: r.pid, force: true) }
        let hooks = ServiceHooks.local(r.backend)
        if let deny = hooks.inbox.waiting().first(where: { $0.ticketId == u.id }) {
            try hooks.answer(deny.id, approve: false)
            XCTAssertEqual(try ticket(r, u.id).state, "blocked")
            XCTAssertTrue(try ticket(r, u.id).note.contains("did not allow"))
        } else { XCTFail("the second ticket should have been held at a privacy gate") }
    }

    func testATicketFromThePhoneThatMayUsePaidRolesWaitsForTheComputer() async throws {
        let r = try await rig()
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        let a = try r.backend.orgAgreement(projectId: r.pid)
        _ = try r.backend.orgStart(projectId: r.pid, digest: a.digest)
        r.backend.orgStopLoop()
        let t = try add(r, "From my phone", source: "phone")
        XCTAssertEqual(t.state, "gate"); XCTAssertEqual(t.gate?.kind, "approval")
        let item = try XCTUnwrap(r.backend.orgInbox().waiting().first)
        XCTAssertEqual(item.desktopOnly, true)
        let ranWaiting = try await r.backend.orgStep(projectId: r.pid)
        XCTAssertFalse(ranWaiting)
        // The routes: the phone sees the list and the gate but is refused the approval.
        let summary = OrgRoutes.summary(try ticket(r, t.id))
        XCTAssertEqual(summary["gate"]?["desktopOnly"]?.bool, true)
        _ = try r.backend.ticketApprove(projectId: r.pid, ticketId: t.id)
        XCTAssertEqual(try ticket(r, t.id).state, "ready")
        // A local-only organization takes phone tickets straight into the queue.
        let r2 = try await rig()
        try await make(r2, "small")
        let p = try add(r2, "Local from phone", source: "phone")
        XCTAssertEqual(p.state, "ready")
    }

    // MARK: Projects without git

    func testAProjectWithoutGitIsWorkedInDirectlyAndSaysSo() async throws {
        let r = try await rig(repo: false)
        try await make(r, "small", gates: [])
        try start(r)
        let t = try add(r, "No repo")
        let done = try await drive(r, t.id)
        XCTAssertEqual(done.state, "done")
        XCTAssertNil(done.branch)
        XCTAssertEqual(try String(contentsOfFile: r.folder + "/feature.txt", encoding: .utf8), "done\n")
        let build = try XCTUnwrap(r.backend.ticketDetail(projectId: r.pid, ticketId: t.id).artifacts["build.md"])
        XCTAssertTrue(build.contains("not a git repository"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.folder + "/.black-team/tickets/T-1/build.md"), "artifacts are in the project folder too")
        XCTAssertTrue(done.history.last?.text.contains("in your project folder") == true)
    }

    func testARepositoryWithNoCommitsBlocksTheTicketWithAPlainReason() async throws {
        let r = try await rig(repo: false)
        XCTAssertTrue(OrgGit.run(["init", "-q", "-b", "main"], in: r.folder).ok)
        try await make(r, "small", gates: [])
        try start(r)
        let t = try add(r, "Empty repo")
        let stuck = try await drive(r, t.id)
        XCTAssertEqual(stuck.state, "blocked"); XCTAssertTrue(stuck.note.contains("no commits yet"), stuck.note)
        XCTAssertTrue(r.backend.orgInbox().waiting().contains { $0.kind == "note" && $0.question.contains("no commits yet") })
        _ = try r.backend.ticketRetry(projectId: r.pid, ticketId: t.id)
        XCTAssertEqual(try ticket(r, t.id).state, "ready")
    }

    func testTwoTicketsGetTwoBranchesAndCancelledTicketsDoNotRun() async throws {
        let r = try await rig()
        try await make(r, "small", gates: [])
        try start(r)
        let a = try add(r, "Alpha thing"), b = try add(r, "Beta thing"), c = try add(r, "Gamma thing")
        _ = try r.backend.ticketCancel(projectId: r.pid, ticketId: c.id)
        _ = try await drive(r, a.id); _ = try await drive(r, b.id)
        XCTAssertEqual(try ticket(r, a.id).branch, "black-team/t1-alpha-thing"); XCTAssertEqual(try ticket(r, b.id).branch, "black-team/t2-beta-thing")
        XCTAssertEqual(try ticket(r, c.id).state, "cancelled")
        let branches = git(["branch", "--list", "black-team/*"], in: r.folder)
        XCTAssertTrue(branches.contains("t1-alpha-thing") && branches.contains("t2-beta-thing") && !branches.contains("gamma"))
        XCTAssertEqual(git(["branch", "--show-current"], in: r.folder), "main")
        XCTAssertTrue(r.script.prompts.allSatisfy { !$0.text.contains("Gamma thing") })
    }

    // MARK: Small pieces

    func testReadingRepliesAndNames() throws {
        XCTAssertEqual(OrgGit.branchName(number: 12, title: "Add a  Dark Mode!! to Settings, please do it soon"), "black-team/t12-add-a-dark-mode-to-settings-plea")
        XCTAssertEqual(OrgGit.branchName(number: 3, title: "!!!"), "black-team/t3")
        XCTAssertEqual(Backend.orgField("SIZE", in: "x\n**SIZE:** Small\n"), "Small")
        XCTAssertEqual(Backend.orgField("touches_ui", in: "TOUCHES_UI: yes"), "yes")
        XCTAssertNil(Backend.orgField("QUESTION", in: "Acceptance criteria\n1. a"))
        XCTAssertEqual(Backend.orgFence("html", in: "x\n```html\n<b>\n```\ny"), "<b>")
        XCTAssertNil(Backend.orgFence("css", in: "```html\n<b>\n```"))
        XCTAssertEqual(Backend.orgSplit(#"SPLIT: {"tickets":[{"title":"A","body":"b"},{"body":"no title"}]}"#)?.count, 1)
        XCTAssertEqual(Backend.orgQAVerdict(#"all good {"verdict":"PASS","reason":""}"#)?.pass, true)
        XCTAssertEqual(Backend.orgQAVerdict(#"{"verdict":"fail","reason":"x"}"#)?.reason, "x")
        XCTAssertNil(Backend.orgQAVerdict("pass"))
        XCTAssertTrue(Backend.orgGuessUI("Add a dark mode button to the settings page"))
        XCTAssertFalse(Backend.orgGuessUI("Speed up the importer"))
    }

    func testTicketFindingAndLimits() async throws {
        let r = try await rig()
        try await make(r, "small")
        let t = try add(r, "One")
        XCTAssertEqual(try r.backend.orgFindTicket(projectId: r.pid, "1").id, t.id)
        XCTAssertEqual(try r.backend.orgFindTicket(projectId: r.pid, "T-1").id, t.id)
        XCTAssertEqual(try r.backend.orgFindTicket(projectId: r.pid, String(t.id.prefix(8))).id, t.id)
        await fail({ _ = try r.backend.orgFindTicket(projectId: r.pid, "9") }, contains: "There is no ticket")
        await fail({ _ = try r.backend.ticketAdd(projectId: r.pid, title: "  ") }, contains: "Give the ticket a title")
        await fail({ _ = try r.backend.ticketAdd(projectId: r.pid, title: "x", body: String(repeating: "y", count: 5000)) }, contains: "details are up to")
        await fail({ _ = try r.backend.ticketApprove(projectId: r.pid, ticketId: t.id) }, contains: "not waiting for you")
        await fail({ _ = try r.backend.ticketSendBack(projectId: r.pid, ticketId: t.id, note: "x") }, contains: "can be sent back when")
    }

    // MARK: Helpers

    func fail(_ body: () throws -> Void, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try body(); XCTFail("expected a refusal", file: file, line: line) }
        catch { XCTAssertTrue(messageOf(error).contains(text), "\(messageOf(error)) should contain \(text)", file: file, line: line) }
    }

    func waitFor(_ what: String, timeout: Double = 20, _ condition: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("timed out waiting for \(what)")
    }
}
