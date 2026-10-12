#!/usr/bin/env bash
# Build the release `black-team` command with the right toolchain for this computer and link it into ~/.local/bin.
#   macos/dev/install-cli.sh              -> ~/.local/bin/black-team
#   macos/dev/install-cli.sh --to ~/bin   -> another folder (install-command refuses to replace anything that is not a Black Team link)
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)" in
  Darwin) SWIFT=swift; BUILD=(build) ;;
  Linux)
    # Swift for Linux kept in the home folder by swiftly; bt-swift sets up its libraries.
    if [ -x "$HOME/.local/share/swiftly/bin/bt-swift" ]; then SWIFT="$HOME/.local/share/swiftly/bin/bt-swift"; BUILD=(build)
    elif command -v swift >/dev/null 2>&1; then SWIFT=swift; BUILD=(build)
    else echo "Swift is not installed. Install Swift 6 from https://swift.org/install and run this again." >&2; exit 1; fi ;;
  *) echo "Black Team's command runs on macOS and Linux only." >&2; exit 1 ;;
esac
"$SWIFT" "${BUILD[@]}" -c release --product black-team
BIN="$("$SWIFT" build -c release --show-bin-path)"
exec "$BIN/black-team" install-command "$@"
