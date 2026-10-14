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

Install [Hermes Agent](https://github.com/NousResearch/hermes-agent) and its needed
dependencies separately. Open **Settings → Agents & apps**. Black Team scans for
ready local installations and offers **Connect Hermes** when one is found. Select
an installation first if several are found. Once connected, choose **Hermes** as
what runs new Code conversations; existing conversations keep the engine they
started with. Hermes brings far more than Black Team Code does (browser and desktop
tools, hundreds of skills, plugins and MCP tool servers), and each thing it adds is
more text a local model reads before every reply. The Hermes screen therefore shows
what each choice costs.

If Hermes is elsewhere, choose **Choose Hermes folder**. Black Team checks that
folder for its Python environment. If nothing is installed, **Install Hermes Agent**
opens the upstream guide; finish that setup, then choose **Find again**. Connecting
Hermes does not install it or download an agent automatically.

For unusual layouts, **Tools and advanced setup** exposes the source directory
(containing `hermes_bootstrap.py`) and its Python interpreter, with Browse buttons,
and the optional browser and desktop-driver executables. Save manual changes with
**Save changes**. No developer-specific paths are required.

The adapter was written against the APIs present in Hermes checkout
`158fd638da1629c8e62caf9ade1515d162def8ab`. Other versions may change internal
interfaces. The host uses `HermesCLI`, session ownership, `StreamJsonEmitter`,
plugin approval transport and terminal/computer approval callbacks. The portable
host has mocked lifecycle tests; live compatibility still needs verification.
Everything the screens list is read from the connected install, so a version that
lacks a tool group, skill or plugin simply does not show it.

Configure Hermes on the desktop, then use **Start agent work** on Workspace or
choose **Agent · work with tools** in a new desktop or phone conversation. A model must support the
provider's tool-call protocol. Small or non-tool models may chat successfully but
fail agent tasks; tool capability is not inferred from the model name. Hermes itself
refuses a model whose context is under 64,000 tokens.

### What Hermes can do: the four lists

**Settings → Agents & apps → Hermes** has four lists. Black Team asks the connected
Hermes once (a short, read-only call made with Hermes's own Python in a scratch
folder, only after you have connected it) which tool groups it has and how large each
tool's description is, and keeps the answer until the install changes. **Read again**
asks again. Nothing found is run, enabled or installed until you switch it on.

**Tool groups.** Every group Hermes defines, with Hermes's own description and a plain label:

| Label | Meaning |
| --- | --- |
| Works on this computer | Runs here with nothing to sign up for. |
| Needs an account or key | Does nothing until you give Hermes an account or key for it. |
| Uses the internet | Sends requests to websites or services when used. |
| Needs the always-running service | Messaging platforms, scheduled jobs and the task board. Shown off and cannot be switched on yet; see [the proposal](HERMES-SERVICE.md). |

A new connection keeps what it always had: Black Team's file-delivery tools (always on)
plus the old "coding" set, the groups `terminal`, `file` and `todo`; the Skills group is
added when you link skills. Browser (`browser`) and desktop control (`computer_use`)
stay opt-in. A saved connection from an earlier version keeps its old switches
(coding, browser, desktop) as the starting choice until you change a group.

**The cost of each switch.** Beside each group is about how many tokens its tool
descriptions add to every message (the length of Hermes's own tool descriptions divided
by four, so only "about"). A running total at the top counts every tool once, however
many groups hold it, plus the skill list and any measured MCP server. When the total
passes one fifth of the model's context, the screen says in plain words that replies
will start more slowly and what to turn off. A group is never added without this number.

**Skills.** Hermes's bundled skills are written instructions the model reads when a
task matches. They are listed by category with each skill's name and one-line
description (from its `SKILL.md` front matter; a skill's text is not read to list it),
searchable, each on or off, and a category can be switched as a whole. Skills Hermes
keeps under `optional-skills/` are shown as "optional, off" and cannot be switched on
here. The ones you choose are *linked* (symbolic links, not copies) into the
conversation's private profile at `skills/<category>/<skill>`, the Skills group is
switched on, and Hermes puts only a short index (a line per skill) in the prompt. About
56 bundled skills cost about 1,600 tokens that way. Skills the agent writes itself land
in the profile, never in your Hermes. **Your own skills**: a folder named
`hermes-skills` in Black Team's data folder is linked in as `skills/own`; put a folder
with a `SKILL.md` inside to add one. Hermes logs a warning, and nothing else, that a
linked skill lives outside its own skills folder.

**Plugins.** Hermes's own plugins and the ones you installed in Hermes
(`~/.hermes/plugins`, read only), with the same labels. A plugin you switch on is named
in the profile's `plugins.enabled`, and one you installed yourself is also linked in.
Memory-provider plugins are listed but stay off, because Black Team has its own
[memory vault](MEMORY.md) and a second memory would keep another copy of what you say.
Messaging-platform plugins need the service. A plugin that sends data off this computer
says so. Plugin keys (for example Langfuse's) are entered in a secure field.

**Web search.** Used when the Web group is on. Providers that need no key come first:
`ddgs` (DuckDuckGo; needs Hermes's `ddgs` Python package, which the screen names when it
is missing) and `searxng` (your own server's address). `brave-free` and the others need a
key or account. Black Team always turns off Hermes's fallback to free vendor search
services, so search uses only the provider you chose and does nothing if you chose none.
A search sends the words searched to that service.

**MCP servers.** Extra tool servers for Hermes conversations, written into the profile's
`mcp_servers` in the format Hermes reads. A server is a **program** (its absolute path
and one literal argument per field) or an **address on this computer**
(`http://127.0.0.1:...`). The rules are those of the external launchers below: absolute
paths, literal arguments, no shell, no JSON to type, and an address elsewhere is refused.
An argument containing `${` is refused, because Hermes would substitute an environment
value into it. Environment values go in secure fields. A server's reading cost is shown
after its first conversation (Hermes reports the size of each tool it sent) and says "not
measured" until then.

**Keys.** A key or environment value is stored in a file readable only by you in Black
Team's data folder, is never shown again, and is passed to the Hermes process by
environment only, and only when the thing that needs it is switched on. It is never
written into a profile file or sent to the window or a phone; they are only told which
names have a value. **Forget** removes it.

**On the command line**, `black-team hermes tools|skills|plugins|mcp|key` lists and
switches the same things (`black-team hermes --help`).

### Running a conversation

Black Team creates a private Hermes profile for each Agent conversation. It pins
the model and compression provider to the selected local endpoint and uses its
own plugin plus the ones you switched on. It does not copy your normal Hermes profile or
its provider credentials. Replies and tool events are saved with the conversation; the
Hermes session ID lets the next message continue the same session. Start a new Agent
conversation when changing models or workspace. Changes to the lists apply to new
turns.

- File publishing attaches snapshots from the workspace for private download.
  The plugin can request a Taildrop transfer to an owned device after an approval.
- Browser tools are opt-in and use Hermes's local browser backend. Install its
  supported browser tooling separately. Browser navigation accesses websites.
- Desktop control is opt-in and requires Hermes's computer-use driver. Wayland
  support depends on that driver and the target app; it is not universally verified.

Approval requests show the action and allow **Approve once** or **Deny**. They
expire; mismatched/expired responses are rejected. Closing a phone does not grant
approval. Plugin tools and Hermes determine which actions request approval; this
is not a promise that every file edit or read asks first.

Tools act as your OS user, and the workspace is not an OS sandbox. Switches
control available toolsets, not process isolation. Give the agent only the access
you intend. File publishing restricts attachments to the workspace and blocks
common credential names, but it is not a universal sensitive-data classifier.
Skills, plugins and MCP servers are software you choose to trust: they run as you.

A turn has a 48-step / 30-minute budget. Stop cancels the owned agent process group;
a subsequent instruction can resume the saved session. The host must stay open.
There is no unattended retry loop or automatic restart of interrupted work.

## Agents found on this computer

The Workspace page lists the agents Black Team finds on your command path.
**Connect** saves a launcher for one in a single step; **Open** then starts it
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
version supports your local server. Black Team does not install them, rewrite
all their profiles, promise compatibility with every model, or mirror their
independent terminal sessions into Phone Companion. The built-in Black Team Agent
provides the integrated phone tool/approval experience.

CPU/RAM readings reflect the whole computer. External jobs are not part of Black
Team's busy/cancellation tracking. Stop those jobs before stopping an app-owned
model or changing connections. Use an existing independent model server if it
must remain available after Black Team closes.
