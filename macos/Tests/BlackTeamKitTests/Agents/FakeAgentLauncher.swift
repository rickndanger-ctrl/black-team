import Foundation
@testable import BlackTeamKit

/// Stands in for Claude Code and Codex: it records each command and plays back the lines it is given, so no tool starts.
final class FakeAgentLauncher: AgentLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentCommand] = []
    var tool: String? = "/fake/bin/agent"
    var lines: [(AgentStream, String)]
    var exit: AgentExit
    /// When set, the run waits (as a long-running tool does) until its signal is cancelled.
    var holdUntilStopped = false
    /// Runs when the tool "starts", to change files in the workspace as a real run would.
    var effect: (@Sendable (AgentCommand) -> Void)?

    init(lines: [(AgentStream, String)] = [], exit: AgentExit = AgentExit(status: 0)) {
        self.lines = lines; self.exit = exit
    }

    private func record(_ command: AgentCommand) { lock.lock(); recorded.append(command); lock.unlock() }

    var commands: [AgentCommand] { lock.lock(); defer { lock.unlock() }; return recorded }

    func executable(for service: AgentService) -> String? { tool }

    func run(_ command: AgentCommand, timeout: TimeInterval, signal: CancelSignal,
             onLine: @escaping @Sendable (AgentStream, String) -> Void) async -> AgentExit {
        record(command)
        effect?(command)
        for (stream, line) in lines {
            if signal.isCancelled { return AgentExit(status: nil, cancelled: true) }
            onLine(stream, line)
        }
        if holdUntilStopped {
            while !signal.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return AgentExit(status: nil, cancelled: true)
        }
        return exit
    }
}

/// Lines as Claude Code's `--output-format stream-json` printed them for the first task in the live test (a bug fix in a
/// one-file folder), with the personal folder replaced and the session id fixed. The hook and rate-limit lines are real too.
let claudeRecordedLines: [String] = [
    ##"{"type": "system", "subtype": "hook_started", "hook_id": "2e261593-b0be-47cc-8391-a525d7b7a019", "hook_name": "SessionStart:startup", "hook_event": "SessionStart", "uuid": "2c187d29-645b-47cd-b801-2c38aa9656bd", "session_id": "7bbdb053-bc31-4ecd-928c-bcf9daf4e494"}"##,
    ##"{"type": "system", "subtype": "hook_response", "hook_id": "2e261593-b0be-47cc-8391-a525d7b7a019", "hook_name": "SessionStart:startup", "hook_event": "SessionStart", "output": "", "stdout": "", "stderr": "", "exit_code": 0, "outcome": "success", "uuid": "fd109512-da48-45d2-8428-2d060d3bb5bd", "session_id": "7bbdb053-bc31-4ecd-928c-bcf9daf4e494"}"##,
    ##"{"type": "system", "subtype": "init", "cwd": "/Users/tester/bt-agent-test/proj", "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001", "tools": ["Read", "Edit", "Bash"], "model": "claude-sonnet-5-5", "permissionMode": "acceptEdits", "apiKeySource": "none"}"##,
    ##"{"type": "assistant", "message": {"id": "msg_011CfwjHckEZaNakViJAzhCp", "role": "assistant", "content": [{"type": "tool_use", "id": "toolu_01THcKM8aeiRgWikLKXUN6xC", "name": "Read", "input": {"file_path": "/Users/tester/bt-agent-test/proj/greet.py"}, "caller": {"type": "direct"}}]}, "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"}"##,
    ##"{"type": "rate_limit_event", "rate_limit_info": {"status": "allowed", "resetsAt": 1791786600, "rateLimitType": "five_hour", "overageStatus": "rejected", "overageDisabledReason": "org_level_disabled", "isUsingOverage": false, "unifiedWindows": {"five_hour": {"utilization": 0.06, "resetsAt": 1791786600}, "seven_day": {"utilization": 0.14, "resetsAt": 1792216800}}}, "uuid": "df81c172-7b34-45f7-84d1-95e6407320bd", "session_id": "7bbdb053-bc31-4ecd-928c-bcf9daf4e494"}"##,
    ##"{"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_01THcKM8aeiRgWikLKXUN6xC", "type": "tool_result", "content": "1\tdef greet(name):\n2\t    return \"Hello \" + nme\n3\t\n4\t\n5\tif __name__ == \"__main__\":\n6\t    print(greet(\"world\"))\n7\t"}]}, "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"}"##,
    ##"{"type": "assistant", "message": {"id": "msg_011CfwjHjHddzZWYFUm6UdNu", "role": "assistant", "content": [{"type": "tool_use", "id": "toolu_017CzwqiRNyGthA3G5C7UGtb", "name": "Edit", "input": {"replace_all": false, "file_path": "/Users/tester/bt-agent-test/proj/greet.py", "old_string": "\"Hello \" + nme", "new_string": "\"Hello \" + name"}, "caller": {"type": "direct"}}]}, "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"}"##,
    ##"{"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_017CzwqiRNyGthA3G5C7UGtb", "type": "tool_result", "content": "The file /Users/tester/bt-agent-test/proj/greet.py has been updated successfully. (file state is current in your context — no need to Read it back)"}]}, "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"}"##,
    ##"{"type": "assistant", "message": {"id": "msg_011CfwjHqcdoETEZvCNBLCX8", "role": "assistant", "content": [{"type": "text", "text": "I fixed the typo in `greet.py`. Line 2 used `nme`, which isn't defined, so it would have raised a `NameError`. It now uses the parameter `name`. I didn't run anything, as you asked."}]}, "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001"}"##,
    ##"{"type": "result", "subtype": "success", "is_error": false, "result": "I fixed the typo in `greet.py`. Line 2 used `nme`, which isn't defined, so it would have raised a `NameError`. It now uses the parameter `name`. I didn't run anything, as you asked.", "session_id": "8f1c2d3e-1111-4a5b-9c8d-000000000001", "num_turns": 3, "stop_reason": "end_turn"}"##,
]

/// What the reply said in that run (the final result, also the assistant's text).
let claudeReplyText = "I fixed the typo in `greet.py`. Line 2 used `nme`, which isn't defined, so it would have raised a `NameError`. It now uses the parameter `name`. I didn't run anything, as you asked."

/// Lines as Codex's `exec --json` printed them in the live test. That run refused to read the file (the task said not to run
/// anything, and Codex reads files with commands), so it has messages and no command steps.
let codexRecordedLines: [String] = [
    ##"{"type": "thread.started", "thread_id": "019e0000-0000-7000-8000-000000000002"}"##,
    ##"{"type": "item.completed", "item": {"id": "item_0", "type": "error", "message": "Under-development features enabled: chronicle. Under-development features are incomplete and may behave unpredictably. To suppress this warning, set `suppress_unstable_features_warning = true` in /Users/tester/.codex/config.toml."}}"##,
    ##"{"type": "turn.started"}"##,
    ##"{"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": "I’ll inspect and edit `greet.py` without running commands, the script, or tests.\n"}}"##,
    ##"{"type": "item.completed", "item": {"id": "item_2", "type": "agent_message", "text": "Please paste `greet.py`. Reading local files here requires running a command, which you prohibited. I haven’t run commands or changed any files."}}"##,
    ##"{"type": "turn.completed", "usage": {"input_tokens": 95691, "cached_input_tokens": 73088, "cache_write_input_tokens": 0, "output_tokens": 442, "reasoning_output_tokens": 281}}"##,
]

/// Command steps in Codex's `exec --json` format. NOT captured live: the live run ran no command. Shapes follow the tool's
/// documented item types (command_execution with command, aggregated_output and exit_code).
let codexCommandLines: [String] = [
    #"{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat greet.py'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
    #"{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat greet.py'","aggregated_output":"def greet(name):\n    return 'Hello ' + nme\n","exit_code":0,"status":"completed"}}"#,
]

/// The text of Codex's replies in the recorded run, joined as the Black Team reply shows them.
let codexReplyText = "I\u{2019}ll inspect and edit `greet.py` without running commands, the script, or tests.\n\n\n" +
    "Please paste `greet.py`. Reading local files here requires running a command, which you prohibited. I haven\u{2019}t run commands or changed any files."
