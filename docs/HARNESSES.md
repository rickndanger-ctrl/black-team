# Harnesses and agent work

A model generates responses; a harness manages the conversation, tool calls,
context and execution around it. Black Team offers built-in Chat and Hermes-based
Agent work plus launchers for other locally installed harnesses.

## Black Team Agent / Hermes

Install [Hermes Agent](https://github.com/NousResearch/hermes-agent) and its needed
dependencies separately. In Settings, enable Black Team Agent, set the absolute
path to the Python interpreter used by that Hermes installation, and select its
source directory (containing `hermes_bootstrap.py`). These are your own paths;
no developer home directory or preinstalled model is assumed. Optional browser
and computer-use executable fields let you point at the dependencies you have
installed when Hermes cannot discover them from its isolated profile.

The adapter was written against the APIs present in Hermes checkout
`158fd638da1629c8e62caf9ade1515d162def8ab`. Other versions may change internal
interfaces. The host uses `HermesCLI`, session ownership, `StreamJsonEmitter`,
plugin approval transport and terminal/computer approval callbacks. The portable
host has mocked lifecycle tests; live compatibility still needs verification.

Configure tools on the desktop, then choose **Black Team Agent · Hermes tools**
in a new conversation on either desktop or phone. A model must support the
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

## External harness launchers

Install your chosen harness and configure its local provider first. Then add a
launcher in Settings. A launcher contains:

```json
{
  "id": "my-local-client",
  "name": "My Local Client",
  "executable": "/home/you/bin/my-local-client",
  "args": ["--model", "{model}", "--base-url", "{endpoint}"],
  "terminal": ["/usr/bin/xterm", "-e"]
}
```

This is an example schema, not a universal CLI command. Replace arguments with
those supported by the installed client or your wrapper. A GUI executable can
use `"terminal": []`. CLI clients generally need a terminal prefix. All executable
paths must be absolute and executable. Arguments are literal; no shell expansion
or pasted shell command is evaluated.

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
