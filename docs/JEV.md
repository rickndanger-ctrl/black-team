# Optional JEV research and API keys

Normal Black Team Chat and Hermes Agent work do **not** use JEV. They need no
JEV account or API key. JEV is a hosted experimental decision helper, not the
local language model and not a requirement for context handling.

There is a dedicated private location for a user's research key:

```sh
python3 scripts/configure-jev.py
```

Enter the key at the hidden prompt. It is saved as
`~/.config/black-team/jev.json` (directory 0700, file 0600), outside this source
repository. The script never prints the key and stores `enabled: false`.
Re-running replaces this research key. A custom location can be passed with
`--file /absolute/private/path/jev.json`. Remove the file to forget the saved key.
Do not put keys in GitHub, command arguments, screenshots or issue reports.

The optional context experiment requires a separately supplied, reviewed Dog
Walker adapter checkout; it is **not** bundled in the app. Explicitly running:

```sh
/path/to/adapter-python scripts/context_experiment.py \
  --provider jev --adapter-root /path/to/dog-walker \
  --jev-config "$HOME/.config/black-team/jev.json" \
  --output /tmp/black-team-context-jev.json
```

uses the adapter's test-only call with your key. Its hosted provider receives
synthetic counts and option labels. The script does not read customer chats or
workspaces. Saving the key by itself never sends data or enables a hosted helper
in Chat/Agent mode. Existing keys from another application's profile are not
read automatically. The adapter may also accept `TYPESAFE_API_KEY` in its environment;
review that adapter before running it.

The prior experiment obtained no usable JEV result. There is no demonstrated JEV
quality improvement or working live integration claimed for this release. See
[context research](CONTEXT-RESEARCH.md) and [the recorded
experiment](../benchmarks/CONTEXT-RESULTS.md).
