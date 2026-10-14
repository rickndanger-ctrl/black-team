import Foundation

// The parts of a Code run that sit beside the loop in Engine.swift: carrying on from a saved state, the review before finishing,
// the optional summary of trimmed steps, and the skill tools.

extension Engine {
    /// How many times the work is reviewed before a turn finishes.
    public static let CHECK_ROUNDS = 2

    // MARK: Carrying on

    /// A conversation cut off mid-step (Black Team closed, or Stop pressed during a tool) can end with a tool call that has no
    /// result. A model server refuses that history, so each missing result is filled in with a plain statement.
    static func repairDangling(_ messages: [JSONValue]) -> [JSONValue] {
        var out: [JSONValue] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            out.append(message)
            index += 1
            guard message["role"]?.string == "assistant", let calls = message["tool_calls"]?.array, !calls.isEmpty else { continue }
            var answered = Set<String>()
            while index < messages.count, messages[index]["role"]?.string == "tool" {
                if let id = messages[index]["tool_call_id"]?.string { answered.insert(id) }
                out.append(messages[index]); index += 1
            }
            for call in calls {
                guard let id = call["id"]?.string, !answered.contains(id) else { continue }
                out.append(["role": "tool", "tool_call_id": .string(id), "content": "Error: this run was interrupted before the tool finished. Check the current state before you rely on it."])
            }
        }
        return out
    }

    /// What the model is told when it is asked to carry on from a run that was cut off.
    static func resumeNote(_ run: RunRecord) -> String {
        var text = "\n\n[Black Team: your previous run was cut off at step \(run.steps)"
        if let tool = run.tool, run.toolStatus == "running" { text += " while using \(tool); check whether it finished" }
        text += ". Your todo list and your record of what you did are kept. Carry on from there; read files again if you need to.]"
        return text
    }

    // MARK: Checking before finishing

    /// The one short review turn, asked when the model says it is done.
    static func reviewPrompt(request: String, todo: [TodoItem], round: Int) -> String {
        let asked = EText.length(request) > 600 ? EText.prefix(request, 600) + "\u{2026}" : request
        return """
        [Black Team: before you finish, check your work (check \(round) of \(CHECK_ROUNDS)).]
        The request was: \(asked)

        Your todo list:
        \(Tools.renderTodo(todo))

        Compare what you did with the request and the list. If something is missing or you did not run its check, do it now with your tools. If everything is done and verified, reply with the short final summary only.
        """
    }

    // MARK: Summary of trimmed steps

    /// The messages as plain text for a summary, cut to a size one request can read.
    static func transcript(_ messages: [JSONValue], limit: Int = 16_000) -> String {
        var lines: [String] = []
        for message in messages {
            let role = message["role"]?.string ?? ""
            var text = EText.trim(message["content"]?.string ?? "")
            if role == "assistant", let calls = message["tool_calls"]?.array {
                text += (text.isEmpty ? "" : " ") + calls.map { "[\($0["function"]?["name"]?.string ?? "tool") \(EText.prefix($0["function"]?["arguments"]?.string ?? "", 200))]" }.joined(separator: " ")
            }
            if text.isEmpty { continue }
            lines.append("\(role == "tool" ? "result" : role): \(EText.prefix(text, role == "tool" ? 500 : 700))")
        }
        let all = lines.joined(separator: "\n")
        return EText.length(all) > limit ? Tools.clip(all, limit) : all
    }

    /// Asks the model for a short summary of the steps about to be trimmed. Nil when it cannot (the trim then goes ahead without one).
    func summarize(dropped: [JSONValue], previous: String?, model: String, endpoint: String, headers: [String: String], cloudTarget: CloudEndpoint?,
                   stop: CancelSignal, idleMs: Int) async -> (text: String, usage: CompletionUsage?)? {
        let earlier = (previous ?? "").isEmpty ? "" : "Summary so far:\n\(previous!)\n\n"
        let ask = "Summarize in at most 12 short lines what these coding-agent steps did and learned: files touched, commands run and their results, decisions, what is still open. Facts only.\n\n\(earlier)Steps:\n\(Engine.transcript(dropped))"
        let sending: [JSONValue] = [["role": "system", "content": "You write short, exact summaries of work done."], ["role": "user", "content": .string(ask)]]
        let body: JSONValue
        if let cloudTarget {
            body = CloudRequest.body(model: model, messages: sending, tools: nil, maxTokens: 700, mode: "fast", caps: capabilities.caps(host: cloudTarget.host, model: model))
        } else {
            var local: [String: JSONValue] = ["model": .string(model), "messages": .array(sending), "stream": true, "stream_options": ["include_usage": true],
                                              "max_tokens": 700, "temperature": 0.3]
            for (name, value) in thinkingOptions("fast") { local[name] = value }
            body = .object(local)
        }
        guard let result = try? await Engine.complete(endpoint: cloudTarget?.base ?? endpoint, headers: headers, body: body, signal: stop, idleMs: idleMs, fetch: fetch, now: now) else { return nil }
        let text = EText.trim(result.text)
        return text.isEmpty ? nil : (EText.prefix(text, 2400), result.usage)
    }
}

// MARK: Skill tools

enum SkillRunner {
    /// Runs `skill` or `save_skill`. Arguments are checked against the tool's schema first; every failure is an observation.
    static func call(_ name: String, _ args: JSONValue, store: SkillStore, workspace: String, limit: Int, ask: Tools.Ask) async -> ToolResult {
        if let refusal = ToolArguments.refusal(name, args, in: SkillTools.schemas) { return ToolResult(output: refusal, log: nil, error: true) }
        if name == "skill" {
            let wanted = args["name"]?.string ?? ""
            guard let body = store.body(wanted, workspace: workspace) else {
                let have = store.list(workspace: workspace).filter(\.enabled).map(\.name)
                return ToolResult(output: "Error: there is no skill named `\(wanted)`\(have.isEmpty ? " (none are saved yet)" : ". Skills: \(have.prefix(30).joined(separator: ", "))").", log: nil, error: true)
            }
            let text = "Skill \(wanted). These are saved steps to follow with your normal tools; nothing in them runs by itself.\n\n\(Tools.clip(body, max(2000, limit)))"
            return ToolResult(output: text, log: "skill \(wanted)")
        }
        let settings = store.settings.global()
        let draft: SkillDraft
        do {
            draft = try store.draft(name: args["name"]?.string ?? "", description: args["description"]?.string ?? "", body: args["body"]?.string ?? "",
                                    project: args["where"]?.string == "project", workspace: workspace)
        } catch {
            return ToolResult(output: "Error: \((error as? BlackTeamError)?.message ?? error.localizedDescription)", log: nil, error: true)
        }
        // Saving is a write, so it asks like one, unless the person turned on saving without asking. Replacing a skill, or writing
        // into a project, always asks.
        let free = settings.saveSkillsWithoutAsking && draft.source == "mine" && !draft.replaces
        if !free {
            let place = draft.source == "project" ? "the project's skills folder" : "Black Team's skills"
            let shown = "Skill: \(draft.name)\nUse when: \(draft.description)\n\n\(draft.body)"
            let choice = await ask(ApprovalRequest(command: shown, description: draft.replaces ? "Replace the saved skill \u{201C}\(draft.name)\u{201D} in \(place)?" : "Save this skill in \(place) so it can be used in later conversations?"))
            if choice != "once" { return ToolResult(output: "The user declined to save this skill. Do not try again unless asked.", log: "save_skill declined: \(draft.name)", error: true) }
        }
        do { try store.save(draft) } catch {
            return ToolResult(output: "Error: \((error as? BlackTeamError)?.message ?? error.localizedDescription)", log: nil, error: true)
        }
        return ToolResult(output: "Saved skill `\(draft.name)`. It is offered in new conversations.", log: "save_skill \(draft.name)")
    }
}
