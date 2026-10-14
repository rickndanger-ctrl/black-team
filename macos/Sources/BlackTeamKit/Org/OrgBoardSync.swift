import Foundation

// The board step of the organization's loop (Org/OrgLoop.swift calls `orgBoardTick` before it runs a stage). Each pass, for a project that is
// working for a board: look after the tickets Black Team already holds (renew the lease, notice an approval written in the note, notice that
// another owner took a ticket or that a person changed its status), and, when nothing is waiting its turn, claim the next free ticket.
// Stages themselves are run by the ordinary stage machine (Org/OrgRunner.swift); what changes there is written back by `orgBoardPush`.

extension Backend {
    private func plain(_ text: String, max: Int) -> String {
        OrgStore.clean(EText.prefix(text.replacingOccurrences(of: "\r", with: ""), max), max: max, multiline: true, allowEmpty: true) ?? ""
    }

    /// The ticket text Black Team works from: the note's Context, Acceptance criteria and Plan.
    func orgBoardBody(_ note: BoardNote) -> String {
        var parts: [String] = []
        for (heading, label) in [("Context", "Context"), ("Acceptance criteria", "Acceptance criteria"), ("Plan", "Plan from the board")] {
            if let text = note.section(heading), !text.isEmpty { parts.append(label + "\n" + text) }
        }
        return plain(parts.joined(separator: "\n\n"), max: OrgLimits.body)
    }

    private func orgBoardTitle(_ note: BoardNote) -> String {
        let title = plain(note.title, max: OrgLimits.title)
        return title.isEmpty ? note.id : title
    }

    /// Adds a Log line about Black Team's own work to a note, whoever holds it.
    private func orgBoardAppendLog(_ board: OrgBoard, file: String, _ text: String) {
        orgBoardRuntime.io.lock(); defer { orgBoardRuntime.io.unlock() }
        let me = orgBoardOwner(), moment = orgBoardNow()
        for _ in 0..<3 {
            guard let entry = orgBoardRead(board, file: file), entry.note.valid else { return }
            var note = entry.note
            note.log(moment, who: me, text)
            if (try? BoardIO.commit(entry.path, expected: entry.data, new: Data(note.text.utf8), beforeRename: orgBoardRuntime.beforeRename)) == true { return }
        }
    }

    // MARK: Letting go

    /// Black Team stops working on a ticket that is no longer its own (taken by another owner, marked done by a person, gone from the board).
    /// Nothing is written to a note someone else holds, except one Log line about this.
    func orgBoardLose(_ org: Organization, _ t: OrgTicket, why: String) {
        if orgRuntime.current?.ticket == t.id { orgRuntime.stopRequested = true; cancel() }
        if let gate = t.gate { _ = try? orgInbox().settle(gate.inboxId, as: "ended", at: now()) }
        _ = try? orgTicketMutateQuiet(org.projectId, t.id) { x in x.state = "cancelled"; x.gate = nil; x.currentRole = nil; x.note = why; orgEvent(&x, why) }
        if let board = org.board, let file = t.boardFile { orgBoardAppendLog(board, file: file, "Black Team stopped working on this: \(why)") }
        orgInboxNote(org, title: "\(t.label) is no longer Black Team's", text: why)
    }

    /// The folder is gone or cannot be written: stop, and say so in the Inbox.
    func orgBoardHalt(_ org: Organization, _ why: String) {
        if orgBoardRuntime.tell(org.projectId + "|halt|" + why) {
            orgInboxNote(org, title: "\(org.name) stopped working for the board", text: why + " Fix it, then resume the organization.")
        }
        _ = try? orgMutate(org.projectId) { $0.paused = true; $0.pausedReason = why }
        if let c = orgRuntime.current, c.project == org.projectId { orgRuntime.stopRequested = true; cancel() }
    }

    // MARK: Approving from the note

    /// The last Log line is by someone other than Black Team and says "approved" (and not "not approved").
    func orgBoardApprovedByHand(_ note: BoardNote) -> Bool {
        guard let last = note.log.last else { return false }
        let me = orgBoardOwner().lowercased()
        var rest = String(last.dropFirst(2))
        if let space = rest.firstIndex(of: " ") { rest = String(rest[rest.index(after: space)...]) }
        let author = rest.range(of: ": ").map { String(rest[rest.startIndex..<$0.lowerBound]).lowercased() } ?? ""
        let what = rest.range(of: ": ").map { String(rest[$0.upperBound...]).lowercased() } ?? rest.lowercased()
        return author != me && what.contains("approved") && !what.contains("not approved") && !what.contains("unapproved")
    }

    // MARK: Before a stage, and while it runs

    /// A stage is about to start: the note is read again, so a title or criteria changed by someone mid-run are used, and the claim is checked.
    /// Nil when the ticket is no longer Black Team's (it was handled; the stage must not run).
    func orgBoardStageStart(_ org: Organization, _ t: OrgTicket) -> OrgTicket? {
        guard let board = org.board, let file = t.boardFile else { return t }
        switch orgBoardRenew(board, file: file) {
        case .held: break
        case .other(let who): orgBoardLose(org, t, why: "\(who) now holds \(t.label) on the board."); return nil
        case .gone: orgBoardLose(org, t, why: "\(t.label)'s note is not on the board any more."); return nil
        case .free:
            guard orgBoardClaim(board, file: file, stage: t.stage.rawValue, text: "Took the ticket back: its lease had run out and nobody else had claimed it.") != nil else { return nil }
        }
        guard let entry = orgBoardRead(board, file: file) else { return t }
        let title = orgBoardTitle(entry.note), body = orgBoardBody(entry.note)
        if title != t.title || body != t.body {
            return (try? orgTicketMutateQuiet(org.projectId, t.id) { x in x.title = title; x.body = body; orgEvent(&x, stage: x.stage, "The ticket's text changed on the board, so this stage uses the new text.") }) ?? t
        }
        return t
    }

    /// Called often while a stage runs; at most once a minute it checks the claim and renews the lease, so a long local run does not lose it.
    func orgBoardKeepAlive(_ projectId: String, ticketId: String) {
        guard let org = orgLoad(projectId), let board = org.board, board.working, let t = orgTicket(projectId, ticketId), let file = t.boardFile, let id = t.boardId else { return }
        let key = board.folder + "|" + id + "|check", moment = orgBoardNow()
        if let last = orgBoardRuntime.keepAlive(key), moment.timeIntervalSince(last) < 60 { return }
        orgBoardRuntime.setKeepAlive(key, moment)
        switch orgBoardRenew(board, file: file) {
        case .held: break
        case .other(let who): orgBoardLose(org, t, why: "\(who) now holds \(id) on the board.")
        case .gone: orgBoardLose(org, t, why: "\(id)'s note is not on the board any more.")
        case .free:
            if orgBoardClaim(board, file: file, stage: t.stage.rawValue, text: "Took the ticket back: its lease had run out and nobody else had claimed it.") == nil {
                orgBoardLose(org, t, why: "\(id) could not be kept: its claim was lost.")
            }
        }
    }

    // MARK: The pass

    /// One pass over a project's board. Never runs a stage; the loop does that next.
    func orgBoardTick(_ projectId: String) async {
        guard let org = orgLoad(projectId), let board = org.board, board.working else { return }
        if !org.running || org.paused { orgBoardReleaseAll(projectId, why: org.paused ? "Black Team is paused." : "Black Team stopped working for the board."); return }
        if let why = orgBoardReach(board) { orgBoardHalt(org, why); return }
        if OrgGit.toplevel(board.repo) == nil { orgBoardHalt(org, "The repository is not there any more: \(board.repo)"); return }
        let me = orgBoardOwner(), moment = orgBoardNow()
        var held = 0, active = 0
        for t in orgBoardTickets(projectId) where !t.finished {
            guard let file = t.boardFile, let id = t.boardId else { continue }
            var entry = orgBoardRead(board, file: file)
            if entry == nil || entry?.note.id != id {
                // The file may have been renamed by another agent; the note is found again by its id. Black Team never renames one itself.
                entry = orgBoardScan(board).entries.first { $0.note.id == id }
                if let found = entry { _ = try? orgTicketMutateQuiet(projectId, t.id) { $0.boardFile = found.file } }
            }
            guard let current = entry else { orgBoardLose(org, t, why: "\(id)'s note is not on the board any more."); continue }
            let file2 = current.file, note = current.note
            let busy = orgRuntime.current?.ticket == t.id
            if note.owner == me {
                held += 1
                if busy { active += 1; continue }
                orgBoardRenew(board, file: file2)
                let marked = ["done", "blocked", "backlog"].contains(note.status)
                if t.state == "gate" {
                    if note.status == "ready", orgBoardApprovedByHand(note) { _ = try? ticketApprove(projectId: projectId, ticketId: t.id) }
                    else if note.status == "ready", orgBoardRuntime.tell("remind|" + t.id + "|\(note.log.filter { !$0.contains(" \(me): ") }.count)") {
                        orgBoardAppendLog(board, file: file2, "\(id) is still waiting for approval. Add a Log line saying \"approved\" and set the status to ready, or approve it in Black Team.")
                    } else if marked { orgBoardLose(org, t, why: "\(id) was marked \(note.status) on the board."); held -= 1 }
                    continue
                }
                if marked { orgBoardLose(org, t, why: "\(id) was marked \(note.status) on the board."); held -= 1; continue }
                active += 1
                continue
            }
            if !note.free(at: moment) { orgBoardLose(org, t, why: "\(note.owner) now holds \(id) on the board."); continue }
            // Nobody holds it (Black Team let it go on a stop or pause, or the lease ran out).
            let wanted = ["ready", "in-progress", "review"].contains(note.status) || (board.takeBacklog && note.status == "backlog")
            switch t.state {
            case "ready", "running":
                if ["done", "blocked"].contains(note.status) { orgBoardLose(org, t, why: "\(id) was marked \(note.status) on the board."); continue }
                if wanted, orgBoardClaim(board, file: file2, stage: t.stage.rawValue, text: "Claimed again by Black Team (local models). Carrying on at \(t.stage.title).") != nil { held += 1; active += 1 }
            case "gate":
                if note.status == "ready", orgBoardApprovedByHand(note),
                   orgBoardClaim(board, file: file2, stage: t.stage.rawValue, text: "Approved on the board. Carrying on.") != nil {
                    held += 1
                    _ = try? ticketApprove(projectId: projectId, ticketId: t.id)
                    active += 1
                }
            case "blocked":
                if note.status == "ready", orgBoardClaim(board, file: file2, stage: t.stage.rawValue, text: "Trying again after the ticket was set back to ready.") != nil {
                    held += 1; active += 1
                    _ = try? ticketRetry(projectId: projectId, ticketId: t.id)
                }
            default: break
            }
        }
        // A new ticket is taken only when nothing else is waiting for the one local model.
        let due = orgBoardRuntime.lastScan.map { moment.timeIntervalSince($0) >= orgBoardRuntime.scanEvery } ?? true
        guard active == 0, held < 3, due, !orgRuntime.stepping else { return }
        orgBoardRuntime.lastScan = moment
        let scan = orgBoardScan(board)
        let known = Set(orgBoardTickets(projectId).filter { !$0.finished }.compactMap(\.boardId))
        for candidate in orgBoardCandidates(scan.entries, board: board, at: moment, skipping: known).prefix(3) {
            let host = String(me.dropFirst("black-team-local@".count))
            guard let won = orgBoardClaim(board, file: candidate.file, stage: OrgStage.intake.rawValue,
                                          text: "Claimed by Black Team (local models on \(host)). Starting at intake; the work will be on its own branch.") else { continue }
            do {
                let made = try orgCreateTicket(org, title: orgBoardTitle(won.note), body: orgBoardBody(won.note), source: "board", ui: nil, parent: nil)
                _ = try orgTicketMutateQuiet(projectId, made.id) { x in
                    x.boardId = won.note.id; x.boardFile = won.file
                    x.history.removeAll()
                    orgEvent(&x, stage: .intake, "Taken from the board.")
                    x.boardLogged = x.history.last.map { $0.at + "\u{1}" + $0.text }
                }
            } catch {
                orgBoardRelease(board, file: won.file, why: "Black Team could not start it: \(messageOf(error))")
            }
            break
        }
    }
}
