# Privacy and execution boundaries

Black Team has no analytics integration, hosted chat backend, advertising scripts,
online license check, or automatic cloud model fallback. Fonts and artwork are
packaged locally. A Black Team account is not needed.

## Models and harnesses

The app sends model requests only to configured loopback HTTP endpoints. Its
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
There is no universal network sandbox. Browsing, tool commands, downloads and
explicit transfers can access external services.

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
