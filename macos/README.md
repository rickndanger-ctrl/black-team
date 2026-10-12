# Black Team for macOS

A native Swift version of Black Team. The engine is a port of `lib/*.cjs` in this
repository, which stays the reference for behaviour. The interface follows the
maintainer's daily Black Team app: a Command center window (select your model,
choose your harness, set the pace, launch) and a Camp window (Chat and Code,
Memory, Plugins, DSH sessions, Servers & access).

## Layout

| Folder | What it is |
| --- | --- |
| `Sources/BlackTeamKit` | The app without a window: one folder per area, one Swift file per `lib/` module |
| `Sources/BlackTeamUI` | The SwiftUI interface |
| `Sources/BlackTeam` | The app entry point |
| `Tests/BlackTeamKitTests` | XCTest ports of `tests/*.test.cjs`, in the same area folders |
| `dev/mini.sh` | Builds and tests on a Mac over SSH from a computer without Swift |

## Conventions

- Swift language mode 5, macOS 14 or later, no third-party packages.
- A JavaScript factory such as `createMemory({vault})` becomes a `final class Memory`
  with the same method names. Plain objects with a fixed shape become `Codable`
  structs; data whose shape belongs to a model server or a tool call is `JSONValue`.
- Errors shown to the person are `BlackTeamError("…")` with the Linux app's wording,
  changed only where it names Linux.
- Anything a test must control (the clock, the network, a folder) is passed in with
  a default, as the JavaScript does.
- Files on disk keep the Linux app's names and JSON shapes, private to the user
  (folders 0700, files 0600), under `~/Library/Application Support/Black Team`.
- Comments say why, briefly, as in the JavaScript.

## What is in it

Chat, Code (the agent loop, tools, diffs with Undo, approvals), the memory vault,
projects, saved models, finding local servers and GGUF files, connecting other
agent apps in Terminal, and the three themes. New on the Mac: first run can
download the llama.cpp runtime (from its GitHub releases) and a starter model
(from Hugging Face) into the data folder; `Download/StarterModels.swift` is the list.

Phone pairing is built (`Sources/BlackTeamKit/Phone/`): on Camp's Servers & access page, "Enable private phone access"
publishes a private Tailscale Serve route (HTTPS 8449 to 127.0.0.1:18199), a small HTTP server on Network.framework
answers it while access is on, and the phone pairs with a QR code or link. Every check of `lib/server.cjs` and
`lib/phone.cjs` is ported (loopback peer, Host, Origin, Tailscale account, paired cookie, route verified private).
The Mac has no desktop browser session, so the local address grants nothing. The server serves the built web app from
`Contents/Resources/web` (`npm run build`; `build-app.sh` copies it). Left out: phone notifications and Taildrop.

Image attachments are built (`Sources/BlackTeamKit/Images/`, Chat only, as in the daily app): "+ Files", drag and drop and paste
attach up to 4 pictures a message. Any picture macOS can read (JPEG, PNG, WebP, HEIC, TIFF, GIF) is prepared natively: orientation
applied, longer side at most 1280 px, flattened onto white, re-encoded as a JPEG at quality 0.85 with no metadata, at most 1 MB
(a source file may be 20 MB). Each picture is a private file, `<data>/attachments/<conversation id>/<image id>.jpg` (0600, folders
0700), never inside the conversation JSON; the message keeps `{id, name, bytes, width, height}`. Files stay with their
conversation (there is no conversation delete yet); a submit that fails leaves none behind. A message with images is sent as
text plus `image_url` data URLs, and every earlier turn's pictures are sent again. Context is measured on the text, plus 1,700
tokens per image (measured on llama.cpp with Qwen3.5 projectors: about 1 token per 32x32 pixels, 1,602 for a 1280x1280 picture).
The starter models Qwen3.5 0.8B and 4B and Ornith 1.5 9B have a vision file (projector) that `Backend.installVision` / the
interface's "Download vision file" button fetches, sets as `model.mmproj` and loads by restarting the model; a model with none
(Qwen3 14B, other files) is told so. The phone's web app has no image support: a thread reaches it without image references.
CLI: `chat "..." --image <path>`, `vision status|install`.

Cloud models (Mac only): "Available configurations" can add an OpenAI-compatible service with the person's own key
(`Core/Cloud.swift`: address rule, redaction, request body, what each model refused, token usage; `App/BackendCloud.swift`:
conversation levels, refusals, conversion, project switch). Privacy travels with the work: every conversation is `local` or
`cloud`, a local one is never silently sent to a cloud model, projects are local only until allowed, cloud conversations get no
memory, phones cannot start or convert one, harnesses are not launched against a cloud model. See `docs/PRIVACY.md` and
`docs/MODELS.md`. `black-team-cli cloud add|models` and `--allow-cloud`. The CLI alone honours `BLACK_TEAM_CLOUD_TEST_HOST=127.0.0.1:<port>`
(through an injected `CloudRules` in `BlackTeamCLI/main.swift`) so `Tests/CloudStub/stub.py`, a stand-in service, can be used
without a real key; the app, built from `Backend()` with the default rules, neither contains that code nor the variable's name.

Subscription agents (`Sources/BlackTeamKit/Agents/`, `App/BackendAgents.swift`): a task can be handed to the person's own Claude Code or
Codex command-line app, which runs under that app's own saved login and subscription. Black Team never sees a key or token. The model
menu offers "Claude Code · your subscription" and "Codex · your subscription" only when the tool is found on this Mac. The tool starts
in the conversation's folder (the project's, or the workspace, or `--workspace`), its output and tool steps are saved as they arrive, and
the conversation is kept by the tool's session id, so a follow-up resumes it. Each tool is started with its modest defaults: Claude Code
with `--permission-mode acceptEdits`, Codex with `-s workspace-write`; nothing skips permissions. Provider keys
(`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`) are removed from the tool's environment. A run
stops after 30 minutes, and a reply is kept to 256 KiB. Before each run the project folder is archived with `/usr/bin/tar` to
`<data>/agent-snapshots/<conversation>/<run>.tar` (private; `.git`, `node_modules`, `.build`, `build`, `dist` and `DerivedData` are left
out; folders over 200 MB or 20,000 files are not archived, and the message says so). The newest five per conversation are kept, and
"Roll back this task" restores the changed files (and removes files the task created) when no task is running. Subscription agents count
as cloud: the conversation leaves this Mac, is marked with the provider (anthropic.com or openai.com), and follows the same rules as a
cloud model (a private conversation must be sent first, a local-only project refuses, a phone never starts one, no memory is used).
CLI: `agent claude|codex "<task>" [--workspace <folder>] [--thread <id>] [--allow-cloud]` and `agent rollback <thread id> <run id>`.

Not built yet, and left off the screens until they work: Hermes and its plugins, dictation, DSH session listing. Not done for
images: removing a conversation's picture files (no conversation delete yet), and keeping unsent drafts across app launches.

`black-team-cli` runs the same backend from a terminal (`status`, `starter list`,
`starter install <id>`, `chat`, `code`, `agent`, `find`, `models`, `use`, `memory`, `phone status|enable|disable|link|reset`,
and `serve`, which keeps phone access answering until Ctrl-C; `--web <folder>` or `BLACK_TEAM_WEB` names the built web app), which is
how the app is tested on a Mac with nobody at the screen. `BLACK_TEAM_DATA=<folder>`
points the app or the CLI at a throwaway data folder.

`Tests/DesignSnapshot` renders every screen to PNG at the size of the Linux
reference screenshots; the Mac interface is meant to match the daily app exactly.

## Building

On a Mac: `swift build`, `swift test`, and `./build-app.sh` for the app bundle.
From Linux: `dev/mini.sh <slot> all swift test`.

## Releasing

`./build-app.sh --release` signs with the Developer ID Application certificate in
the login keychain (unlock it first: `security unlock-keychain`), using the hardened
runtime, and writes `build/Black-Team-<version>-mac-<arch>.zip` with its checksum.
Set `NOTARY_PROFILE` to a `notarytool` keychain profile
(`xcrun notarytool store-credentials`) to notarize and staple; without it other
Macs will warn when opening the app.
