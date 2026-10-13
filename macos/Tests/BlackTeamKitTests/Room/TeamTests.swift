import XCTest
@testable import BlackTeamKit

/// What the fake model server says: one closure decides, from the newest message of the conversation, for local and for cloud.
final class Responder: @unchecked Sendable {
    private let lock = NSLock()
    private var _respond: @Sendable (_ cloud: Bool, _ prompt: String) async throws -> String = { _, _ in "A result." }
    var respond: @Sendable (Bool, String) async throws -> String {
        get { lock.lock(); defer { lock.unlock() }; return _respond }
        set { lock.lock(); _respond = newValue; lock.unlock() }
    }
}

final class TeamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func jump(minutes: Double) { lock.lock(); date = date.addingTimeInterval(minutes * 60); lock.unlock() }
}

/// Hands out a number each time it is asked, safely from any thread.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// A team run through the real Backend, with a fake Claude Code, a fake model server and the room's usual fakes.
final class TeamTests: XCTestCase {
    let secret = "sk-cloud-test-key-1234567890abcdef"
    let host = "api.cloud-test.com"
    let vaultCore = "Vault-Secret-Alpha: the owner keeps rare coins."
    let vaultNote = "the umbrella is kept in Vault-Secret-Beta"

    struct Rig {
        var fixture: BackendFixture
        var backend: Backend
        var agents: FakeAgentLauncher
        var project: ProjectSummary
        var localKey: String
        var responder: Responder
        var clock: TeamClock
        var vault: Memory?
        var engineSeen: Seen
        var pid: String { project.id }
    }

    func rig(cloudAllowed: Bool = true, agents: FakeAgentLauncher = FakeAgentLauncher(), codeEngine: Bool = false) async throws -> Rig {
        let fixture = try BackendFixture(self)
        let vault = try Memory(vault: fixture.stateDir + "/vault")
        try vault.write("Core", "# Core\n\n\(vaultCore)\n")
        try vault.remember("Umbrella", vaultNote)
        fixture.memory = vault
        let responder = Responder(), clock = TeamClock(), engineSeen = Seen()
        let host = self.host
        fixture.reply = { request in
            let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
            let prompt = body["messages"]?.array?.last?["content"]?.string ?? ""
            let text = try await responder.respond(request.url?.host == host, prompt)
            let chunk = JSONValue.object(["choices": [["delta": ["content": .string(text)]]]]).text()
            return sse("data: \(chunk)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
        }
        if codeEngine {
            // The real Code engine, so the request it sends (tools, system text) can be read.
            let script: HTTPStreamFetch = { request in
                engineSeen.add((try? JSONValue.parse(request.httpBody ?? Data())) ?? .null)
                let text = try await responder.respond(false, "")
                let chunk = JSONValue.object(["choices": [["delta": ["content": .string(text)]]]]).text()
                return sse("data: \(chunk)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
            }
            fixture.realEngine = try Engine(stateDir: fixture.stateDir, vault: vault, fetch: script, home: fixture.files.dir, useRtk: false)
            try fixture.rewriteConfig { $0.model.context = 65536 }
        }
        let requests = fixture.requests, planned = fixture.planned
        let backend = try Backend(
            dataFolder: fixture.stateDir, version: "0.1.0-test", runtime: fixture.runtime, engine: fixture.realEngine ?? fixture.engine, memory: vault,
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            stream: { request in requests.add(request); return try await fixture.reply(request) },
            contextPlanner: { messages, context, mode, _, _, _ in
                planned.add(messages: messages, mode: mode)
                return PreparedContext(messages: messages, maxTokens: 512, report: ContextReport(
                    measuredInputTokens: 30, context: context, maxTokens: 512, omittedMessages: 0, method: "fixture", inputBudget: 3000, safetyMargin: 64, decision: "keep"))
            },
            discover: { noTools }, terminal: { _, _ in }, now: { clock.now }, home: fixture.files.dir + "/home", keeperInterval: 3600, agents: agents)
        fixture.backends.append(backend)
        addTeardownBlock { await backend.shutdown() }
        let project = try backend.createProject(name: "Team Work")
        if cloudAllowed { _ = try backend.setProjectCloud(project.id, allowed: true, confirmed: true) }
        let key = try XCTUnwrap(backend.savedModels.list().first { !$0.isCloud }).key
        return Rig(fixture: fixture, backend: backend, agents: agents, project: project, localKey: key, responder: responder, clock: clock, vault: vault, engineSeen: engineSeen)
    }

    func addCloudModel(_ r: Rig) async throws -> String {
        _ = try await r.backend.saveSetup(["model": ["source": "cloud", "endpoint": .string("https://\(host)/v1"), "id": "big-model", "apiKey": .string(secret),
                                                      "name": "Cloud Big", "context": .number(100_000)]])
        let key = try XCTUnwrap(r.backend.savedModels.list().first { $0.isCloud }).key
        _ = try await r.backend.switchTo(key: r.localKey)
        return key
    }

    @discardableResult
    func add(_ r: Rig, _ name: String, role: String = "", model: String? = nil, agent: String? = nil, work: String = "chat") throws -> RoomMemberView {
        try r.backend.roomAddMember(projectId: r.pid, name: name, role: role, modelKey: model, agent: agent, work: model == nil ? nil : work).members.last!
    }

    func preview(_ r: Rig, goal: String = "Ship the helper", lead: String? = nil, reviewer: String? = nil) throws -> TeamPreview {
        try r.backend.roomTeamPreview(projectId: r.pid, goal: goal, leadId: lead, reviewerId: reviewer)
    }

    /// Previews, runs and waits for the end.
    func runTeam(_ r: Rig, goal: String = "Ship the helper", lead: String? = nil, reviewer: String? = nil, from origin: SubmitOrigin = .mac) async throws -> TeamRun {
        let p = try preview(r, goal: goal, lead: lead, reviewer: reviewer)
        _ = try r.backend.roomTeamRun(projectId: r.pid, goal: goal, leadId: lead, reviewerId: reviewer, digest: p.digest, from: origin)
        await r.backend.roomTeamSettle()
        return try XCTUnwrap(try r.backend.room(projectId: r.pid).team)
    }

    func fail(_ body: () async throws -> Void, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected a refusal", file: file, line: line) }
        catch { XCTAssertTrue(messageOf(error).contains(text), "\(messageOf(error)) should contain \(text)", file: file, line: line) }
    }

    func planJSON(_ tasks: [(String, String, String)]) -> String {
        JSONValue.object(["tasks": .array(tasks.map { ["title": .string($0.0), "detail": .string($0.1), "member": .string($0.2)] })]).text()
    }

    /// What Claude Code prints for a reply: the assistant's text and the final result line.
    func claudeLines(_ text: String) -> [String] {
        let sid = "8f1c2d3e-1111-4a5b-9c8d-000000000001"
        return [
            JSONValue.object(["type": "system", "subtype": "init", "session_id": .string(sid)]).text(),
            JSONValue.object(["type": "assistant", "message": ["id": "msg_1", "role": "assistant", "content": [["type": "text", "text": .string(text)]]],
                              "session_id": .string(sid)]).text(),
            JSONValue.object(["type": "result", "subtype": "success", "is_error": false, "result": .string(text), "session_id": .string(sid),
                              "num_turns": 1, "stop_reason": "end_turn"]).text(),
        ]
    }

    /// The message Claude Code was given for its Nth run.
    func claudeMessage(_ agents: FakeAgentLauncher, _ n: Int) -> String { agents.commands[n].arguments.count > 1 ? agents.commands[n].arguments[1] : "" }

    func allRequestText(_ r: Rig) -> String {
        r.fixture.requests.list.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.joined(separator: "\n")
    }

    /// An all-local team: a lead, a worker and a reviewer, all on the one local model.
    func localTeam(_ r: Rig) throws -> (lead: RoomMemberView, worker: RoomMemberView, judge: RoomMemberView) {
        (try add(r, "Lead", role: "lead", model: r.localKey), try add(r, "Ornith", role: "builder", model: r.localKey), try add(r, "Judge", role: "reviewer", model: r.localKey))
    }

    // MARK: The agreement

    func testPreviewSaysWhoGetsWhatAndTheDigestFollowsTheTeam() async throws {
        let r = try await rig()
        let claude = try add(r, "Claude Code", role: "lead", agent: "claude-code")
        let ornith = try add(r, "Ornith", role: "builder", model: r.localKey)
        let cloudKey = try await addCloudModel(r)
        let big = try add(r, "Cloud Big", model: cloudKey)
        let p = try preview(r)
        XCTAssertEqual(p.leadId, claude.id, "the Claude Code member leads by default")
        XCTAssertNil(p.reviewerId)
        XCTAssertTrue(p.leavesThisMac); XCTAssertFalse(p.memoryUsed)
        XCTAssertEqual(p.members.map(\.kind), ["cloud", "local", "cloud"])
        XCTAssertEqual(p.members.map(\.provider), ["anthropic.com", "", host])
        XCTAssertEqual(p.agreement, "This run shares your goal and each member's results with every member of this team: Claude Code, Ornith, Cloud Big. "
            + "Claude Code, Cloud Big are cloud: what is shared with them is sent to anthropic.com, \(host). Your memory is not used in a team run that has a cloud member.")
        // The digest covers the goal, the lead and the reviewer.
        XCTAssertNotEqual(p.digest, try preview(r, goal: "Another goal").digest)
        XCTAssertNotEqual(p.digest, try preview(r, lead: ornith.id).digest)
        XCTAssertNotEqual(p.digest, try preview(r, reviewer: big.id).digest)
        XCTAssertEqual(p.digest, try preview(r).digest)
        await fail({ _ = try self.preview(r, lead: newID()) }, contains: "lead")
        await fail({ _ = try self.preview(r, reviewer: newID()) }, contains: "reviewer")
        await fail({ _ = try self.preview(r, goal: "  ") }, contains: "goal")
        // An all-local team says so.
        let local = try await self.rig()
        try add(local, "Ornith", model: local.localKey)
        let q = try preview(local)
        XCTAssertFalse(q.leavesThisMac); XCTAssertTrue(q.memoryUsed)
        XCTAssertTrue(q.agreement.hasSuffix("nothing leaves it."))
        XCTAssertEqual(q.leadId, q.members[0].id, "without a Claude Code member the first member leads")
    }

    // MARK: A whole run

    func testFullRunWithClaudeCodeLeadALocalMemberAndACloudMember() async throws {
        let agents = FakeAgentLauncher()
        let plan = planJSON([("Write the helper", "In helper.py.", "ornith"), ("Check the helper", "Read it over.", "CLOUD BIG")])
        agents.scripts = [claudeLines("Here is the plan:\n```json\n\(plan)\n```\nGood luck."), claudeLines("Report: the helper is written and checked.")]
        let r = try await rig(agents: agents)
        let claude = try add(r, "Claude Code", role: "lead", agent: "claude-code")
        let ornith = try add(r, "Ornith", role: "builder", model: r.localKey)
        let cloudKey = try await addCloudModel(r)
        let big = try add(r, "Cloud Big", role: "checker", model: cloudKey)
        r.responder.respond = { cloud, _ in cloud ? "CLOUD-CHECKED the helper" : "LOCAL-WRITTEN helper code" }

        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.leadId, claude.id); XCTAssertNil(team.reviewerId); XCTAssertNil(team.current)
        XCTAssertEqual(team.runs, 4)                                     // plan, two tasks, report
        XCTAssertEqual(team.report, "Report: the helper is written and checked.")
        XCTAssertEqual(team.message, "")
        let state = try r.backend.room(projectId: r.pid)
        XCTAssertEqual(state.tasks.map(\.title), ["Write the helper", "Check the helper"])
        XCTAssertEqual(state.tasks.map(\.assignee), [ornith.id, big.id])
        XCTAssertEqual(state.tasks.map(\.status), [.done, .done])
        XCTAssertEqual(state.tasks.map(\.result), ["LOCAL-WRITTEN helper code", "CLOUD-CHECKED the helper"])
        XCTAssertEqual(Set(state.tasks.compactMap(\.threadId)).count, 2, "each task has its own new conversation")

        // The lead was told the goal and the members; the plan step is read-only.
        let planMessage = claudeMessage(agents, 0)
        XCTAssertTrue(planMessage.contains("Ship the helper"))
        XCTAssertTrue(planMessage.contains("- Ornith (builder): chat work") && planMessage.contains("- Cloud Big (checker): chat work"))
        XCTAssertTrue(planMessage.contains("at most 6 tasks") && planMessage.contains("do not change any file"))
        let args = agents.commands[0].arguments
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--permission-mode")) + 1], "manual", "planning runs the agent in Ask, not Edit")
        // Results are passed on: the cloud member got the local member's result, and the lead got both in the report step.
        let cloudBody = r.fixture.requests.list.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.last { $0.contains("Check the helper") } ?? ""
        XCTAssertTrue(cloudBody.contains("Results so far from the team:") && cloudBody.contains("LOCAL-WRITTEN helper code") && cloudBody.contains("Write the helper (Ornith)"))
        XCTAssertTrue(cloudBody.contains("Ship the helper"))
        let reportMessage = claudeMessage(agents, 1)
        XCTAssertTrue(reportMessage.contains("LOCAL-WRITTEN helper code") && reportMessage.contains("CLOUD-CHECKED the helper") && reportMessage.contains("Cloud Big"))
        XCTAssertTrue(reportMessage.contains("what is left or uncertain") && reportMessage.contains("brief and plain"))
        // Every member run was a new conversation.
        XCTAssertEqual(agents.commands.count, 2)
        XCTAssertEqual(r.backend.threads().count, 4)
        // The log reads in order and every entry fits.
        XCTAssertEqual(team.log.map(\.kind).filter { $0 != "system" }, ["plan", "work", "work", "work", "work", "report"])
        XCTAssertTrue(team.log.allSatisfy { $0.text.utf16.count <= 2000 && !$0.at.isEmpty })
        XCTAssertEqual(team.log.first?.kind, "system"); XCTAssertEqual(team.log.last?.text, "The team run finished.")
        XCTAssertEqual(team.log.first { $0.kind == "work" }?.memberName, "Ornith")
        // The same state is what the screens read, with every key present.
        let json = try JSONValue.parse(JSONEncoder().encode(team))
        XCTAssertEqual(json["phase"]?.string, "done"); XCTAssertEqual(json["current"], .null); XCTAssertEqual(json["reviewerId"], .null)
        XCTAssertEqual(json["log"]?[0]?["taskId"], .null); XCTAssertNotNil(json["log"]?[0]?["memberName"])
        let again = try r.backend.room(projectId: r.pid).team
        XCTAssertEqual(again, team)
    }

    // MARK: Reading the plan

    func members() -> [RoomMember] {
        [RoomMember(id: newID(), name: "Ornith", role: "", modelKey: "k", agent: nil, permission: nil, work: "chat"),
         RoomMember(id: newID(), name: "Claude Code", role: "", modelKey: nil, agent: "claude-code", permission: "edit", work: nil)]
    }

    func testPlanParsingToleratesFencesProseAndCase() {
        let m = members()
        let plain = TeamText.parsePlan(#"{"tasks":[{"title":"A","detail":"d","member":"ornith"}]}"#, members: m)
        XCTAssertEqual(plain.tasks, [PlannedTask(title: "A", detail: "d", memberId: m[0].id)]); XCTAssertNil(plain.problem)
        let fenced = TeamText.parsePlan("```json\n{\"tasks\":[{\"title\":\"A\",\"detail\":\"d\",\"member\":\"CLAUDE code\"}]}\n```", members: m)
        XCTAssertEqual(fenced.tasks.map(\.memberId), [m[1].id])
        let prose = TeamText.parsePlan("Sure! Here {is} my plan: {\"tasks\":[{\"title\":\"A } brace\",\"member\":\"Ornith\"}]} Hope it helps {ok}.", members: m)
        XCTAssertEqual(prose.tasks.map(\.title), ["A } brace"]); XCTAssertEqual(prose.tasks[0].detail, "")
        let unknown = TeamText.parsePlan(#"{"tasks":[{"title":"A","member":"Ornith"},{"title":"B","member":"Nobody"},{"title":"","member":"Ornith"},{"member":"Ornith"}]}"#, members: m)
        XCTAssertEqual(unknown.tasks.map(\.title), ["A"]); XCTAssertTrue(unknown.notes.joined().contains("not on the team"))
    }

    func testPlanParsingCapsClipsAndExplainsWhatWentWrong() {
        let m = members()
        let many = "{\"tasks\":[" + (1...9).map { "{\"title\":\"T\($0)\",\"member\":\"Ornith\"}" }.joined(separator: ",") + "]}"
        let capped = TeamText.parsePlan(many, members: m)
        XCTAssertEqual(capped.tasks.map(\.title), ["T1", "T2", "T3", "T4", "T5", "T6"]); XCTAssertTrue(capped.notes.joined().contains("cap"))
        let long = TeamText.parsePlan("{\"tasks\":[{\"title\":\"\(String(repeating: "t", count: 300))\",\"detail\":\"\(String(repeating: "d", count: 5000))\",\"member\":\"Ornith\"}]}", members: m)
        XCTAssertEqual(long.tasks[0].title.utf16.count, RoomLimits.title); XCTAssertEqual(long.tasks[0].detail.utf16.count, RoomLimits.detail)
        XCTAssertTrue(TeamText.parsePlan("I could not decide.", members: m).problem?.contains("No JSON") == true)
        XCTAssertTrue(TeamText.parsePlan(#"{"plan":[]}"#, members: m).problem?.contains("tasks") == true)
        XCTAssertTrue(TeamText.parsePlan(#"{"tasks":[]}"#, members: m).problem?.contains("empty") == true)
        let none = TeamText.parsePlan(#"{"tasks":[{"title":"A","member":"Zed"}]}"#, members: m)
        XCTAssertTrue(none.tasks.isEmpty); XCTAssertTrue(none.problem?.contains("Ornith, Claude Code") == true)
        XCTAssertEqual(TeamText.parseVerdict("```{\"verdict\":\"Revise\",\"reason\":\" add a test \"}```")?.accept, false)
        XCTAssertEqual(TeamText.parseVerdict("{\"verdict\":\"revise\",\"reason\":\" add a test \"}")?.reason, "add a test")
        XCTAssertEqual(TeamText.parseVerdict("ok: {\"verdict\":\"accept\"}")?.accept, true)
        XCTAssertNil(TeamText.parseVerdict("{\"verdict\":\"maybe\"}"))
    }

    func testMessagesStayShortAndTheOldestResultsAreClippedFirst() {
        let earlier = (1...4).map { TeamItem(title: "Task \($0)", member: "M", result: String(repeating: "\($0)", count: 5000), outcome: "") }
        let message = TeamText.workMessage(goal: "Goal", title: "Now", detail: "Do it", earlier: earlier)
        XCTAssertLessThan(message.utf16.count, 12_100)
        XCTAssertTrue(message.hasPrefix("The team's goal:\nGoal\n\nYour task: Now\nDo it\n\nResults so far from the team:\n1. Task 1 (M)\n"))
        XCTAssertTrue(message.contains(String(repeating: "4", count: 5000)), "the newest result is kept whole")
        XCTAssertFalse(message.contains(String(repeating: "1", count: 5000)), "the oldest is clipped")
        XCTAssertTrue(message.contains("4. Task 4 (M)"))
        let small = TeamText.workMessage(goal: "G", title: "T", detail: "", earlier: [])
        XCTAssertEqual(small, "The team's goal:\nG\n\nYour task: T\n\nResults so far from the team:\n(nothing yet)")
        XCTAssertLessThan(TeamText.reportMessage(goal: "G", items: earlier).utf16.count, 12_100)
    }

    // MARK: The plan step in a run

    func testGarbageTwiceEndsTheRunFailedAndTheSecondAskStatesTheProblem() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        let prompts = Tally()
        let seen = PromptList()
        r.responder.respond = { _, prompt in seen.add(prompt); _ = prompts.next(); return "I am not sure what to do." }
        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .failed)
        XCTAssertTrue(team.message.contains("Lead") && team.message.contains("No JSON object"), team.message)
        XCTAssertEqual(team.runs, 2)
        XCTAssertEqual(prompts.value, 2)
        XCTAssertTrue(seen.all[1].contains("Your previous reply could not be used: No JSON object was found in the reply."))
        XCTAssertTrue(try r.backend.room(projectId: r.pid).tasks.isEmpty)
        XCTAssertNil(team.current)
    }

    func testGarbageOnceThenAGoodPlanRuns() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        let plans = Tally()
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return plans.next() == 1 ? "no idea" : planJSON([("Only task", "", "Ornith")]) }
            if prompt.contains("Write the final report") || prompt.contains("final report") { return "All done." }
            return "Task result"
        }
        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 4)
        XCTAssertEqual(try r.backend.room(projectId: r.pid).tasks.count, 1)
    }

    func testMoreThanSixTasksOnlySixAreRun() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON((1...8).map { ("Step \($0)", "", "Ornith") }) }
            return "ok"
        }
        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(try r.backend.room(projectId: r.pid).tasks.count, 6)
        XCTAssertEqual(team.runs, 8)
        XCTAssertTrue(team.log.contains { $0.kind == "system" && $0.text.contains("cap is 6") })
    }

    // MARK: Review

    /// Plan one task for Ornith; the reviewer says what `verdicts` says in turn (the last repeats).
    func reviewRig(_ verdicts: [String]) async throws -> (Rig, (Lead: RoomMemberView, Ornith: RoomMemberView, Judge: RoomMemberView), PromptList) {
        let r = try await rig()
        let m = try localTeam(r)
        let asked = Tally(), works = Tally(), prompts = PromptList()
        r.responder.respond = { [self] _, prompt in
            prompts.add(prompt)
            if prompt.contains("Plan the work as at most") { return planJSON([("Add tests", "Cover the parser.", "Ornith")]) }
            if prompt.contains("You are the reviewer") { let n = asked.next(); return verdicts[min(n, verdicts.count) - 1] }
            if prompt.contains("Write the final report") { return "Final report." }
            return "Work result \(works.next())"
        }
        return (r, (m.lead, m.worker, m.judge), prompts)
    }

    func testReviewerAcceptsAndTheTaskIsAccepted() async throws {
        let (r, m, prompts) = try await reviewRig([#"{"verdict":"accept","reason":"fine"}"#])
        let team = try await runTeam(r, reviewer: m.Judge.id)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 4)                                     // plan, work, review, report
        XCTAssertEqual(team.reviewerId, m.Judge.id)
        let task = try r.backend.room(projectId: r.pid).tasks[0]
        XCTAssertEqual(task.status, .done)
        let review = try XCTUnwrap(prompts.all.first { $0.contains("You are the reviewer") })
        XCTAssertTrue(review.contains("Ornith was given this task") && review.contains("Add tests") && review.contains("Work result 1") && review.contains("\"verdict\""))
        XCTAssertTrue(review.contains("do not change any file"))
        XCTAssertTrue(team.log.contains { $0.kind == "review" && $0.memberName == "Judge" })
        XCTAssertTrue(prompts.all.last?.contains("accepted by Judge") == true)
    }

    func testReviewerSendsItBackOnceThenTheSecondResultIsAccepted() async throws {
        let (r, m, prompts) = try await reviewRig([#"{"verdict":"revise","reason":"Add a test for empty input."}"#, #"{"verdict":"accept"}"#])
        let team = try await runTeam(r, reviewer: m.Judge.id)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 6)                                     // plan, work, review, work again, review, report
        let task = try r.backend.room(projectId: r.pid).tasks[0]
        XCTAssertEqual(task.status, .done); XCTAssertEqual(task.result, "Work result 2")
        // The same conversation continues, and the member is told why.
        let thread = try XCTUnwrap(r.backend.history.get(try XCTUnwrap(task.threadId)))
        XCTAssertEqual(thread["messages"]?.array?.count, 4)
        XCTAssertTrue(thread["messages"]?[2]?["content"]?.string?.contains("Add a test for empty input.") == true)
        XCTAssertTrue(team.log.contains { $0.text.contains("sent the task back: Add a test for empty input.") })
        XCTAssertTrue(prompts.all.last?.contains("revised once, then accepted by Judge") == true)
    }

    func testAfterOneRevisionTheTaskIsAcceptedWhateverTheReviewerSays() async throws {
        let (r, m, prompts) = try await reviewRig([#"{"verdict":"revise","reason":"Not yet."}"#])
        let team = try await runTeam(r, reviewer: m.Judge.id)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 6)
        XCTAssertEqual(try r.backend.room(projectId: r.pid).tasks[0].status, .done)
        XCTAssertTrue(team.log.contains { $0.kind == "review" && $0.text.contains("Revision limit reached (1)") })
        XCTAssertTrue(prompts.all.last?.contains("accepted after one revision although Judge still asked for changes: Not yet.") == true)
    }

    func testAMemberIsNotReviewedByItselfAndAnUnreadableVerdictAccepts() async throws {
        let (r, m, _) = try await reviewRig(["I like it."])
        var team = try await runTeam(r, reviewer: m.Ornith.id)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 3)                                     // no review run
        let (r2, m2, _) = try await reviewRig(["I like it."])
        team = try await runTeam(r2, reviewer: m2.Judge.id)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 4)
        XCTAssertTrue(team.log.contains { $0.text.contains("had no verdict") })
    }

    // MARK: Caps

    func testTheRunCapStopsTheRunAtTwentyMemberRuns() async throws {
        let r = try await rig()
        let m = try localTeam(r)
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON((1...6).map { ("Step \($0)", "", "Ornith") }) }
            if prompt.contains("You are the reviewer") { return #"{"verdict":"revise","reason":"again"}"# }
            return "result"
        }
        let team = try await runTeam(r, reviewer: m.judge.id)
        XCTAssertEqual(team.phase, .stopped)
        XCTAssertEqual(team.runs, 20)
        XCTAssertTrue(team.message.contains("run cap"), team.message)
        XCTAssertTrue(team.log.last?.text.contains("run cap") == true)
        XCTAssertTrue(team.report.isEmpty)
    }

    func testTheTimeCapStopsTheRunAfterSixtyMinutes() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        let clock = r.clock
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON([("One", "", "Ornith"), ("Two", "", "Ornith")]) }
            clock.jump(minutes: 61)
            return "slow result"
        }
        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .stopped)
        XCTAssertTrue(team.message.contains("time cap") && team.message.contains("60 minutes"), team.message)
        XCTAssertLessThan(try r.backend.room(projectId: r.pid).tasks.count, 2)
        XCTAssertTrue(team.report.isEmpty)
    }

    // MARK: Stop

    func testStopCancelsTheRunningJobAndEndsTheRunStoppedKeepingTheTasks() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON([("Quick", "", "Ornith"), ("Slow", "", "Ornith")]) }
            if prompt.contains("Slow") {
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
                throw CancellationError()
            }
            return "quick result"
        }
        let p = try preview(r)
        _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest)
        // Only one team run at a time.
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest) }, contains: "already")
        for _ in 0..<500 where !(r.backend.isBusy && (try? r.backend.room(projectId: r.pid))?.tasks.count == 2) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(r.backend.isBusy)
        _ = try r.backend.roomTeamStop(projectId: r.pid)
        await r.backend.roomTeamSettle()
        let state = try r.backend.room(projectId: r.pid)
        let team = try XCTUnwrap(state.team)
        XCTAssertEqual(team.phase, .stopped); XCTAssertEqual(team.message, "Stopped by you.")
        XCTAssertNil(team.current)
        XCTAssertEqual(state.tasks.map(\.status), [.done, .todo])        // the first kept its state; the stopped one is not finished
        XCTAssertEqual(state.tasks[1].note, "Stopped.")
        XCTAssertFalse(r.backend.isBusy)
        XCTAssertTrue(team.report.isEmpty)
        // Stop with nothing running changes nothing.
        XCTAssertEqual(try r.backend.roomTeamStop(projectId: r.pid).team, team)
        // And a new run can start afterwards.
        r.responder.respond = { [self] _, prompt in prompt.contains("Plan the work as at most") ? planJSON([("Again", "", "Ornith")]) : "fine" }
        let next = try await runTeam(r)
        XCTAssertEqual(next.phase, .done, next.message)
        XCTAssertNotEqual(next.id, team.id)
    }

    func testStopDuringTheLeadsPlanningStep() async throws {
        let agents = FakeAgentLauncher()
        agents.holdUntilStopped = true
        let r = try await rig(agents: agents)
        try add(r, "Claude Code", agent: "claude-code")
        let p = try preview(r)
        _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest)
        try await waitForAgentCondition { !agents.commands.isEmpty }
        _ = try r.backend.roomTeamStop(projectId: r.pid)
        await r.backend.roomTeamSettle()
        let team = try XCTUnwrap(try r.backend.room(projectId: r.pid).team)
        XCTAssertEqual(team.phase, .stopped); XCTAssertEqual(agents.commands.count, 1)
        XCTAssertTrue(try r.backend.room(projectId: r.pid).tasks.isEmpty)
    }

    // MARK: Errors

    func testAMemberRunThatErrorsIsRetriedOnce() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        let tries = Tally()
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON([("Flaky", "", "Ornith")]) }
            if prompt.contains("Flaky"), tries.next() == 1 { throw URLError(.networkConnectionLost) }
            return "worked on the second try"
        }
        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(team.runs, 4)                                     // plan, the failed run, the retry, report
        XCTAssertEqual(try r.backend.room(projectId: r.pid).tasks[0].result, "worked on the second try")
        XCTAssertTrue(team.log.contains { $0.kind == "system" && $0.text.contains("Trying once more") })
    }

    func testASecondErrorEndsTheRunFailedNamingTheMemberAndItsError() async throws {
        let r = try await rig()
        _ = try localTeam(r)
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON([("Doomed", "", "Ornith")]) }
            throw URLError(.networkConnectionLost)
        }
        let team = try await runTeam(r)
        XCTAssertEqual(team.phase, .failed)
        XCTAssertTrue(team.message.hasPrefix("Ornith could not finish \u{201C}Doomed\u{201D}: "), team.message)
        XCTAssertEqual(team.runs, 3)
        let task = try r.backend.room(projectId: r.pid).tasks[0]
        XCTAssertEqual(task.status, .todo); XCTAssertTrue(task.failed)
        XCTAssertTrue(team.report.isEmpty)
    }

    // MARK: Agreement and gate

    func testRunIsRefusedWhenTheTeamChangedAfterThePreview() async throws {
        let r = try await rig()
        try add(r, "Ornith", model: r.localKey)
        let p = try preview(r)
        try add(r, "Late joiner", model: r.localKey)
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest) }, contains: "changed since you reviewed")
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "A different goal", digest: try self.preview(r).digest) }, contains: "changed since you reviewed")
        XCTAssertNil(try r.backend.room(projectId: r.pid).team)
        XCTAssertTrue(r.backend.threads().isEmpty)
    }

    func testAPhoneMayNotStartATeamWithACloudMember() async throws {
        let r = try await rig()
        try add(r, "Claude Code", agent: "claude-code")
        try add(r, "Ornith", model: r.localKey)
        let p = try preview(r)
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest, from: .phone) }, contains: "decision made at \(Place.the)")
        XCTAssertNil(try r.backend.room(projectId: r.pid).team); XCTAssertTrue(r.backend.threads().isEmpty); XCTAssertTrue(r.agents.commands.isEmpty)
        // An all-local team may be started from a phone.
        let local = try await self.rig()
        try add(local, "Ornith", model: local.localKey)
        local.responder.respond = { [self] _, prompt in prompt.contains("Plan the work as at most") ? planJSON([("Do", "", "Ornith")]) : "done" }
        let team = try await runTeam(local, from: .phone)
        XCTAssertEqual(team.phase, .done, team.message)
    }

    func testAProjectThatIsLocalOnlyRefusesACloudMemberUpFront() async throws {
        let r = try await rig(cloudAllowed: false)
        try add(r, "Ornith", model: r.localKey)
        let cloudKey = try await addCloudModel(r)
        try add(r, "Cloud Big", model: cloudKey)
        let p = try preview(r)
        XCTAssertFalse(p.members[1].usable)
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest) }, contains: "The project Team Work is local only, so the cloud model Cloud Big")
        XCTAssertNil(try r.backend.room(projectId: r.pid).team)
        XCTAssertTrue(r.backend.threads().isEmpty)
        XCTAssertEqual(r.fixture.requests.count, 0)
        // With Claude Code the gate speaks of the agent.
        let r2 = try await rig(cloudAllowed: false)
        try add(r2, "Claude Code", agent: "claude-code")
        await fail({ _ = try r2.backend.roomTeamRun(projectId: r2.pid, goal: "x", digest: try self.preview(r2, goal: "x").digest) }, contains: "is local only, so Claude Code")
        XCTAssertTrue(r2.agents.commands.isEmpty)
    }

    func testAMemberThatCannotBeUsedRefusesTheRun() async throws {
        let agents = FakeAgentLauncher()
        agents.tool = nil
        let r = try await rig(agents: agents)
        try add(r, "Claude Code", agent: "claude-code")
        let p = try preview(r)
        XCTAssertFalse(p.members[0].usable)
        await fail({ _ = try r.backend.roomTeamRun(projectId: r.pid, goal: "Ship the helper", digest: p.digest) }, contains: "Claude Code cannot take part: Claude Code is not installed")
        XCTAssertNil(try r.backend.room(projectId: r.pid).team)
    }

    // MARK: Memory

    func testWithACloudMemberNoMemoryReachesAnyMembersRequest() async throws {
        let agents = FakeAgentLauncher()
        agents.scripts = [claudeLines(planJSON([("Write it", "", "Ornith"), ("Check it", "", "Cloud Big")])), claudeLines("Report.")]
        let r = try await rig(agents: agents)
        try add(r, "Claude Code", agent: "claude-code")
        try add(r, "Ornith", model: r.localKey)
        let cloudKey = try await addCloudModel(r)
        try add(r, "Cloud Big", model: cloudKey)
        r.responder.respond = { _, _ in "a result" }
        let vault = try XCTUnwrap(r.vault)
        let notes = vault.notes().count
        let team = try await runTeam(r, goal: "Find where the umbrella is kept")
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(r.fixture.requests.count, 2)                      // the local member and the cloud member (the lead is Claude Code)
        let hosts = r.fixture.requests.list.map { $0.url?.host ?? "" }
        XCTAssertEqual(Set(hosts).count, 2, "one request went to the local model and one to the cloud: \(hosts)")
        for body in r.fixture.requests.list.map({ String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }) {
            XCTAssertFalse(body.contains("Vault-Secret"), "memory text reached a member's request")
            XCTAssertFalse(body.contains("rare coins") || body.contains("From your memory") || body.contains("What you know about the user"))
        }
        let local = r.fixture.requests.body(hosts.firstIndex { $0 != host }!)
        XCTAssertEqual(local["messages"]?[0]?["content"]?.string, ChatStream.CLOUD_SYSTEM)
        XCTAssertNil(local["tools"])
        for message in agents.commands.map({ $0.arguments.joined(separator: " ") }) { XCTAssertFalse(message.contains("Vault-Secret")) }
        // The local member's conversation is marked and holds no Core or recalled notes; the vault gained nothing.
        let threads = try r.backend.room(projectId: r.pid).tasks.compactMap(\.threadId).compactMap { r.backend.history.get($0) }
        XCTAssertEqual(threads.count, 2)
        for thread in threads {
            XCTAssertNil(thread["core"]); XCTAssertNil(thread["messages"]?[0]?["recalled"])
        }
        XCTAssertEqual(threads.first { $0["privacy"]?.string == "local" }?["noMemory"], .bool(true))
        XCTAssertEqual(vault.notes().count, notes)
    }

    func testWithACloudMemberALocalCodeMemberGetsNoMemoryToolsNoCoreAndWritesNoJournal() async throws {
        let agents = FakeAgentLauncher()
        agents.scripts = [claudeLines(planJSON([("Tidy up", "", "Coder")])), claudeLines("Report.")]
        let r = try await rig(agents: agents, codeEngine: true)
        try add(r, "Claude Code", agent: "claude-code")
        try add(r, "Coder", model: r.localKey, work: "code")
        r.responder.respond = { _, _ in "Tidied." }
        let vault = try XCTUnwrap(r.vault)
        let notes = vault.notes().count
        let team = try await runTeam(r, goal: "Tidy the umbrella folder")
        XCTAssertEqual(team.phase, .done, team.message)
        XCTAssertEqual(r.engineSeen.count, 1)
        let body = r.engineSeen[0]
        let tools = body["tools"]?.array?.compactMap { $0["function"]?["name"]?.string } ?? []
        XCTAssertFalse(tools.isEmpty)
        XCTAssertFalse(tools.contains("remember")); XCTAssertFalse(tools.contains("recall"))
        XCTAssertFalse(body.text().contains("Vault-Secret")); XCTAssertFalse(body.text().contains("memory that lasts")); XCTAssertFalse(body.text().contains("rare coins"))
        XCTAssertEqual(vault.notes().count, notes, "no journal entry")
        XCTAssertFalse(allRequestText(r).contains("Vault-Secret"))
    }

    func testWithOnlyLocalMembersMemoryWorksAsNormal() async throws {
        let r = try await rig(codeEngine: true)
        let lead = try add(r, "Lead", model: r.localKey)
        try add(r, "Coder", model: r.localKey, work: "code")
        _ = lead
        r.responder.respond = { [self] _, prompt in
            if prompt.contains("Plan the work as at most") { return planJSON([("Tidy up", "", "Coder")]) }
            return "Fine."
        }
        let vault = try XCTUnwrap(r.vault)
        let notes = vault.notes().count
        let team = try await runTeam(r, goal: "Where is the umbrella kept?")
        XCTAssertEqual(team.phase, .done, team.message)
        // The lead's chat requests carry Core, like any local chat.
        XCTAssertTrue(r.fixture.requests.list.count >= 2)
        for request in r.fixture.requests.list {
            let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(text.contains("rare coins"), "a local chat request should carry the Core note")
        }
        // The Code member has the memory tools and Core, and its run is journaled.
        XCTAssertEqual(r.engineSeen.count, 1)
        let tools = r.engineSeen[0]["tools"]?.array?.compactMap { $0["function"]?["name"]?.string } ?? []
        XCTAssertTrue(tools.contains("remember") && tools.contains("recall"))
        XCTAssertTrue(r.engineSeen[0].text().contains("Vault-Secret-Alpha"))
        XCTAssertGreaterThan(vault.notes().count, notes)
        for thread in try r.backend.room(projectId: r.pid).tasks.compactMap(\.threadId).compactMap({ r.backend.history.get($0) }) { XCTAssertNil(thread["noMemory"]) }
    }

    // MARK: Left unfinished

    func testARunLeftUnfinishedIsMarkedStoppedOnTheNextReadAndNotResumed() async throws {
        let r = try await rig()
        try add(r, "Ornith", model: r.localKey)
        let file = r.fixture.stateDir + "/rooms/" + r.pid + ".json"
        let base = try XCTUnwrap(try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: file))).object)
        let run = newID()
        var object = base
        object["team"] = JSONValue.object(["id": .string(run), "goal": "Ship it", "leadId": .string(newID()), "reviewerId": .null, "phase": "working", "current": .string(newID()),
                                          "runs": 3, "started": "2026-01-01T00:00:00.000Z", "updated": "2026-01-01T00:00:00.000Z", "report": "", "message": "",
                                          "log": [["at": "2026-01-01T00:00:00.000Z", "memberId": .null, "memberName": "", "kind": "system", "taskId": .null, "text": "Team run started."]]])
        try Data(JSONValue.object(object).text().utf8).write(to: URL(fileURLWithPath: file))
        let team = try XCTUnwrap(try r.backend.room(projectId: r.pid).team)
        XCTAssertEqual(team.id, run); XCTAssertEqual(team.phase, .stopped); XCTAssertEqual(team.message, "Black Team was closed during this run.")
        XCTAssertNil(team.current); XCTAssertEqual(team.runs, 3)
        XCTAssertEqual(team.log.count, 2); XCTAssertEqual(team.log.last?.text, "Black Team was closed during this run.")
        XCTAssertTrue(r.backend.threads().isEmpty, "it is not resumed")
        // The change is saved, and a finished run is left as it is.
        XCTAssertEqual(try r.backend.room(projectId: r.pid).team, team)
        let saved = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: file)))
        XCTAssertEqual(saved["team"]?["phase"]?.string, "stopped")
    }
}

final class PromptList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
