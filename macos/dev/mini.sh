#!/usr/bin/env bash
# Build or test the Mac app on the Mac mini from the Linux laptop, which has no Swift.
#
#   dev/mini.sh <slot> <areas> <command...>
#
# <slot>   a private build folder on the mini, so parallel work does not collide
# <areas>  comma-separated folders of Sources/BlackTeamKit and Tests/BlackTeamKitTests to
#          send (Support is always sent), "ui" for the interface targets, or "all"
# <command> what to run in the package folder there, e.g. swift build, swift test --filter X
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
slot="$1"; areas="$2"; shift 2
host="${BLACK_TEAM_MAC:-macmini1}"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
if [ "$areas" = all ]; then
  rsync -a --exclude .build --exclude build "$here/" "$stage/"
else
  mkdir -p "$stage/Sources/BlackTeamKit" "$stage/Tests/BlackTeamKitTests"
  cp "$here/Package.swift" "$stage/"
  for area in Support ${areas//,/ }; do
    [ "$area" = ui ] && continue
    for base in Sources/BlackTeamKit Tests/BlackTeamKitTests; do
      [ -d "$here/$base/$area" ] && cp -r "$here/$base/$area" "$stage/$base/"
    done
  done
  if [[ ",$areas," == *,ui,* ]]; then
    cp -r "$here/Sources/BlackTeamUI" "$here/Sources/BlackTeam" "$stage/Sources/"
  else
    # The interface targets must exist for the package to load; send empty stand-ins.
    mkdir -p "$stage/Sources/BlackTeamUI/Resources" "$stage/Sources/BlackTeam"
    echo 'public enum BlackTeamUIPlaceholder {}' > "$stage/Sources/BlackTeamUI/Placeholder.swift"
    touch "$stage/Sources/BlackTeamUI/Resources/.keep"
    echo 'print("placeholder")' > "$stage/Sources/BlackTeam/main.swift"
  fi
  mkdir -p "$stage/Sources/BlackTeamCLI"
  echo 'print("placeholder")' > "$stage/Sources/BlackTeamCLI/main.swift"
fi
rsync -a --delete --exclude .build --exclude build "$stage/" "$host:bt-build/$slot/"
ssh -o BatchMode=yes "$host" "cd ~/bt-build/$slot && $*"
