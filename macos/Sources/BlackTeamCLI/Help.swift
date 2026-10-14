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
  setup [--yes]                       connect the agents on this computer and install Hermes, after one approval
  recommend                           which models suit this computer, best first
  search <words> | <owner/repo>        find a GGUF model on Hugging Face, or list one repository's files
  download <id> | <owner/repo> <file> download a model, check it, and set it up so it is ready to chat
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
  hermes tools | skills | plugins | mcp | key   what your connected Hermes may do in a conversation
  serve                              keep Black Team and phone access running
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
    "setup": """
    Usage: black-team setup [--yes]
    Shows what it would do to set up your agents, and asks once. Nothing is installed, downloaded or connected until you answer yes.
      - connects each agent found on this computer (Claude Code, Codex, Pi, OpenCode, DeepSeek Harness, Aider) so it opens with your model
      - installs Hermes Agent into Black Team's own folder, if it is not installed (from github.com and the Python package index), then connects it
      - agents that are not installed are listed with their makers' install commands; Black Team never runs those
    Answering no is remembered, so the window does not ask again for the same things.
      --yes   approve every step without asking
    --json prints the plan (or, with --yes, the result of each step).
    """,
    "recommend": """
    Usage: black-team [--json] recommend
    Ranks the model catalogue for this computer (its cores, memory, free disk space and, where it can be read, graphics card). Each model is
    marked as fitting well, tight or too big, with an estimated speed and what it is good for. One is the best for this computer, one the
    best for Code (tools), and the fastest is named when it is another. Nothing is downloaded and nothing leaves this computer.
    """,
    "search": """
    Usage: black-team [--json] search <words>
           black-team [--json] search <owner/repo>
      <words>        search Hugging Face for GGUF models, most downloaded first
      <owner/repo>   list that repository's GGUF files with size, quantisation and how each fits this computer;
                     * marks the one suggested (Q4_K_M when it fits), and a vision or speed-up file is mentioned when the repository has one
    Contacts huggingface.co, only when you run it. These models are made by other people; read the licence before you use one.
    """,
    "download": """
    Usage: black-team [--json] download <id> [--with-vision] [--with-draft] [--use] [--no-optimize]
           black-team [--json] download <owner/repo> <file> [--with-vision] [--with-draft] [--use] [--no-optimize]
    Downloads a catalogue model (see `recommend`) or any GGUF file from Hugging Face, resuming a partial download and checking its size and
    SHA-256 against Hugging Face's own figures. Installs the llama.cpp runtime first when none is installed, then saves the model so it is
    ready to chat. It becomes the model in use when none was set up; --use makes it the model in use anyway (the model in use must be stopped).
      --with-vision   also download the repository's vision file, so the model can read pictures
      --with-draft    also download its speed-up (MTP or draft) file
      --no-optimize   do not measure the model on this computer afterwards (see `black-team optimize`)
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
    Usage: black-team chat "<message>" [--image <path>]... [--thread <id>] [--mode fast|balanced|deep|extended] [--allow-cloud] [--stop-other]
    Sends one message to the model in use and prints the reply, then details (thread, speed, usage).
      --image        attach a picture (the model must be able to read pictures); can be repeated
      --thread       continue a conversation
      --mode         how long and careful the reply is
      --allow-cloud  send an existing private conversation to the cloud model's service, after you have chosen so
      --stop-other   if the model will not fit beside another model server you run, stop that server first (otherwise nothing is stopped)
    """,
    "code": """
    Usage: black-team code "<message>" [--workspace <folder>] [--thread <id>] [--mode ...] [--approve once|deny] [--allow-cloud] [--stop-other]
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
           black-team room team <project> "<goal>" [--lead <member>] [--reviewer <member>] [--pipeline] [--yes]
           black-team room team stop <project>
           black-team room roster [list] | add --name N --role R (--model <key> | --agent claude|codex) | remove <n> | use <project> <n> | save <project> <member>
    <task> is its number from `room show`, or its id. handoff and team show exactly what would be shared and whether it leaves this
    computer, then stop; --yes sends or runs.
    When the lead is a paid member (a cloud model that does code work, Claude Code or Codex) the team run is DRIVEN: the lead works on the
    goal and hands real jobs to the other members while it works, then the tokens each side used are listed. --pipeline runs plan, work,
    review, report instead. The roster holds agents you made once; `roster use` adds one to a project's room.
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
    "hermes": """
    Usage: black-team hermes tools [on|off <group>...]
           black-team hermes skills [list | search <words> | on|off <category or category/skill>...]
           black-team hermes plugins [on|off <plugin>... | set web <provider>]
           black-team hermes mcp [list | add <name> <absolute program> [args...] [--env NAME] | add <name> --url <address> | on|off|remove <name>...]
           black-team hermes key set|forget <NAME>      (set reads the value from standard input)
    What your connected Hermes may do in Black Team conversations: tool groups (with about how many tokens each adds to every
    message), its skills, plugins and MCP servers. Connect Hermes in the app first. Black Team's own settings change; Hermes's do not.
    Options: --scripts <folder> if the app's scripts folder is not found.
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
One message: black-team -p "<message>" [--code] [--json] [--approve once] [--allow-cloud] [--stop-other] [--mode fast|balanced|deep|extended]
             [--workspace <folder>] [--image <path>]... [--thread <id>]
  Prints only the reply on stdout and errors on stderr; the exit status is non-zero on failure. It never asks anything: an approval
  is denied, and a question about sending a conversation to the cloud is refused, unless --approve once or --allow-cloud is given. A model that will
  not fit beside another model server you run is not started until you add --stop-other, which stops that server.
"""
