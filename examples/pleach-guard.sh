#!/usr/bin/env bash
# pleach-guard - example Claude Code SessionStart hook.
#
# Warns when an agent is opened OUTSIDE a pleach session - that is, directly in
# the canonical checkout, where implementation work collides with whatever the
# other sessions are doing.
#
# Register it in your project's .claude/settings.json:
#
#   { "hooks": { "SessionStart": [ { "hooks": [
#       { "type": "command",
#         "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/pleach-guard.sh\"" } ] } ] } }
#
# Deliberately path-agnostic: it recognises a session by the .session-env marker
# pleach writes, and the canonical by .pleach.conf - so it works in any workspace
# with no hardcoded directories.
#
# Tolerant by design: anything unexpected exits 0. A guard must never be the
# reason a session fails to start.
set -u

dir="${CLAUDE_PROJECT_DIR:-$PWD}"

find_up() { # $1 = starting dir, $2 = marker name -> echoes the dir holding it
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -e "$d/$2" ] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# Inside a session: this is the right place, stay quiet.
find_up "$dir" ".session-env" >/dev/null 2>&1 && exit 0

# Not in a session. Is this even a pleach workspace? If not, say nothing.
canonical="$(find_up "$dir" ".pleach.conf" 2>/dev/null)" || exit 0

cat <<EOF
[pleach-guard] This agent was opened in the CANONICAL checkout ($canonical).

The canonical is for integration, releases and maintenance. Implementation work
belongs in an isolated session, so parallel agents cannot overwrite each other:

    pleach open <name>      # creates the session if needed, then opens your tool

If the user explicitly asked to work here, confirm before editing code.
EOF
exit 0
