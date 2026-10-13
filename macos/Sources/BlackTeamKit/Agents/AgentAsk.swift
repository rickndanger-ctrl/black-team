import Foundation

/// What Ask does with one step Claude Code could not do without approval.
enum AskDecision: Equatable {
    /// Ask the person; if allowed, `rule` is the one `--allowedTools` rule for the resume.
    case ask(rule: String, command: String, label: String)
    /// Never allowed in Ask: not asked about, and the reply says so. `reason` groups the closing lines.
    case refuse(reason: String, label: String)
}

/// The Ask level for Claude Code: `-p` cannot ask, so a run that ends with denials is turned into questions, one at a time,
/// and what the person allows is handed to one resume as exact `--allowedTools` rules. Rules are built from the tool's own
/// input (never from model text), apply to that one resume, and are not remembered.
enum AgentAsk {
    /// At most this many resumes follow one message from the person.
    static let maxRounds = 5
    static let outsideFolder = "outside this conversation's folder"
    static let notExact = "cannot be allowed as one exact command"
    static let notSupported = "cannot be approved from here"
    static let declined = "not approved"

    /// The tool names whose input is a file path.
    private static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Short text for a denial: the command, or the path, or the tool's name.
    static func label(_ denial: AgentDenial) -> String {
        let text: String
        if denial.tool == "Bash" { text = denial.input["command"]?.string ?? "a command" }
        else if fileTools.contains(denial.tool) { text = path(denial.input) ?? denial.tool }
        else { text = denial.tool }
        return EText.prefix(text.replacingOccurrences(of: "\n", with: " "), 200)
    }

    private static func path(_ input: JSONValue) -> String? {
        let raw = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string
        return raw.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func decide(_ denial: AgentDenial, workspace: String) -> AskDecision {
        let shown = label(denial)
        if denial.tool == "Bash" {
            guard let command = denial.input["command"]?.string, !command.isEmpty else { return .refuse(reason: notExact, label: shown) }
            // A rule is one line; `*` would widen it into a pattern; unbalanced brackets would break the rule's own syntax.
            let opens = command.filter { $0 == "(" }.count, closes = command.filter { $0 == ")" }.count
            if command.contains("\n") || command.contains("\r") || command.contains("*") || opens != closes {
                return .refuse(reason: notExact, label: shown)
            }
            return .ask(rule: "Bash(\(command))", command: command, label: shown)
        }
        guard fileTools.contains(denial.tool) else { return .refuse(reason: notSupported, label: shown) }
        guard let given = path(denial.input) else { return .refuse(reason: notExact, label: shown) }
        if given.contains(where: { "*?[]{}()\n\r".contains($0) }) { return .refuse(reason: notExact, label: shown) }
        let absolute = given.hasPrefix("/") ? given : workspace + "/" + given
        let url = URL(fileURLWithPath: normalized(absolute))
        guard inside(url, workspace: workspace) else { return .refuse(reason: outsideFolder, label: shown) }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let verb = denial.tool == "Write" && !exists ? "Create" : "Edit"
        // Claude Code reads one leading slash as "from the project folder" and two as "from the root of the disk", and its Edit
        // rules cover every file-changing tool (a Write rule does not let Write through). Checked with Claude Code 2.1.295.
        return .ask(rule: "Edit(/\(url.path))", command: "\(verb) \(url.path)", label: "\(verb) \(url.path)")
    }

    /// The path with "." and ".." resolved by name only, so the rule says the path as it was given.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when the file (which may not exist yet) is the workspace or inside it, after symlinks are resolved.
    static func inside(_ file: URL, workspace: String) -> Bool {
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path
        let real: String
        if FileManager.default.fileExists(atPath: file.path) { real = file.resolvingSymlinksInPath().path }
        else { real = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path }
        return real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The closing lines for what was not done, grouped by reason, in the order the reasons first came.
    static func closingLines(_ items: [(reason: String, label: String)]) -> [String] {
        var order: [String] = [], grouped: [String: [String]] = [:]
        for item in items {
            if grouped[item.reason] == nil { order.append(item.reason) }
            if !(grouped[item.reason] ?? []).contains(item.label) { grouped[item.reason, default: []].append(item.label) }
        }
        return order.map { "Not done (\($0)): " + grouped[$0]!.joined(separator: "; ") + "." }
    }

    /// The plain line Edit and Auto end with when a step needed approval.
    static func notAllowedLine(_ denials: [AgentDenial], permission: AgentPermission) -> String {
        let list = denials.map { label($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "; ")
        let hint = permission == .edit ? "Switch this conversation to Ask or Auto to allow it." : "Switch this conversation to Ask to be asked first."
        return "Not done (needs approval): \(list). \(hint)"
    }

    static let approvedMessage = "Approved: go ahead with what was just approved. Do not do anything else that needs approval without asking."
    static let codexReadOnlyLine = "Codex cannot ask for approval here. It only read files. Switch this conversation to Edit or Auto to let it make changes."

    /// Raises one approval card and waits for the answer: true for "once". The existing expiry (five minutes) and Stop both deny.
    static func ask(job: JobState, stop: CancelSignal, command: String, description: String, now: @escaping @Sendable () -> Date) async -> Bool {
        let choice = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let id = UUID().uuidString.lowercased()
            let digest = SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
            let gate = AskGate()
            let finish: @Sendable (String) -> Void = { choice in
                guard gate.take() else { return }
                gate.timer?.cancel(); gate.stopWatching?(); job.withdraw()
                continuation.resume(returning: choice)
            }
            gate.timer = Task { try? await Task.sleep(nanoseconds: UInt64(Engine.APPROVAL_SECONDS) * 1_000_000_000); finish("deny") }
            gate.stopWatching = stop.observe { finish("deny") }
            job.present(PendingApproval(id: id, digest: digest, command: EText.prefix(redactSecrets(command), 8000),
                                        description: redactSecrets(description),
                                        expires: EText.millis(now()) + Int64(Engine.APPROVAL_SECONDS) * 1000)) { answer in
                guard answer.id == id, answer.digest == digest, ["once", "deny"].contains(answer.choice) else { throw BlackTeamError("No matching active approval.") }
                job.progress = answer.choice == "once" ? "Approved. Continuing\u{2026}" : "Declined. Continuing\u{2026}"
                finish(answer.choice)
            }
            if stop.isCancelled { finish("deny"); return }
            job.progress = "Waiting for your approval"
        }
        return choice == "once"
    }
}

private final class AskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    var timer: Task<Void, Never>?
    var stopWatching: (@Sendable () -> Void)?
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
