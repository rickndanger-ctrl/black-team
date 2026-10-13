#!/usr/bin/env bash
# Build "Black Team.app" with SwiftPM and wrap it in an app bundle. Run on a Mac.
#   ./build-app.sh             -> build/Black Team.app, signed for this Mac only
#   ./build-app.sh --install   -> also copy it to ~/Applications
#   ./build-app.sh --release   -> sign with a Developer ID, make the download
#                                 (build/Black-Team-<version>-mac-<arch>.zip + .sha256),
#                                 and notarize it when NOTARY_PROFILE names a
#                                 notarytool keychain profile
# SIGN_IDENTITY chooses the Developer ID when there is more than one.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
# BLACK_TEAM_VERSION wins when set, so a release build cannot pick up a neighbouring checkout's version.
VERSION="${BLACK_TEAM_VERSION:-$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' ../package.json 2>/dev/null | head -1)}"
VERSION="${VERSION:-0.1.0}"
ARCH="$(uname -m)"
swift build -c release --product BlackTeam
swift build -c release --product black-team
BIN="$(swift build -c release --show-bin-path)"
APP="build/Black Team.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BlackTeam" "$APP/Contents/MacOS/BlackTeam"
# The terminal program, so `black-team install-command` can link the one inside the app.
cp "$BIN/black-team" "$APP/Contents/MacOS/black-team"
# SwiftPM's resource bundles (fonts, logo); the app looks for them in Resources.
for bundle in "$BIN"/*.bundle; do [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Black Team Agent</string>
  <key>CFBundleDisplayName</key><string>Black Team Agent</string>
  <key>CFBundleIdentifier</key><string>com.rickndanger.blackteam</string>
  <key>CFBundleExecutable</key><string>BlackTeam</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION%%-*}</string>
  <key>CFBundleVersion</key><string>${BLACK_TEAM_BUILD:-1}</string>
  <key>BlackTeamVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>AGPL-3.0-only</string>
</dict></plist>
PLIST
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256; do
  sips -z $s $s Resources/icon-512.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/icon-512.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp ../LICENSE "$APP/Contents/Resources/LICENSE" 2>/dev/null || true
# The phone interface: the web app from `npm run build` in the repository root.
if [ -f ../dist/index.html ]; then
  ditto ../dist "$APP/Contents/Resources/web"
elif [[ $MODE == --release ]]; then
  echo 'The web interface is missing: run "npm run build" in the repository root first.' >&2; exit 1
else
  echo 'Note: ../dist is missing, so this build has no phone interface.' >&2
fi

if [[ $MODE == --release ]]; then
  IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
  [[ -n $IDENTITY ]] || { echo 'No Developer ID Application certificate found in the keychain.' >&2; exit 1; }
  # Sign inside out; the hardened runtime is required for notarization.
  find "$APP/Contents/Resources" -name '*.bundle' -print0 | xargs -0 -I{} codesign --force --timestamp --sign "$IDENTITY" {}
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/black-team"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  ZIP="build/Black-Team-${VERSION}-mac-${ARCH}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
  else
    echo 'Signed but NOT notarized: set NOTARY_PROFILE to notarize. Other Macs will warn until it is.' >&2
  fi
  (cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  echo "release: $ZIP"
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "built: $APP"

if [[ $MODE == --install ]]; then
  mkdir -p ~/Applications
  TARGET="$HOME/Applications/Black Team.app"
  rm -rf "$TARGET.next"
  ditto "$APP" "$TARGET.next"
  codesign --verify --deep --strict "$TARGET.next"
  rm -rf "$TARGET"
  mv "$TARGET.next" "$TARGET"
  echo "installed: $TARGET"
fi
