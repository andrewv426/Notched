#!/bin/bash
# Runs the in-app self-test in the foreground inside a Tart macOS VM, so the checks that need
# keyboard focus run too. The app takes focus inside the VM, never on this Mac's screen.
#
# Usage: Scripts/vm-selftest.sh [checkout]   (default: this checkout, uncommitted changes included)
#   NOTCHED_VM=<name>   the VM to use (default: flotion-test). It must be running, with its user
#                       logged in to the desktop:  tart run --no-graphics <name> &
#
# Copies the checkout's files (tracked and untracked, not git-ignored) to ~/notched-vm/<checkout name>
# in the VM, runs Scripts/verify.sh there, launches the self-test's first phase through
# LaunchServices with NOTCHED_FOREGROUND=1, then the live media check (the real adapter against a
# fixture player, which receives every playback command, and the VM's output volume), and copies the
# results to .build/vm-selftest/ (the live media check's to .build/vm-selftest/media/).
# It fails if any check fails or is still skipped.
set -euo pipefail
# Tart installs to ~/.local/bin, which is not on every shell's PATH.
export PATH="$HOME/.local/bin:$PATH"

SRC=$(cd "${1:-$(dirname "$0")/..}" && pwd)
VM=${NOTCHED_VM:-flotion-test}
RUN="notched-vm/$(basename "$SRC")"     # relative to the VM user's home
OUT="$SRC/.build/vm-selftest"

guest() { tart exec "$VM" /bin/bash -c "$1"; }
step() { printf '\n==> %s\n' "$1"; }

if ! tart ip "$VM" >/dev/null 2>&1; then
  echo "VM '$VM' is not running. Start it with: tart run --no-graphics $VM &" >&2
  exit 2
fi
if [[ $(guest 'stat -f %Su /dev/console') != $(guest 'id -un') ]]; then
  echo "Nobody is logged in to the VM's desktop, so the app cannot show windows there." >&2
  exit 2
fi

step "Copy $SRC to ~/$RUN in $VM"
# Keep the VM's .build so later runs build incrementally; replace everything else.
guest "mkdir -p ~/$RUN && find ~/$RUN -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +"
(cd "$SRC" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) \
  | tart exec -i "$VM" tar -x -C "$RUN"

step "Build and test in the VM (Scripts/verify.sh --no-dmg)"
guest "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; cd ~/$RUN && ./Scripts/verify.sh --no-dmg"

step "In-app self-test in the VM, in the foreground"
# Launched through LaunchServices (open), as a user's launch would be. macOS only lets an app
# take focus that way; started as a plain child process, it stays in the background.
guest "
  cd ~/$RUN
  out=\$PWD/.build/vm-selftest
  rm -rf \"\$out\"; mkdir -p \"\$out\"
  open -W -n --env NOTCHED_SELFTEST=\"\$out\" --env NOTCHED_FOREGROUND=1 \
    --stdout \"\$out/app.log\" --stderr \"\$out/app.log\" \
    .build/xcode/Build/Products/Debug/Notched.app --args -ApplePersistenceIgnoreState YES &
  for _ in \$(seq 1 90); do kill -0 \$! 2>/dev/null || exit 0; sleep 2; done
  pkill -f \"\$PWD/.build/xcode/Build/Products/Debug/Notched.app/Contents/MacOS/Notched\"
  echo 'self-test timed out after 3 minutes'
"

step "Live media check in the VM (real adapter, fixture player, CoreAudio)"
guest "
  cd ~/$RUN
  out=\$PWD/.build/vm-selftest/media
  rm -rf \"\$out\"; mkdir -p \"\$out\"
  pkill -f FixturePlayer.app/Contents/MacOS/FixturePlayer || true
  Scripts/fixture-player/build.sh .build/FixturePlayer.app
  : > \"\$out/commands.log\"
  open -n .build/FixturePlayer.app --args \"\$out/commands.log\"
  sleep 2
  open -W -n --env NOTCHED_SELFTEST=\"\$out\" --env NOTCHED_SELFTEST_MEDIA=live --env NOTCHED_FIXTURE_LOG=\"\$out/commands.log\" \
    --stdout \"\$out/app.log\" --stderr \"\$out/app.log\" \
    .build/xcode/Build/Products/Debug/Notched.app --args -ApplePersistenceIgnoreState YES &
  for _ in \$(seq 1 45); do kill -0 \$! 2>/dev/null || break; sleep 2; done
  pkill -f \"\$PWD/.build/xcode/Build/Products/Debug/Notched.app/Contents/MacOS/Notched\" && echo 'live media check timed out after 90 s'
  pkill -f FixturePlayer.app/Contents/MacOS/FixturePlayer || true
"

rm -rf "$OUT"; mkdir -p "$OUT"
tart exec "$VM" tar -C "$RUN/.build/vm-selftest" -cf - . | tar -x -C "$OUT"
# One launch writes result.txt, or result-<phase>.txt once the self-test has phases.
RESULT=$(ls "$OUT"/result.txt "$OUT"/result-main.txt 2>/dev/null | head -1 || true)
if [[ -z $RESULT ]]; then
  echo "no result written; see $OUT/app.log"
  exit 1
fi
cat "$RESULT"
echo "results and PNGs: $OUT"
if grep -q '^skip ' "$RESULT"; then
  echo "checks were skipped: the app did not get focus in the VM"
  exit 1
fi
grep -q 'RESULT pass=[0-9]* fail=0 ' "$RESULT"

echo
cat "$OUT/media/result.txt" 2>/dev/null || { echo "the live media check wrote no result; see $OUT/media/app.log"; exit 1; }
grep -q 'RESULT pass=[0-9]* fail=0 skip=0' "$OUT/media/result.txt"
