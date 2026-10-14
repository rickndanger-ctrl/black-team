# Proposal: an always-running Hermes service

Status: a proposal only. Nothing described here exists in Black Team, and no part of it is switched on by this document.

A Black Team conversation runs Hermes one turn at a time: the window or a phone sends a message, Hermes works while the app is
open, and the process ends (see [Harnesses](HARNESSES.md)). Hermes can also run as a long-lived service that answers messages from
chat platforms, runs scheduled jobs and works a task board. The Hermes screen lists those tool groups, shows them off and says
"Needs the always-running service". This note describes what supporting them would take.

## What it unlocks

| Needs the service | Hermes names | Why a turn-at-a-time host cannot do it |
| --- | --- | --- |
| Messaging platforms | the `hermes-telegram`, `hermes-discord`, `hermes-slack`, `hermes-signal`, `hermes-email`, `hermes-sms` ... groups, the `discord`, `discord_admin`, `feishu_*` and `yuanbao` groups, and the `platforms/*` plugins | Messages arrive when nobody has the window open; something must be listening. |
| Scheduled jobs | the `cronjob` group, and the `hermes-cron` bundle | A job fires at a time, not when a person sends a message. |
| Task board | the `kanban` group | A dispatcher starts workers and they report back for hours. |

The platform bundles also re-list Hermes's whole default tool set (about 25,000 tokens of tool descriptions in the Hermes this was
checked against), which is more than most local models should read before every message. A service would need its own, smaller
choice of groups per platform, shown with their cost as the tool groups are now.

## What it would need

**Process supervision.** One Hermes gateway process per profile, owned by Black Team: started only when the person turns the
service on, never at login by default; stopped when they turn it off, when Black Team's model is stopped, or when the model's server
goes away. It needs a restart limit (a service that fails three times in ten minutes stays off and says so), a log the person can
open, and a clear state in the app ("running", "stopped", "waiting for the model"). The existing turn host already starts Hermes in its
own process group and stops it by group; the service would reuse that, with the supervising code in the engine, not the window, so
it also works from the terminal program and the Mac app.

**The model.** Platform messages arrive at any time, and a local model may be stopped to save memory. The service must say what
happens to a message that arrives while the model is off: start it (and show that it did), queue it, or reply that it is away. The
person chooses; the default is to queue and tell the sender. A message is never answered by a hosted model unless the person has set
up a cloud model for that platform ([Privacy](PRIVACY.md)).

**Approvals when nobody is at the window.** Today an approval card waits up to five minutes and expires. A service cannot assume
a person is watching. The rules would be: the dangerous groups (`terminal`, `file` writes, `computer_use`, `browser`) are off for
service conversations unless chosen separately; an action that needs approval is sent to the person's phone through Black Team's
phone access (or a named platform account they own) and denied when the wait ends; there is no "approve always". A platform sender
who is not the owner can never approve anything.

**Who may talk to it.** Each platform needs an allow-list of senders, empty by default (nobody). Credentials for a platform are
entered in a secure field, kept in the owner-only key file, and reach the process by environment only, as keys do now. Scheduled
jobs and task-board workers run under the same toolset limits as the conversation that created them.

**Where its work shows.** Service conversations are saved like any other, marked with their source, and open in the Workspace list.
A scheduled job's output is saved with the job. The phone shows them read-only unless the person continues them.

**Privacy.** Turning on a platform sends that platform's messages through that platform's company, and the model's replies back. The
screen says so before the first start, per platform, and [PRIVACY.md](PRIVACY.md) would list each one. Scheduled jobs that use the
web or a cloud model carry the same labels as tool groups.

## Open questions

- Whether to run Hermes's own gateway or to let Black Team's engine own the platform connections and call Hermes per message. The
  first is less code and brings every upstream platform; the second keeps one supervisor and one approval path.
- Whether the Mac app can share the design (Hermes is not available on macOS yet).
- How much of the Hermes dashboard, if any, to expose. The proposal says none.
- The cost of a platform message: each starts a turn with the reading cost of its groups. A per-platform budget may be needed.
