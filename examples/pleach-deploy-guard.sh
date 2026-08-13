#!/usr/bin/env bash
# pleach-deploy-guard - example Claude Code PreToolUse (Bash) hook.
#
# Blocks deployment commands run INSIDE a pleach session. Rationale: two sessions
# shipping to the same target collide in the ENVIRONMENT, not in the files - git
# offers no protection there. This turns "ship from the canonical only" from a
# convention into a structural rule.
#
# Register it in your project's .claude/settings.json:
#
#   { "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
#       { "type": "command",
#         "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/pleach-deploy-guard.sh\"" } ] } ] } }
#
# Customise the blocked commands with PLEACH_GUARDED_COMMANDS, a "|"-separated
# list of substrings. The default covers the common serverless and IaC CLIs.
#
# Tolerant by design: a missing dependency or a parse failure exits 0. A hook
# that dies must never stop the original tool from running.
set -u

DEFAULT_GUARDED='wrangler deploy|wrangler versions upload|fly deploy|flyctl deploy|vercel deploy|sst deploy|serverless deploy|terraform apply'
GUARDED="${PLEACH_GUARDED_COMMANDS:-$DEFAULT_GUARDED}"

# Without jq we will not risk hand-parsing the hook JSON - let it through.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

matched=""
old_ifs="$IFS"
IFS="|"
# shellcheck disable=SC2086  # deliberate split: GUARDED is a "|"-separated list
for needle in $GUARDED; do
  [ -n "$needle" ] || continue
  case "$cmd" in
    *"$needle"*) matched="$needle"; break ;;
  esac
done
IFS="$old_ifs"
[ -n "$matched" ] || exit 0

# It is a shipping command. Are we inside a session? Walk up for .session-env.
find_session() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.session-env" ] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

session_dir=""
if found="$(find_session "${PWD:-.}")"; then
  session_dir="$found"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && found="$(find_session "$CLAUDE_PROJECT_DIR")"; then
  session_dir="$found"
fi
[ -n "$session_dir" ] || exit 0

canonical="$(grep -m1 '^export PLEACH_CANONICAL=' "$session_dir/.session-env" 2>/dev/null | cut -d= -f2- | tr -d '"')"
{
  echo "[pleach-deploy-guard] blocked: '$matched' inside a pleach session ($session_dir)."
  echo "This command runs from the canonical checkout only${canonical:+: $canonical}."
  echo "Two sessions shipping to the same target collide in the environment, not in the files."
} >&2
exit 2
