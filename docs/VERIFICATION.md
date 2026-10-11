# Portable alpha verification

Version reviewed: **0.1.0-alpha.4**. This source includes the local server,
configurable harness, performance, Black Team Code, the memory vault, projects
and optional Hermes work added for the public Black Team project. It is separate from the older machine-specific installation.

## Automated checks

The production React/Vite build passes. There are 112 passing JavaScript tests
and 20 passing Python tests in this review. The suites cover:

- Per-user configuration, header/runtime validation, restricted file permissions,
  owned model process start/stop/authentication, cancellation and failure handling.
- Loopback-only existing server URLs, model discovery, optional authentication,
  exact selected model IDs, key redaction and non-destructive disconnect.
- Local tokenizer context budgeting for owned llama.cpp; explicitly labeled byte
  estimates for generic servers; protected input and complete-turn trimming.
- Harness launch argument boundaries and local provider environment; invalid
  integration settings and unknown harness rejection.
- Hermes profile/model/compaction configuration, correlated approvals, events,
  session resume, process-group cancellation and temporary query cleanup with a
  mocked Hermes subprocess. These do not prove live Hermes/model compatibility.
- Agent-vs-chat routing, public job serialization and saved conversation kind.
- Black Team Code with a scripted model: the tool loop, append-only history,
  speed-derived budgets, trimming at step boundaries, overflow retry, the
  stuck-call guard, approvals bound to one command, stop, key redaction,
  workspace-confined writes, credential and private-data refusal, diffs and
  ordered undo, and search without ripgrep.
- The memory vault: path confinement, links and graph, dated facts by project,
  journals, chat lookup that stays quiet without a real match, limits, archive
  sweeps and model condensing that keeps the original.
- Server routes for memory, projects, undo and dictation; Core and recalled
  lines replayed unchanged across turns; the keeper using only a loaded model.
- Host/origin checks, desktop/phone authentication, private route isolation,
  streaming parsing, durable request IDs, persistence and interrupted recovery.
- Electron bridge sandbox and action allowlists using mocked Electron.
- Installer upgrade/rollback, checksums, payload allowlist and unsafe archive/asset
  rejection using fake runtime archives.
- Synthetic context experiment policy/response checks. No hosted JEV call is
  required by or made during the normal test suite.

## Live follow-up — October 10, 2026

A fresh GitHub clone completed npm installation and production build. The real
Electron 44.7.0 app and an isolated packaged installation both launched. The
archive checksum and all 110 payload hashes matched; installation into a path
containing spaces succeeded. Installer upgrade/rollback checks also passed.

Desktop controls discovered and connected an existing llama.cpp model server.
Real local chat succeeded. A custom external harness launched through Black
Team's provider environment and obtained the expected response from that model.
This does not establish compatibility with every third-party harness.

The real Hermes host created and read workspace files. Cancellation stopped its
process group in 1.55 seconds, and resuming preserved the saved session and prior
conversation. A fix shares installed Hermes dependencies instead of reinstalling
several gigabytes per conversation, while retaining separate conversation state.
One model turn selected an incorrect nested path and added an unwanted newline;
model task accuracy remains a limitation.

Desktop phone setup enabled a separate private Tailscale route. A remote Mac
client verified pairing, reconnect, and rejection of unpaired, wrong-key,
cross-origin and direct-network access. Automated checks cover cookie persistence
and revocation. This is remote-client evidence, not physical phone certification.

## Guided setup review — October 10, 2026

The revised desktop was opened with an isolated fresh application profile. Real
Electron UI controls were exercised through Clawd Cursor's DOM interface:

- Four model connection choices, local server discovery, model selection, and
  Save and open chat.
- Installed Hermes detection and one-button connection, followed by its Connected
  state and direct Agent conversation action.
- A detected Codex launcher was added and saved without typing paths or JSON.
  This checks launcher setup, not Codex's local provider compatibility.
- One-button phone setup detected the current Tailscale computer/account and
  prepared the pairing QR/link on the separate portable-app route.

New automated checks cover bounded installation discovery, incomplete installs,
virtual-environment interpreter identity, phone setup and disabled-access cleanup
failure, retry after an unsuccessful pairing exchange, native action locking and
fixed installation-help destinations. The real UI retained an unsent Agent draft and its work mode after visiting
Settings and returning to Conversations; uncertain sends retain their request identity and
prevent switching to a different conversation until resolved.

These checks do not certify visual layout or physical phone scanning. The earlier
packaged archive predates this UI revision; it must be rebuilt and checked before
shipping the new flows as a binary. The [product principles](PRODUCT-PRINCIPLES.md)
record the simplicity guideline and the remaining acceptance scenarios.

## Live follow-up — October 11, 2026 (alpha.4)

On one Linux laptop (CPU only), the portable backend was run without mocks
against an existing llama.cpp server holding a 35B Q4 model at a 65,536-token
context, connected as a local server.

- **Code:** asked to change a function in a small Python file, run it, report the
  output and save a fact. It searched, read, edited, ran and remembered in 57
  seconds; the file and the reported output (`15`) were correct. Measured 49
  tokens/s reading and 13 writing, using 1,998 of a 35,185-token working budget.
- **Memory:** the fact was filed under the project with a journal entry. A new
  Chat conversation asking about it was handed that one line and answered
  correctly in 6 seconds.
- **Undo:** undoing the recorded edit restored the original line.

The interface was also driven in headless Chromium against the same real
backend, with only the model scripted: creating a project from the sidebar, a
Code turn with two file changes, Undo, the memory graph and notes, Chat using
memory, Remember this, and the dictation button, at desktop and phone widths,
with no page errors.

The alpha.4 Linux package was then built and checked on the same laptop: both
checksums verify, the payload contains the engine, tools and memory modules and
the license, and the packaged app started with an empty data folder, opened its
window, created its vault and engine folders, answered 401 without a session and
403 for a foreign Host header, and quit cleanly.

The published alpha.4 release was then installed and used the way a new user
would, on the same laptop on 2026-10-11. This was an empty home folder with a
stripped environment, not a separate Linux account: nothing from the developer's
own setup was visible to the installer or the app.

- **Download and install:** both release files were fetched from GitHub and both
  checksums verified. `install.sh` installed the app, launcher and menu entry,
  and refused a second install of the same version.
- **First run:** the installed app opened its real window on the setup screen.
  It was connected to the llama.cpp server through "Another server", found the
  model, and saved a 65,536-token context.
- **Code in the packaged build:** in a new project, asked to write a script, run
  it, report the output and save a fact. It did all three in 53 seconds; the
  file and reported output were correct and the diff with Undo appeared.
  Measured 48 tokens/s reading and 12 writing.
- **Memory in the packaged build:** the Memory graph showed the project's notes,
  and a new Chat conversation recalled the saved fact and answered correctly in
  11 seconds.
- **Privacy on disk:** the data folder and vault were mode 700 and the
  configuration and phone key files 600. Nothing was written outside the test
  home. No page errors.

That run showed replies displaying Markdown as raw text (`**bold**`, code
fences). Replies are now formatted, by a small renderer that builds interface
elements from text and never inserts HTML; links are shown with their address
and are not clickable. This fix is in the source after alpha.4 and is covered by
parser tests and a rendered check at desktop and phone widths; it is not in the
alpha.4 package.

Not covered by these runs: a separate Linux account or another machine, an
owned GGUF runtime or Ollama/LM Studio with Code, trimming and approvals during
a long real task, model condensing by a real model, and dictation with a real
speech tool.

One risk is known and untested: the package's Electron sandbox helper is not
installed setuid root, so the app relies on unprivileged user namespaces.
Distributions that restrict them by default, such as Ubuntu 24.04, may refuse to
start it until the user allows that or the installer handles it.

## Still outstanding

- Installation under a separate account, on another machine and on other Linux
  distributions, including ones that restrict unprivileged user namespaces; a
  simpler download/install experience.
- Live Ollama/LM Studio and owned GGUF startup; other models and runtime combinations.
- Physical iPhone/Android Home Screen cookies, background/reconnect behavior,
  phone-triggered agent approvals and file downloads in this portable build.
- Real UI approval/denial of a model-requested risky tool, browser/desktop opt-ins,
  and additional named third-party harnesses.
- CPU/RAM readings compared against system measurements during sustained work.

The older machine-specific Camp's physical iPhone and image-upload results are
separate. Its local image customization is not included in this public source.

## Live release checklist

Use a clean Linux user account with the source dependencies installed. Configure
an owned GGUF and an existing server separately. Send a real streaming chat,
cancel, restart, change models and test context pressure. Confirm the configured
model receives requests and no unintended provider is used.

Configure Hermes using that user's own installation. Enable coding first; create
and read a harmless workspace file, approve/deny a prompted action, attach a
result, stop a turn and resume it. Then separately test browser/desktop opt-ins.
Confirm keys never appear in renderer status or logs. Launch at least two external
harnesses, checking each actually uses the chosen local provider. Check CPU and
RAM reporting during work; external jobs are not app-owned jobs.

Pair both an iPhone and Android phone. Verify correct-account plus paired-browser
access, wrong-account/unpaired rejection, agent approvals, private downloads,
reconnect/retry behavior, Home Screen install and revocation. Verify the computer
must remain awake and open for work to continue.

Package with a reviewed upstream Electron runtime, verify its upstream checksum,
then verify app archive checksums and fresh install/upgrade/rollback. Archives are
unsigned; SHA-256 checks integrity, not publisher identity. Do not label this
alpha production-ready, universally model-compatible, or multi-distro certified.

## Continuous integration template

The GitHub Actions build/test configuration is included as `docs/ci-checks.yml`.
It is a template and is not active. The publishing credential did not have GitHub's
`workflow` scope. To enable CI later, move this file to
`.github/workflows/checks.yml` using a GitHub session or credential permitted to
manage workflows. It builds the renderer and runs the automated suites without
downloading an Electron binary.
