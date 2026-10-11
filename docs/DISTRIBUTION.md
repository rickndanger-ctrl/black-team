# Black Team Linux preview

This is an unsigned Linux x86-64 alpha. It includes an upstream Electron runtime
and the Black Team application. The `BUILD.json` inside the installed release
records both versions. The first preview uses Electron 40.10.2 from an existing
upstream archive; its version is stated explicitly, and this preview is not a
security audit or a claim of support across all Linux distributions.

## Install and launch

Extract the complete `black-team-<version>-linux-x64.tar.gz` archive. From the
extracted folder run:

```sh
./install.sh
~/.local/bin/black-team-desktop
```

The application menu entry is **Black Team**. The executable is deliberately named
`black-team-desktop` so the installer will not replace an existing `black-team`
command. Installation requires no administrator access and does not start the app.
The installer refuses to replace unrelated files at its managed launcher/menu paths.

The default install is `~/.local/share/black-team/releases/<version>` with a
`current` symlink. Use `./install.sh --prefix /absolute/directory` to install under
another prefix; its `bin` and `share` directories are used. Keep the extracted
archive if you want to reinstall elsewhere. The installer supports paths with
spaces and does not modify shell configuration.

Black Team's application data is held separately in its per-user data directory
(`~/.local/share/black-team-data` with the default Linux environment). Installing
or rolling back does not delete conversations, settings or imported model files.
The runtime is not granted setuid permissions; Electron's sandbox remains enabled.

## Updates and rollback

Quit Black Team before applying an update. Obtain a newer versioned archive,
extract it, and run its installer using the same prefix. The installer validates
the payload SHA-256, stages the release, then atomically switches `current`.
Earlier releases remain on disk and `previous` points at the release replaced.
An already-installed version is not overwritten.

```sh
~/.local/bin/black-team-desktop --rollback
```

Rollback swaps `current` and `previous`. It does not roll back application data;
future releases that change data formats must document compatibility. This alpha
does not include an automatic updater, update server, publisher signature,
license activation service or recurring online license check. SHA-256 sidecars
detect corruption; they do not authenticate the publisher.

## Runtime and system requirements

This preview targets Linux x86-64. It needs the desktop libraries required by its
bundled Electron version (including glibc, GTK 3, NSS, ALSA and X11/Wayland support)
and a working Chromium sandbox/user-namespace configuration. The installer needs
standard shell/core utilities plus `tar`, `gzip` and `sha256sum`. A successful
installation is not a guarantee that a particular distribution can launch it.
Do not work around launch errors by adding `--no-sandbox`.

Models and the inference engine are supplied separately. Import the GGUF model
and an intact compatible llama-server runtime directory, including its libraries.
No model or inference runtime is automatically downloaded. Available memory, model
size and context settings affect whether inference fits on a customer's computer.
Keep third-party runtime and model license files with those downloads.

Companion remains an optional Home Screen web application connected to the
customer's computer. The desktop application works independently of phone pairing.
Phone access requires the configured private connection and an awake computer.

## Build another archive

With the renderer already built, run from the source checkout:

```sh
npm run build
python3 scripts/package.py --runtime-zip /path/to/electron-v44.7.0-linux-x64.zip --out release
```

The packager uses Python's standard library and an explicit application allowlist:
`main.cjs`, `preload.cjs`, `lib/*.cjs`, built `dist`, a minimal `package.json` and
required third-party notices. It does not include the source checkout's
`node_modules`, home directories, models, chats, keys or existing customer state.
It rejects symlinks in app assets, source maps and unsafe runtime ZIP paths.
The payload includes a file-hash manifest; the outer archive has a SHA-256 sidecar.
No downloads or global package installations happen during packaging.

Run the installer regression suite with:

```sh
python3 -m unittest discover -s tests -p 'install*.py' -v
```

Tests use fake runtimes in temporary prefixes and do not change the live install.
Fresh-machine launch, real model inference and phone pairing must also be verified
on the intended customer environment before a public release.

## Agent and external harness dependencies

The archive includes the Black Team Hermes host and Companion tools plugin.
It does not include Hermes itself, Python, model weights, llama.cpp, browser/desktop
drivers, or other harnesses. Configure your installed dependencies in Settings.
Existing local server connections do not require a GGUF/runtime selection.
See [MODELS.md](MODELS.md) and [HARNESSES.md](HARNESSES.md).
