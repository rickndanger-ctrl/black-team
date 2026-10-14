import Foundation
import BlackTeamKit
import BlackTeamTerminal

/// `black-team -p "<message>"`: one turn, the reply on stdout and nothing else there, problems on stderr, a non-zero status on failure.
/// It never asks a question: an approval is denied and a privacy question refused, unless --approve once / --allow-cloud say otherwise.
@MainActor func runOneShot(_ backend: Backend, _ options: OneShotOptions) async -> Int32 {
    var message = options.message ?? ""
    if message.isEmpty, !isTerminal(0) {
        message = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !message.isEmpty else {
        emitError("Give a message: black-team -p \"<message>\", or pipe one in.\n")
        return 2
    }
    var uploads: [ImageUpload] = []
    for path in options.images {
        do { uploads.append(try ImagePreparer.prepare(url: URL(fileURLWithPath: path))) } catch { emitError("\((path as NSString).lastPathComponent): \(describe(error))\n"); return 2 }
    }
    let kind = options.code ? "agent" : "chat"
    let check = backend.privacyCheck(threadId: options.thread, project: nil, kind: kind)
    switch check.outcome {
    case .allowed: break
    case .startsCloud:
        if !options.allowCloud {
            emitError(check.message + "\nNothing was sent. Add --allow-cloud to start this cloud conversation, or choose a local model with `black-team use <key>`.\n")
            return 1
        }
    case .needsChoice:
        if options.allowCloud, let thread = options.thread {
            do { try backend.convertToCloud(threadId: thread, confirmingProvider: check.provider) } catch { emitError(describe(error) + "\n"); return 1 }
        } else {
            emitError(check.message + "\nNothing was sent. Add --allow-cloud (with --thread) to send this conversation, omit --thread to start a new one, or run `black-team use <key>` to select a local model.\n")
            return 1
        }
    case .projectLocalOnly, .phoneNeedsMac:
        emitError(check.message + "\n"); return 1
    }
    if let question = try? await backend.startApproval() {
        guard options.stopOther else {
            emitError(question.question + "\nNothing was stopped or sent. Add --stop-other to stop it and go on.\n"); return 1
        }
        do { try await backend.approveStop(pid: question.pid) } catch { emitError(describe(error) + "\n"); return 1 }
    }
    let workspace = options.code ? (options.workspace ?? FileManager.default.currentDirectoryPath) : nil
    let sent: SubmitResult
    do {
        sent = try backend.submit(message: message, kind: kind, mode: options.pace, requestId: UUID().uuidString.lowercased(), threadId: options.thread,
                                  workspace: workspace, images: uploads)
    } catch { emitError(describe(error) + "\n"); return 1 }
    var hooks = ReplyHooks()
    var wrote = false
    if !options.json { hooks.text = { piece in if !piece.isEmpty { emit(piece); wrote = true } } }
    if options.code {
        hooks.phase = { record in if record.phase.isUnfinished { emitError("[\(record.phase.rawValue)] \(record.line())\n") } }
        hooks.step = { name, detail in emitError("[\(name)] \(detail)\n") }
        hooks.result = { summary, _ in emitError("  -> \(summary)\n") }
    }
    hooks.approval = { approval in
        let allowed = options.approve == "once"
        emitError("[approval] \(approval.description): \(approval.command) -> \(allowed ? "allowed once" : "denied (add --approve once to allow)")\n")
        return allowed ? "once" : "deny"
    }
    let finished = await followReply(backend, sent: sent, hooks: hooks)
    if options.json {
        var out: [String: JSONValue] = ["threadId": .string(finished.threadId), "state": .string(finished.state), "reply": .string(finished.text)]
        if let meter = finished.meter { out["meter"] = meter }
        if let run = finished.run { out["run"] = run }
        if let error = finished.error { out["error"] = .string(error) }
        print(JSONValue.object(out).text(pretty: true))
    } else if wrote {
        emit("\n")
    }
    if options.code, let run = runFacts(finished.run) { emitError("run: \(run)\n") }
    if finished.state != "done", let error = finished.error { emitError(error + "\n") }
    return finished.state == "done" ? 0 : 1
}
