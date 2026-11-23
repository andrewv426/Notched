#!/bin/bash
# The single gate. Default: package build + headless tests + app build into .build/xcode, then the
# disk image .build/Notched-<version>.dmg, installed into /Applications (Scripts/package.sh).
#   --no-app    skip the Xcode app build and the disk image
#   --no-dmg    skip the disk image and the install
#   --ui        also run the in-app smoke test (launches the app in the background for a few seconds)
# Quiet on success; prints the full log of any step that fails.
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=Packages/NotchedKit
APP=1; UI=0; DMG=1
for arg in "$@"; do
  case "$arg" in
    --no-app) APP=0 ;;
    --no-dmg) DMG=0 ;;
    --ui) UI=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ $UI -eq 1 && $APP -eq 0 ]]; then echo "--ui needs the app build; drop --no-app" >&2; exit 2; fi

step() { printf '\n==> %s\n' "$1"; }

# Runs a command quietly: prints only lines matching the pattern on success,
# the whole log on failure.
filtered() {
  local pattern=$1; shift
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    grep -E "$pattern" "$log" || true
    rm -f "$log"
  else
    cat "$log"; rm -f "$log"; exit 1
  fi
}

step "Package build (warnings are errors)"
filtered "Build complete" swift build --package-path "$PKG"

step "Headless tests"
filtered "✘|Test run" swift test --package-path "$PKG"

if [[ $APP -eq 1 ]]; then
  step "App build"
  filtered "BUILD SUCCEEDED" xcodegen generate --quiet
  filtered "BUILD SUCCEEDED" xcodebuild -project Notched.xcodeproj -scheme Notched -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode build -quiet
  echo "built .build/xcode/Build/Products/Debug/Notched.app"
fi

if [[ $UI -eq 1 ]]; then
  step "In-app smoke test (runs in the background; NOTCHED_FOREGROUND=1 to watch)"
  Scripts/selftest.sh .build/selftest
fi

if [[ $APP -eq 1 && $DMG -eq 1 ]]; then
  Scripts/package.sh
fi

printf '\nverify: all green\n'
