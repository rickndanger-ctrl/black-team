import Foundation
import BlackTeamKit
import BlackTeamTerminal

/// The interactive session: `black-team` with no arguments. A prompt, slash commands, replies as they arrive, and the questions the
/// engine asks (approvals, what leaves this computer) put to the person right where they are working.
@MainActor final class Session {
    let backend: Backend
    let style: Style
    let reader: LineReader
    let isTerminalInput: Bool

    var mode = "chat"                       // "chat" or "code"
    var agent: AgentService?                // a subscription agent doing the Code work
    var permission: AgentPermission?        // chosen with /permission; nil keeps the conversation's own
    var pace = "balanced"
    var threadId: String?
    var projectId: String?
    var pendingImages: [(name: String, upload: ImageUpload)] = []
    var lastChanges: [String] = []          // file changes of the last Code reply
    var lastAgentRun: (thread: String, run: String)?
    var lastCtrlC: Date?
    let folder = FileManager.default.currentDirectoryPath

    init(backend: Backend, interactive: Bool) {
        self.backend = backend
        isTerminalInput = interactive
        style = Style(enabled: Style.decide(isTerminal: isTerminal(1), environment: ProcessInfo.processInfo.environment))
        reader = LineReader(interactive: interactive, historyPath: interactive ? backend.dataFolder + "/command-history" : nil)
    }

    // MARK: Words

    func say(_ text: String = "") { emit(text + "\n") }
    func meta(_ text: String) { say(style.dim(text)) }
    func problem(_ text: String) { emit(style.red(text) + "\n") }

    var modelName: String {
        guard let model = try? backend.configStore.read().model else { return "no model" }
        if model.source == "cloud" { return (model.name.isEmpty ? model.id : model.name) + " (cloud)" }
        if model.name.isEmpty { return "no model" }
        return model.name
    }

    var who: String { agent?.displayName ?? modelName }

    var promptParts: (styled: String, plain: String) {
        let level: String? = agent == nil ? nil : (permission ?? AgentPermission.edit).rawValue
        return (PromptText.styled(mode: mode, who: who, permission: level, style: style), PromptText.plain(mode: mode, who: who, permission: level))
    }

    /// Asks a question on its own line. nil when there is no answer (end of input or Ctrl-C).
    func ask(_ question: String) -> String? {
        switch reader.read(prompt: question, plain: question, keepHistory: false, tab: false, question: true) {
        case .line(let text): return text.trimmingCharacters(in: .whitespaces)
        case .eof, .interrupt: return nil
        }
    }

    func confirm(_ question: String) -> Bool {
        guard let answer = ask(question + " [y/N] ")?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    // MARK: Loop

    func run() async -> Int32 {
        say(style.bold("Black Team Agent") + style.dim("  \(backend.version)  \u{00B7}  /help for commands, Ctrl-D to leave"))
        meta("folder: \(folder)")
        if let notice = backend.engineLock.noticeOnce() { say(style.yellow(notice)) }
        if (try? await backend.status())?.setupComplete == false { meta("No model is set up yet. Use /model, or `black-team starter list` and `black-team use <key>`.") }
        while true {
            let prompt = promptParts
            switch reader.read(prompt: prompt.styled, plain: prompt.plain) {
            case .eof:
                return 0
            case .interrupt(let hadText):
                if hadText { lastCtrlC = nil; continue }
                if let last = lastCtrlC, Date().timeIntervalSince(last) < 2 { return 0 }
                lastCtrlC = Date()
                meta("Press Ctrl-C again within two seconds to leave, or type /quit.")
            case .line(let raw):
                lastCtrlC = nil
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                reader.remember(raw)
                switch Slash.parse(text) {
                case .notCommand: await send(text)
                case .unknown(let name): problem("Unknown command /\(name). Type /help for the list.")
                case .command(let name, let argument):
                    if name == "quit" { return 0 }
                    await runCommand(name, argument)
                }
            }
        }
    }

    // MARK: Slash commands

    func runCommand(_ name: String, _ argument: String) async {
        do {
            switch name {
            case "help":
                say("Type a message to send it. Slash commands:\n" + Slash.helpText())
                meta("Tab completes a command. Up and down bring back earlier lines. Ctrl-C stops a reply.")
            case "chat": switchMode("chat")
            case "code": switchMode("code")
            case "new":
                startOver("Started a new conversation.")
            case "resume": try await resume(argument)
            case "model": try await chooseModel(argument)
            case "agent": agentCommand(argument)
            case "permission":
                guard let level = AgentPermission(rawValue: argument.lowercased()) else { problem("Use /permission ask, edit or auto."); return }
                permission = level
                say("Permission: \(level.rawValue)." + (agent == nil ? " It applies when a subscription agent is in use (/agent claude)." : ""))
            case "pace":
                guard ["fast", "balanced", "deep", "extended"].contains(argument.lowercased()) else { problem("Use /pace fast, balanced, deep or extended."); return }
                pace = argument.lowercased(); say("Pace: \(pace).")
            case "project": try projectCommand(argument)
            case "image": imageCommand(argument)
            case "undo": try undoCommand()
            case "team": try await teamCommand(argument)
            case "status": try await statusCommand()
            case "continue":
                guard threadId != nil, mode == "code" else { problem("Nothing to continue here. /resume opens an earlier Code conversation."); return }
                await send(argument.isEmpty ? "Continue." : argument)
            case "skills":
                let found = backend.skills.list(workspace: mode == "code" ? folder : nil)
                if argument.isEmpty {
                    if found.isEmpty { say("No skills saved yet. Code saves one when you approve it.") }
                    for skill in found { say("\(style.cyan(skill.name))\(skill.enabled ? "" : style.dim(" (off)"))  \(oneLine(skill.description, 90))") }
                } else if let text = try? backend.skills.text(argument, workspace: folder) { say(text) } else { problem("No skill named \(argument).") }
            case "memory":
                guard !argument.isEmpty else { problem("Use /memory <what to look for>."); return }
                let hits = try await backend.memorySearch(argument)
                if hits.isEmpty { say("No matches.") }
                for hit in hits.prefix(20) { say("\(style.cyan(hit.id)):\(hit.line)  \(oneLine(hit.text, 100))") }
            default: problem("Unknown command /\(name). Type /help for the list.")
            }
        } catch {
            problem(describe(error))
        }
    }

    func startOver(_ message: String? = nil) {
        threadId = nil; pendingImages = []; lastChanges = []; lastAgentRun = nil
        if let message { say(message) }
    }

    func switchMode(_ target: String) {
        if target == "chat" { agent = nil }
        let hadConversation = threadId != nil
        mode = target
        startOver()
        say(target == "chat" ? "Chat with \(modelName)." : "Code with \(who) in \(projectName() ?? folder).")
        if hadConversation { meta("A conversation cannot change kind, so this is a new one. /resume brings the earlier one back.") }
    }

    func projectName() -> String? { projectId.flatMap { id in backend.projectList().first { $0.id == id }?.name } }

    func resume(_ argument: String) async throws {
        let all = Array(backend.threads().prefix(15))
        if all.isEmpty { say("No conversations yet."); return }
        var pick = Int(argument)
        if pick == nil {
            for (n, t) in all.enumerated() {
                let mark = t.privacy == "cloud" ? style.yellow(" [cloud: \(t.provider)]") : ""
                say("  \(n + 1). \(oneLine(t.title, 60))  \(style.dim(t.kind == "agent" ? "code" : "chat"))\(mark)  \(style.dim(String(t.updated.prefix(16))))")
            }
            guard let answer = ask("Open which? (number, Enter to cancel) "), let n = Int(answer) else { return }
            pick = n
        }
        guard let n = pick, n >= 1, n <= all.count else { problem("Choose a number from the list."); return }
        let chosen = all[n - 1]
        guard let view = backend.thread(chosen.id) else { problem("That conversation is gone."); return }
        threadId = chosen.id; pendingImages = []; lastChanges = []; lastAgentRun = nil
        projectId = chosen.project
        if chosen.kind == "agent" {
            mode = "code"; agent = AgentService.forEngine(view["engine"]?.string)
        } else { mode = "chat"; agent = nil }
        say(style.bold(oneLine(chosen.title, 80)))
        for message in (view["messages"]?.array ?? []).suffix(4) {
            let role = message["role"]?.string == "user" ? style.cyan("you") : style.green("reply")
            say("\(role): \(String((message["content"]?.string ?? "").prefix(600)))")
        }
        if chosen.privacy == "cloud" { meta("This conversation was sent to \(chosen.provider).") }
    }

    func chooseModel(_ argument: String) async throws {
        let config = try backend.configStore.read()
        let list = backend.savedModels.list(active: config.model)
        if list.isEmpty { say("No saved models. See `black-team starter list`, or `black-team cloud add --help`."); return }
        var pick = Int(argument)
        if pick == nil {
            for (n, m) in list.enumerated() {
                let kind = m.isCloud ? style.yellow("cloud: \(m.provider)") : style.green("local")
                say("  \(n + 1). \(m.active ? "*" : " ") \(m.name)  \(kind)  \(style.dim("\(m.context) tokens"))")
            }
            guard let answer = ask("Use which? (number, Enter to cancel) "), let n = Int(answer) else { return }
            pick = n
        }
        guard let n = pick, n >= 1, n <= list.count else { problem("Choose a number from the list."); return }
        let result = try await backend.switchTo(key: list[n - 1].key)
        say("Now using \(result.name).")
        if list[n - 1].isCloud { meta("Conversations with a cloud model leave this computer; you are asked before one starts.") }
    }

    func agentCommand(_ argument: String) {
        let word = argument.lowercased()
        if word == "off" {
            guard agent != nil else { say("No agent is in use."); return }
            agent = nil
            startOver("Not using an agent. Code now uses \(modelName), in a new conversation.")
            return
        }
        guard let service = AgentService.allCases.first(where: { $0.program == word }) else { problem("Use /agent claude, /agent codex or /agent off."); return }
        guard backend.agentInstalled(service) else { problem("\(service.displayName) is not installed on this computer. Install it and sign in with your subscription first."); return }
        let had = threadId != nil
        agent = service; mode = "code"
        startOver("Using \(service.displayName) for this conversation (\((permission ?? .edit).rawValue) permission), in a new conversation.")
        if had { meta("A conversation cannot change kind, so this is a new one.") }
        meta("It runs on \(service.provider) under your subscription; you are asked before anything is sent.")
    }

    func projectCommand(_ argument: String) throws {
        let all = backend.projectList()
        func choose(_ id: String?) {
            let changed = id != projectId
            projectId = id
            if changed, threadId != nil { startOver() }
            say(id == nil ? "No project." : "Project: \(projectName() ?? "")" + (changed ? " (a new conversation)." : "."))
        }
        if argument.lowercased() == "none" { choose(nil); return }
        if argument.lowercased().hasPrefix("new ") {
            let made = try backend.createProject(name: String(argument.dropFirst(4)))
            choose(made.id); return
        }
        var pick = Int(argument)
        if pick == nil, !argument.isEmpty, let hit = all.first(where: { $0.name.lowercased() == argument.lowercased() }) { choose(hit.id); return }
        if pick == nil {
            if all.isEmpty { say("No projects yet. /project new <name> makes one."); return }
            for (n, p) in all.enumerated() {
                say("  \(n + 1). \(p.id == projectId ? "*" : " ") \(p.name)  \(style.dim(p.workspace))" + (p.cloudAllowed ? "" : style.dim("  local only")))
            }
            guard let answer = ask("Use which? (number, Enter to cancel, \"none\" to leave) ") else { return }
            if answer.lowercased() == "none" { choose(nil); return }
            guard let n = Int(answer) else { return }
            pick = n
        }
        guard let n = pick, n >= 1, n <= all.count else { problem("Choose a number from the list."); return }
        choose(all[n - 1].id)
    }

    func imageCommand(_ argument: String) {
        if argument.isEmpty {
            if pendingImages.isEmpty { say("No picture is attached. /image <path> attaches one to your next chat message.") }
            else { say("Attached to your next message: " + pendingImages.map(\.name).joined(separator: ", ")) }
            return
        }
        if argument.lowercased() == "clear" { pendingImages = []; say("Pictures cleared."); return }
        if mode == "code" { problem(ImageRules.codeRefusal); return }
        var path = Slash.words(argument).first ?? argument
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
        if !path.hasPrefix("/") { path = folder + "/" + path }
        do {
            let upload = try ImagePreparer.prepare(url: URL(fileURLWithPath: path))
            pendingImages.append((name: (path as NSString).lastPathComponent, upload: upload))
            say("Attached \((path as NSString).lastPathComponent). It goes with your next message.")
        } catch { problem("\((path as NSString).lastPathComponent): \(describe(error))") }
    }

    func undoCommand() throws {
        if backend.isBusy { problem("Wait for the reply to finish first."); return }
        if let run = lastAgentRun {
            guard confirm("Roll back every file the last agent task changed?") else { say("Nothing changed."); return }
            let restored = try backend.rollBack(threadId: run.thread, runId: run.run)
            lastAgentRun = nil
            say("Restored \(restored.restored.count) file(s), removed \(restored.removed.count).")
            return
        }
        guard let id = lastChanges.last else { say("There is nothing to undo from the last reply."); return }
        guard confirm("Undo the last file change of the last Code reply?") else { say("Nothing changed."); return }
        let result = try backend.undo(id)
        lastChanges.removeLast()
        say(result.removed ? "Removed \(result.path), which that edit had created." : "Put \(result.path) back as it was.")
    }

    func statusCommand() async throws {
        let status = try await backend.status()
        let thread = threadId.flatMap { backend.thread($0) }
        say("model: \(modelName)  (\(status.runtime.state))")
        say("mode: \(mode)" + (agent.map { " with \($0.displayName), permission \((permission ?? .edit).rawValue)" } ?? "") + ", pace \(pace)")
        say("folder: \(projectId != nil ? (backend.projectList().first { $0.id == projectId }?.workspace ?? folder) : folder)")
        say("project: \(projectName() ?? "none")")
        say("conversation: " + (thread.map { "\(oneLine($0["title"]?.string ?? "", 60)) (\($0["privacy"]?.string == "cloud" ? "sent to \($0["provider"]?.string ?? "a cloud service")" : "private to this computer"))" } ?? "new"))
        if !pendingImages.isEmpty { say("pictures waiting: \(pendingImages.map(\.name).joined(separator: ", "))") }
        if let other = backend.engineLock.otherHolder() { say(style.yellow("Black Team is also open in \(other.program); it holds the local model.")) }
        for warning in status.hardware.warnings { say(style.yellow("warning: \(warning)")) }
    }

    // MARK: Team

    func teamCommand(_ argument: String) async throws {
        guard let goal = Slash.words(argument).first, !goal.isEmpty else { problem("Use /team \"<goal>\"."); return }
        guard let id = projectId else { problem("A team works in a project's room. Choose one with /project first."); return }
        // A paid lead drives: it hands work to the other members while it works (docs/ROOM.md). A local lead plans, then members work in turn.
        let driven = backend.roomCanDrive(projectId: id, leadId: nil)
        let preview = try backend.roomTeamPreview(projectId: id, goal: goal, leadId: nil, reviewerId: nil, driven: driven)
        say(preview.agreement + "\n")
        for m in preview.members {
            say("  \(m.name)" + (m.role.isEmpty ? "" : " [\(m.role)]") + " - \(m.kind)" + (m.kind == "cloud" ? " (\(m.provider))" : "")
                + (m.lead ? (driven ? " - driver" : " - lead") : "") + (m.reviewer ? " - reviewer" : "") + (m.usable ? "" : " - cannot be used: \(m.reason)"))
        }
        guard confirm("\nRun the team?") else { say("Nothing was started."); return }
        _ = try backend.roomTeamRun(projectId: id, goal: preview.goal, leadId: preview.leadId, reviewerId: preview.reviewerId, digest: preview.digest,
                                    from: .mac, driven: driven)
        var seen: TeamLogEntry?
        Interrupts.stopReply.clear(); Interrupts.replying.set()
        defer { Interrupts.replying.clear() }
        var stopping = false
        while true {
            if Interrupts.stopReply.isSet, !stopping { stopping = true; _ = try? backend.roomTeamStop(projectId: id); meta("Stopping the team\u{2026}") }
            let team = try backend.room(projectId: id).team
            if let team {
                var start = 0
                if let seen, let at = team.log.lastIndex(of: seen) { start = at + 1 } else if seen != nil { start = team.log.count }
                for entry in team.log[start...] {
                    let who = entry.memberName.isEmpty ? "" : " \(entry.memberName)"
                    say(style.dim("[\(entry.kind)]\(who):") + " " + oneLine(entry.text, 400))
                }
                seen = team.log.last ?? seen
                if team.phase.finished { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await backend.roomTeamSettle()
        if let final = try backend.room(projectId: id).team {
            if !final.report.isEmpty { say("\n" + style.bold("Report:") + "\n" + final.report) }
            if let ledger = final.ledger { say("\n" + ledgerText(ledger)) }
            say("\nTeam run \(final.phase.rawValue)" + (final.message.isEmpty ? "" : ": \(final.message)") + " (\(final.runs) member runs).")
        }
    }

    // MARK: Sending

    /// The questions about what leaves this computer, asked here in the engine's own words. True when the message may go.
    func privacyGate() async -> Bool {
        for _ in 0..<3 {
            let kind = mode == "chat" ? "chat" : "agent"
            let check = agent.map { backend.agentPrivacyCheck(service: $0, threadId: threadId, project: projectId) }
                ?? backend.privacyCheck(threadId: threadId, project: projectId, kind: kind)
            switch check.outcome {
            case .allowed: return true
            case .projectLocalOnly, .phoneNeedsMac:
                problem(check.message); return false
            case .startsCloud:
                say(style.yellow(check.message))
                return confirm("Start this cloud conversation with \(check.provider)?")
            case .needsChoice:
                say(style.yellow(check.message))
                var options: [(String, String)] = [("new", "Start a new cloud conversation with \(check.modelName)")]
                if agent != nil { options.append(("local", "Stop using \(check.modelName) and go back to \(modelName)")) }
                else if !check.localModelKey.isEmpty { options.append(("local", "Switch back to \(check.localModelName)")) }
                options.append(("send", "Send this conversation to \(check.provider) (you confirm by typing its name)"))
                for (n, option) in options.enumerated() { say("  \(n + 1). \(option.1)") }
                guard let answer = ask("Choose (Enter to cancel) "), let n = Int(answer), n >= 1, n <= options.count else { say("Nothing was sent."); return false }
                switch options[n - 1].0 {
                case "new": threadId = nil; lastChanges = []; lastAgentRun = nil; continue
                case "local":
                    if agent != nil { agent = nil; threadId = nil; say("Not using an agent; this is a new conversation with \(modelName).") }
                    else if let result = try? await backend.switchTo(key: check.localModelKey) { say("Now using \(result.name).") }
                    else { problem("Could not switch models."); return false }
                    continue
                default:
                    say(check.convertWarning)
                    guard let typed = ask("Type \(check.provider) to confirm: "), typed == check.provider, let thread = threadId else { say("Not confirmed. Nothing was sent."); return false }
                    do {
                        if let agent { try backend.convertToCloud(threadId: thread, confirmingProvider: typed, agent: agent) }
                        else { try backend.convertToCloud(threadId: thread, confirmingProvider: typed) }
                    } catch { problem(describe(error)); return false }
                    continue
                }
            }
        }
        return false
    }

    /// The question asked before a model start that would not fit beside another model server. True when the message may go.
    func startGate() async -> Bool {
        guard let question = try? await backend.startApproval() else { return true }
        guard confirm(style.yellow("Approval needed: ") + question.question) else { say("Nothing was stopped or sent."); return false }
        do { try await backend.approveStop(pid: question.pid); return true }
        catch { problem(describe(error)); return false }
    }

    func send(_ text: String) async {
        guard await privacyGate() else { return }
        guard await startGate() else { return }
        let sent: SubmitResult
        let images = pendingImages.map(\.upload)
        do {
            if let agent {
                sent = try backend.submitAgentTask(service: agent, message: text, requestId: UUID().uuidString.lowercased(), threadId: threadId,
                                                   project: projectId, workspace: projectId == nil ? folder : nil, permission: permission)
            } else {
                sent = try backend.submit(message: text, kind: mode == "chat" ? "chat" : "agent", mode: pace, requestId: UUID().uuidString.lowercased(),
                                          threadId: threadId, project: projectId, workspace: mode == "code" && projectId == nil ? folder : nil, images: images)
            }
        } catch {
            problem(describe(error)); return
        }
        threadId = sent.threadId
        pendingImages = []
        Interrupts.stopReply.clear(); Interrupts.replying.set()
        var atLineStart = true
        func newline() { if !atLineStart { say(); atLineStart = true } }
        var hooks = ReplyHooks()
        hooks.text = { piece in
            if piece.isEmpty { return }
            emit(piece); atLineStart = piece.hasSuffix("\n")
        }
        hooks.step = { [self] name, detail in
            newline(); say(style.dim("\u{25CF} ") + style.cyan(name) + (detail.isEmpty ? "" : "  " + style.dim(detail)))
        }
        hooks.result = { [self] summary, failed in
            newline(); say("  " + (failed ? style.red("\u{21B3} " + summary) : style.dim("\u{21B3} " + summary)))
        }
        hooks.stop = { Interrupts.stopReply.isSet }
        hooks.phase = { [self] record in
            // The ends are told in the facts line below; the phases on the way are shown as they change.
            if record.phase.isUnfinished { newline(); say(style.dim("\u{2022} " + record.line())) }
        }
        hooks.approval = { [self] approval in
            newline()
            say(style.yellow("Approval needed: ") + approval.description)
            say("  " + style.bold(approval.command))
            if Interrupts.stopReply.isSet { return "deny" }
            Interrupts.replying.clear()
            defer { Interrupts.replying.set() }
            let allowed = confirm("Allow once?")
            return allowed ? "once" : "deny"
        }
        let finished = await followReply(backend, sent: sent, hooks: hooks)
        Interrupts.replying.clear()
        newline()
        if Interrupts.stopReply.isSet { meta("Stopped.") }
        else if finished.state != "done" {
            if let error = finished.error { problem(error) }
            if let needs = finished.needsSignIn { meta("Sign in first: black-team agent signin \(needs)") }
        }
        var facts: [String] = []
        if let read = finished.meter?["read"]?.int { facts.append("read \(read) tokens/s") }
        if let write = finished.meter?["write"]?.int { facts.append("write \(write) tokens/s") }
        if let usage = finished.usage { facts.append("\(usage["prompt"]?.int ?? 0) tokens in, \(usage["completion"]?.int ?? 0) out") }
        if let run = runFacts(finished.run) { facts.append(run) }
        if let phase = finished.run?["phase"]?.string, phase == "stopped" || phase == "failed" { facts.append("/continue picks it up from the saved state") }
        if let provider = finished.cloudProvider { facts.append("sent to \(provider)") }
        if !finished.changes.isEmpty { facts.append("\(finished.changes.count) file change(s), /undo to revert") }
        if finished.rollbackReady { facts.append("/undo rolls the task back") }
        if let note = finished.rollbackNote { facts.append(note) }
        if !facts.isEmpty { meta(facts.joined(separator: " \u{00B7} ")) }
        lastChanges = finished.changes
        lastAgentRun = finished.rollbackReady ? (finished.threadId, finished.runId) : nil
    }
}
