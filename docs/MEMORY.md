# Memory: the Black Team vault

Local models forget everything between conversations. The Black Team vault gives
them a place to keep what matters, and it holds **only local memory**.

It is a folder of plain Markdown notes inside Black Team's data folder
(`~/.local/share/black-team-data/vault`). Nothing in it is sent anywhere. It is
deliberately separate from any notes app you already use: a vault that hosted
assistants can also read is no longer local, and a small dedicated vault is
faster for a local model to search than a large personal one.

## What is in it

| Place | Purpose |
| --- | --- |
| `Core.md` | A few lines told to every conversation. Only you edit it. |
| `Notes/` | Facts that are true everywhere |
| `Projects/<name>/` | Each project's overview, journal and its own facts |
| `Archive/` | Older material: kept, but left out of recall |

On first start Black Team creates this layout itself: the three folders and a
`Core.md` holding only a guidance comment, which is not shown to the model. So
memory is ready before anything is saved; the Memory page explains the flow
and offers **Write Core** until the first note arrives.

Notes link to each other with `[[Note name]]`. The **Memory** page shows them as
a graph, lets you search, open and edit any note, and create projects.

## How the models use it

- **Code** has two tools: `remember` saves one dated fact under a short title,
  and `recall` searches, or returns a whole note. Inside a project, that
  project's notes come first. After each Code turn the engine itself writes a
  journal entry (what was asked, what was done, the result) with no model call.
- **Chat** has no tools, so Black Team looks things up for it. For each message
  it finds the few saved lines that share the message's distinctive words and
  hands them to the model. It stays quiet when nothing really matches, and a
  reply that was given memory says which notes ("Memory used: …").
- **Core** is read once when a conversation starts and then left alone, and
  recalled lines stay attached to the message they were found for. Earlier turns
  are therefore sent identically every time, which keeps the model server's
  prompt cache working.
- **Remember this** under any reply saves it to the vault.

Write `Core.md` yourself, briefly: how you like answers, what you are working
on. It is limited to 1,500 characters because every conversation reads it.

## The keeper: staying within limits

Memory is only useful while it stays quick to search and cheap to read, so it
has limits and something that enforces them.

| Limit | Default |
| --- | --- |
| One note | 6,000 characters |
| One project journal | 30 entries |
| All active notes together | 400,000 characters |

- After every task, and when idle, the keeper moves journal entries beyond the
  newest 30 to the archive and, if the vault is over its total, archives the
  stalest notes first. This needs no model.
- A note over its limit is **condensed by your local model**: rewritten shorter
  with every fact kept. The original is archived first, and a result that is
  empty or not shorter is thrown away. This happens only when your model is
  already loaded and idle; the keeper never starts a model by itself.
- **Tidy now** on the Memory page runs both at once. Recent upkeep is listed
  there, so nothing happens out of sight.

Deleting a note moves it to the vault's `.trash` folder, where it stays for 30
days before the keeper removes it.

## Keeping it local

- Code cannot read the vault as files; it goes through `remember` and `recall`.
- The vault is plain files, so you can back it up or read it with any editor.
  Back it up with the rest of the data folder.
- If you use hosted coding assistants on the same computer, tell them to stay
  out of `~/.local/share/black-team-data`. Black Team cannot enforce that for
  other programs running as you.
