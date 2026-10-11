<p align="center"><img src="public/black-team-mark.png" width="120" alt="Black Team emblem"></p>

# Black Team

**Your local models. Your choice of harness. Your computer, wherever you work.**

Black Team is a local AI workspace for Linux. It gives you one place to connect
your own LLMs, launch the harnesses you use, watch CPU and memory usage, and work
with an agent that can use tools on your computer. Its built-in **Black Team
harness** connects a compatible local model to **Hermes tools** for coding, files,
terminal work, task planning, and optional browser or desktop work.

You can use it at your desk or connect privately from your phone. The model and
agent run on your computer; your phone is a window into that same workspace.
The phone interface supports browser access from **iPhone and Android**.

**Status: Linux alpha, 0.1.0-alpha.3.** Source and automated tests are available;
the portable agent/server integrations still need live testing on fresh machines
and physical phones. See [verification and known limits](docs/VERIFICATION.md).

## What Black Team does

- **Bring your existing models.** Load a compatible GGUF through llama.cpp, or
  connect to an existing local OpenAI-compatible server such as Ollama or LM Studio.
  Discover its model IDs and select the one you want. You are not limited to a
  model name chosen by the developer.
- **Choose a harness.** Use Black Team Chat for a conversation, Black Team Agent
  for Hermes-powered work, or configure launchers for other installed harnesses.
  A harness is the software around the model: it manages prompts, context,
  tools, sessions, and the way you interact with the model.
- **See what your computer is doing.** The desktop shows live whole-system CPU
  utilization, CPU cores, load average, available RAM, and disk space. CPU and
  memory readings also appear in the phone interface. These are system readings,
  not per-model speed benchmarks or GPU telemetry.
- **Give your local model tools.** Enable Hermes terminal/file/task tools; opt
  into browser or desktop tools when their local dependencies are installed.
  Tool activity and approval requests appear in the conversation. Continue a
  saved agent session or stop a running task.
- **Work privately from your phone.** Send instructions, read replies and tool
  activity, respond to approval cards, stop tasks, and download attached files
  through your private network. Your computer does the work.
- **Keep your own data.** Conversation history, configuration, agent profiles,
  and attached files are stored on your computer. No Black Team account,
  hosted chat backend, analytics integration, or cloud fallback is required.

## How it fits together

```text
Your Linux computer
  Black Team desktop
    ├── Model connection: owned llama.cpp / existing local server
    ├── Black Team Chat: streaming conversations + context control
    ├── Black Team Agent: local model + installed Hermes tools
    ├── Other installed harnesses: configured local launchers
    └── Local history, agent sessions, approvals, files and performance
              │
       Private Tailscale HTTPS connection
              │
     Your phone browser / Home Screen app
```

Black Team supplies the workspace and orchestration. Your model supplies the
inference. Hermes supplies the agent tool runtime. Other harnesses remain their
own applications; their interfaces are not all embedded or mirrored to the phone.
The phone can interact with Black Team's built-in Chat and Agent conversations.

## What “local” means

With a locally running model, prompts and inference stay on your computer.
Desktop chat can operate without internet after you have installed the app,
runtime, and model. Black Team connects model requests only to a loopback address;
it does not silently switch to a hosted AI service.

A local server can itself be configured to call the cloud. Choose a **downloaded
local model** in Ollama, LM Studio, or another server if you want local inference.
Black Team cannot prove how another program routes its requests. External
harnesses also have their own provider settings and privacy behavior.

Tools that browse websites, send files, or use online services still make network
requests. Phone access uses Tailscale's account and network infrastructure.
Optional JEV research is hosted and separate from normal chat and agent work.
Local files have private permissions but are **not encrypted by Black Team**.
Read the complete [privacy boundaries](docs/PRIVACY.md).

## Get started

### Requirements

- A Linux desktop. The archive packager currently targets x86-64.
- Enough RAM/VRAM for your chosen model and its context window. There is no
  universal minimum that fits every model.
- Either a compatible GGUF plus native llama.cpp runtime, **or** a running local
  server with `/v1/models` and streaming `/v1/chat/completions` support.
- For source setup: Node.js 22.12+ and npm. Python 3 is needed for packaging/tests;
  Agent mode uses the Python environment belonging to your Hermes installation.
- Optional: an installed compatible Hermes Agent, other harnesses you want to
  launch, and Tailscale on your computer and phone for private remote access.

### Run from source

Download or clone this repository, open its folder, then run:

```sh
npm install
npm start
```

`npm start` builds the UI and launches the project-local Electron dependency.
It does not require a machine-specific `electron43` command. The first install
needs network access to fetch dependencies and Electron. This release declares
[Electron 44.7.0](https://releases.electronjs.org/release/v44.7.0).

### Use a packaged build

If an alpha archive is provided with a release, verify its SHA-256, extract it,
and run `./install.sh` from the extracted directory. Open **Black Team** from
applications, or run `~/.local/bin/black-team-desktop`.

The per-user installer needs no root install, preserves data across versions,
and supports rollback. It includes Electron, but **does not bundle models,
llama.cpp, Hermes, or third-party harnesses**. See [installation and
packaging](docs/DISTRIBUTION.md). Old alpha archives may not have the features
listed for this source version.

## Connect your model

Open **Workspace** or **Settings** and choose a connection type.

| What you already have | Choose | Configure |
| --- | --- | --- |
| A GGUF model | GGUF file | Pick the model and a native `llama-server`; set context, CPU threads, and GPU layers |
| Ollama | Existing local server | Start Ollama; use `http://127.0.0.1:11434/v1`; find models |
| LM Studio | Existing local server | Enable its local server; use its address, commonly `http://127.0.0.1:1234/v1`; find models |
| Another compatible server | Existing local server | Enter its loopback `/v1` URL, optional API key, and exact model ID |
| Another model file format | Existing local server | Load it in a compatible inference engine first, then connect that engine |

Choose a workspace, save, then start/connect the model or send a message.
**Test connection & find models** checks discovery; a real chat is the final
check that the selected model supports generation. Models used for Agent work
must also support the tool calling required by Hermes. Embedding-only, image,
and audio models are not supported by this text interface.

For GGUF mode, Black Team starts and stops its own authenticated llama.cpp
process. For an existing server, it only connects/disconnects; it does not stop
that server or download models. Set the context in Black Team no higher than the
context loaded in your server. [Model setup and troubleshooting](docs/MODELS.md)
explains the differences in context measurement and estimates.

## Use multiple harnesses

**Black Team Chat** is ready once a model is connected. For **Black Team Agent**,
open Settings, enter your installed Hermes Python executable and source folder,
and enable the tools you want. Then start a new conversation and choose
**Black Team Agent · Hermes tools**. The desktop and phone share this workflow.

Terminal, file, search, and task tools are configurable. Browser and desktop
control are separate opt-ins and need the corresponding Hermes dependencies.
Each agent conversation has its own Hermes profile/session. Approval cards permit
one action or deny it; they do not automatically grant permanent approval.
The current agent budget is 48 steps / 30 minutes per turn.

For other harnesses—such as a configured Hermes terminal, Codex, DSH, Pi, or
another local-compatible client—add its executable/wrapper in Settings with
literal arguments and an optional terminal prefix. Black Team supplies the local
endpoint, model ID, key and workspace in the launch environment. **Each external
harness must actually support and be configured for your local provider.** It is
not enough just to install a CLI with a familiar name.

Enabled tools operate as your Linux user. The chosen workspace is a working
directory, **not a sandbox**. Review [harness setup and tool
boundaries](docs/HARNESSES.md) before enabling agent tools.

## Work from your phone

Install Tailscale on the computer and phone, join your own private network, and
use **Phone Companion** in the desktop app to detect your computer/account and
enable access. Open the pairing link on your phone.

- **iPhone:** open in Safari; use Share → Add to Home Screen.
- **Android:** open in Chrome; use its menu → Add to Home screen / Install.
- You can also use a compatible browser without installing a Home Screen app.

The same local model can answer messages and perform agent work on the computer.
Approval cards and attached-file downloads work through the authenticated
connection. Keep Black Team open or minimized and the computer awake. A phone
disconnection does not cancel a running turn. Quitting Black Team stops its owned
model and agent task; it does not stop an independently running model server.
Tasks do not automatically resume after an app/computer restart.

There is no public model port, required port forwarding, App Store app, or
Google Play app in this release. See [the complete phone setup](docs/PHONE.md).
Physical iPhone/Android verification is still required for the portable alpha.

## JEV and context management

JEV is **not enabled in chat or Agent mode**, and local operation needs no JEV
key. Black Team Chat budgets context locally. Hermes Agent uses local model
compaction; its compression provider is pinned to the selected local endpoint.

An optional synthetic research script supports JEV through a separately supplied
reviewed adapter. If you want to run it with your own key:

```sh
python3 scripts/configure-jev.py
```

The hidden prompt stores the key outside the repository at
`~/.config/black-team/jev.json` with private permissions. Saving it makes no
request and does not enable JEV in the application. See [JEV setup and research
limits](docs/JEV.md) before explicitly running a hosted experiment.

## Data, development, and limitations

Data defaults to `~/.local/share/black-team-data`, or
`$XDG_DATA_HOME/black-team-data` when that variable is an absolute path. Settings
has an **Open data folder** button. Quit before backing it up. Backups include
conversation content, keys, agent sessions, and pairing material; keep them private.
Model weights stay where you selected them.

```sh
npm run build
npm test
npm run package:linux -- --runtime-zip /path/to/electron-v44.7.0-linux-x64.zip --out release
```

The portable release is still an alpha: clean-machine installation, real model
inference, Hermes tool execution, browser/desktop drivers, and physical phone
flows need the live checks listed in [VERIFICATION.md](docs/VERIFICATION.md).
Windows/macOS desktop packaging, GPU monitoring, automatic harness installation,
and automatic task recovery across restarts are not included.

Project license terms have not yet been selected. Third-party components retain
their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Model and
harness licensing also remains with their respective publishers.
