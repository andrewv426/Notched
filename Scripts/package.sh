#!/bin/bash
# Builds a Release Notched.app, wraps it in a disk image, and installs the app from that image into
# /Applications, so it launches from Spotlight. A copy already running from /Applications is quit
# first and relaunched after.
# Usage: Scripts/package.sh [--no-install]   → .build/Notched-<version>.dmg (and /Applications/Notched.app)
# The app is ad-hoc signed, not notarized: it launches on the Mac that built it. Another Mac's
# Gatekeeper blocks a downloaded copy until it is allowed in System Settings › Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

DERIVED=.build/release
STAGE=.build/dmg-stage

step() { printf '\n==> %s\n' "$1"; }

# Runs a command quietly: prints the whole log only on failure.
quiet() {
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then rm -f "$log"; else cat "$log"; rm -f "$log"; exit 1; fi
}

step "Release build"
quiet xcodegen generate --quiet
quiet xcodebuild -project Notched.xcodeproj -scheme Notched -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" build
APP="$DERIVED/Build/Products/Release/Notched.app"
codesign --verify --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG=".build/Notched-$VERSION.dmg"

step "Disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Notched.app"
ln -s /Applications "$STAGE/Applications"
quiet hdiutil create -volname "Notched $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
quiet hdiutil verify "$DMG"

echo "built $DMG"
[[ $INSTALL -eq 1 ]] || exit 0

step "Install into /Applications"
TARGET=/Applications/Notched.app
RUNNING="$TARGET/Contents/MacOS/Notched"
WAS_RUNNING=0
if pgrep -f "$RUNNING" >/dev/null; then
  WAS_RUNNING=1
  pkill -f "$RUNNING"
  for _ in $(seq 1 50); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.1; done
fi
MOUNT=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null; rmdir "$MOUNT" 2>/dev/null' EXIT
# Update the bundle in place: deleting and re-creating it makes Spotlight drop it from the index
# after it has been imported.
if [[ -d $TARGET ]]; then
  rsync -a --delete "$MOUNT/Notched.app/" "$TARGET/"
else
  ditto "$MOUNT/Notched.app" "$TARGET"
fi
codesign --verify --strict "$TARGET"
echo "installed $TARGET"

# Tell Launch Services and Spotlight now rather than whenever they next scan, and wait until a
# Spotlight query actually finds it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
indexed=0
for _ in 1 2 3; do
  mdimport -i "$TARGET" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    if mdfind "kMDItemCFBundleIdentifier == 'app.notched.Notched'" 2>/dev/null | grep -qx "$TARGET"; then
      indexed=1; break 2
    fi
    sleep 0.5
  done
done
if [[ $indexed -eq 1 ]]; then
  echo "Spotlight finds Notched"
else
  echo "note: Spotlight has not indexed Notched yet; it will on its next scan"
fi
if [[ $WAS_RUNNING -eq 1 ]]; then
  open "$TARGET"
  echo "relaunched Notched"
fi
