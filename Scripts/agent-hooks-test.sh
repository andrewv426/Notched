#!/bin/bash
# Tests Scripts/agent-hooks.sh against temporary copies only: every path it could touch is
# overridden, and HOME points into the temp directory too. Run by Scripts/verify.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export NOTCHED_CLAUDE_SETTINGS="$T/claude/settings.json"
export NOTCHED_SUPPORT_DIR="$T/support"
export NOTCHED_APP="$T/Notched.app"
mkdir -p "$HOME" "$NOTCHED_APP/Contents/Helpers"
printf '#!/bin/sh\necho "$@" >> "%s/helper-calls"\n' "$T" >"$NOTCHED_APP/Contents/Helpers/notched-agent"
chmod 755 "$NOTCHED_APP/Contents/Helpers/notched-agent"

HOOKS=Scripts/agent-hooks.sh
passed=0
ok() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1"; exit 1; }
events() { jq -r '.hooks | keys_unsorted | join(",")' "$NOTCHED_CLAUDE_SETTINGS"; }
ours() { jq '[.hooks[][] | select(any(.hooks[]; .command | contains("Notched/bin/notched-agent")))] | length' "$NOTCHED_CLAUDE_SETTINGS"; }
backups() { ls "$NOTCHED_CLAUDE_SETTINGS".notched-backup-* 2>/dev/null | wc -l | tr -d ' '; }

$HOOKS install >/dev/null
[[ $(ours) == 9 ]] || fail "install into a missing settings file adds 9 hook entries, got $(ours)"
[[ $(events) == "UserPromptSubmit,PreToolUse,PermissionRequest,PostToolUse,PostToolUseFailure,Notification,Stop,StopFailure,SessionEnd" ]] \
  || fail "the events are the snippet's, got $(events)"
ok "install creates settings.json with one entry per event"
[[ -x $NOTCHED_SUPPORT_DIR/bin/notched-agent ]] || fail "the helper is copied to the stable path"
ok "install copies the helper to the stable path"
[[ $(jq -S . "$NOTCHED_CLAUDE_SETTINGS") == "$($HOOKS print | jq -S .)" ]] || fail "print matches what install writes"
ok "print shows exactly what install writes"

before=$(shasum "$NOTCHED_CLAUDE_SETTINGS")
[[ $($HOOKS install) == *"settings unchanged"* ]] || fail "a second install reports no change"
[[ $(shasum "$NOTCHED_CLAUDE_SETTINGS") == "$before" && $(ours) == 9 && $(backups) == 0 ]] \
  || fail "a second install leaves the file byte-identical, with no backup"
ok "install is idempotent"

rm -f "$NOTCHED_CLAUDE_SETTINGS"
cat >"$NOTCHED_CLAUDE_SETTINGS" <<'JSON'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }],
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "./guard.sh" }] }]
  },
  "enabledPlugins": { "pstack@open-pstack": true }
}
JSON
original=$(jq . "$NOTCHED_CLAUDE_SETTINGS")
$HOOKS install >/dev/null
[[ $(ours) == 9 ]] || fail "install beside other hooks adds 9 entries"
[[ $(jq -r '.hooks.Stop[0].hooks[0].command' "$NOTCHED_CLAUDE_SETTINGS") == "say done" \
   && $(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$NOTCHED_CLAUDE_SETTINGS") == "./guard.sh" ]] \
  || fail "the user's own hooks stay first"
[[ $(jq -r 'keys_unsorted | join(",")' "$NOTCHED_CLAUDE_SETTINGS") == "model,permissions,hooks,enabledPlugins" \
   && $(jq -c .permissions "$NOTCHED_CLAUDE_SETTINGS") == '{"allow":["Bash(ls:*)"]}' ]] \
  || fail "every other key is kept, in order"
[[ $(backups) == 1 ]] || fail "changing an existing file saves one backup"
ok "install keeps the user's hooks and settings, and backs the file up"
$HOOKS install >/dev/null
[[ $(ours) == 9 && $(backups) == 1 ]] || fail "reinstalling beside other hooks changes nothing"
ok "install beside other hooks is idempotent"

$HOOKS uninstall >/dev/null
[[ $(jq . "$NOTCHED_CLAUDE_SETTINGS") == "$original" ]] || fail "uninstall restores the original settings exactly"
[[ ! -e $NOTCHED_SUPPORT_DIR/bin/notched-agent ]] || fail "uninstall removes the helper"
ok "uninstall removes exactly our entries and the helper"
[[ $($HOOKS uninstall) == *"settings unchanged"* ]] || fail "a second uninstall changes nothing"
ok "uninstall is idempotent"

rm -f "$NOTCHED_CLAUDE_SETTINGS"
$HOOKS uninstall >/dev/null
[[ ! -e $NOTCHED_CLAUDE_SETTINGS ]] || fail "uninstall never creates a settings file"
ok "uninstall with no settings file creates none"

echo '{ not json' >"$NOTCHED_CLAUDE_SETTINGS"
if $HOOKS install >/dev/null 2>&1; then fail "install refuses a settings file that is not JSON"; fi
[[ $(cat "$NOTCHED_CLAUDE_SETTINGS") == '{ not json' ]] || fail "a broken settings file is left untouched"
ok "install leaves a broken settings file alone and fails"

command=$($HOOKS print | jq -r '.hooks.Stop[0].hooks[0].command')
out=$(sh -c "$command" 2>&1); status=$?
[[ $status -eq 0 && -z $out ]] || fail "with no helper installed the hook exits 0 silently"
mkdir -p "$HOME/Library/Application Support/Notched/bin"
cp "$NOTCHED_APP/Contents/Helpers/notched-agent" "$HOME/Library/Application Support/Notched/bin/"
sh -c "$command"
[[ $(cat "$T/helper-calls") == "hook claude" ]] || fail "the hook command runs the helper with 'hook claude'"
ok "the hook command is a no-op without the helper and runs it when installed"

echo "agent-hooks: $passed checks passed"
