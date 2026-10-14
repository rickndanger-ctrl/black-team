# The `black-team` command

`black-team` is Black Team in a terminal, for Mac and Linux. Run it and you are in a session: you type, the model answers, and
it can work in your folders, hand tasks to your Claude Code or Codex subscription, and run your project's team. It uses the
same models, conversations, projects and memory as the app, so you can switch between them.

## Installing

**Mac.** The app already contains the command. Build the app (`macos/build-app.sh --install`), then run

    /Applications/Black\ Team.app/Contents/MacOS/black-team install-command

(or `~/Applications/...` if that is where the app is). To build just the command from the source, use `macos/dev/install-cli.sh`.

**Linux.** The installer links the command as `black-team` in the same `bin` folder as `black-team-desktop` (`~/.local/bin` by default) when that name is free, and says so when it finishes; if something else already has the name, it prints the full path to run instead. To build just the command from the source, use `macos/dev/install-cli.sh`.

`install-command` links the program you ran into `~/.local/bin` (it makes the folder if needed) and tells you whether that folder
is on your `PATH`. If it is not, it prints the one line to add to your shell's start-up file. It never replaces something that is
not already a link to a Black Team program: it says what is in the way and stops. Choose another place with
`black-team install-command --to <folder>`.

## The session

Run `black-team` with nothing after it. The prompt shows the mode and who answers:

    chat · Ornith 1.5 9B ›
    code · Claude Code [edit] ›

Type a message and press Enter. The reply appears as it is written. In Code, each step the model takes is one short line: the
tool, what it was given, and what came back. **Ctrl-C** stops the reply that is running and gives you the prompt back. At an empty
prompt, press Ctrl-C twice within two seconds (or type `/quit`, or press Ctrl-D) to leave. When you leave, the model is shut down.

Editing: left and right, Home and End (or Ctrl-A and Ctrl-E), Backspace and Delete, Ctrl-U (to the start of the line), Ctrl-K
(to the end), Ctrl-W (the last word). Up and down bring back earlier lines; the last 500 are kept between sessions in a private
file (`command-history` in the data folder, readable only by you). A paste with several lines stays one message. Accented
and Chinese, Japanese, Korean and emoji text edit as whole characters. If the input is not a terminal (a pipe), lines are read
plainly and nothing but text is printed.

Colour is used sparingly and dimmed text marks side notes. It is off when `NO_COLOR` is set, when `TERM=dumb`, and when the output
is not a terminal.

### Slash commands

Type `/help` to see them. Tab completes a command (and the word after `/agent`, `/permission`, `/pace`).

| Command | What it does |
| --- | --- |
| `/chat`, `/code` | Switch mode. A conversation cannot change kind, so this starts a new one and says so. Code works in the folder you started in, or the chosen project's folder. |
| `/new` | A new conversation in the same mode. |
| `/resume` | Lists recent conversations with numbers; type a number (or `/resume 3`) to open one and see its last messages. |
| `/model` | Lists saved models, local or cloud, with numbers; a number switches. |
| `/agent claude\|codex\|off` | Use your Claude Code or Codex subscription for this conversation (Code mode). |
| `/permission ask\|edit\|auto` | How much the agent may do without asking. |
| `/pace fast\|balanced\|deep\|extended` | How long and careful replies are. |
| `/project` | Lists projects; choose one by number or name, `none` to leave, `new <name>` to make one. |
| `/image <path>` | Attach a picture to your next chat message; `/image` shows what is attached; `/image clear`. |
| `/undo` | Undo the last file change of the last Code reply, or roll back the last agent task, after you confirm. |
| `/team "<goal>"` | Run the current project's team: shows the agreement, asks `[y/N]`, prints the team log as it grows, then the report. When the lead is a paid member it drives: it hands work to the other members while it works, and the tokens each side used are listed at the end ([ROOM.md](ROOM.md)). |
| `/status` | Model, mode, conversation, folder, and whether the app holds the local model. |
| `/memory <query>` | Search what Black Team remembers. |
| `/quit` | Leave. |

An unknown command says so and points to `/help`. A line that starts like a path (`/home/me/notes.txt what is this?`) is sent as text.

## One message

    black-team -p "Summarise this in one line" 
    echo "What is a monad?" | black-team -p
    black-team -p --code "Add a --version flag" --approve once

`-p` sends one Chat message with the model in use and prints only the reply on standard output. Problems go to standard error and
the exit status is non-zero if it failed (2 for a mistake in the command). Options: `--code` (a Code turn, with the current folder
as the workspace, or `--workspace <folder>`; its steps go to standard error), `--json` (one JSON object at the end),
`--mode fast|balanced|deep|extended`, `--image <path>` (Chat only), `--thread <id>`, `--approve once`, `--allow-cloud`.

It never asks you anything. A command the model wants to run is **denied** unless you gave `--approve once`; a question about
what would leave your computer is **refused**, with the reason on standard error, unless you gave `--allow-cloud`.

## Privacy and approvals in the terminal

Nothing leaves your computer without your say-so, and the terminal asks right where you are working, in the same words the app uses.

- **Approvals.** When the model wants to run a command it shows the command and the reason, then `Allow once? [y/N]`. Anything but
  `y` denies it.
- **Starting a cloud conversation** (a cloud model, or Claude Code or Codex) first shows what would leave your computer, and asks `[y/N]`.
- **A private conversation and a cloud model.** If you try to send a conversation that has stayed on this computer to a cloud
  service, it is refused and you get numbered choices: start a new cloud conversation, switch back to your local model, or send
  this conversation after you confirm the service's name by typing it. Press Enter to cancel; nothing is sent.
- Projects marked local only never use a cloud model.

## Running beside the app

The app and the command can be open on the same data folder. Conversations are files, so both see them. But only one can run
your **local model** at a time. The first to start takes a small lock file (`engine.lock` in the data folder: the process number,
the program, and when it started). The second says once, "Black Team is also open in ... Only one of them can run your local model
at a time.", and if you try to start a local model there it says "Your local model is in use by ... Stop it there, or use a cloud
model or a subscription agent here." Cloud models and subscription agents work in both. When the first one closes (or is
killed; a lock whose program is gone is ignored) the other can start the model.

## The other commands

`black-team --help` lists everything and `black-team <command> --help` explains one: `status`, `starter`, `runtime`, `find`,
`models`, `use`, `cloud`, `chat`, `code`, `agent`, `vision`, `room`, `memory`, `phone`, `serve`, `install-command`. They print and
exit, take `--json`, and work as they did before the session existed. `black-team-cli` still works as another name.
`BLACK_TEAM_DATA=<folder>` uses a different data folder (handy for trying things out).
