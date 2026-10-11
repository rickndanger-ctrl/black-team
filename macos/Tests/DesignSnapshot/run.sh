#!/usr/bin/env bash
# Renders DesignGallery to PNGs on the mini and copies them to the folder given as $1.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"; mkdir -p "$out"
"$here/dev/mini.sh" design Markdown,ui true
rsync -a "$here/Tests/DesignSnapshot/" macmini1:bt-build/design/Tests/DesignSnapshot/
ssh macmini1 'cd ~/bt-build/design && perl -0pi -e '"'"'s|(\.testTarget\(name: "BlackTeamKitTests")|.testTarget(name: "DesignSnapshot", dependencies: ["BlackTeamUI", "BlackTeamKit"], path: "Tests/DesignSnapshot", exclude: ["run.sh"], swiftSettings: [.swiftLanguageMode(.v5)]),\n        $1|'"'"' Package.swift && swift test --filter DesignSnapshot 2>&1 | grep -E "error|SNAPSHOT|passed|failed" | head -30'
for t in covert light ghost; do
  p=$(ssh macmini1 'echo $TMPDIR')bt-gallery-$t.png
  scp -q "macmini1:$p" "$out/gallery-$t.png"
done
