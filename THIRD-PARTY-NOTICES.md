# Black Team third-party notices

This preview includes the following software. Their licenses apply to their
respective components. Black Team itself is licensed under the GNU Affero General
Public License, version 3; see `LICENSE`.

| Component | License | Included license text |
| --- | --- | --- |
| Electron | MIT | Runtime root `LICENSE` |
| Chromium and Electron bundled components | Multiple | Runtime root `LICENSES.chromium.html` |
| React | MIT | `resources/app/third-party/react-LICENSE.txt` |
| React DOM | MIT | `resources/app/third-party/react-dom-LICENSE.txt` |
| Scheduler | MIT | `resources/app/third-party/scheduler-LICENSE.txt` |
| QRCode | MIT | `resources/app/third-party/qrcode-LICENSE.txt` |
| dijkstrajs | MIT | `resources/app/third-party/dijkstrajs-LICENSE.txt` |
| Adwaita Sans, derived from Inter | SIL OFL 1.1 | `resources/app/dist/fonts/Adwaita-OFL.txt` |
| JetBrains Mono | SIL OFL 1.1 | `resources/app/dist/fonts/JetBrainsMono-OFL.txt` |

Vite is a build tool and is not included in the runtime payload. React and its
runtime dependencies are compiled into the local renderer assets. Font files and
licenses are served locally. No model weights or llama.cpp executable are bundled
in this preview; users supply a compatible runtime and model under those
components' own licenses. The distribution's `BUILD.json` records the application
and Electron versions and the SHA-256 of the supplied runtime ZIP.

Hermes Agent is an optional, separately installed dependency, not included in
this archive. It is published by Nous Research under its upstream license.
Black Team includes its own Hermes host/Companion plugin glue. Other selected
harnesses, model servers, browser/desktop drivers, and models retain their
respective licenses.
