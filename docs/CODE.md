# Black Team Code

Code is Black Team's own agent loop. It is built in, needs no other software, and
is written for the conditions local models actually run under: reading a long
prompt is slow, the context window is small, and nobody wants to wait twelve
minutes for a model to re-read what it already saw.

Open **Chat / Code** and select the terminal mark at the top of the page. The
mark is the switch: the chat bubble is Chat, the terminal is Code.

## What it does

| Tool | What the model can do |
| --- | --- |
| `read`, `search`, `list` | Read numbered lines, search file contents, list a folder |
| `edit`, `write` | Change or create files inside the workspace |
| `run` | Run a shell command in the workspace |
| `todo` | Keep a task list that survives trimming |
| `publish` | Attach a finished file to the conversation for download |
| `remember`, `recall` | Save and look up facts in [memory](MEMORY.md) |
| `skill`, `save_skill` | Load a saved routine, or save one that just worked (see [skills](MEMORY.md#skills-routines-that-worked)) |

Your model must support tool calling.

## Built around your model's real speed

- **It measures.** After each reply the engine records how fast your model reads
  and writes, from the server's own timings where they exist (llama.cpp) and from
  the clock otherwise. The speeds are remembered per model.
- **It budgets from the measurement.** The working budget is the most the model
  could re-read in about twelve minutes, never more than 60% of the context
  window. A single tool result is capped at about one minute of reading. A faster
  model automatically gets more room.
- **It never rewrites history.** Messages are only appended, so the model
  server's prompt cache stays valid and each step reads only what is new.
- **Trimming costs no model call.** A work log and the todo list are kept as the
  task runs. When the budget is reached, the oldest steps are replaced by that
  record. Files can always be read again.

The gauge beside the response-length selector shows reading speed, writing speed
and how full the working budget is.

Code needs a context window of at least 8,192 tokens; 32,768 or more is a better
fit for real work. One turn is limited to 48 steps or 30 minutes; send
"continue" (or press **Continue**) to pick up from the todo list.

## You can see where a run is, and pause it

Each Code task has a **phase**, shown above the conversation and in the terminal:
*Planning* (the model is writing its to-do list, before its first action), *Working*, *Checking the work*,
*Waiting for your approval*, *Paused*, and the ends *Done*, *Stopped* and *Failed*. Beside it are the step,
the tool in use, the tokens used and, for a cloud model with a price set, the money spent.

- **Pause** takes effect between steps: the step on its way finishes, including a tool that is running, and
  nothing more is asked of the model until you press **Resume**. Pausing does not count against the task's
  time limit. In the terminal, Ctrl-\ pauses and Ctrl-\ again resumes; `/continue` and
  `black-team code --continue --thread <id>` pick a task up again.
- **The state is saved with the conversation** after every step: the to-do list and which items are done, the
  steps taken, the tool that was running and the counters. If Black Team is closed or crashes mid-task, the
  conversation shows where it stopped, with a **Continue** button. Continue sends the model the whole
  saved history and to-do list and a note of where it was cut off (a tool call that never finished is marked
  as interrupted); it does not start again.

## Limits

- One turn is limited to 48 steps or 30 minutes, as before.
- A **token limit** per conversation (2,000,000 by default; 0 means none) counts everything read and written,
  as the model server or cloud service reports it. When it is reached the task stops with a plain message,
  and stays stopped until you raise the limit.
- A **spending limit** and **prices** for cloud models only. You enter the price per million tokens read and
  per million written for each cloud model; Black Team has no price list and fetches none. The running cost
  is worked out from the usage the service reports. If a spending limit is set but no price is, the task does
  not start another step and says why. A model on this computer has no money limit because it costs nothing
  per token.
- **A loop is stopped.** The same tool called with the same arguments and giving the same result three times
  in a row ends the task, and the message says so.

Set these under **Limits and checks** in the conversation (for that conversation) or before you start (for new
ones).

## Strict tool arguments

Every tool call is checked against that tool's own JSON schema before it runs: required fields, unknown
fields, text, whole number and true/false types, allowed values and the length limits the schemas state. A
mismatch goes back to the model as a short observation, such as ``argument `path` is required`` or ``argument
`lines` must be a whole number``, and counts as a step. It never reaches the tool and never crashes. A
command's result always starts with `exit <code>` (or `timed out after <n>s`) and then its output, with the
two output streams of the command shown together in the order they arrived.

## Check the work before finishing

**Check the work before finishing** (per conversation) makes the model review its result once it says it is
done: one short extra turn compares what it did with the request and the to-do list and either gives the final
summary or carries on with what is missing, at most twice. It runs only when the task changed something or the
to-do list still has open items. It is **on by default for a cloud model** and **off by default for a model on
this computer**, because each check has to read the whole task again and can take minutes there.

## Working memory

Trimming costs no model call, as above. A **written summary of the trimmed part** is added only for a cloud
model, or when you turn on **Summarize earlier steps when trimming** (it asks the model to read the steps it
is about to drop, which can take minutes on a processor). The summary is kept with the conversation as a note
and goes into the record that replaces the trimmed steps.

## Where the owner's brief is done

| Point of the brief | Where Black Team Code does it |
| --- | --- |
| 1. State machine and core loop; state tracker; token, loop and money caps | `Engine/Engine.swift` is the think, act, observe loop. `Engine/RunControl.swift` holds the phases (`RunPhase`: idle, planning, working, checking, waiting, paused, done, stopped, failed), the saved state (`RunRecord`: to-do items, steps, tool and its status, counters), pause/resume and the ceilings (`RunCeilings`) and loop guard (`LoopGuard`). The per-turn limits (steps, time, working budget) and the new per-conversation token and money limits are checked at every step. |
| 2. Typed tool registry, strict validation, results formatted for the model | `Tools/Tools.swift` is the registry (`Tools.SCHEMAS`). `Tools/ToolValidation.swift` checks each call against its schema; failures come back as observations. `run` returns `exit <code>` then the output. |
| 3. Tiered memory: working window, long-term and skill memory | Working: the budget, trimming and the optional summary in `Engine/EngineMemory.swift` and `Engine/EngineRun.swift`. Long-term: the [vault](MEMORY.md) (`Memory/`). Skills: `Skills/SkillStore.swift`, `skill` and `save_skill`, in Hermes's `SKILL.md` format. |
| 4. Resilient execution | A tool error, invalid JSON, invalid arguments or a declined command is returned to the model as its next observation (`Engine.swift`, `ToolValidation.swift`). A run cut off by a crash is repaired and continued (`Engine.repairDangling`, `Engine.resumeNote`). |

The brief names states IDLE, PLANNING, EXECUTING, CRITIQUING and PAUSED; Black Team calls them idle, planning,
working, checking and paused, and adds waiting (for an approval) and the three ends.

## Every change is shown, and can be undone

Each file the model edits or creates appears in the conversation as a diff with
an **Undo** button. Undo puts that one file back as it was. It is refused when
the file has changed again since, so a later edit is never lost, and it waits
while a task is running.

## The code map (graphify)

When [graphify](https://pypi.org/project/graphifyy/) is installed (`uv tool
install graphifyy` or `pip install graphifyy`), Code gets a `map` tool. It asks a
graph of the workspace's code which files and functions relate to a question,
and gets back names with paths and line numbers within the usual result budget.
A local model that asks the map first reads far fewer files.

The map is graphify's code-only extraction: no model is involved, so building it
takes seconds and needs no key. It is built on first use and kept under
`graphs/` in Black Team's data folder, never inside the project. It is rebuilt
after Code edits files in that conversation, after ten minutes, or when the
model asks with `refresh`. Documents and images in the workspace are not mapped;
that would need a model run, which Black Team does not do on its own.

Settings → Agents & apps shows whether graphify was found. Black Team never
installs it for you.

## Boundaries

- **Writes stay in the workspace.** `edit`, `write` and `publish` only accept
  paths inside the conversation's workspace, after resolving symbolic links.
- **Reads stay in your home folder**, and never include credential files
  (`.ssh`, `.gnupg`, `.env`, `*.key`, `*.pem` and similar) or Black Team's own
  data folder. Search results are held to the same rule.
- **Risky commands wait for you.** Anything that deletes, installs, changes
  system state, reaches the network, rewrites git history or touches dotfiles
  shows an approval card first. Approve once or deny; nothing is approved
  permanently. Unanswered requests deny themselves after five minutes.
- **A stuck model is stopped.** The same call with the same result three times in
  a row ends the task, and says so. A turn that ends early says so; it never
  reports "done".

The `run` tool is a shell running as your Linux user. The approval list is a
guard against accidents, **not a sandbox**: a command that does not match it runs
without asking. Use a workspace you are comfortable letting a model work in.

## Projects

Press **+** beside **Projects** in the sidebar and name the project. Black Team
creates a folder for it inside your workspace and a folder of notes in memory.
Conversations started in a project stay grouped under it; Code works in the
project's folder and writes a short journal entry to memory after each turn, so
you can open the project later and pick up where you left off.

## Optional helpers

- [ripgrep](https://github.com/BurntSushi/ripgrep) makes `search` faster. Without
  it, Code uses `grep`.
- [RTK](https://github.com/rtk-ai/rtk), when installed, shortens noisy command
  output before the model reads it. Without it, commands run unchanged.
- `diff` (diffutils) produces the change views. Without it, Undo still works.

## Hermes

If you have Hermes Agent installed you can connect it in **Settings → Agents &
apps** and choose it for new Code conversations, mainly for its browser and
desktop tools. See [harnesses](HARNESSES.md). A conversation keeps the engine it
started with.
