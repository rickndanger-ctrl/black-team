# Harnesses and agent work

A model generates responses; a harness manages the conversation, tool calls,
context and execution around it. Black Team has its own built-in harness for Chat
and Code, can use an installed Hermes Agent instead for Code, and offers launchers
for other locally installed harnesses.

## Black Team Code

Code is built in and needs no setup beyond a model that supports tool calling.
It is described in [Black Team Code](CODE.md), with its tools, budgets, approvals
and boundaries. [Memory](MEMORY.md) describes the vault it remembers in.

## Hermes (optional)

The **Set up your agents** card installs and connects Hermes for you after one
approval. It appears after your first model is ready, on Workspace when something
new is found, and under **Settings → Agents & apps** as the always-available card.
**Not now** is remembered, so it does not come back for the same things. The
command line does the same: `black-team setup` shows the plan and asks once;
`--yes` approves it.

If Hermes Agent is not on this computer, approving downloads one fixed version
of [Hermes Agent](https://github.com/NousResearch/hermes-agent) (about 79 MB, from
github.com, checked against a recorded SHA-256), builds its Python environment
and installs its packages from the Python package index, all inside Black Team's
data folder (`hermes/hermes-agent`). Your own `~/.hermes` and any Hermes you
installed are not touched. It needs `uv`, or Python 3.14 (uv can fetch that);
without either the card says what to install. Stopping keeps what was downloaded,
and trying again carries on. A Hermes you installed yourself is used as it is:
the card only connects it.

Connecting enables Hermes with files, terminal, search and planning on, browser
and desktop control off, and makes it what runs new Code conversations (change
that under **Settings → Agents & apps**). Existing conversations keep the engine
they started with. Hermes is mainly useful for its browser and desktop tools.

You can still do it by hand: open **Settings → Agents & apps** and choose
**Connect Hermes** when one is found (select an installation first if several are
found), or **Choose Hermes folder** if it is elsewhere.

For unusual layouts, **Tools and advanced setup** exposes the source directory
(containing `hermes_bootstrap.py`) and its Python interpreter, with Browse buttons.
It also holds tool switches and optional browser/desktop executable paths. Save
manual changes with **Save changes**. No developer-specific paths are required.

The adapter was written against the APIs present in Hermes checkout
`158fd638da1629c8e62caf9ade1515d162def8ab`. Other versions may change internal
interfaces. The host uses `HermesCLI`, session ownership, `StreamJsonEmitter`,
plugin approval transport and terminal/computer approval callbacks. The portable
host has mocked lifecycle tests; live compatibility still needs verification.

Configure tools on the desktop, then use **Start agent work** on Workspace or
choose **Agent · work with tools** in a new desktop or phone conversation. A model must support the
provider's tool-call protocol. Small or non-tool models may chat successfully but
fail agent tasks; tool capability is not inferred from the model name.

- Coding enables terminal commands, file read/edit/search and task planning.
- File publishing attaches snapshots from the workspace for private download.
  The plugin can request a Taildrop transfer to an owned device after an approval.
- Browser tools are opt-in and use Hermes's local browser backend. Install its
  supported browser tooling separately. Browser navigation accesses websites.
- Desktop control is opt-in and requires Hermes's computer-use driver. Wayland
  support depends on that driver and the target app; it is not universally verified.

Black Team creates a private Hermes profile for each Agent conversation. It pins
the model and compression provider to the selected local endpoint and uses its
own plugin. It does not copy your normal Hermes profile or its provider credentials.
Replies and tool events are saved with the conversation; the Hermes session ID
lets the next message continue the same session. Start a new Agent conversation
when changing models or workspace.

Approval requests show the action and allow **Approve once** or **Deny**. They
expire; mismatched/expired responses are rejected. Closing a phone does not grant
approval. Plugin tools and Hermes determine which actions request approval; this
is not a promise that every file edit or read asks first.

Tools act as your OS user, and the workspace is not an OS sandbox. Switches
control available toolsets, not process isolation. Give the agent only the access
you intend. File publishing restricts attachments to the workspace and blocks
common credential names, but it is not a universal sensitive-data classifier.

A turn has a 48-step / 30-minute budget. Stop cancels the owned agent process group;
a subsequent instruction can resume the saved session. The host must stay open.
There is no unattended retry loop or automatic restart of interrupted work.

## Agents found on this computer

The Workspace page lists the agents Black Team finds on your command path. The
setup card connects them all at once; **Connect** saves a launcher for one in a single step; **Open** then starts it
in a terminal, in your workspace folder, already pointed at the model you are
using. Switch models in Black Team and the next Open uses the new one.

| Agent | How Black Team points it at your model |
|---|---|
| Claude Code (`claude`) | Environment only: the server address, model name, long local timeouts and non-essential traffic off. Your server must also speak the Anthropic Messages API; llama.cpp does. |
| Codex (`codex`) | `-c` overrides that add a "Black Team" provider using the Responses API and select it, with web search off. |
| Pi (`pi`) | A separate Pi profile folder inside Black Team's data folder, holding one provider and model. |
| OpenCode (`opencode`) | An inline configuration with one OpenAI-compatible provider. |
| DeepSeek Harness (`dsh`) | A separate profile folder and a patch that adds your model and switches its hosted providers off. It starts DeepSeek Harness's own browser interface (the `web` profile) and the page opens in your browser. |
| Aider (`aider`) | `--openai-api-base` and `--model`. |
| Hermes Terminal (`hermes`) | Opened as it is; it keeps its own profile settings. |

None of this edits an agent's own configuration files. Arguments and
environment apply to that one launch, and the two profile folders live under
`harnesses/` in Black Team's data folder, readable only by you.

Each agent decides for itself what else it contacts. Black Team sets the
switches listed above and nothing more; check an agent's own privacy settings if
that matters to you. An agent chosen by hand under **Settings → Agents & apps**
is connected the same way when its file has one of the names above.

What has been checked: with each of Claude Code 2.1, Codex 0.162, Pi, OpenCode
1.19 and DeepSeek Harness 0.2, a one-shot run using these settings sent its
request to the given local address with the given model and key. A full working
session through a real model was not run for each, and Aider was not installed
to check.

## External harness launchers

Install your chosen harness and configure its local provider first. In **Settings
→ Agents & apps**, scroll to **Other apps**:

1. Choose a detected installed app from **Add an app**, or leave **Choose an app
   file…** selected and browse for its executable when you select **Add app**.
2. Adjust the app name if needed. Detected command-line apps use an available
   terminal automatically. If none is available, install a terminal and **Find again**.
3. Choose **Save changes**. Open the app from its new Workspace button.

Most launchers need no configuration text. **Launch options** provides **Open in**
for a terminal or the app's own window and **App argument** fields for any required
options. Enter one literal argument per field, for example `--model` followed by
`{model}` when that specific app supports such a flag. No JSON or shell-command
syntax is required. A manually chosen command-line app may need you to select a
terminal; a GUI app can use **Its own app window**.

**Custom terminal command** is available for unusual launchers. Its first field
is the absolute terminal executable; following fields are its launch arguments.
All executable paths must be absolute and executable. Arguments are literal: no
shell expansion or pasted shell command is evaluated. Use only options supported
by the installed client or your wrapper.

Supported substitutions are `{endpoint}`, `{model}` and `{workspace}`. Every
launch uses the selected workspace as its working directory and receives:

| Environment variable | Value |
| --- | --- |
| `BLACK_TEAM_BASE_URL`, `OPENAI_BASE_URL` | Selected local `/v1` endpoint |
| `BLACK_TEAM_MODEL`, `OPENAI_MODEL` | Exact model ID / owned runtime alias |
| `BLACK_TEAM_WORKSPACE` | Selected working directory |
| `OPENAI_API_KEY` | Local server key, or a local placeholder when none is needed |

Keys are passed through the child environment rather than command-line arguments.
Common desktop/session environment values are retained; unrelated provider secrets
are not inherited. A launcher is software you choose to trust. It can read its own
configuration or make network requests, and not every client honors these variable
names. Check the effective provider in that harness before sending private content.

Codex, DSH, Pi, Hermes terminal, or another client can be added when its installed
version supports your local server. Black Team does not install them (the setup card shows their makers' install commands as text), rewrite
all their profiles, promise compatibility with every model, or mirror their
independent terminal sessions into Phone Companion. The built-in Black Team Agent
provides the integrated phone tool/approval experience.

CPU/RAM readings reflect the whole computer. External jobs are not part of Black
Team's busy/cancellation tracking. Stop those jobs before stopping an app-owned
model or changing connections. Use an existing independent model server if it
must remain available after Black Team closes.
