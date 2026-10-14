import Foundation

/// `black-team --help` and `black-team <command> --help`.
let usage = """
Black Team Agent: local AI models, a coding agent and a team, in your terminal.

Usage:
  black-team                          start a session: chat, code, resume, switch models (type /help inside)
  black-team -p "<message>" [options] send one message, print only the reply (also: echo "<message>" | black-team -p)
  black-team [--json] <command> [options]

Commands (black-team <command> --help for details):
  status                              set-up state, runtime, saved models, hardware
  starter list | install <id>         the starter models; download the runtime and one of them
  runtime status | install            the downloaded llama.cpp program
  find                                look for running model servers and model files
  models                              the saved models
  use <key>                           make a saved model the one in use
  optimize [model]                    measure this computer and keep the fastest settings for a model
  cloud add | models                  save a cloud model; ask a service which models it offers
  chat "<message>"                    one chat message, with the details printed after
  code "<message>"                    one message to the model working in a folder
  agent claude|codex "<task>"         hand a task to your Claude Code or Codex subscription
  vision status | install             can the model read pictures
  room ...                            a project's team: members, tasks, hand-offs, team runs
  memory core | list | search         what Black Team remembers
  phone status | enable | disable | link | reset
  serve                               keep Black Team and phone access running
  install-command [--to <folder>]     put `black-team` on your PATH

Options for everything: --json prints JSON; --help and --version.
The data folder is the app's own; BLACK_TEAM_DATA=<folder> uses another.
"""

let commandHelp: [String: String] = [
    "status": """
    Usage: black-team [--json] status
    Shows whether set-up is complete, the model in use, the runtime, the number of saved models and conversations, memory, and warnings.
    """,
    "starter": """
    Usage: black-team starter list
           black-team starter install <id>
      list      the starter models, what is installed, and the recommendation for this computer
      install   download the llama.cpp runtime and one starter model, and set it up
    """,
    "runtime": """
    Usage: black-team runtime status
           black-team runtime install
      status    the downloaded llama.cpp program, if any
      install   download llama.cpp (no model)
    """,
    "find": """
    Usage: black-team find
    Looks for running model servers and model files on this computer. Once Black Team is set up, the ones it
    can run are added to your models; one you removed stays out.
    """,
    "models": """
    Usage: black-team models
    Lists the saved models. * marks the one in use. Cloud models say which service they send to.
    """,
    "use": """
    Usage: black-team use <key>
    Makes a saved model the one in use. Keys are shown by `black-team models`.
    """,
    "optimize": """
    Usage: black-team optimize [<key or name>]
    Starts the model a few times with different settings (threads, context size, draft model, graphics chip), reads the speeds the
    model reports for a short fixed test, and keeps the fastest settings for this computer. Takes up to about 3 minutes; the model is
    stopped while it is measured and started again afterwards if it was running. Not while a response is being written.
    A model on a server of its own is only measured, since its settings belong to that server. Ctrl-C stops it and puts things back.
    """,
    "cloud": """
    Usage: black-team cloud add --url <https address> --key-env <NAME> --model <id> [--name <text>] [--context <tokens>]
           black-team cloud models [--url <address> --key-env <NAME>]
      add      save a cloud model. The key is read from the environment variable NAME, never from the command line.
               Conversations with a cloud model leave this computer.
      models   ask the service which models it offers (the saved cloud model's service, by default)
    """,
    "chat": """
    Usage: black-team chat "<message>" [--image <path>]... [--thread <id>] [--mode fast|balanced|deep|extended] [--allow-cloud]
    Sends one message to the model in use and prints the reply, then details (thread, speed, usage).
      --image        attach a picture (the model must be able to read pictures); can be repeated
      --thread       continue a conversation
      --mode         how long and careful the reply is
      --allow-cloud  send an existing private conversation to the cloud model's service, after you have chosen so
    """,
    "code": """
    Usage: black-team code "<message>" [--workspace <folder>] [--thread <id>] [--mode ...] [--approve once|deny] [--allow-cloud]
    Lets the model work in a folder: it reads, edits and runs things, and prints each step.
      --workspace    the folder it works in
      --approve      once allows each command it asks about, one time; deny (the default) refuses them
    """,
    "agent": """
    Usage: black-team agent claude|codex "<task>" [--workspace <folder>] [--thread <id>] [--allow-cloud]
                           [--permission ask|edit|auto] [--approve once|deny]
           black-team agent signin claude|codex
           black-team agent rollback <thread id> <run id>
    Hands a task to your Claude Code or Codex subscription. The conversation leaves this computer.
      --permission   ask: asks before changes (Claude Code) or only reads (Codex); edit: edits files; auto: more on its own
      signin         open the tool's sign-in in Terminal
      rollback       undo the files a task changed
    """,
    "vision": """
    Usage: black-team vision status
           black-team vision install
      status    whether the model can read pictures
      install   download a starter model's vision file
    """,
    "room": """
    Usage: black-team room show <project>
           black-team room member add <project> --name N --role R (--model <key> [--work chat|code] | --agent claude|codex [--permission ask|edit|auto])
           black-team room task add <project> "<title>" [--detail D] [--to <member>]
           black-team room start <project> <task>          run a task with its assignee and wait
           black-team room accept <project> <task>
           black-team room sendback <project> <task> --note N
           black-team room handoff <project> <task> --to <member> [--title T] [--detail D] [--no-result] [--yes]
           black-team room team <project> "<goal>" [--lead <member>] [--reviewer <member>] [--yes]
           black-team room team stop <project>
    <task> is its number from `room show`, or its id. handoff and team show exactly what would be shared and whether it leaves this
    computer, then stop; --yes sends or runs.
    """,
    "memory": """
    Usage: black-team memory core
           black-team memory list
           black-team memory search <query>
    """,
    "phone": """
    Usage: black-team phone status | enable | disable | link | reset
    Phone access over your Tailscale network. `serve` answers phones; `link` prints the pairing link; `reset` unpairs every phone.
    """,
    "serve": """
    Usage: black-team serve [--web <folder>]
    Keeps Black Team and phone access running until Ctrl-C.
    """,
    "install-command": """
    Usage: black-team install-command [--to <folder>]
    Links this program into a folder as `black-team` (default ~/.local/bin, created if needed), then says whether the folder is on
    your PATH and what to add if it is not. It will not replace anything that is not already a link to a Black Team program;
    choose another place with --to <folder>.
    """,
]

let helpTopicText = """
Interactive session: run `black-team` with no arguments in a terminal. Type /help in it for the slash commands.
One message: black-team -p "<message>" [--code] [--json] [--approve once] [--allow-cloud] [--mode fast|balanced|deep|extended]
             [--workspace <folder>] [--image <path>]... [--thread <id>]
  Prints only the reply on stdout and errors on stderr; the exit status is non-zero on failure. It never asks anything: an approval
  is denied, and a question about sending a conversation to the cloud is refused, unless --approve once or --allow-cloud is given.
"""
