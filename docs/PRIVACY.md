# Privacy and execution boundaries

Black Team has no analytics integration, hosted chat backend, advertising scripts,
online license check, or automatic cloud model fallback. Fonts and artwork are
packaged locally. A Black Team account is not needed.

## Cloud models

Both apps can use a **cloud model**: an OpenAI-compatible service you name, reached over
HTTPS with your own API key (on Linux since 0.1.0-alpha.20). Nothing changes until you save a cloud
model. Privacy then travels with the work, not with a section of the app, and the rule is enforced by
the engine, which is the same program on Mac and Linux. Where this section says "this Mac", read "this
computer" on Linux:

- **Every conversation has a level**, shown at all times: `local` (nothing in it is sent off this Mac,
  the default) or `cloud` (it may be sent to the service named on it). The level is fixed by the model
  a conversation is started with. Before the first send of a new cloud conversation the app lists what
  will leave: your messages and pictures, and in Code the contents of any file the agent reads, the
  output of any command it runs and the path of the workspace folder.
- **Local never silently becomes cloud.** A message in a local conversation is refused while a cloud
  model is selected. You may start a new cloud conversation, switch back to a local model, or send the
  conversation to the service after a confirmation that names it and says all of it will be sent. A
  cloud conversation continued with a local model runs locally but stays marked cloud, because its
  history was sent. A cloud conversation is also refused for a different service until converted again.
- **Projects** are local only until you allow cloud models in one (its menu, confirmed once). Cloud
  models are refused for conversations inside a local-only project.
- **Memory stays local.** A cloud conversation gets no Core, no recalled notes and no `remember` or
  `recall` tools; nothing is written to the vault from it, including the Code journal. Converting a
  conversation removes the Core and recalled notes already in it. Memory tidying (which asks a model to
  rewrite notes) refuses to run while a cloud model is selected.
- **A phone** may continue conversations but cannot start one with a cloud model, convert one, or choose
  a model; it is refused with the same words as the desktop app. A phone also cannot add or change a cloud
  model or its key, allow cloud models in a project, change what a subscription agent may do, or use the
  Room.
- **Keys** live in the private `config.json` and saved-models file (owner-only), are never shown again,
  never sent to a phone, never put in conversations or logs, and are removed from error messages. A key
  is sent only to the host it was entered for; if the saved address's host changes the key is cleared.
  A local server's key never becomes a cloud key. Redirects are refused.
- **Addresses** must be `https` with a real host name: not `localhost`, not an IP address in any
  spelling, not a name ending `.local`, `.lan`, `.internal` and the like, and no credentials, query or
  fragment. Local sources still accept only loopback.
- **Requests** carry standard fields only (no llama.cpp extras). Token counts from the service's own
  `usage` are shown per cloud conversation. Prices are not.
- **Harnesses** (Claude Code, DeepSeek Harness and the rest) are not launched against a cloud model.

What this does not cover: the service's own retention and training policy (read it); what a model says
back, which is saved locally; and a model that quotes vault text it was shown in a *local* turn before a
conversation was converted (only the vault text Black Team itself attached is removed). A host name that
resolves to a private address is not detected. Anyone with your OS account can read the key file.

## Models and harnesses

For every model that is not a cloud model, the app sends model requests only to configured loopback HTTP endpoints. Its
owned llama.cpp process uses a fresh private key and is checked for model identity
and authentication. Startup clears inherited inference overrides; stop affects
only that owned child. A selected executable is trusted software running as you.

Existing local servers and external harnesses remain independent programs. They
may have cloud model routes or online settings of their own. A loopback URL alone
cannot prove all inference remains local. Select locally downloaded models and
verify the provider in each harness. Black Team never silently replaces a failing
local connection with a hosted one.

Black Team Agent creates separate Hermes profiles, pins the main and compression
model to the selected endpoint, and does not copy normal Hermes profile secrets.
Unrelated provider keys are excluded from the launch environment. Hermes and
installed browser/desktop tools still have their own behavior and dependencies.
Choosing **Get a model** contacts Hugging Face only when you ask. A search sends
your search words to huggingface.co; opening a repository asks it for the file list
(sizes and checksums); a download fetches the file from huggingface.co and its
download servers (hf.co), and the llama.cpp program from github.com if it is not
installed yet. No account, token or cookie is sent, nothing else is sent, and
redirects to any other host are refused. Ranking the models for this computer reads
its hardware locally and contacts nothing. Models there are made by other people.
There is no universal network sandbox. Browsing, tool commands, downloads and
explicit transfers can access external services.

**Set up your agents.** The setup card connects agents already on your computer
and can install Hermes Agent. It does nothing until you press Approve (or answer
yes to `black-team setup`); looking at what is on your computer only checks for
files. Connecting an agent only saves a launcher in Black Team's settings. The
Hermes install, and only that, contacts the internet, and only after approval:
github.com (one fixed, checksum-checked source archive of Hermes Agent, which
GitHub serves from codeload.github.com), the Python package index (pypi.org and
its file host) for Hermes's Python packages, and, if you have no Python 3.14 and
use uv, github.com again for a Python build. Nothing about you or your
conversations is sent; these are ordinary downloads. Everything lands in Black
Team's own data folder (`hermes/`). Your own `~/.hermes` and any Hermes you
installed yourself are not touched. Agents that are not installed are listed with
their makers' install commands as text; Black Team never runs those.

Agent tools run as the OS user. The selected workspace is not a filesystem
sandbox. Toolset switches and approval cards control application behavior, not
all capabilities of a local process. The file publishing plugin limits attachments
to the workspace and rejects common credential paths; it cannot identify every
sensitive document. Only publish intended deliverables.

## Local storage and desktop

Configuration, server keys, chat history, agent sessions, the memory vault,
project list, undo records and artifacts live under
`~/.local/share/black-team-data` (or an absolute `XDG_DATA_HOME`). They use private
directories and owner-only files. They are **not application-encrypted**. Your OS
account, disk encryption and backups still matter. Other processes running as the
same user can read your files and process environment.

If you turn on "Keep Black Team running in the background" (off by default, see
[Background service](SERVICE.md)), your engine keeps running when the window is closed. It runs
as you, listens only on `127.0.0.1` (the same listener the window uses), and writes one extra
private file, `service.json`, holding that run's loopback port and a secret made fresh for each
start; whoever can read it can do what the window does, so it is `0600` in the `0700` data
folder and refused if wider. Scheduled work runs only what you scheduled, at the level you
chose; a step that needs your yes waits for you and ends "not approved" if nobody answers.
Schedules, the inbox and the service's settings are stored in the data folder like the rest.
The service sends nothing anywhere that the window would not; a scheduled run with a cloud
model follows the same cloud rules as any conversation.

Server keys are excluded from renderer status responses, phone responses and
harness command arguments. The runtime/harness receives the needed local key
in its private configuration/environment. Keys are not a protection against other
software already running as your user.

The Electron renderer uses sandboxing, context isolation, no Node integration,
and a small bridge restricted to its main frame. Remote renderer requests,
popups, navigation, webviews and browser permission requests are denied. Model
and harness configuration is available through desktop IPC rather than phone APIs.

## Memory and Code

The [memory vault](MEMORY.md) is read and written only by Black Team, for your
local models. Its contents are sent to one place: the local model endpoint you
configured, as part of a prompt. Black Team Code cannot read the data folder as
files and asks before running a command that names it. Other programs running as
your user, including hosted coding assistants, can still read those files; keep
them out of that folder if you want the vault to stay local-only.

Black Team Code edits files only inside its workspace, records what each file
held before an edit so the change can be undone, and keeps the 300 most recent
records. Those records contain file contents. Dictation, when you use it, is
done by the system tool you installed; Black Team only starts and stops it.

## Phone and optional services

Phone access uses Tailscale Serve with saved account identity plus a paired browser
cookie. Black Team does not enable Funnel or public hosting. Phone users can use
Chat and any Agent tools enabled by the desktop owner. They can read agent output,
approve actions and download attached files. Pair trusted devices only.

The browser caches static app assets rather than chat/API responses. Content can
still be viewed, copied, screenshotted or downloaded on authorized devices.
Tailscale's coordination, account and network infrastructure are outside Black Team.

JEV is disabled in chat and Agent work. The optional synthetic research runner
makes hosted requests only when explicitly invoked with the JEV provider and an
adapter/key. Its dedicated key file is outside the repository. No customer chats
or workspaces are used by that fixture runner. See [JEV.md](JEV.md).

This is an architectural description, not an independent security audit. See
[VERIFICATION.md](VERIFICATION.md) for completed tests and remaining live checks.
