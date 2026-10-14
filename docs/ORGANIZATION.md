# The organization

An **organization** is a team of agents that works on one project like a small company, with you as the owner who approves what
matters. It is the [Room](ROOM.md) grown up: the same members, the same board, the same privacy gate, and the [background
service](SERVICE.md) to keep it going. Work arrives as **tickets**; each ticket passes through stages, each stage run by a role; each
stage leaves something you can read; you decide at the gates; and nothing is merged into your branch unless you do it.

## What to expect

Be realistic about speed. Local models on a computer without a graphics card are slow, and a ticket goes through several stages, each a
model run that reads the earlier work before it writes. **A full ticket through every stage can take hours on a local model.** So:

- Keep tickets small. One ticket is one change. The lead reads each new ticket and, if it is large, **splits it into smaller tickets**.
- Stages skip when they are not needed (below). A small change is intake, build, review, ship.
- Progress is always visible: the Tickets page shows each ticket's stage, who is working on it and what it has made so far.
- A paid lead (a cloud model, Claude Code or Codex) makes planning and decisions better and faster; local models do the bulk.

The organization does **not** produce production-quality software unattended. It writes code, has it reviewed and tested by other
agents, and prepares a branch and release notes. You read the work and decide whether to merge it.

## Roles

A role is a roster-style agent with a **charter** (a short brief of what it is responsible for and the standards it holds), a model or
subscription agent, how much it may do on its own (read only, ask first, edit files in the project, automatic), a few plain guidance
notes, and optionally a price and daily ceilings for paid work. Everything is editable; add as many roles as you like (a room holds up
to eight distinct members; roles on the same model and kind of work share one).

| Role | Does |
| --- | --- |
| **Lead** | Runs the company. Reads each ticket, decides its size and whether it touches the interface, splits large tickets, writes the acceptance criteria when there is no product manager. A paid agent or your strongest local model. |
| **Product manager** | Turns the request into a spec with numbered, checkable acceptance criteria. If the request is too unclear it asks you one question instead. |
| **Designer** | Writes a design spec and produces **real files**: an HTML and CSS mockup (`design/mockup.html`) and design tokens (`design/tokens.css`) in the ticket's branch. If a model that can look at pictures and a headless browser are installed, it also reviews a picture of the mockup. |
| **Architect** | Breaks the spec into engineering tasks (at most six) and decides structure, reading the code first. |
| **Engineers** | Build one task at a time on the ticket's branch. More than one engineer shares the tasks in turn. Local models do most of this. |
| **Reviewer** | Reviews the diff against the spec and the code's conventions: accept, or ask for named changes. |
| **QA** | Runs the project's tests, checks each acceptance criterion, writes missing tests, and reports pass or fail. |
| **Docs writer** | Writes the documentation for the change. |
| **Release manager** | Prepares the change for you: summary, how each criterion was checked, what review and QA found, the branch to merge, release notes. |

**Templates:** *Software company* (all of the above), *Design studio* (lead, designer, reviewer) and *Small team* (lead, one engineer,
reviewer). Make one in **Organization** (or `black-team org create`); every role then needs a model or an agent, which the form fills
in for you from the model you choose. The charters are a first draft; edit them.

**One organization per project, not across projects.** The Room, the git repository, the cloud setting and the memory notes are all
per project, so each of those rules keeps meaning what it already meant. Saved agents are still shared the way they always were:
`Save to roster` on a role.

## The pipeline

```text
Intake -> Spec -> Design -> Plan -> Build -> Review -> QA -> Ship
```

Each stage is a **room task** run by the role's room member through the room's own start path, so the privacy gate, the one local model
slot and the board work exactly as they do for a task you start by hand. The tasks appear on the Room's board
(`T-3 Build: ...`) and in its work log. Each stage saves an **artifact**:

| Stage | Role | Artifact |
| --- | --- | --- |
| Intake | Lead | `intake.md`: summary, size, whether it touches the interface, acceptance criteria |
| Spec | Product manager | `spec.md` |
| Design | Designer | `design.md`, `mockup.html`, `tokens.css` (and the files in the branch), `visual-review.md` when a picture review was possible |
| Plan | Architect | `plan.md` (the tasks) |
| Build | Engineers | `build.md` (what each task did, files changed) and `diff.patch` (the real `git diff` of the branch) |
| Review | Reviewer | `review.md` |
| QA | QA | `qa.md` (the test report) |
| Ship | Docs writer, Release manager | `docs.md`, `release-notes.md` (with the branch and the merge command) |

**Skipping:** Design runs only when the ticket touches the interface (you can say so when you add it, or the lead decides) and there is a
designer. Plan is skipped for a small ticket. Spec is folded into Intake when there is no product manager (you still approve it).
Review and QA are skipped when there is no such role. The ticket's history says what was skipped and why.

**Send-backs.** If Review or QA fails the change, the ticket goes back to Build with their findings, and the engineer sees them. After
two send-backs from the same stage the ticket stops and asks you (accept it as it is, or send it back with your own note). A spec the
product manager cannot write because the request is unclear becomes a **question for you** (`QUESTION:`); answer it on the Tickets page
or with `black-team ticket answer`, and the spec is written again with your answer. A review with no verdict counts as accepted, and
says so in the history; a QA report with no pass or fail does not pass.

**Tickets come from** you (the Tickets page or `black-team ticket add`), your phone, a **routine** (a ticket made on a schedule, such as
"weekdays at 9:00: check for outdated packages"; a routine makes no new ticket while its last one is open), or the lead splitting a
larger ticket. A ticket added from the phone waits for a yes on the computer when the organization uses a paid agent, because a phone
cannot start a paid run.

## Your branch is never touched

For a project that is a **git repository**, each ticket's engineering work happens on **its own branch** (`black-team/t3-...`), made from
the commit you were on, in **its own working folder** (a git worktree inside the project at `.black-team/work/`, kept out of your
`git status` by the repository's local exclude file). Your branch, your commit and your files are never changed. The branch holds the
design files, the code, the tests, and a `.black-team/tickets/T-3/` folder with the ticket's artifacts (delete it before merging if you
do not want it in your history). When you approve shipping the ticket is marked done and the release notes tell you the exact
`git merge` command. **Black Team never merges.**

Limits of this: the branch starts from your last commit, so uncommitted changes in your folder are not in it. A repository with no
commits yet cannot be branched; the ticket stops and says so. A project that is **not a git repository** is worked in directly in its
folder (there is nothing to branch), with no diff, and the ticket and the docs say so.

## Gates: where you decide

By default you approve **the spec** and **shipping**; you can choose any stages. A gate holds the ticket until you answer, and shows in
the background service's **Inbox** (and the window, and the phone's Inbox) with the artifact to read. **Approve**, or **Send back** with a
note; the stage is done again with your note. A gate waits for you for as long as it takes (it does not expire, and a restart leaves it
alone). Nothing else runs on that ticket, while other tickets carry on.

## What leaves this computer

Starting an organization shows an **agreement** first: exactly which roles run on a paid service, which service, and what they are
given: the ticket's words and the earlier stages' work (including what local roles wrote), the project files they read and the output of
commands they run. You confirm it; `black-team org start` prints it and needs `--yes`. The start is refused unless the agreement's
digest still matches the roles, the project allows cloud models, and the request is not from a phone.

- If you later move a role to a service you have not agreed to, continuous pickup **stops** until you read the agreement again, and even a
  manual step holds the ticket at a **privacy gate** ("T-3 would be sent to X for the Review stage. Allow it?") before anything is sent.
  Only the computer can answer a privacy gate.
- **Your memory vault stays out** when any role is paid: no Core, no recalled notes, no memory tools, no journal, for local roles too.
- Every stage is a **new conversation** made for it; no existing conversation is passed on.
- What a paid agent reads in your project with its own tools goes to its service, as with any use of that tool.

## Running continuously

Start an organization and it picks up the next ticket whenever this computer is idle, one stage at a time:

- With the **background service** on ([SERVICE.md](SERVICE.md)) it carries on with the window closed. Without it, it works while the
  window is open, the same way. (If you close the window with it running, it carries on the next time Black Team opens.)
- It queues behind the one local model slot: a stage never starts while a response, an optimizing run or a team run holds the model, and
  it never runs two stages at once. It finishes the ticket furthest along before starting another.
- It stops at gates, when it is paused, and when a ceiling is reached. A stage that was running when Black Team quit runs again.
- Pausing stops the stage that is running; its ticket waits again.
- The model is not unloaded for memory while an organization has work.
- A command a role needs your yes for (a role that may only "ask first") appears in the Inbox like any other question.

A **stand-up report** is made daily (by default at 9:00; change or turn it off in Organization): what moved, what is waiting for you,
what is stuck, the queue, and today's spend. It is saved under the organization's `standups/` folder and left as a note in the Inbox.
It is made by Black Team from the tickets and the ledger, not by a model, so it costs nothing.

## Budgets and the ledger

For each stage run Black Team records who ran it, the tokens the engine or the service reported, whether it was paid or local, and
how long it took. The **ledger** (Organization, and `black-team org show`) groups them: "Local agents did 41,200 tokens of work today;
paid agents used 9,800." Anything not reported is **not measured**, and said so, never guessed.

Per organization and per role you can set a **ceiling per day** on paid tokens and on money. Money uses **prices you enter** (per
million tokens read and written) on each role; nothing is built in, and a paid role with no price adds no money (it is still counted in
tokens). Reaching a ceiling **pauses the organization** and leaves a note in the Inbox; resume it after raising the ceiling or the
next day. Local work is measured but never limited. Claude Code and Codex report their usage when a run ends, so a ceiling is met after
the run that crosses it, not during it.

## On the command line

```text
black-team org create <project> [--template software|studio|small] [--local <model key>] [--lead-model <key> | --lead-agent claude|codex]
black-team org show | start [--yes] | pause | resume | step | standup | remove <project>
black-team org role <project> list | add <kind> | remove <role> | set <role> [--model|--agent|--access|--charter|--price-in/--price-out|...]
black-team org set <project> [--gates spec,ship] [--tokens-per-day N] [--money-per-day X] [--standup "daily at 9:00"|off]
black-team org routine <project> [add "<title>" --when "weekdays at 9:00" | remove <n>]
black-team ticket add <project> "<title>" [--detail D] [--ui yes|no]
black-team ticket list | show [--artifact <name>] | approve | send-back --note N | answer | retry | cancel <project> [<ticket>]
```

With the background service running these go to it; otherwise they use an engine of their own (like `room`), and `org start` then picks
tickets up only while that command runs.

## Where it is stored

`<data>/orgs/<project>/`: `org.json` (roles, gates, ceilings; **no API keys**, a role names a saved model by its key), `tickets.json`,
`usage.json`, `tickets/<ticket>/` (the artifacts) and `standups/`. Folders are private (0700), files owner-only (0600). A gate is also
an item in `<data>/inbox.json`.

## What this does not do

- It does not merge, push or publish anything.
- It does not make a local model good at something it is not. A weak model gives weak specs and weak code; the reviewer and QA catch some
  of it, not all. Give the roles that need judgment the best model you have.
- The Lead does not drive its team with the Room's `team` and `delegate` tools inside the pipeline: each stage is run directly by its
  role. (A [driven run](ROOM.md) in the Room is still the way to have a paid agent hand jobs to local members within one goal.)
- Two engineers do not build at the same time (one model slot), and a ticket's tasks are built one after another.
- A picture review of a mockup needs a model that can look at pictures and an installed headless browser (Chromium or Chrome); without
  them the Designer's work is reviewed by the Reviewer from the files, and the ticket's history says the picture review was skipped.
- The Mac app's screens do not show organizations yet; the engine, the command and the Linux window do.
