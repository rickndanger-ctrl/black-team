# The Room

A **room** belongs to one project. Its members are saved models (local, or cloud with your own API key) and subscription agents
(Claude Code and Codex, which run through their own command-line tools and logins). A room has a task board, hand-offs that you
make by hand, and **team runs**. Only one job runs at a time, except inside a driven run (below).

## Two ways to run a goal

| | Who decides what happens next | When it is used |
| --- | --- | --- |
| **Plan, work, review, report** | A lead plans once (read-only), members work the tasks one after another, a reviewer checks, the lead writes a report. | The lead is a local model, or you ask for it (`--pipeline` on the command line). |
| **Driven run** | A paid member, the **driver**, works on the goal itself and hands real pieces of work to the other members while it works. | The lead is a paid member that can use tools: a cloud model that does Code work, Claude Code or Codex, and the room has at least one other member. |

The idea of a driven run is to let the paid agent spend its tokens on planning, hard decisions and review, and to let the local
models, which cost nothing and keep data on this computer, do the bulk: reading and searching files, summarising, first drafts, tests
and repetitive edits.

## What a driven run is

The driver is given two tools for that run only:

- **team** lists the other members: name, role, whether each runs on this computer, what work it does, whether it has tools and
  vision, and for each local model how fast it reads and writes (measured by Black Team the last time it ran; "not measured yet"
  until then) and whether it is the model loaded now.
- **delegate** takes a member, a self-contained task, optional files to look at, and whether the member may change files (off by
  default). It puts a task on the room's board for that member, runs it in a **new conversation** of that member, waits, and
  returns the result (clipped to 6,000 characters, with the number of files changed, or the error in plain words). The task appears
  on the board and in the work log like any other. A read-only job gets a Code member without the tools that change files.

How the tools reach each kind of driver:

- **A cloud model** runs in Black Team's own Code loop and calls the tools directly.
- **Claude Code and Codex** are started with an MCP server for that one launch only, named `blackteam`, on the command line:
  Claude Code gets `--strict-mcp-config --mcp-config '<json>'` and the two tools allowed by name; Codex gets `-c mcp_servers.blackteam.*`
  overrides (command, args, a one-hour tool timeout, tools approved). Their own configuration files are not edited. The server is
  `black-team mcp-room --run <file>`. It does not open your data folder; it passes each call to the running Black Team over a
  socket that exists only while the run does, in a private folder, readable only by you, with a secret made for that run. Nothing else
  listens, and the file is deleted when the run ends.

The driver is told the rules of the room in a short first message: local members are free and private; give them real jobs with exact
files and a clear finish; keep planning, hard decisions and review for yourself; check a result before building on it; do not redo
work a member has done.

## Running while the driver waits

The driver's job is the one job. Delegated member runs run beneath it:

- Local models share one model slot, so they run **one at a time**, in the order asked, and the model that is already loaded goes
  first (switching models stops the loaded one). A paid member (a cloud model, Claude Code, Codex) may run at the same time as a
  local one.
- **Stop** ends the driver and every member run beneath it. Tasks keep the state they reached; members that were running are shown
  as stopped.
- A command a member needs approval for is shown on the driver's job, where you answer it.
- Two agents changing the same files at once can collide. Give members that may change files different files.

## Limits

A driven run stops at the first of these, and says which:

| Limit | Value |
| --- | --- |
| Hand-offs (delegations) | 12, which also count toward the 20 member runs of a team run |
| Time | 60 minutes |
| Tokens on paid services | 400,000 (read plus written, driver and paid members) |
| One task | 4,000 characters; one result handed back 6,000 characters; 20 files |

The paid-token cap is checked live for a cloud model driver and for paid members, whose services report usage with every reply.
Claude Code and Codex report their usage when they finish, so for them the cap is met only at the end of the run.

## The ledger

For each run and each member the Room shows the tokens read and written and the time, grouped as **paid** and **local**, and one
sentence: "Local agents did 41,200 tokens of work; paid agents used 9,800." It is in the Room while the run goes, in the final report,
and in `black-team room team`. The figures are the ones the model server, the cloud service or the tool itself reported. Anything not
reported (a tool that prints no usage, a server that sends none) is shown as **not measured**, never estimated, and is named in the
sentence.

## What leaves this computer

A driven run sends the local members' results to the paid driver. The agreement you confirm before it starts says so, names the
service the driver runs on (for example anthropic.com), names any other paid member and its service, and states the limits. Nothing
new leaves without that agreement, and every existing rule holds:

- The project must allow cloud models; otherwise a paid driver or member is refused.
- A phone cannot start a run with a paid member, and cannot use the Room at all.
- Your memory vault is not used in a run that has a paid member: no Core, no recalled notes, no memory tools, no journal entry, for
  local members too.
- The run starts only if the agreement's digest still matches the room. Change the goal, the members or the driver and you review
  again.
- Every member run is a new conversation made for the run; no existing conversation is passed on.

What the driver reads in your project folder with its own tools is also sent to its service, as with any use of that tool.

## Saved agents (the roster)

Create a Black Team agent once, then add it to any project's room in one step. An entry has a name, a role, a saved model or a
subscription agent, a permission (agents: ask, edit or auto) and a kind of work (models: chat or code). The roster is one private
file in the data folder, `roster.json`, and holds **no secrets**: a model is named by its saved key, and its API key stays in the
saved-models file. The room gets its own copy when you add an agent, and a room member can be saved to the roster.

In the window: **Room → Who is on this team → Saved agents**. On the command line: `black-team room roster`.

## Where to use it

- **Linux window.** Cloud models (Settings → Models → Cloud model) and the subscription agents (Settings → Agents & apps) work in the
  Linux window since 0.1.0-alpha.20, and so does the Room with them. Choose a paid member as **Driver** on the Room page, read the
  agreement, and start. The live list shows who was given what and how it is going; the ledger and Stop are beside it.
- **Command line.** `black-team room team <project> "<goal>"` (and `/team "<goal>"` in a session) shows the agreement and asks; a
  paid lead drives, `--pipeline` runs plan, work, review, report instead.
- **Mac app.** The engine is the same; the Mac screens do not show the driven run's hand-offs and ledger yet. A driven run started
  there with `driven: true` is recorded in the same room file.

## Grown into a company

The [organization](ORGANIZATION.md) is built on the room: its roles become room members, each pipeline stage is a task on this board
run through the same start path, and the same privacy gate, caps and ledger words apply.

## What this does not do

- A local model cannot be a driver. A local lead uses plan, work, review, report.
- Members cannot hand work to each other; only the driver delegates.
- A driver's own mistakes are its own: Black Team checks limits and privacy, not whether a result is good. The driver is told to check.
