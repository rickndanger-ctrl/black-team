# Keep Black Team running in the background

Off by default. When you turn it on, Black Team's engine runs from login, with the window closed, so work you scheduled carries on and
your phone can still reach it. The window and the `black-team` command attach to that one engine instead of starting their own.

## What runs

`black-team service run` is the same engine the window uses (the model, Chat, Code, the vault, the phone server on `127.0.0.1`), with no
window attached. It also runs:

- the **scheduler**: messages you set up to send on a schedule, as normal conversations in a project;
- the **idle timer**: stops the model to free memory when nothing needs it (see Memory);
- **helpers**: supervised programs registered in one place, `Service/ServiceHelpers.swift`. None is registered today.

It runs as you, never as root, and opens no listener beyond the loopback one the window already uses.

## Turning it on and off

- **Settings, App & data, "Keep Black Team running in the background"**, or one step of "Set up your agents" (listed, never ticked for
  you), or `black-team service install`.
- It writes **one file** for your user: `~/.config/systemd/user/black-team.service` on Linux, or
  `~/Library/LaunchAgents/com.blackteam.service.plist` on a Mac. It turns the unit on for your next login. It does **not** start anything
  now: use `black-team service start`, or close the window and open it again (a window starts a service that you turned on).
- **Off:** flip the switch back, or `black-team service uninstall`. That stops the service and removes exactly what install wrote
  (a record of it is kept in `<data>/service-install.json`). Your data, schedules and conversations stay.

The unit has `Restart=on-failure`, `NoNewPrivileges=yes` and a few other hardening options that leave the tools Code uses alone. It
holds your data folder's engine lock: if the Black Team window started its own engine first, the service says so and waits (systemd
tries again). Do not run both: close the window and let it attach.

```text
black-team service install | uninstall | start | stop | restart | status | logs [-n N]
black-team service set idle-minutes|approval-hours|runs-per-day <number>
black-team service run            the service itself, in the foreground (what the unit starts)
```

`status` exits 0 when the service is running and 3 when it is not.

## How the window and the command attach

When the service is up it writes `<data>/service.json` (private, 0600): the protocol number, version, process id, loopback port, a secret
made fresh for every start (the service's session key), the window's bootstrap key, a control key, and the data folder. The window (`engine-client.cjs`)
and the command read it, and use the service only if the file is private and ours, its process is alive, and the service answers
`GET /api/service/ping` with the same process id when given the secret. A file left behind by a crash fails those checks and is ignored.
A service that refuses the secret is not replaced by a second engine; you are told.

Requests use the same loopback address, session cookie and same-origin header the window's own pages use, so every check in
`Phone/PhoneRouter.swift` (loopback peer, Host, Origin, cookie) applies to the new routes too. Closing the window only detaches: the
service, the model and any running job carry on. A window and a service of different versions say "Restart the background service" (the
window offers to do it) instead of failing oddly.

Without the service, nothing changes: the window starts its own engine and stops it, model included, when it closes.

`black-team status`, `black-team -p "<message>"` (Chat), `schedule` and `inbox` use the running service. Code and picture one-shots,
`chat`, `code` and the interactive session start an engine of their own; if your model is a local file the service holds, they say it is in
use by the background service (a cloud model or a model server is not affected).

## Memory

A background service must not sit on a laptop's memory. The model it started is **stopped after 10 idle minutes** (change it with
`black-team service set idle-minutes N`; 0 = never) and started again on demand. "Idle" means no job running, no scheduled run going or
waiting, no conversation lately, and no open window. A job is never interrupted. While unloaded, the window says "Model unloaded to free
memory". A model server you run yourself (Ollama, LM Studio) is never stopped; only a model Black Team started is.

## Scheduled work

A schedule has a name, a project, Chat or Code, the message, which model (the one in use unless you choose), when, and for Code a
permission level. When is one of: every N minutes or hours (5 minutes to 7 days), every day at a time, weekdays at a time, or once at a
time. In the window use **Schedules**; on the command line `black-team schedule add --when "daily at 9:30"` (also `every 30 minutes`,
`weekdays at 17:00`, `once at 2026-10-14 09:30`).

- Each run is a normal conversation in the project, named after the schedule: it shows in the window, on the phone and in history.
- **Catch-up:** a run missed while the computer was off runs **once** when the service starts, not once per missed time.
- **No overlap:** a schedule that is still running when it comes due again is skipped, not stacked.
- **One model slot:** a run that comes due while another job is going waits its turn, in order.
- **Limits:** up to 20 schedules and 24 runs a day (change the second with `service set runs-per-day N`); each run keeps Code's usual step and
  time budgets (48 steps, 30 minutes of work; time spent waiting for your answer does not count).
- A schedule that names another model switches to it for the run, and that model stays the one in use.
- Times follow this computer's clock, including clock changes: a daily 09:00 stays 09:00; a time that does not exist one day runs at the
  first moment that does; a time that happens twice runs once.
- Schedules run only while the service is on. You can edit them without it; nothing runs.

## What it can do unattended, and approvals with nobody there

Code runs at one of three levels, chosen per schedule:

| Level | Reads | Edits files in the project | Runs commands |
| --- | --- | --- | --- |
| **Read only** | yes | cannot (not offered the tools) | cannot |
| **Ask me first** (default) | yes | asks first, every time | asks first, every time |
| **Edit files in the project** | yes | yes, inside the project folder only | asks first, every time |

A step that needs a yes does not fail and does not go on: the run **waits**. The question is saved in your **Inbox**, shown on a badge in
the window, on the phone (the same approval card as any other approval, and the Inbox page), and in `black-team service status` and
`black-team inbox`. Answer with Approve or Deny in the window, on the phone, or `black-team inbox approve|deny <id>`. If nobody
answers within the set time (24 hours; `service set approval-hours N`), the run ends **not approved**. If the service stops while a run
waits, the run is marked interrupted and its question closed; nothing happens on restart without you.

A phone cannot push a notification today (there is no push path); the badge, the Inbox and the approval card are where a question shows.
Scheduled Code always uses Black Team Code, not Hermes, so its limits are the ones above.

## Organizations

An [organization](ORGANIZATION.md) that is running picks up its next ticket whenever the computer is idle, also with the window closed
(the service runs the same loop the window does). Its gates, the questions its roles ask, and its stand-up report are in the **Inbox**.
The Inbox keeps a gate until you answer it: a restart does not settle it. A gate that may use a paid agent can only be answered on the
computer, not from a phone. While an organization has tickets waiting, the idle timer does not unload the model.

## Helpers

`Service/HelperSupervisor.swift` starts each registered helper with the service, checks it, restarts it with a growing wait (2 s, doubling
to 5 minutes, back to 2 s after a minute of stable running), keeps its output in `<data>/run/<id>.log` and stops it with the service. The
folder is private (0700), logs 0600. A helper is started from an absolute path with an argument list, never through a shell. To add one
(for example a Hermes gateway), return a `HelperSpec` from `ServiceHelpers.specs(for:)`.

## Security notes

- Loopback only. The service opens the one listener the window already uses (default port 18199); the connection file's secret is its session
  key. Anyone who can read `service.json` can do what the window does, which is why it is 0600 in a 0700 folder, new for every start, and
  refused if its mode is wider or it is not a plain file owned by you. Other software running as you could read it; this is the same
  boundary as the rest of the data folder (see [Privacy](PRIVACY.md)).
- Every new route sits behind the existing Host, Origin and session checks. The control route (`POST /api/service/control`) is the window's
  own set of actions and nothing more, and it also needs the control key from the private file, which the window's main process holds and
  its page never sees: a compromised page has the session cookie but cannot reach those actions (they stay what only the main process
  asks for, as with the spawned engine). A phone may read schedules and the Inbox and answer a question; it cannot install, edit or change
  settings.
- No secrets on command lines; nothing a person or model typed is evaluated by a shell. The unit's `ExecStart` quotes every word.
- The service never runs as root, and installing or removing it never needs more than your own account.
