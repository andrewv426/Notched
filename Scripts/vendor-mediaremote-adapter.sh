#!/bin/bash
# Copies ungive/mediaremote-adapter at a pinned commit into Vendor/MediaRemoteAdapter, unchanged.
# Rerun it and `git diff Vendor/` to check that the vendored files are exactly upstream's.
# Usage: Scripts/vendor-mediaremote-adapter.sh [commit]   (default: the pinned one below)
#
# Copied: LICENSE (BSD-3), bin/mediaremote-adapter.pl, include/, src/adapter, src/private, src/utility,
# and src/test/NowPlayingTest.h, which the adapter includes.
# Left out: the test client's sources, CMake and editor files, scripts and the README.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=https://github.com/ungive/mediaremote-adapter.git
COMMIT=${1:-2ef957c736256cee7905c9f3f1c7e279087bf195}   # tag v0.9.0
DEST=Vendor/MediaRemoteAdapter

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" fetch -q --depth 1 "$REPO" "$COMMIT"
git -C "$WORK" checkout -q FETCH_HEAD

rm -rf "$DEST"
mkdir -p "$DEST"
(cd "$WORK" && tar -cf - LICENSE bin/mediaremote-adapter.pl include src/adapter src/private src/utility src/test/NowPlayingTest.h) | tar -xf - -C "$DEST"
printf '%s\n%s\n' "$REPO" "$(git -C "$WORK" rev-parse HEAD)" > "$DEST/UPSTREAM"
echo "vendored $(git -C "$WORK" rev-parse HEAD) into $DEST"
