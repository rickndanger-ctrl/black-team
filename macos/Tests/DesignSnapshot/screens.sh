#!/usr/bin/env bash
# Renders the daily-app screens (1280 points wide, scale 2) on the mini and copies them to the folder given as $1,
# under the names of the reference screenshots (a0-command-center-full.png, b6-chat-done.png, ...).
# Uses its own build slot, "daily", so it does not disturb other work.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"; mkdir -p "$out"
slot="${BT_SLOT:-daily}"
"$here/dev/mini.sh" "$slot" all true
ssh macmini1 "bash -s $slot" <<'REMOTE'
cd ~/bt-build/$1
grep -q DesignSnapshot Package.swift || perl -0pi -e 's|(\.testTarget\(name: "BlackTeamKitTests")|.testTarget(name: "DesignSnapshot", dependencies: ["BlackTeamUI", "BlackTeamKit"], path: "Tests/DesignSnapshot", exclude: ["run.sh", "screens.sh"], swiftSettings: [.swiftLanguageMode(.v5)]),\n        $1|' Package.swift
rm -f "$TMPDIR"/bt-screen-*.png
swift test --filter ScreenSnapshotTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'error:|passed|failed|Executed [1-9]' | head -40
REMOTE
tmp=$(ssh macmini1 'echo $TMPDIR')
for f in $(ssh macmini1 "ls ${tmp}bt-screen-*.png"); do scp -q "macmini1:$f" "$out/$(basename "$f" | sed 's/bt-screen-//')"; done
