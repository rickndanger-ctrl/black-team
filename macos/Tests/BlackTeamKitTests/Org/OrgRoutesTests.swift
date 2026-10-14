import XCTest
@testable import BlackTeamKit

// The organization's routes (what the window, the phone and the command call), the Inbox's old files, and the small rules around them.
extension OrgTests {
    func call(_ r: Rig, _ method: String, _ path: String, query: [String: String] = [:], input: [String: JSONValue] = [:], who: DesktopAccess = .desktop) async throws -> JSONValue {
        try await OrgRoutes(r.backend).dispatch(method, path, query: query, input: input, who: who)
    }

    func refused(_ body: () async throws -> Void, status: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected a refusal", file: file, line: line) }
        catch let failure as HTTPFailure { XCTAssertEqual(failure.status, status, failure.message, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testThePhoneReadsTheTicketsListAndAddsAndApprovesButDoesNotTouchTheRest() async throws {
        let r = try await rig()
        try await make(r, "small", gates: ["intake"])
        try start(r)
        let t = try add(r, "Phone can see me")
        _ = try await drive(r, t.id)
        let q = ["project": r.pid]
        // The list: titles, stages and what waits.
        let list = try await call(r, "GET", "/api/org/tickets", query: q, who: .phone)
        XCTAssertEqual(list["tickets"]?.array?.count, 1)
        XCTAssertEqual(list["tickets"]?.array?[0]["label"]?.string, "T-1"); XCTAssertEqual(list["tickets"]?.array?[0]["gate"]?["kind"]?.string, "approval")
        XCTAssertNil(list["tickets"]?.array?[0]["artifacts"], "the phone list does not carry the work itself")
        // Everything else is the computer's.
        await refused({ _ = try await self.call(r, "GET", "/api/org", query: q, who: .phone) }, status: 403)
        await refused({ _ = try await self.call(r, "GET", "/api/org/ticket", query: q.merging(["id": t.id]) { $0 + $1 }, who: .phone) }, status: 403)
        await refused({ _ = try await self.call(r, "POST", "/api/org/ticket/sendback", input: ["project": .string(r.pid), "id": .string(t.id), "note": "x"], who: .phone) }, status: 403)
        await refused({ _ = try await self.call(r, "POST", "/api/org/start", input: ["project": .string(r.pid), "digest": "x"], who: .phone) }, status: 403)
        await refused({ _ = try await self.call(r, "POST", "/api/org/role/save", input: ["project": .string(r.pid), "role": [:]], who: .phone) }, status: 403)
        // A phone may add a ticket (it is marked as from the phone) and approve a gate that does not use a paid agent.
        let added = try await call(r, "POST", "/api/org/ticket/add", input: ["project": .string(r.pid), "title": "From the couch"], who: .phone)
        XCTAssertEqual(added["tickets"]?.array?.last?["source"]?.string, "phone")
        let approved = try await call(r, "POST", "/api/org/ticket/approve", input: ["project": .string(r.pid), "id": .string("1")], who: .phone)
        XCTAssertEqual(approved["tickets"]?.array?.first?["state"]?.string, "ready")
    }

    func testThePhoneCannotAnswerAGateThatMayUsePaidAgents() async throws {
        let r = try await rig()
        _ = try r.backend.orgCreate(projectId: r.pid, template: "small", local: r.localKey, leadModel: r.cloudKey)
        let a = try r.backend.orgAgreement(projectId: r.pid)
        _ = try r.backend.orgStart(projectId: r.pid, digest: a.digest)
        r.backend.orgStopLoop()
        let t = try add(r, "Paid path", source: "phone")
        XCTAssertEqual(t.state, "gate")
        let list = try await call(r, "GET", "/api/org/tickets", query: ["project": r.pid], who: .phone)
        XCTAssertEqual(list["tickets"]?.array?[0]["gate"]?["desktopOnly"]?.bool, true)
        await refused({ _ = try await self.call(r, "POST", "/api/org/ticket/approve", input: ["project": .string(r.pid), "id": .string(t.id)], who: .phone) }, status: 403)
        XCTAssertEqual(try ticket(r, t.id).state, "gate")
        // The Inbox route refuses it for a phone too (Service/ServiceRoutes.swift checks `desktopOnly`), and the computer may answer.
        XCTAssertEqual(r.backend.orgInbox().waiting().first?.desktopOnly, true)
        _ = try await call(r, "POST", "/api/org/ticket/approve", input: ["project": .string(r.pid), "id": .string(t.id)])
        XCTAssertEqual(try ticket(r, t.id).state, "ready")
    }

    func testTheCommandUsesTheSameRoutesWithoutAService() async throws {
        let r = try await rig()
        _ = try await r.backend.orgCall("POST", "/api/org/create", input: ["project": .string(r.pid), "template": "small", "local": .string(r.localKey)])
        let shown = try await r.backend.orgCall("GET", "/api/org", query: ["project": r.pid])
        XCTAssertEqual(shown["organization"]?["roles"]?.array?.count, 3)
        _ = try await r.backend.orgCall("POST", "/api/org/ticket/add", input: ["project": .string(r.pid), "title": "From the command", "source": "command"])
        XCTAssertEqual(r.backend.orgTickets(r.pid).first?.source, "command")
        let agreement = try await r.backend.orgCall("GET", "/api/org/agreement", query: ["project": r.pid])
        XCTAssertEqual(agreement["leavesThisMac"]?.bool, false)
        _ = try await r.backend.orgCall("POST", "/api/org/start", input: ["project": .string(r.pid), "digest": agreement["digest"] ?? .null])
        r.backend.orgStopLoop()
        XCTAssertEqual(try r.backend.orgLoad(r.pid)?.running, true)
        do { _ = try await r.backend.orgCall("POST", "/api/org/start", input: ["project": .string(r.pid), "digest": "nope"]); XCTFail("stale digest") }
        catch { XCTAssertTrue(messageOf(error).contains("Read it again")) }
        // Role edits arrive as the role's own JSON.
        let role = try XCTUnwrap(r.backend.orgLoad(r.pid)?.roles.first { $0.kind == "engineer" })
        var edited = JSONValue.encoded(role)
        edited = edited.setting("charter", "Only touch the docs folder.")
        let saved = try await r.backend.orgCall("POST", "/api/org/role/save", input: ["project": .string(r.pid), "role": edited])
        XCTAssertEqual(saved["organization"]?["roles"]?.array?.first { $0["kind"]?.string == "engineer" }?["charter"]?.string, "Only touch the docs folder.")
    }

    func testAnInboxFileFromBeforeTheOrganizationStillReads() throws {
        let dir = NSTemporaryDirectory() + "bt-inbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let old = #"{"items":[{"id":"a","scheduleId":"s","scheduleName":"Morning","command":"rm x","question":"Run it?","digest":"d","created":1,"expires":2,"state":"waiting"}]}"#
        try old.write(toFile: dir + "/inbox.json", atomically: true, encoding: .utf8)
        let store = InboxStore(dataFolder: dir)
        XCTAssertEqual(store.waiting().count, 1)
        XCTAssertNil(store.waiting()[0].kind); XCTAssertNil(store.waiting()[0].desktopOnly)
        // A restart settles questions from runs that are gone, and leaves an organization's gate alone.
        try store.add(InboxItem(id: "g", scheduleId: "org:t", scheduleName: "Org", threadId: nil, project: nil, command: "", question: "Approve?", digest: "", created: 3, expires: 0,
                                state: "waiting", answered: nil, kind: "gate", orgProject: "p", ticketId: "t", stage: "spec", gateKind: "approval", artifact: "spec.md", desktopOnly: nil))
        try store.settleAll(as: "ended")
        XCTAssertEqual(store.waiting().map(\.id), ["g"])
        XCTAssertEqual(store.get("g")?.artifact, "spec.md")
    }

    func testNoPictureReviewWithoutAVisionModelAndTheDesignStillWorks() async throws {
        let r = try await rig()
        try await make(r, gates: [])
        try start(r)
        let org = try XCTUnwrap(r.backend.orgLoad(r.pid))
        XCTAssertEqual(r.backend.orgVisionBlocker(org), "no role uses a model that can look at pictures")
        let t = try add(r, "A page", ui: true)
        let now = try await drive(r, t.id)
        XCTAssertEqual(now.state, "done")
        XCTAssertTrue(now.history.contains { $0.text.contains("No picture review of the mockup: no role uses a model that can look at pictures") }, "\(now.history.map(\.text))")
        XCTAssertNil(now.artifacts.first { $0.name.hasPrefix("visual-review") })
        XCTAssertTrue(now.artifacts.contains { $0.name == "mockup.html" })
    }

    func testTheModelStaysLoadedWhileTicketsWaitAndTheIdleTimerKnows() async throws {
        let r = try await rig()
        try await make(r, "small")
        XCTAssertFalse(r.backend.orgHasWork, "not started")
        try start(r)
        XCTAssertFalse(r.backend.orgHasWork, "no tickets")
        _ = try add(r, "Wait")
        XCTAssertTrue(r.backend.orgHasWork)
        _ = try r.backend.orgPause(projectId: r.pid)
        XCTAssertFalse(r.backend.orgHasWork, "paused")
    }

    func testAskingForAdditionalRolesThatShareAModelUsesOneRoomMember() async throws {
        let r = try await rig()
        try await make(r, "software", gates: [])
        try start(r)
        let t = try add(r, "Share members")
        _ = try await drive(r, t.id, limit: 3)
        let room = try r.backend.room(projectId: r.pid)
        // Roles on the same model and kind of work share one member of the room; the board shows the stage tasks.
        XCTAssertLessThanOrEqual(room.members.count, 2)
        XCTAssertTrue(room.tasks.allSatisfy { $0.title.hasPrefix("T-1 ") && $0.status == .done })
        XCTAssertTrue(room.notes.contains { $0.text.contains("accepted") })
    }
}
