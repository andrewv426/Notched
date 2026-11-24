#!/bin/bash
# Builds the fixture player (main.swift) into an app bundle, for the live media check in the VM.
# Usage: Scripts/fixture-player/build.sh <output .app path>
set -euo pipefail
APP=$1
SRC="$(cd "$(dirname "$0")" && pwd)/main.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleIdentifier string app.notched.fixture-player" \
  -c "Add :CFBundleName string FixturePlayer" \
  -c "Add :CFBundleExecutable string FixturePlayer" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :LSUIElement bool true" \
  "$APP/Contents/Info.plist" >/dev/null
swiftc -O -swift-version 6 "$SRC" -o "$APP/Contents/MacOS/FixturePlayer"
codesign --sign - --force "$APP" 2>/dev/null
