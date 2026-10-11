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
"continue" to pick up from the todo list.

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
- **A stuck model is stopped.** A call repeated with the same result is pointed
  out to the model on the third time and ends the turn on the fifth. A turn that
  ends early says so; it never reports "done".

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
