import Foundation

// Running continuously. One loop per Backend (the window's engine or the background service's), started when an organization is started and
// when the app opens with one running. Each pass: put right what a restart left half done, make the tickets that are due from routines, make
// the daily stand-up when it is due, and run ONE stage if the computer is idle. A stage never starts while a response, an optimizing run or
// a team run holds the model, so organizations queue behind everything else behind the one local slot.

extension Backend {
    func orgProjectIds() -> [String] {
        let dir = dataFolder + "/orgs"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { History.validID($0) }.sorted()
    }

    /// Starts the loop (once). `every` is the pause between passes.
    public func orgStartLoop(every seconds: Double = 3) {
        guard orgRuntime.loop == nil else { return }
        orgRuntime.loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.locked({ self.closing }) else { return }
                await self.orgTickAll()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    public func orgStopLoop() {
        let loop = orgRuntime.loop
        orgRuntime.loop = nil
        loop?.cancel()
    }

    /// An organization is on a stage, or has a ticket waiting its turn: the idle timer must not unload the model.
    var orgHasWork: Bool {
        if orgRuntime.stepping { return true }
        return orgProjectIds().contains { id in
            guard let org = orgLoad(id), org.running, !org.paused else { return false }
            return orgTickets(id).contains { $0.state == "ready" || $0.state == "running" }
        }
    }

    /// Whether any organization is set to run continuously (the app starts the loop when one is).
    public func orgAnyRunning() -> Bool { orgProjectIds().contains { orgLoad($0)?.running == true } }

    /// One pass over every organization: housekeeping, then stages until the computer is no longer idle.
    public func orgTickAll() async {
        // Another Black Team holds the engine (and the model) for this data folder: it does the work, this one only shows it.
        guard engineLock.isHeld else { return }
        let ids = orgProjectIds()
        for id in ids { orgHousekeeping(id) }
        var ran = true
        while ran, !Task.isCancelled {
            ran = false
            for id in ids where (try? await orgStep(projectId: id)) == true { ran = true; break }
        }
    }

    /// Settles what a stopped Black Team left behind (a stage marked running with nothing behind it), and runs what is due.
    /// The background loop calls it; so does `black-team org start` when it is the organization's engine.
    public func orgHousekeeping(_ projectId: String) {
        guard let org = orgLoad(projectId) else { return }
        // A stage that was running when Black Team quit did not finish: the ticket waits again.
        if !orgRuntime.stepping {
            for t in orgTickets(projectId) where t.state == "running" {
                _ = try? orgTicketMutate(projectId, t.id) { x in x.state = "ready"; x.currentRole = nil; orgEvent(&x, stage: x.stage, "Black Team stopped during this stage, so it will run again.") }
            }
        }
        guard org.running, !org.paused else { return }
        orgRoutinesDue(org)
        orgStandupDue(org)
    }

    // MARK: Routines

    private func orgRoutinesDue(_ org: Organization) {
        let moment = now()
        var changedAny = false
        var routines = org.routines
        for i in routines.indices {
            guard let when = try? ScheduleWhen.parse(routines[i].whenText, now: moment) else { continue }
            if routines[i].next == nil { routines[i].next = when.next(after: moment)?.timeIntervalSince1970; changedAny = true; continue }
            guard let due = routines[i].next, Date(timeIntervalSince1970: due) <= moment else { continue }
            routines[i].next = when.next(after: moment)?.timeIntervalSince1970
            changedAny = true
            // A routine does not pile up: if its last ticket is still open, a new one is not made.
            let open = orgTickets(org.projectId).contains { !$0.finished && $0.title == routines[i].title && $0.source == "schedule" }
            if !open { _ = try? orgCreateTicket(org, title: routines[i].title, body: routines[i].body, source: "schedule", ui: nil, parent: nil) }
        }
        if changedAny { _ = try? orgMutate(org.projectId) { $0.routines = routines } }
    }

    @discardableResult
    public func orgAddRoutine(projectId: String, title: String, body: String = "", when: String) throws -> OrgState {
        guard let clean = OrgStore.clean(EText.trim(title), max: OrgLimits.title) else { throw BlackTeamError("Give the routine a title of up to \(OrgLimits.title) characters.") }
        let words = EText.trim(when)
        let parsed = try ScheduleWhen.parse(words, now: now())
        guard let text = OrgStore.clean(body, max: OrgLimits.body, multiline: true, allowEmpty: true) else { throw BlackTeamError("A routine's details are up to \(EText.grouped(OrgLimits.body)) characters.") }
        try orgMutate(projectId) { org in
            if org.routines.count >= 10 { throw BlackTeamError("An organization has up to 10 routines.") }
            org.routines.append(OrgRoutine(id: UUID().uuidString.lowercased(), title: clean, body: text, whenText: words, next: parsed.next(after: now())?.timeIntervalSince1970))
        }
        return try orgState(projectId: projectId)
    }

    @discardableResult
    public func orgRemoveRoutine(projectId: String, routineId: String) throws -> OrgState {
        try orgMutate(projectId) { $0.routines.removeAll { $0.id == routineId } }
        return try orgState(projectId: projectId)
    }

    // MARK: The stand-up

    private func orgStandupDue(_ org: Organization) {
        guard !org.standupAt.isEmpty, let when = try? ScheduleWhen.parse(org.standupAt, now: now()) else { return }
        let moment = now()
        guard let due = org.standupNext else {
            _ = try? orgMutate(org.projectId) { $0.standupNext = when.next(after: moment)?.timeIntervalSince1970 }
            return
        }
        guard Date(timeIntervalSince1970: due) <= moment else { return }
        _ = try? orgStandupMake(projectId: org.projectId, notify: true)
        _ = try? orgMutate(org.projectId) { $0.standupNext = when.next(after: moment)?.timeIntervalSince1970 }
    }

    /// Makes the stand-up report now: what moved, what is blocked, what waits for the owner, and what was spent. Saved under `standups/`; a note in the Inbox.
    @discardableResult
    public func orgStandupMake(projectId: String, notify: Bool = false) throws -> String {
        let org = try orgRequire(projectId)
        let text = orgStandupText(org)
        let day = orgDay()
        let dir = OrgStore.folder(dataFolder, projectId) + "/standups"
        try privateDirectory(dir)
        try CoreFS.writeAtomic(dir + "/" + day + ".md", Data(text.utf8), temporary: dir + "/" + day + ".md." + CoreFS.hex(6) + ".tmp")
        let stamp = roomNow()
        try orgMutate(projectId) { $0.standupLast = stamp }
        if notify { orgInboxNote(org, title: "\(org.name) stand-up", text: EText.prefix(text, 1800), artifact: nil) }
        return text
    }

    func orgStandupText(_ org: Organization) -> String {
        let all = orgTickets(org.projectId)
        let since = org.standupLast.isEmpty ? EText.iso(now().addingTimeInterval(-86_400)) : org.standupLast
        let day = orgDay()
        var out = "# Stand-up \u{00B7} \(org.name) \u{00B7} \(day)\n\n"
        if org.paused { out += "The organization is **paused**: \(org.pausedReason)\n\n" }
        else if !org.running { out += "The organization is not running; start it to pick up tickets.\n\n" }
        out += "## What moved\n"
        var moved: [String] = []
        for t in all {
            let events = t.history.filter { $0.at > since }
            if events.isEmpty { continue }
            moved.append("- \(t.label) \(t.title): " + events.suffix(3).map(\.text).joined(separator: " "))
        }
        out += moved.isEmpty ? "Nothing moved.\n" : moved.prefix(12).joined(separator: "\n") + "\n"
        out += "\n## Waiting for you\n"
        let waiting = all.filter { $0.state == "gate" }
        out += waiting.isEmpty ? "Nothing.\n" : waiting.map { "- \($0.label) \($0.title): \($0.gate?.question ?? "")" }.joined(separator: "\n") + "\n"
        out += "\n## Blocked\n"
        let blocked = all.filter { $0.state == "blocked" }
        out += blocked.isEmpty ? "Nothing.\n" : blocked.map { "- \($0.label) \($0.title): \($0.note)" }.joined(separator: "\n") + "\n"
        out += "\n## In the queue\n"
        let queue = all.filter { $0.state == "ready" || $0.state == "running" }.sorted { $0.number < $1.number }
        out += queue.isEmpty ? "Empty.\n" : queue.prefix(12).map { "- \($0.label) \($0.title): \($0.stage.title)" }.joined(separator: "\n") + "\n"
        let done = all.filter { $0.state == "done" && $0.updated > since }
        if !done.isEmpty { out += "\n## Finished\n" + done.map { "- \($0.label) \($0.title)" + ($0.branch.map { " (branch \($0))" } ?? "") }.joined(separator: "\n") + "\n" }
        let ledger = orgLedger(usage: OrgStore.usage(dataFolder, org.projectId), day: day)
        out += "\n## Spend today\n\(ledger.summary)\n"
        for line in ledger.lines { out += "- \(line.roleName) (\(line.paid ? "paid" : "local")): \(EText.grouped(line.tokens)) tokens, \(line.runs) run\(line.runs == 1 ? "" : "s")" + (line.money > 0 ? ", about \(orgMoney(line.money))" : "") + "\n" }
        return out
    }

    // MARK: Design review by a vision model

    /// Where a headless browser is, for taking a picture of the mockup. Nil when none is installed.
    static func orgBrowser() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for name in ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "chrome"] {
            for dir in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return "\(dir)/\(name)" }
        }
        return nil
    }

    /// A role whose model can look at pictures (a local model with a vision file).
    func orgVisionRole(_ org: Organization) -> OrgRole? {
        org.roles.first { r in
            guard let key = r.modelKey, let m = savedModels.find(key) else { return false }
            return m.source == "gguf" && !m.mmproj.isEmpty
        }
    }

    /// Why a vision review cannot be done now, or nil when it can.
    func orgVisionBlocker(_ org: Organization) -> String? {
        if orgVisionRole(org) == nil { return "no role uses a model that can look at pictures" }
        if Self.orgBrowser() == nil { return "no browser is installed to take a picture of the mockup" }
        return nil
    }

    /// Takes a picture of the mockup and asks a vision-capable role to look at it. Best effort: any problem skips the review and says why.
    func orgDesignReview(_ org: Organization, _ t: OrgTicket, mockupPath: String) async -> String? {
        if let why = orgVisionBlocker(org) {
            _ = try? orgTicketMutate(org.projectId, t.id) { orgEvent(&$0, stage: .design, "No picture review of the mockup: \(why).") }
            return nil
        }
        guard let role = orgVisionRole(org), let key = role.modelKey, let browser = Self.orgBrowser() else { return nil }
        let png = NSTemporaryDirectory() + "/bt-mockup-\(CoreFS.hex(6)).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: browser)
        process.arguments = ["--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars", "--window-size=1000,800", "--screenshot=" + png, "file://" + mockupPath]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        process.waitUntilExit(); killer.cancel()
        guard let data = FileManager.default.contents(atPath: png), !data.isEmpty else { return nil }
        guard (try? await switchTo(key: key)) != nil else { return nil }
        let ask = "You are the \(role.name). This is a picture of the HTML mockup for \(t.label) (\(t.title)). Say in a few lines what works, what is unclear or hard to read, and what to fix. Judge layout, contrast and wording."
        guard let sent = try? submit(message: ask, kind: "chat", mode: "balanced", requestId: UUID().uuidString.lowercased(), threadId: nil, project: org.projectId,
                                     images: [ImageUpload(name: "mockup.png", data: data)], from: .mac, useMemory: false) else { return nil }
        await waitForIdle()
        guard let reply = teamReply(threadId: sent.threadId).text else { return nil }
        return "Reviewed from a picture of the mockup by \(role.name):\n\n" + reply
    }
}
