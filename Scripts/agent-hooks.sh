#!/bin/bash
# Installs or removes the Claude Code hooks that show agents in the notch.
#
# Usage: Scripts/agent-hooks.sh print|install|uninstall
#   print       prints the hooks snippet; changes nothing
#   install     copies the notched-agent helper to a stable path, then merges the hooks into
#               Claude Code's settings.json. Running it again changes nothing.
#   uninstall   removes exactly the entries whose command runs Notched/bin/notched-agent, and the helper.
#
# Before changing settings.json it saves a copy beside it (settings.json.notched-backup-<time>).
# Every other key and every other hook is kept. jq rewrites the file with two-space indentation.
#
# Overrides, for tests (the real files are never touched when these are set):
#   NOTCHED_CLAUDE_SETTINGS   settings file   (default ~/.claude/settings.json)
#   NOTCHED_SUPPORT_DIR       helper's home   (default ~/Library/Application Support/Notched)
#   NOTCHED_APP               the app to copy the helper from (default /Applications/Notched.app)
set -euo pipefail

SETTINGS=${NOTCHED_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}
SUPPORT=${NOTCHED_SUPPORT_DIR:-$HOME/Library/Application Support/Notched}
APP=${NOTCHED_APP:-/Applications/Notched.app}
JQ=$(command -v jq || echo /usr/bin/jq)

# The command is the marker: install and uninstall recognise our entries by this path. The guard
# makes every hook a silent no-op once the helper is deleted, and `exit 0` means a hook never fails.
COMMAND='h="$HOME/Library/Application Support/Notched/bin/notched-agent"; [ -x "$h" ] && "$h" hook claude; exit 0'
MARKER='Notched/bin/notched-agent'

snippet() {
  "$JQ" -n --arg command "$COMMAND" '
    def entry: {type: "command", command: $command, timeout: 5};
    def any_tool: [{matcher: "*", hooks: [entry]}];
    def always: [{hooks: [entry]}];
    {hooks: {
      UserPromptSubmit: always,
      PreToolUse: any_tool,
      PermissionRequest: any_tool,
      PostToolUse: any_tool,
      PostToolUseFailure: any_tool,
      Notification: always,
      Stop: always,
      StopFailure: always,
      SessionEnd: always
    }}'
}

# settings.json without our entries; events left empty, and an empty hooks object, are dropped.
STRIP='
  def ours: any(.hooks[]?; (.command? // "") | contains($marker));
  if has("hooks") then
    .hooks |= (with_entries(.value |= map(select(ours | not))) | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end'

current() {
  if [[ -s $SETTINGS ]]; then "$JQ" . "$SETTINGS"; else echo '{}'; fi
}

# Writes stdin to settings.json only when it differs, saving a backup first.
write_settings() {
  local next; next=$(mktemp)
  cat >"$next"
  if { [[ -f $SETTINGS ]] && cmp -s <("$JQ" . "$SETTINGS") "$next"; } \
     || { [[ ! -f $SETTINGS ]] && [[ $("$JQ" -c . "$next") == '{}' ]]; }; then
    rm -f "$next"; echo "settings unchanged: $SETTINGS"; return
  fi
  mkdir -p "$(dirname "$SETTINGS")"
  if [[ -f $SETTINGS ]]; then
    local backup; backup="$SETTINGS.notched-backup-$(date +%Y%m%d-%H%M%S)"
    cp -p "$SETTINGS" "$backup"
    echo "saved $backup"
    diff -u "$backup" "$next" || true
  fi
  chmod 600 "$next"
  mv "$next" "$SETTINGS"
  echo "updated $SETTINGS"
}

case "${1:-}" in
  print)
    snippet
    ;;
  install)
    helper="$APP/Contents/Helpers/notched-agent"
    [[ -x $helper ]] || { echo "no helper at $helper; install Notched first (Scripts/verify.sh)" >&2; exit 1; }
    mkdir -p "$SUPPORT/bin"
    cp "$helper" "$SUPPORT/bin/.notched-agent.new"
    chmod 755 "$SUPPORT/bin/.notched-agent.new"
    mv "$SUPPORT/bin/.notched-agent.new" "$SUPPORT/bin/notched-agent"
    echo "installed $SUPPORT/bin/notched-agent"
    current | "$JQ" --arg marker "$MARKER" --argjson ours "$(snippet)" "$STRIP"'
      | .hooks = reduce ($ours.hooks | to_entries[]) as $e (.hooks // {}; .[$e.key] = ((.[$e.key] // []) + $e.value))' \
      | write_settings
    ;;
  uninstall)
    current | "$JQ" --arg marker "$MARKER" "$STRIP" | write_settings
    rm -f "$SUPPORT/bin/notched-agent"
    echo "removed $SUPPORT/bin/notched-agent"
    ;;
  *)
    echo "usage: $0 print|install|uninstall" >&2
    exit 2
    ;;
esac
