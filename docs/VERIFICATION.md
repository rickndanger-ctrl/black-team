# Portable alpha verification

Version reviewed: **0.1.0-alpha.3**. This source includes the local server,
configurable harness, performance, and Hermes Agent work added for the public
Black Team project. It is separate from the older machine-specific installation.

## Automated checks

The production React/Vite build passes. There are 76 passing JavaScript tests
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

## Still outstanding

- Fresh-machine and other Linux distribution installation; a public binary release
  and a simpler download/install experience.
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
