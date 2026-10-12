#!/usr/bin/env bash
# Build the engine the Linux package ships: macos/.build/engine/black-team.
# It is fully static (Swift's Static Linux SDK, musl), so it runs on any x86-64 Linux whatever its C library version.
# Needs the SDK once:  swift sdk install <the static-linux bundle for your Swift version from swift.org> --checksum <its checksum>
# SWIFT names the swift launcher to use (default: swift).
set -euo pipefail
cd "$(dirname "$0")/../macos"
swift_cmd="${SWIFT:-swift}"
"$swift_cmd" build -c release --swift-sdk x86_64-swift-linux-musl --product black-team --scratch-path .build/static
mkdir -p .build/engine
cp .build/static/x86_64-swift-linux-musl/release/black-team .build/engine/black-team.new
strip .build/engine/black-team.new
mv .build/engine/black-team.new .build/engine/black-team
echo "engine: $(pwd)/.build/engine/black-team"
