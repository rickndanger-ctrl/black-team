# Portable alpha verification

Version reviewed: **0.1.0-alpha.17**. This source includes the local server,
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
and are not clickable. This fix is in alpha.5 and is covered by parser tests and a
rendered check at desktop and phone widths; the alpha.4 package does not have it.

The alpha.5 package was built and put through the same clean-home test on the
same day: checksums verified, the installer ran, first-run setup connected to
the local server, Code wrote and ran a file and saved a fact in 50 seconds with
its reply shown formatted, and Chat recalled the fact in 9 seconds. No page
errors.

Not covered by these runs: a separate Linux account or another machine, an
owned GGUF runtime or Ollama/LM Studio with Code, trimming and approvals during
a long real task, model condensing by a real model, and dictation with a real
speech tool.

The package's Electron sandbox helper is not installed setuid root, so the app
relies on unprivileged user namespaces, which Ubuntu 24.04 and later deny to
programs without an AppArmor profile. From alpha.6 the installer and launcher
detect this, explain it, and offer `--enable-sandbox`, which installs one
profile through `sudo`. This was tested with simulated kernel settings, and the
generated profile compiles with the AppArmor 4.0.1 parser from Ubuntu 24.04. It
has not been run on an Ubuntu machine, so whether the window then starts there
is still unconfirmed.

The alpha.6 package was built and put through the clean-home test on
2026-10-11: checksums verified, the installer ran, the window started as before
on this unrestricted laptop, Code wrote and ran a file and saved a fact in 67
seconds, and Chat recalled it in 12 seconds, with no page errors. With the
Ubuntu restriction simulated against the installed package, it reported the
blocked sandbox and printed the `--enable-sandbox` instruction.

## Live follow-up — October 11, 2026 (alpha.7)

Four changes merged after alpha.6, each checked from source before the package
was built:

- **Saved models and switching.** Each model set up joins a list; with two or
  more, the chat header is a menu and Settings lists them with Use and Remove.
  Driven in headless Chromium against the real backend and config store with a
  scripted model server: switch from the header, replies labelled by model,
  switch back, remove.
- **Agents found on the computer.** The Workspace page lists the agents on the
  command path with one-step Connect and Open. For Claude Code 2.1, Codex 0.162,
  Pi, OpenCode 1.19 and DeepSeek Harness 0.2, the settings Black Team builds were
  run through each real program against a logging stand-in server, and each sent
  its request to the given local address with the given model and key. A full
  session through a real model was not run for each; Aider was not installed.
- **Model finder and first-run flow.** On this laptop it found the running
  llama.cpp server on a non-standard port with its 65,536 context and two GGUF
  files, skipping three helper files. The two-step first run was driven against
  the real backend and the real finder. Ollama, LM Studio, Jan and KoboldCpp were
  not running; their handling is covered by scripted tests. Starting a found
  GGUF file through Black Team's own runtime was not run.
- **Computer readout.** Physical cores and threads, clock, temperature, memory
  the kernel can hand out, swap, the model server's own memory and usable disk
  space, checked against `lscpu`, `/proc/meminfo`, `df` and the model process's
  status on this laptop.

Automated suites at the build: 136 Node and 22 Python tests pass.

The alpha.7 package was then installed into an empty home folder with a
stripped environment and driven through its real window on the same laptop:
checksums verified; the first screen listed the running llama.cpp server with
its 65,536 context, already ticked; Add took it to step two, which listed Black
Team Code (no other agents are on a bare path); Start chatting opened the
conversation. In a new project, Code wrote and ran a file and saved a fact in 62
seconds with the reply labelled by model and shown formatted; the Memory graph
showed three notes; Chat recalled the fact in 15 seconds; Settings listed the
model as in use and the finder marked it as already saved; the Workspace cards
showed the model server holding 26.3 GB. No page errors.

## Live follow-up — October 11, 2026 (alpha.8)

Four changes merged after alpha.7, each checked from source:

- **Vault ready on first start.** A new vault gets its folders and a Core note
  holding only guidance, which the model never sees; the Memory page explains
  the flow until Core is written. Rendered against the real backend with a fresh
  data folder, including writing Core through the page.
- **Code map (graphify).** With graphify 0.9.85 installed, Code asked the map
  where risky commands are approved and answered correctly (`lib/tools.cjs`, the
  `run` tool, line 157) in 152 seconds on the llama.cpp server; the map was
  written under the data folder, not the project.
- **Thinking level.** The mode selector now carries the thinking controls. On
  the llama.cpp server, Off answered 17×23 in 4 tokens with no reasoning;
  Standard produced reasoning first (73 tokens in all).
- **Found models offered on the home page.** With Ornith saved by hand, the
  home page offered the two Qwen files on the laptop; Not now hid one and Add
  listed the other without changing the model in use.

Automated suites at the build: 140 Node and 22 Python tests pass.

The alpha.8 package was then installed into an empty home folder with a
stripped environment and driven through its real window on the same laptop:
checksums verified; the first screen found the running llama.cpp server; Add
took it to step two and the vault already held `Core.md`, `Notes/`, `Projects/`
and `Archive/`; the Memory page showed the introduction; the Chat / Code page
showed the Thinking selector at Standard. In a new project, Code (thinking on)
wrote and ran a file and saved a fact in 84 seconds with the reply labelled and
formatted; the Memory graph showed four notes; Chat recalled the fact in 31
seconds; Settings showed the Code map card reporting graphify not installed,
as a bare path has none. No page errors.

## Live follow-up — October 11, 2026 (alpha.9)

One change merged after alpha.8: the launch plan for model files. The
llama-server build's help is read once and each setting is added only when that
build understands it: physical-core threads, smaller CPU batches, a 1 GiB prompt
cache, an eight-bit KV cache with flash attention, the vision projector and a
draft model found beside the file. Files are named from their own GGUF metadata
and offered a context that fits beside their weights. Checked with unit tests
(launch plan, GGUF reader, finder, desktop wiring) and a dry plan for the
laptop's Qwen 3.8 27B file with the mainline llama.cpp build, which matched the
user's hand-tuned launch in substance.

The plan was then run for real on the laptop, with the usual model server
stopped so the file fit in memory. Through the same `ModelRuntime` code path
the app uses, the finder's description of the Qwen 3.8 27B Q4_K_XL file
(32,768 context, 6 threads, projector and MTP draft found beside it) started
the mainline llama.cpp build 11390 with all four planned features; the server
was ready in 17 seconds the first time and 5 seconds warm, reported the same
model file and 32,768 context, enforced the private key, and the process used
23.8 GiB. Two chat completions answered correctly and the runtime stopped
cleanly. On a 1,063-token prompt it processed 5.1 tokens/s and generated 1.36
tokens/s; without the draft file, 5.1 and 1.27. The user's own hand-tuned
launch of the same file on a different (forked) llama.cpp build measured 6.1
and 2.34 on the same prompt, so the plan runs the model well for a mainline
build but a specialised build is still faster at generation. That forked build
also rejects `--no-webui`, which the plan always passes, so it cannot be used
as Black Team's runtime; the finder only proposes a running server's executable
when no `llama-server` is on PATH.

That was fixed before the package was rebuilt: `--no-webui`, `--alias` and
`--n-gpu-layers` are now added only when the build's help lists them (with
`--webui none` for builds that take a value, and `-ngl` for that spelling), a
help text without `--port` keeps the basics because the build could not be
asked, and a build whose help shows `--spec-type mtp:...` gets the model's own
MTP heads enabled instead of a draft file it cannot load. Run live through the
same `ModelRuntime` path, the forked build then started the Qwen file with
"6 threads, q8 cache, vision, MTP", was ready in 2.6 seconds warm, enforced the
private key, and answered the same prompts at 6.5 tokens/s prompt and 2.0
tokens/s generation, matching the user's hand-tuned launch. The mainline build's
plan is unchanged.

Automated suites at the build: 145 Node and 22 Python tests pass.

The alpha.9 package was rebuilt with that fix and installed into an empty
home folder with a stripped environment, then driven through its real window
on the same laptop: checksums verified; the payload holds the corrected launch
plan; the first screen found the running llama.cpp server, already ticked, and
one click added it; step two named it ready; in a new project, Code (thinking
at Standard) created `greeting.txt` with the exact requested line and saved the
requested fact to the vault in 80 seconds without asking for an approval; a
fresh Chat recalled the fact in 7 seconds, citing the memory note it used; the
Memory page listed the project's conversations; Settings showed the Code map
card and the saved model; the Workspace cards showed the model server's 24.5
GB. The vault held `Core.md`, the project's Overview and Journal and the saved
note. One console error appeared on every load: the page's own inline theme
script is blocked by its Content Security Policy (`script-src 'self'`), so the
saved theme is applied a moment later by the app instead of before first paint.
It does not affect function; a fix is to allow that script's hash.

## Live follow-up — October 11, 2026 (alpha.17)

One change after alpha.16, on macOS only: a **permission level** for each
subscription-agent conversation, and **signing in from Black Team**. The Linux
code is unchanged.

- Ask: Claude Code runs in its manual mode; what it is refused becomes an
  approval card, and what is allowed is resumed with `--allowedTools` naming
  exactly that command or file, for that resume only. Nothing outside the
  project folder can be approved. Codex cannot ask from inside another program,
  so Ask makes it read-only.
- Edit (the default): Claude Code `acceptEdits`, which also runs simple file
  commands such as `touch`; Codex `workspace-write`.
- Auto: Claude Code's own `auto` mode; Codex `--approve-for-me`.
- Neither tool is given a skip-permissions flag. Snapshot and roll back apply at
  every level.
- A signed-out tool is reported as such, with a button that opens the tool's own
  sign-in in Terminal.

Automated suites at the build: 148 Node and 22 Python tests pass on Linux; 427
Swift tests pass on macOS.

Checked live on a Mac mini with the real tools, run inside the logged-in
Terminal from the command line: Claude Code in Ask created a file after
approval; in Auto it ran the command; Codex in Auto created a file and a
resumed follow-up created another; Codex in Ask could not write and said so.
The owner then used the Permission select in the app; a completed Claude Code
conversation with its level saved (Edit) was found in the app's data before
this release.

Not checked: Ask and Auto chosen from the app's own select (only Edit was seen
there); the sign-in button and signed-out detection against a really expired
login; compound commands in Ask.

Subscription agents must not be tested by running Claude Code over SSH on a
Mac: with the keychain locked it renews its login into a file and the keychain
copy goes stale. That happened once during this work and the owner had to sign
in again.

## Live follow-up — October 11, 2026 (alpha.16)

Two changes after alpha.15, both on macOS. The Linux code is unchanged; the
Linux package differs from alpha.15 only in its version and documents.

**OpenRouter models work.** In alpha.15 every message to an OpenRouter model
failed with "not a valid model ID": the model search sent Anthropic-style
headers to every service, and OpenRouter answers those with a list whose names
its chat route rejects. The headers now go to Anthropic only. Checked live with
the owner's key: the search returned real ids, and a free model (Nemotron 3.5
Lightning) answered a Chat message and completed a Code step that edited a
file. The owner then used the same free model in the app on a second Mac mini;
a completed cloud conversation with it was found in that app's data before this
release was made. A model saved with alpha.15 has the wrong id and must be
chosen again.

**Subscription agents.** Black Team can hand a task to the person's own Claude
Code or Codex command-line app, under their subscription and its own saved
login. A run counts as a cloud conversation and passes the same gate (local-only
projects, no silent conversion, not from a phone, nothing from the memory
vault). The project folder is archived first so a task can be rolled back.
Checked live on a Mac mini from the command line with the real tools: Claude
Code fixed a file, a follow-up resumed the same session and roll back restored
the file; Codex fixed a file and ran it to confirm; both were saved as cloud; a
run from a local conversation was refused before any tool started.

Automated suites at the build: 148 Node and 22 Python tests pass on Linux; 409
Swift tests pass on macOS.

Not checked: the app's own screens for subscription agents (the model select
entries, the notice and the roll back button) have not been looked at or
driven by anyone; the 30-minute run limit; OpenAI, Anthropic and Google cloud
models directly; image attachments to a cloud model.

## Live follow-up — October 11, 2026 (alpha.15)

One change after alpha.14, on macOS only: **cloud models you bring yourself**.
A person can add an OpenAI-compatible cloud service by its HTTPS address, their
own key and a model id (presets for OpenRouter, OpenAI, Anthropic and Google).
Privacy is a rule the backend enforces: every conversation is local or cloud;
a local one is never sent to a cloud model without a conversion that names the
service; projects are local only unless switched; the memory vault is not used
in cloud conversations; a phone cannot start or convert one. The picker can
show only free models that can use tools. See `docs/PRIVACY.md`. The Linux code
is unchanged; the Linux package differs from alpha.14 only in its version and
documents.

Automated suites at the build: 148 Node and 22 Python tests pass on Linux; 361
Swift tests pass on macOS, 40 of them for cloud models. They assert on the
request bodies themselves: no vault text, no memory tools, no llama.cpp-only
fields.

Checked on a Mac mini with a throwaway data folder against a stand-in server:
Chat and Code turns from the command line, a file edited through the stand-in's
tool calls, usage totals, and the retries that learn what a service rejects.
The variable that lets tests use a stand-in address is read only by the
command-line tool and is absent from the app binary.

The first real use, by the owner with a free OpenRouter model, failed: every
message was rejected as "not a valid model ID". The cause was in Black Team:
its model search sent Anthropic-style headers to every service, and OpenRouter
answers those with a different list whose names its chat route does not accept.
Those headers now go to Anthropic only. With that fix and the owner's key, a
free OpenRouter model (Nemotron 3.5 Lightning) answered a Chat message and
completed a Code step that edited a file. That is the only real service tried;
OpenAI, Anthropic and Google have not been tried directly, nor image attachments
to a cloud model. alpha.15 as released has the fault. (An earlier version of
this note said the owner had used a free model successfully before release;
that had not happened.)

## Live follow-up — October 11, 2026 (alpha.14)

One change after alpha.13, on macOS only: **image attachments in Chat**. Up to
four pictures per message, by "+ Files", drag and drop or paste. Each is scaled
to 1280 on its longer side and stored as a JPEG without metadata under
`attachments/` in the data folder; the conversation keeps a reference only, and
a paired phone is sent the text alone. A GGUF model needs its projector file:
the starter list names one for Ornith 1.5 9B and Qwen3.5 0.8B and 4B, and
attaching a picture offers the download and restarts the model with it. The
Linux code is unchanged; the Linux package differs from alpha.13 only in its
version and documents.

Automated suites at the build: 148 Node and 22 Python tests pass on Linux; 321
Swift tests pass on macOS, 42 of them for images.

Checked live on a Mac mini. From the command line, Qwen3.5 0.8B answered "A red
circle." and "blue rectangle"; Ornith 1.5 9B with its own vision file answered
"A green triangle." and read "HERON 4721" from a picture of text. A 4000×3000
picture was stored as 1280×960; stored files were JPEG, mode 0600, with no EXIF
or GPS tags, and the conversation files held no image data. In the app's own
window with Ornith 1.5 9B: pasting a picture showed its preview, removing it
worked, sending got "It is a green triangle.", and Code mode had no image
button. With no vision file, the notice appeared, the 922 MB download ran with
progress, the running model restarted with the projector, and the next picture
was read correctly. Image cost on llama.cpp measured about one token per 32×32
pixels (1,614 for the largest picture sent); 1,700 is allowed per picture.

The owner then used image attachments in the app on a second Mac mini and
reported that they work. The Qwen3.5 4B vision file has not been downloaded or
tried. There are no image attachments from a paired phone.

## Live follow-up — October 11, 2026 (alpha.13)

One change after alpha.12: the Thinking selector in the web interface names its
levels as the Mac's "Set the pace" does, Fast, Balanced, Deep and Extended. It
used to say "Off · fastest" and "Standard". The values sent to the model are
unchanged. The web interface is shared, so this shows in the Linux window and
on a phone paired with either a Linux computer or a Mac.

Automated suites at the build: 148 Node and 22 Python tests pass on Linux; 279
Swift tests pass on macOS.

Checked: the interface a Mac serves to a paired phone was fetched over the
tailnet and carried the new names; the owner then confirmed on a physical
iPhone that the selector reads Fast. The Linux package was installed as an
update over alpha.12 and its window opened on the first-run screen.

## Live follow-up — October 11, 2026 (alpha.12)

One change after alpha.11, on macOS only: **private phone access**. The Mac app
serves the web interface on 127.0.0.1:18199 while phone access is on, and
Tailscale Serve publishes it on the tailnet on HTTPS port 8449, as on Linux. The
Linux code is unchanged; the Linux package differs from alpha.11 only in its
version and documents.

Automated suites at the build: 148 Node and 22 Python tests pass on Linux; 279
Swift tests pass on macOS, 53 of them for phone access (wrong Host, wrong
Origin, non-loopback peer, missing or wrong Tailscale login, unpaired cookie,
wrong pairing secret, route not connected, access off, oversized body, path
traversal, and a phone calling a route it must not).

Checked live on a Mac mini with a throwaway data folder, from a laptop on the
same tailnet: the page loaded; an unpaired `/api/status` was refused (401); a
wrong pairing secret was refused (401); a request without an Origin was refused
(403); the right secret paired; the paired status held no model key, file path
or desktop setting. A phone-sized headless Chromium paired from the link, the
fragment left the address bar, and a chat message got the model's reply. After
a pairing reset the old cookie and old link were refused. From the real app
bundle, Enable private phone access created the route and a listener on
127.0.0.1 only, and Turn off, after its confirmation, removed both. The Mac's
other Tailscale Serve routes were identical before and after.

The owner then paired a physical iPhone with the app on a second Mac mini and
reported that it works. Android has not been tried. Notifications and sending
files by Taildrop are not part of the Mac app.

## Live follow-up — October 11, 2026 (alpha.11)

Changes after alpha.10:

- **DeepSeek Harness launch.** The preset started it with a profile named
  `terminal`, which exists only where a separate add-on has been installed; an
  ordinary install exited at once. It now starts the built-in `web` profile on a
  port Black Team picks. Black Team opens the page when it answers, unless the
  harness guards the page (it answers 401 or 403), in which case the harness
  opens the browser itself.
- **Logo.** The wordmark reads `/BLACK TEAM`.
- **macOS.** A native Swift app is in `macos/`; see `macos/README.md`. It is
  packaged separately from the Linux archive.

Automated suites at the build: 148 Node and 22 Python tests pass.

The alpha.11 package was checked as an update: in an empty home folder with a
stripped environment, the alpha.10 package was installed first and the alpha.11
installer run over it under the same prefix. It switched `current` to alpha.11
and left `previous` on alpha.10. The installed app was driven through its real
window on the same laptop, with DeepSeek Harness 0.2.0-rc.2 on the PATH: the
first screen found the running llama.cpp server and one click added it; the
agents list showed DeepSeek Harness and Connect turned into Open; Open started
`dsh --profile web --patch … --port <n>` in a terminal, the app reported
"DeepSeek Harness opened with" the model's name, the harness's plain address
answered 401, and one browser window titled DeepSeek Harness opened, from the
harness itself.

Not checked in this pass: a task sent through the DeepSeek Harness page to the
model, Chat and Code in the installed alpha.11 window (unchanged since
alpha.10), and DeepSeek Harness versions older than 0.2 on Linux.

## Live follow-up — October 11, 2026 (alpha.10)

One change after alpha.9: the theme bootstrap that applies a saved theme
before first paint moved from an inline script in `index.html` to
`public/theme.js`, loaded with an ordinary script tag and served by the local
backend from the same origin. The page's Content Security Policy is unchanged
(`script-src 'self'`); it no longer blocks anything of the page's own, so the
console error on every load is gone and a Light or Ghost theme is in place
before the app mounts. A new test keeps the page free of inline scripts and
inline event handlers and checks the bootstrap's saved, missing, unknown and
blocked-storage cases. Checked live with the source app over the DevTools
protocol: no console errors, `theme.js` served as JavaScript, and after saving
Light the attribute already read `light` while the document was still loading.

Automated suites at the build: 148 Node and 22 Python tests pass.

The alpha.10 package was then checked as an update: in an empty home folder
with a stripped environment, the alpha.9 package was installed first and the
alpha.10 installer run over it under the same prefix. It verified the payload,
staged the release, switched `current` to alpha.10 and left `previous` on
alpha.9. The installed app was driven through its real window on the same
laptop: no console errors on load (the page has no inline script and loads
`theme.js`); the first screen found the running llama.cpp server, already
ticked, and one click added it; in a new project, Code (thinking at Standard)
created `greeting.txt` with the exact requested line and saved the requested
fact in 61 seconds without an approval prompt; a fresh Chat recalled the fact
in 7 seconds, citing the memory note, and the stored reply read exactly "The
project codename is Heron."; the Memory page listed the project's two
conversations; Settings showed the Code map card; the Workspace cards showed
the model server's memory; choosing Light and reloading showed the attribute
already set to `light` while the document was still loading. The vault held
`Core.md` and the project's Overview, Journal and saved note.

## Still outstanding

- Installation under a separate account, on another machine and on other Linux
  distributions; the `--enable-sandbox` step on a real Ubuntu 24.04 machine; a
  simpler download/install experience.
- Live Ollama/LM Studio startup; owned GGUF startup on a GPU, with other models and other llama.cpp builds.
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
