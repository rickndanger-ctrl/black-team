# Portable alpha verification

Version reviewed: **0.1.0-alpha.3**. This source includes the local server,
configurable harness, performance, and Hermes Agent work added for the public
Black Team project. It is separate from the older machine-specific installation.

## Automated checks

The production React/Vite build passes. There are 73 passing JavaScript tests
and 18 passing Python tests in this review. The suites cover:

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
- Host/origin checks, desktop/phone authentication, private route isolation,
  streaming parsing, durable request IDs, persistence and interrupted recovery.
- Electron bridge sandbox and action allowlists using mocked Electron.
- Installer upgrade/rollback, checksums, payload allowlist and unsafe archive/asset
  rejection using fake runtime archives.
- Synthetic context experiment policy/response checks. No hosted JEV call is
  required by or made during the normal test suite.

## What has not been verified here

This execution environment cannot bind local listening sockets or launch the live
Electron UI. It exposes no browser for visual/device testing. Network access from
the terminal cannot reach npm/GitHub. Therefore these remain unverified:

- Fresh online `npm install`, including the pinned Electron 44.7.0 download.
  Development build checks used the existing installed React/Vite dependencies.
- Real portable app rendering, accessibility and narrow-screen layout.
- Live Ollama/LM Studio discovery and generated responses on a fresh machine.
- A real GGUF load, CPU/GPU inference and all model/runtime combinations.
- Actual tool use, approvals/resume, browser and desktop work through the portable
  Hermes host. It targets the APIs present in Hermes commit
  `158fd638da1629c8e62caf9ade1515d162def8ab` and may need adaptation for other versions.
- Physical iPhone and Android pairing, Home Screen cookies, reconnect, approvals,
  file downloads and Taildrop delivery.

The old machine-specific prototype has separate historical live results. Those
are not evidence that every new portable path works on another computer.

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
