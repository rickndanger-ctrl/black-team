# Make the next step easy

Black Team exists to make local models and agent tools easy to connect and use,
on the computer and privately from a phone. This is the product guideline for
new features and reviews, not just a settings redesign.

- Detect installed software before asking for paths. Keep discovery bounded and
  read-only; never run an executable just because it was found.
- Show one clear next action. Saving a model should lead to conversation;
  connecting Hermes should lead to agent work; phone setup should lead to pairing.
- Use useful defaults. Names, working folders, terminal choices and routine
  launch settings should not become required homework.
- Keep technical controls available under advanced settings. Do not require JSON,
  shell syntax, interpreter paths or internal identifiers in the common path.
- Explain missing prerequisites at the point of use and link to their setup.
  Finding an app does not mean its provider is configured or its tools work.
- Make failures recoverable. Preserve drafts and selected work modes, explain the
  next step, and retry an uncertain message with its original request identity.
- Keep permissions understandable. Browser and desktop tools are opt-ins. Phone
  setup stays private, generates QR codes locally and can be turned off even when
  Tailscale route cleanup fails.
- Make capability claims precise. A model list does not prove inference or tool
  calling. An external launcher is not an integrated phone agent session.
- Test the path a person follows, including failure and return paths. A successful
  build is not proof of an easy installation or a usable phone experience.

## Paths implemented in this revision

| Task | Common path |
| --- | --- |
| Use Ollama or LM Studio | Choose the provider → select an available model → Save and open chat |
| Use another local server | Enter its local address → Find models → select → Save and open chat |
| Use a GGUF file | Choose the file → select llama-server if not detected → Save and open chat |
| Set up every agent | Set up your agents card → Approve → Start an agent conversation |
| Enable integrated agent tools | The same card installs and connects Hermes; by hand: Agents & apps → Connect Hermes → Start agent conversation |
| Add an installed external app | Agents & apps → choose the detected app → Add app → Save changes |
| Pair a phone | Connect both devices to Tailscale → Enable private phone access → scan the code |
| Adjust technical settings | Open the relevant advanced section |

These paths assume the corresponding model server, runtime or agent is installed.
A custom executable can also be chosen; provider-specific configuration remains
in that external app. Nothing is installed, downloaded or connected without an
approval. After one, Black Team connects the agents it finds and installs Hermes
Agent into its own folder; other agents are never installed for you (their
install commands are shown as text). Downloading model weights needs its own
button, and universal provider adapters are not automatic in this alpha.

## Acceptance checks

Use a fresh application profile to review setup without relying on developer
paths. Check discovery with nothing installed, one match and multiple matches;
missing software; failed connections; authenticated model servers; editing a
saved connection; and saving an external launcher with literal arguments.

Check new Chat and Agent drafts across navigation, response cancellation, an
uncertain send and retry, saved threads, and approval cards in the correct thread.
On phones, check pairing retries, Home Screen installation, reconnection and
revocation. Compare CPU/RAM readings under load. See [VERIFICATION.md](VERIFICATION.md)
for what has actually been verified and what still needs live coverage.
