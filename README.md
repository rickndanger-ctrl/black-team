<p align="center"><img src="public/black-team-mark.png" width="120" alt="Black Team emblem"></p>

# Black Team

**Your local models. Your choice of harness. Your computer, wherever you work.**

Black Team is a local AI workspace for Linux. It gives you one place to connect
your own LLMs, launch the harnesses you use, watch CPU and memory usage, and work
with an agent that can use tools on your computer. **Black Team Code** is its own
agent loop, built for local models: it measures how fast your model really reads
and sizes its work to match, shows every file change with Undo, and remembers
across conversations in a private, local-only memory vault.

You can use it at your desk or connect privately from your phone. The model and
agent run on your computer; your phone is a window into that same workspace.
The phone interface supports browser access from **iPhone and Android**.

**Status: Linux alpha, 0.1.0-alpha.8.** Source and automated tests are available;
the portable agent/server integrations still need live testing on fresh machines
and physical phones. See [verification and known limits](docs/VERIFICATION.md).

## What Black Team does

- **Bring your existing models.** Load a compatible GGUF through llama.cpp, or
  connect to an existing local OpenAI-compatible server such as Ollama or LM Studio.
  Discover its model IDs and select the one you want. You are not limited to a
  model name chosen by the developer.
- **It finds what you have.** On first start Black Team lists the local model
  servers and model files already on your computer, then the agents. Tick, add,
  start. See [Models](docs/MODELS.md).
- **Several models, one menu.** Every model you set up is kept in a list. Switch
  between them from the top of the conversation; each reply says which model
  wrote it.
- **Chat or Code, one switch.** The mark at the top of the page is the switch:
  the chat bubble for a conversation, the terminal for hands-on work. Launchers
  for other installed harnesses are one click away. A harness is the software
  around the model: it manages prompts, context, tools, sessions, and the way
  you interact with the model.
- **An agent sized to your hardware.** [Black Team Code](docs/CODE.md) reads,
  searches and edits files, runs commands and keeps a todo list. It measures your
  model's reading and writing speed, budgets its context from that, and trims
  without spending a model call. A gauge shows the speeds and how full the
  budget is.
- **A map of your code.** With [graphify](https://pypi.org/project/graphifyy/)
  installed, Code asks a graph of the project where things live before it reads,
  so a local model reads far less. See [Black Team Code](docs/CODE.md).
- **Every change shown, with Undo.** Edits appear as diffs in the conversation.
  Commands that delete, install or reach the network wait for your approval.
- **Memory that stays local.** The [Black Team vault](docs/MEMORY.md) is a small
  folder of linked notes that only your local models use. Code saves and recalls
  facts; Chat is handed the few lines that match your message. A keeper holds it
  within limits, using your own model to condense notes that grow too long.
- **Projects in the sidebar.** Name a project and it gets a folder to work in
  and its own notes and journal. Open it later and pick up where you left off.
- **See what your computer is doing.** The desktop shows live whole-system CPU
  use, the chip's physical cores and threads, its current speed and temperature,
  load against thread count, the memory the kernel can hand out and how much the
  model server is holding (including any pushed to swap), and the disk space you
  can use where Black Team keeps its data. All figures come from the kernel's own
  files, so they match `lscpu`, `free` and `df`. CPU and memory readings also
  appear in the phone interface. These are system readings, not per-model speed
  benchmarks or GPU telemetry.
- **Your other agents, one click away.** Claude Code, Codex, Pi, OpenCode and
  DeepSeek Harness are found automatically. Connect one once and it opens
  already using your local model. See [Harnesses](docs/HARNESSES.md).
- **Bring Hermes if you use it.** Connect an installed Hermes Agent for its
  browser or desktop tools and choose it for Code conversations. It is optional.
- **Dictate.** When a system dictation tool is installed (Voxtype is detected),
  a microphone button in the text bar starts and stops it. Speech is transcribed
  on your computer by that tool.
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
    ├── Black Team Code: own agent loop, tools, diffs + undo, approvals
    ├── Black Team vault: local-only memory, projects, keeper
    ├── Optional: installed Hermes tools for browser/desktop work
    ├── Other installed harnesses: configured local launchers
    └── Local history, agent sessions, approvals, files and performance
              │
       Private Tailscale HTTPS connection
              │
     Your phone browser / Home Screen app
```

Black Team supplies the workspace, the agent loop and the memory. Your model
supplies the inference. Other harnesses remain their
own applications; their interfaces are not all embedded or mirrored to the phone.
The phone can interact with Black Team's built-in Chat and Code conversations,
projects and memory.

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

On first launch, **Workspace** shows the model setup. To change it later, open
**Settings → Models** or choose **Change model** from Workspace.

| What you already have | Choose | Next step |
| --- | --- | --- |
| Ollama with downloaded models | **Ollama** | Black Team finds models at its usual local address; select one |
| LM Studio with its local server running | **LM Studio** | Black Team finds models at its usual local address; select one |
| A compatible GGUF | **Model file** | Choose the model; use the detected llama.cpp runtime or choose its executable |
| Another compatible local server | **Another server** | Enter its loopback `/v1` address, then choose **Find models** |
| Another model file format | Its compatible local server | Load it in that engine first, then connect the server |

Choose **Save and open chat**, then send a message. The first message connects or
starts the configured model automatically. The Ollama and LM Studio buttons fill
in their usual addresses and run discovery; they do not install those apps or
download model weights. Use **Find models** again after starting your server.

Most people can leave **Advanced connection and performance** closed. It holds
optional API keys, a custom server address, a manual model ID, the workspace,
context size, and GGUF CPU/GPU settings. A successful model list confirms
discovery; a real reply confirms generation. Agent work additionally requires
tool calling. This source version supports text chat, not embedding-only,
image-generation or audio models.

For GGUF mode, Black Team starts and stops its own authenticated llama.cpp
process. For an existing server, it only connects/disconnects; it does not stop
that server or download models. Set the context in Black Team no higher than the
context loaded in your server. [Model setup and troubleshooting](docs/MODELS.md)
explains the differences in context measurement and estimates.

## Use multiple harnesses

**Black Team Chat** and **Black Team Code** are ready once you connect a model.
Code needs a model that supports tool calling and a context window of at least
8,192 tokens. See [Black Team Code](docs/CODE.md) and [memory](docs/MEMORY.md).

Hermes is optional. To use it, open **Settings → Agents & apps**. Black Team
looks for an installed Hermes Agent. When it finds one, choose **Connect
Hermes**, then pick **Hermes** as what runs new Code conversations.
If more than one installation is found, select the one you want. If yours is
elsewhere, use **Choose Hermes folder**; if it is not installed, **Install Hermes
Agent** opens its installation guide. After installing it, choose **Find again**.

**Tools and advanced setup** contains manual source/Python paths and the optional
browser and desktop controls. File, terminal, search and planning tools are the
default; browser and desktop work need their own Hermes dependencies. Each Hermes
conversation has its own Hermes profile/session. With either engine, approval
cards allow an action once or deny it; they do not grant permanent approval, and
one turn is limited to 48 steps / 30 minutes.

For another installed harness, use **Other apps → Add an app**, choose a detected
app or browse for an executable, select **Add app**, then **Save changes**. A
launch button appears on Workspace. **Launch options** lets you choose a terminal
or add arguments one field at a time; no JSON editing is required. Black Team
supplies the local endpoint, model ID, key and workspace in the launch environment.
Each external app must support and be configured for your local provider; its
independent session is not mirrored to your phone.

Enabled tools operate as your Linux user. The chosen workspace is a working
directory, **not a sandbox**. Review [harness setup and tool
boundaries](docs/HARNESSES.md) before enabling agent tools.

## Work from your phone

Install Tailscale on the computer and phone, join your own private network, and
open **Phone Companion** in the desktop app and choose **Enable private phone
access**. Black Team detects your computer and account, enables the private
connection, and displays a QR code. Scan it with your phone camera or use
**Copy pairing link**. The QR code is generated on your computer; keep it and the
link private. No separate phone app is required.

- **iPhone:** open in Safari; use Share → Add to Home Screen.
- **Android:** open in Chrome; use its menu → Add to Home screen / Install.
- You can also use a compatible browser without installing a Home Screen app.

The same local model can answer messages and perform agent work on the computer.
Approval cards and attached-file downloads work through the authenticated
connection. Keep Black Team open or minimized and the computer awake. A phone
disconnection does not cancel a running turn. Quitting Black Team stops its owned
model and agent task; it does not stop an independently running model server.
Tasks do not automatically resume after an app/computer restart.

To disable access, open **Connection details and troubleshooting** and choose
**Turn off phone access**. This stops phone requests even if Tailscale route cleanup
cannot complete.

There is no public model port, required port forwarding, App Store app, or
Google Play app in this release. See [the complete phone setup](docs/PHONE.md).
Physical iPhone/Android verification is still required for the portable alpha.

## JEV and context management

JEV is **not enabled in Chat or Code**, and local operation needs no JEV
key. Black Team Chat budgets context locally. Black Team Code trims its own
context without a model call. Hermes uses local model compaction; its
compression provider is pinned to the selected local endpoint.

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

Our product guideline is to detect what is installed, show the shortest useful
path, and keep advanced controls optional. See [Make the next step easy](docs/PRODUCT-PRINCIPLES.md).

Appearance is chosen at the bottom of the sidebar: **Covert** (default), **Light**,
or **Ghost**. The choice is remembered on each device and never sent anywhere.

Data defaults to `~/.local/share/black-team-data`, or
`$XDG_DATA_HOME/black-team-data` when that variable is an absolute path. Settings
has an **Open data folder** button. Quit before backing it up. Backups include
conversation content, the memory vault, keys, agent sessions, and pairing material;
keep them private.
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

Black Team is free software under the [GNU Affero General Public License,
version 3](LICENSE). You may use, study, change and share it; if you distribute a
changed version or offer it as a service, you must publish your changes under
the same license. Copyright © 2026 the Black Team authors. Third-party components
retain their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Model and
harness licensing also remains with their respective publishers.
