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

Not built yet, and left off the screens until they work: Hermes and its plugins, image attachments, dictation,
DSH session listing.

`black-team-cli` runs the same backend from a terminal (`status`, `starter list`,
`starter install <id>`, `chat`, `code`, `find`, `models`, `use`, `memory`, `phone status|enable|disable|link|reset`,
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
