# Private phone access: iPhone and Android

Phone Companion is the browser interface to your Black Team workspace. Your
computer runs the model and Hermes agent; the phone sends instructions and
receives results over your private network. There is no separate model download
on the phone and no native App Store or Google Play package in this alpha.

## Pair a phone

1. Install Tailscale on your Linux computer and phone. Sign both into the same
   private network/account and keep them connected.
2. Open **Phone Companion** in Black Team on the computer and choose **Enable
   private phone access**. Black Team detects the computer hostname and account
   and configures its dedicated HTTPS port 8449 to reach the local app on port
   18199. It refuses to overwrite another application's route or a public Funnel
   route. You do not need to type an address or save a separate enable checkbox.
3. When **Private access ready** appears, scan the QR code with the phone camera.
   The QR code is generated locally on your computer, not by an external QR service.
   You can also choose **Copy pairing link** and open that link on your phone.
4. Keep the code and link private: they grant access to your Black Team workspace.
   Tailscale account identity is checked as well. The app exchanges the fragment
   for a Secure/HttpOnly cookie and removes the fragment from the address bar.
5. Use the browser, or add the interface to your Home Screen:
   - iPhone/Safari: Share → Add to Home Screen.
   - Android/Chrome: menu → Add to Home screen / Install, depending on browser UI.
   - If the installed web app has a separate cookie store, pair that browser
     context again with the desktop link.

Browser installation and cookie behavior vary. Physical iPhone and Android
verification is still outstanding for this portable release.

## What you can do

Send messages to the selected local model, start a Black Team Agent conversation,
see tool activity and CPU/RAM readings, approve or deny requested actions, stop a
task, continue saved sessions, and download attached workspace files. Sending a
message starts/connects the configured model if needed.

Agent mode must first be enabled on the desktop. Once enabled, an authorized
phone can instruct the agent to use those tools on your computer. Pair only your
own trusted devices. Approval controls are per action; pairing is not an OS
sandbox and tool switches are not filesystem isolation.

The phone does not expose model keys, model file paths, or desktop configuration
APIs. It does not display every independent third-party terminal harness. Use
Black Team Agent for the integrated remote workflow.

## Host lifetime and reconnecting

Keep Black Team open or minimized and the computer awake. The existing model
server must also be available when that connection mode is selected. Closing a
phone/browser or losing connectivity does not cancel a turn already accepted by
the computer. Request IDs avoid repeating a submitted turn after a network retry.
Reopen its saved conversation to see the result.

Quitting Black Team stops its owned model process and Agent task. An independently
running model server stays running. A host restart preserves saved partial output
but does not automatically restart a task. A Home Screen app can cache its shell;
that does not mean it can run inference while the host is offline.

## Network setup and revocation

If enabling access needs Tailscale permissions, open **Connection details and
troubleshooting → Show connection command**. Run the shown command in a terminal,
then choose **Enable private phone access** again so Black Team verifies the route:

```sh
tailscale serve --bg --https=8449 http://127.0.0.1:18199
```

Use Tailscale Serve, not a public proxy or Funnel. Port 18199 stays bound to
loopback. Remote conversation/file/approval APIs require both the saved Tailscale
account identity and a paired browser cookie. Black Team also checks the configured
Host and same-origin writes.

**Turn off phone access**, under **Connection details and troubleshooting**,
stops the app accepting phone requests first and then removes only Black Team's
verified route. Access stays disabled even if Tailscale is offline or route cleanup
fails; inspect Tailscale later if a cleanup warning appears.
Re-enabling the same account permits prior pairings until their 30-day cookies
expire. Changing hostname/account invalidates old tokens. To revoke all pairings
without changing the account, quit Black Team, remove only `phone.key` from its
private data directory, reopen, and pair devices again.

Tailscale uses its own account and coordination/network infrastructure. Desktop
local chat does not require Tailscale. Phone content is visible to the person
using that authorized device; browser/OS screenshots, downloads and backups have
their own storage behavior.

## Black Team for macOS

The Mac app does the same steps from Camp, under **Servers & access**: **Enable private phone access**, then scan the
QR code (drawn on the Mac) or **Copy pairing link**. **Reset phone pairing** replaces `phone.key` in the data folder
(`~/Library/Application Support/Black Team`) and unpairs every phone at once; **Turn off phone access** stops the
server and removes only Black Team's own route.

Tailscale's command-line tool is not on the PATH for the App Store or standalone Tailscale app, so Black Team looks
for `/Applications/Tailscale.app/Contents/MacOS/Tailscale` first, then `tailscale` in `/opt/homebrew/bin`,
`/usr/local/bin` and the PATH. The ports, the route rule and the checks are the same as above. The Mac has no desktop
browser session, so only a paired phone can reach the server. Keep the Mac awake. For headless use,
`black-team phone enable`, `black-team serve` and `black-team phone link` do the same.

References: [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve),
[iPhone Home Screen](https://support.apple.com/guide/iphone/turn-a-website-into-an-app-iph42ab2f3a7/ios),
[Android Chrome web apps](https://support.google.com/chrome/answer/9658361?hl=en&co=GENIE.Platform%3DAndroid).
