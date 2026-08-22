#!/usr/bin/env bash
# pleach test harness - runs entirely inside an isolated temporary sandbox.
#
# It NEVER points PLEACH_CANONICAL at a real workspace, and it pins
# PLEACH_EXPECT_CANONICAL to the sandbox so that a wrong cwd cannot resolve
# somewhere else. That guard rail exists because of a real incident: an early
# unpinned harness ran `sync --all` against a live workspace.
#
# This script never modifies the `pleach` under test and never runs git in the
# pleach repo itself - git only ever touches throwaway repos in the sandbox.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLEACH="$ROOT/pleach"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pleach-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

export PLEACH_CANONICAL="$SANDBOX/canon"
export PLEACH_EXPECT_CANONICAL="$SANDBOX/canon"

# Belt and braces: bail out immediately if the canonical is not inside the
# sandbox - no test should be able to escape the temporary directory.
case "$PLEACH_CANONICAL" in
  "$SANDBOX"/*) ;;
  *) echo "guard: canonical outside the sandbox"; exit 1 ;;
esac

CANON="$PLEACH_CANONICAL"
SESSIONS="$SANDBOX/.sessions"

# ---------------------------------------------------------------------------
# Minimal test framework
# ---------------------------------------------------------------------------
TESTS=0
FAILS=0
FAILED_NAMES=""

ok() {
  TESTS=$((TESTS + 1))
  echo "  ok - $1"
}

fail() {
  TESTS=$((TESTS + 1))
  FAILS=$((FAILS + 1))
  # Also collected for the summary. A count on its own is useless the moment the
  # output is piped through `tail`, which is how it gets read from a gate or a CI
  # log — "Failures: 4" with no names sends you back to re-run and hope it happens
  # again. That is exactly what an intermittent failure will not do.
  FAILED_NAMES="${FAILED_NAMES}  - $1
"
  echo "  FAIL - $1" >&2
}

assert_contains() { # <description> <output> <substring>
  local desc="$1" out="$2" needle="$3"
  if [ "${out#*"$needle"}" != "$out" ]; then
    ok "$desc"
  else
    fail "$desc - expected it to contain: [$needle]"
    printf '    captured output:\n%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

assert_not_contains() { # <description> <output> <substring>
  local desc="$1" out="$2" needle="$3"
  if [ "${out#*"$needle"}" != "$out" ]; then
    fail "$desc - it must not contain: [$needle]"
    printf '    captured output:\n%s\n' "$out" | sed 's/^/    | /' >&2
  else
    ok "$desc"
  fi
}

assert_rc() { # <description> <actual-rc> <expected-rc>
  local desc="$1" rc="$2" want="$3"
  if [ "$rc" -eq "$want" ]; then
    ok "$desc"
  else
    fail "$desc - rc=$rc, expected $want"
  fi
}

assert_true() { # <description> <command...> - ok when the command exits 0
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

assert_eq() { # <description> <actual> <expected>
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    fail "$desc - got [$got], expected [$want]"
  fi
}

header() {
  echo ""
  echo "--- $1 ---"
}

# Runs a pleach command, capturing combined output in OUT and the exit code in
# RC. `set -e` safe: the if keeps a non-zero rc from aborting the script.
run() {
  if OUT=$("$@" 2>&1); then RC=0; else RC=$?; fi
}

# Like run(), but with stdin on /dev/null - simulates a non-TTY invocation
# (scripts/agents), used by the `sync --all` tests.
run_noninteractive() {
  if OUT=$("$@" </dev/null 2>&1); then RC=0; else RC=$?; fi
}

# ---------------------------------------------------------------------------
# Fixture: canonical + subA + subB, each a git repo with one commit.
# ---------------------------------------------------------------------------
setup_repo() { # $1 = directory to initialise as a fresh git repo
  mkdir -p "$1"
  git init -q -b main "$1"
  git -C "$1" config user.email "test@test"
  git -C "$1" config user.name "test"
}

# The lock pleach takes is a FILE whose single line names its owner, so a lock is
# present in either of two shapes: that file, or a directory left by an older
# version. `-d` alone silently stops testing — it is false for a file, so
# `[ ! -d ]` would pass over a lock that had leaked.
lock_held()  { [ -e "$SESSIONS/.pleach.lock" ]; }
lock_clear() { ! lock_held; }

setup_fixture() {
  setup_repo "$CANON"
  echo "# canon" > "$CANON/README.md"
  git -C "$CANON" add README.md
  git -C "$CANON" commit -q -m "initial commit in the canonical"

  setup_repo "$CANON/subA"
  printf 'node_modules\n' > "$CANON/subA/.gitignore"
  echo "initial content" > "$CANON/subA/f.txt"
  git -C "$CANON/subA" add .gitignore f.txt
  git -C "$CANON/subA" commit -q -m "initial commit in subA"

  setup_repo "$CANON/subB"
  echo "initial content" > "$CANON/subB/file.txt"
  git -C "$CANON/subB" add file.txt
  git -C "$CANON/subB" commit -q -m "initial commit in subB"
}

echo "sandbox: $SANDBOX"
setup_fixture

# ---------------------------------------------------------------------------
header "Test 1: version"
# ---------------------------------------------------------------------------
run "$PLEACH" version
PKG_VERSION=$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "$ROOT/package.json" | head -1)
assert_rc "version: rc 0" "$RC" 0
assert_eq "version: output matches package.json" "$OUT" "pleach $PKG_VERSION"

# ---------------------------------------------------------------------------
header "Test 2: unexpected-canonical guard rail"
# ---------------------------------------------------------------------------
run env PLEACH_EXPECT_CANONICAL=/nope "$PLEACH" ls
assert_rc "guard: non-zero rc when the canonical differs from the expected one" "$RC" 1
assert_contains "guard: error message" "$OUT" "differs from the expected one"

# ---------------------------------------------------------------------------
header "Test 3: init"
# ---------------------------------------------------------------------------
run bash -c "cd '$CANON' || exit 1; '$PLEACH' init"
assert_rc "init: rc 0" "$RC" 0
assert_true "init: .pleach.conf created" [ -f "$CANON/.pleach.conf" ]
assert_true "init: PLEACH_SUBS detects subA and subB" \
  grep -qF 'PLEACH_SUBS=(subA subB)' "$CANON/.pleach.conf"

# ---------------------------------------------------------------------------
header "Test 4: new s1 --no-bootstrap"
# ---------------------------------------------------------------------------
run "$PLEACH" new s1 --no-bootstrap
assert_rc "new s1: rc 0" "$RC" 0
assert_true "new s1: session lives in the sandbox .sessions dir" \
  [ -d "$SESSIONS/s1" ]
assert_true "new s1: root worktree mounted" [ -e "$SESSIONS/s1/.git" ]
assert_true "new s1: subA worktree mounted" [ -e "$SESSIONS/s1/subA/.git" ]
assert_true "new s1: subB worktree mounted" [ -e "$SESSIONS/s1/subB/.git" ]
assert_eq "new s1: root branch is session/s1" \
  "$(git -C "$SESSIONS/s1" branch --show-current)" "session/s1"
assert_eq "new s1: subA branch is session/s1" \
  "$(git -C "$SESSIONS/s1/subA" branch --show-current)" "session/s1"
assert_eq "new s1: subB branch is session/s1" \
  "$(git -C "$SESSIONS/s1/subB" branch --show-current)" "session/s1"
assert_true "new s1: .session-env exports PORT" \
  grep -q '^export PORT=' "$SESSIONS/s1/.session-env"
assert_true "new s1: VS Code workspace written beside the folder" \
  [ -f "$SESSIONS/s1.code-workspace" ]

# ---------------------------------------------------------------------------
header "Test 5: new s1 a second time fails"
# ---------------------------------------------------------------------------
run "$PLEACH" new s1 --no-bootstrap
assert_rc "new s1 (repeat): non-zero rc" "$RC" 1
assert_contains "new s1 (repeat): says it already exists" "$OUT" "already exists"

# ---------------------------------------------------------------------------
header "Test 6: ls and ls -l"
# ---------------------------------------------------------------------------
run "$PLEACH" ls
assert_rc "ls: rc 0" "$RC" 0
assert_contains "ls: lists s1" "$OUT" "s1"

run "$PLEACH" ls -l
assert_rc "ls -l: rc 0" "$RC" 0
assert_contains "ls -l: shows the root branch" "$OUT" "root: session/s1"
assert_contains "ls -l: marks the session as fully integrated" "$OUT" "fully integrated"

# ---------------------------------------------------------------------------
header "Test 7: sync --dry-run changes nothing"
# ---------------------------------------------------------------------------
git -C "$CANON" commit -q --allow-empty -m "empty commit in the canonical root"
HEAD_BEFORE=$(git -C "$SESSIONS/s1" rev-parse HEAD)

run "$PLEACH" sync s1 --dry-run
assert_rc "sync --dry-run: rc 0" "$RC" 0
assert_contains "sync --dry-run: reports +1 commit to integrate" "$OUT" "would merge +1 commit(s)"
assert_contains "sync --dry-run: reports the pending count" "$OUT" "would be updated"

HEAD_AFTER=$(git -C "$SESSIONS/s1" rev-parse HEAD)
assert_eq "sync --dry-run: root worktree HEAD unchanged" "$HEAD_AFTER" "$HEAD_BEFORE"

# ---------------------------------------------------------------------------
header "Test 8: sync actually integrates"
# ---------------------------------------------------------------------------
run "$PLEACH" sync s1
assert_rc "sync s1: rc 0" "$RC" 0
assert_contains "sync s1: integrates the root" "$OUT" "merged main (+1)"

run "$PLEACH" sync s1
assert_rc "sync s1 (second time): rc 0" "$RC" 0
assert_contains "sync s1 (second time): already up to date" "$OUT" "already up to date"

# ---------------------------------------------------------------------------
header "Test 9: sync skips uncommitted changes"
# ---------------------------------------------------------------------------
printf 'local-change\n' > "$SESSIONS/s1/subA/f.txt"
git -C "$CANON/subA" commit -q --allow-empty -m "empty commit in subA"

run "$PLEACH" sync s1
assert_rc "sync s1 (subA dirty): rc 0" "$RC" 0
assert_contains "sync s1: skips subA over uncommitted changes" "$OUT" "SKIPPED (uncommitted changes)"
assert_eq "sync s1: the local change to f.txt survives" \
  "$(cat "$SESSIONS/s1/subA/f.txt")" "local-change"

git -C "$SESSIONS/s1/subA" checkout -- f.txt

# ---------------------------------------------------------------------------
header "Test 10: sync skips a worktree on another branch"
# ---------------------------------------------------------------------------
git -C "$SESSIONS/s1/subB" checkout -q -b feat/x
git -C "$CANON/subB" commit -q --allow-empty -m "empty commit in subB"

run "$PLEACH" sync s1
assert_rc "sync s1 (subB on another branch): rc 0" "$RC" 0
assert_contains "sync s1: skips subB over the branch mismatch" "$OUT" "SKIPPED (force with: --any-branch)"

run "$PLEACH" sync s1 --any-branch
assert_rc "sync s1 --any-branch: rc 0" "$RC" 0
assert_contains "sync s1 --any-branch: integrates subB on feat/x" "$OUT" "subB: merged main (+1)"

git -C "$SESSIONS/s1/subB" checkout -q session/s1

# ---------------------------------------------------------------------------
header "Test 11: sync --all requires --yes outside a TTY"
# ---------------------------------------------------------------------------
run_noninteractive "$PLEACH" sync --all
assert_rc "sync --all without --yes: non-zero rc" "$RC" 1
assert_contains "sync --all without --yes: demands --yes" "$OUT" "requires --yes"

run_noninteractive "$PLEACH" sync --all --yes
assert_rc "sync --all --yes: rc 0" "$RC" 0

# ---------------------------------------------------------------------------
header "Test 12: rm blocks on pending work; --force removes and keeps the branch"
# ---------------------------------------------------------------------------
echo "work" > "$SESSIONS/s1/g.txt"
git -C "$SESSIONS/s1" add g.txt
git -C "$SESSIONS/s1" commit -q -m "work in progress in the root"

run "$PLEACH" rm s1
assert_rc "rm s1 (no --force): non-zero rc" "$RC" 1
assert_contains "rm s1 (no --force): reports pending work" "$OUT" "pending work"

run "$PLEACH" rm s1 --force
assert_rc "rm s1 --force: rc 0" "$RC" 0
assert_true "rm s1 --force: session folder removed" [ ! -e "$SESSIONS/s1" ]
assert_true "rm s1 --force: session/s1 branch preserved in the canonical" \
  git -C "$CANON" show-ref --verify --quiet refs/heads/session/s1

# ---------------------------------------------------------------------------
header "Test 13: prune (dry run and --apply)"
# ---------------------------------------------------------------------------
run "$PLEACH" new s2 --no-bootstrap
assert_rc "new s2: rc 0" "$RC" 0
run "$PLEACH" new s3 --no-bootstrap
assert_rc "new s3: rc 0" "$RC" 0

echo "work" > "$SESSIONS/s3/h.txt"
git -C "$SESSIONS/s3" add h.txt
git -C "$SESSIONS/s3" commit -q -m "work in progress in s3"

run "$PLEACH" prune
assert_rc "prune (dry run): rc 0" "$RC" 0
assert_contains "prune: s2 is fully integrated" "$OUT" "fully integrated (removable)"
assert_contains "prune: s3 has pending work" "$OUT" "pending work:"
assert_contains "prune: flags itself as a dry run" "$OUT" "Dry run"
assert_true "prune (dry run): s2 still there" [ -d "$SESSIONS/s2" ]
assert_true "prune (dry run): s3 still there" [ -d "$SESSIONS/s3" ]

run "$PLEACH" prune --apply
assert_rc "prune --apply: rc 0" "$RC" 0
assert_true "prune --apply: s2 removed" [ ! -e "$SESSIONS/s2" ]
assert_true "prune --apply: s3 kept" [ -d "$SESSIONS/s3" ]

# ---------------------------------------------------------------------------
header "Test 14: clean (dry run and --apply)"
# ---------------------------------------------------------------------------
mkdir -p "$SESSIONS/s3/subA/node_modules" "$SESSIONS/s3/subA/dist"
echo "junk" > "$SESSIONS/s3/subA/node_modules/junk.txt"
echo "junk" > "$SESSIONS/s3/subA/dist/junk.txt"

run "$PLEACH" clean s3
assert_rc "clean s3 (dry run): rc 0" "$RC" 0
assert_contains "clean: reports node_modules" "$OUT" "node_modules"
assert_contains "clean: preserves a dist that git does not ignore" "$OUT" "not ignored by git (preserved)"
assert_true "clean (dry run): node_modules still there" \
  [ -e "$SESSIONS/s3/subA/node_modules/junk.txt" ]
assert_true "clean (dry run): dist still there" \
  [ -e "$SESSIONS/s3/subA/dist/junk.txt" ]

run "$PLEACH" clean s3 --apply
assert_rc "clean s3 --apply: rc 0" "$RC" 0
assert_true "clean --apply: node_modules removed" \
  [ ! -e "$SESSIONS/s3/subA/node_modules" ]
assert_true "clean --apply: dist preserved" \
  [ -e "$SESSIONS/s3/subA/dist/junk.txt" ]

# ---------------------------------------------------------------------------
header "Test 15: each runs in the canonical and in every session"
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single quotes deliberate: this expands inside the
# `bash -c` pleach runs in each target directory, not here.
run "$PLEACH" each 'echo ping-$(basename "$PWD")'
assert_rc "each: rc 0" "$RC" 0
assert_contains "each: canonical header" "$OUT" "canonical  ("
assert_contains "each: ran inside session s3" "$OUT" "ping-s3"
# The default must not descend. `each` runs the CALLER's command, so widening where
# it lands is a change of blast radius, not a richer report — every other command
# that always descends is running an operation pleach itself defines.
assert_not_contains "each: the default does not descend into sub-repos" "$OUT" "ping-subA"

# --repos: the sub-repos are where most of the work actually lives, and without
# this `pleach each 'git status'` answered for the root worktree only.
# shellcheck disable=SC2016  # same as above: expands inside pleach's bash -c
run "$PLEACH" each --repos 'echo ping-$(basename "$PWD")'
assert_rc "each --repos: rc 0" "$RC" 0
assert_contains "each --repos: reaches a session's sub-repo" "$OUT" "ping-subA"
assert_contains "each --repos: labels it session · repo" "$OUT" "s3 · subA"
assert_contains "each --repos: the root is still visited, and named" "$OUT" "s3 · root"
# The canonical had the same blind spot: only its own root was ever entered.
assert_contains "each --repos: the canonical's sub-repos too" "$OUT" "canonical · subA"
assert_contains "each --repos: and its root" "$OUT" "canonical · root"

# `each` had no flag parsing at all: `pleach each --repos` used to reach bash -c as
# a command. Anything unknown must say so rather than be run.
run "$PLEACH" each --bogus 'true'
assert_rc "each: an unknown flag is an error" "$RC" 1
assert_contains "each: and names it" "$OUT" "unknown flag"
# ...without taking the escape hatch away from a command that starts with a dash.
run "$PLEACH" each -- 'echo dashed'
assert_rc "each: -- ends flag parsing" "$RC" 0
assert_contains "each: and the command still runs" "$OUT" "dashed"
# `--` is only an escape hatch if what follows really escapes: `bash -c "$1"` parses
# a leading dash as a bash OPTION, so the command pleach was handed never ran.
run "$PLEACH" each -- '-x 2>/dev/null || echo dash-led-command-ran'
assert_contains "each: a command starting with a dash reaches the shell, not bash's flags" \
  "$OUT" "dash-led-command-ran"

# --repos must honour an explicit PLEACH_SUBS. Listing what is on DISK would enter a
# vendored or unrelated repo the workspace deliberately left out — and `each` runs
# the caller's command, so that is not a longer report, it is a wider blast radius.
# Its own workspace: adding a repo to the shared fixture would move the sub-repo
# counts every later scenario asserts.
MINIE=$(cd "$SANDBOX" && mkdir -p eachsubs && cd eachsubs && pwd)
setup_repo "$MINIE/canon"
echo root > "$MINIE/canon/f.txt"
git -C "$MINIE/canon" add -A && git -C "$MINIE/canon" commit -q -m "initial"
for r in mine vendored; do
  setup_repo "$MINIE/canon/$r"
  echo "$r" > "$MINIE/canon/$r/f.txt"
  git -C "$MINIE/canon/$r" add -A && git -C "$MINIE/canon/$r" commit -q -m "initial"
done
printf 'PLEACH_SUBS=(mine)\n' > "$MINIE/canon/.pleach.conf"
# shellcheck disable=SC2016  # expands inside pleach's bash -c, not here
run bash -c "env PLEACH_CANONICAL='$MINIE/canon' PLEACH_EXPECT_CANONICAL='$MINIE/canon' '$PLEACH' each --repos 'echo visited-\$(basename \"\$PWD\")'"
assert_rc "each --repos: runs in a workspace with a declared subset" "$RC" 0
assert_contains "each --repos: visits the declared sub-repo" "$OUT" "visited-mine"
assert_not_contains "each --repos: but not the one left out of PLEACH_SUBS" \
  "$OUT" "visited-vendored"

# ---------------------------------------------------------------------------
header "Test 16: add mounts a new sub-repo into an existing session"
# ---------------------------------------------------------------------------
setup_repo "$CANON/subC"
echo "initial content" > "$CANON/subC/file.txt"
git -C "$CANON/subC" add file.txt
git -C "$CANON/subC" commit -q -m "initial commit in subC"

run "$PLEACH" add s3 subC
assert_rc "add s3 subC: rc 0" "$RC" 0
assert_true "add: subC worktree mounted" [ -e "$SESSIONS/s3/subC/.git" ]
assert_eq "add: subC branch is session/s3" \
  "$(git -C "$SESSIONS/s3/subC" branch --show-current)" "session/s3"

# ---------------------------------------------------------------------------
header "Test 17: repos reports drift, --sync aligns the conf"
# ---------------------------------------------------------------------------
run "$PLEACH" repos
assert_rc "repos: rc 0" "$RC" 0
assert_contains "repos: sees subC on disk but not in the conf" "$OUT" "new on disk, absent from the conf: subC"
assert_true "repos: read-only, the conf is untouched" \
  grep -qF 'PLEACH_SUBS=(subA subB)' "$CANON/.pleach.conf"

run "$PLEACH" repos --sync --no-bootstrap
assert_rc "repos --sync: rc 0" "$RC" 0
assert_contains "repos --sync: appends subC to the conf" "$OUT" "PLEACH_SUBS += subC"
assert_true "repos --sync: the conf now lists all three subs" \
  grep -qF 'PLEACH_SUBS=(subA subB subC)' "$CANON/.pleach.conf"
assert_contains "repos --sync: reports the workspace aligned" "$OUT" "workspace aligned"

# ---------------------------------------------------------------------------
header "Test 18: every command is documented"
# ---------------------------------------------------------------------------
# The help text is the only user-facing documentation inside the tool, so a
# command with no help topic is a real defect, not a nicety.
for c in init new open ls path cd add sync status rm prune clean each conflicts repos doctor shell-init completions install update version; do
  run "$PLEACH" help "$c"
  if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
    ok "help $c: documented"
  else
    fail "help $c: missing or errored (rc=$RC)"
  fi
done
run "$PLEACH" help config
assert_rc "help config: rc 0" "$RC" 0
assert_contains "help config: documents PLEACH_EXPECT_CANONICAL" "$OUT" "PLEACH_EXPECT_CANONICAL"

run "$PLEACH" help nonsense
assert_rc "help nonsense: non-zero rc" "$RC" 1

run "$PLEACH" nonsense
assert_rc "unknown command: non-zero rc" "$RC" 1
assert_contains "unknown command: says so" "$OUT" "unknown command"

# ---------------------------------------------------------------------------
header "Test 19: open runs the command inside the session"
# ---------------------------------------------------------------------------
run "$PLEACH" open s3 pwd
assert_rc "open s3 pwd: rc 0" "$RC" 0
assert_contains "open s3 pwd: the command runs in the session folder" "$OUT" "$SESSIONS/s3"

# ---------------------------------------------------------------------------
header "Test 20: runtime identity beyond ports"
# ---------------------------------------------------------------------------
# Worktrees isolate files. Databases and containers are shared state git cannot
# see, so each session carries its own name for them.
assert_true "session-env: exports PLEACH_SLUG" \
  grep -q '^export PLEACH_SLUG=' "$SESSIONS/s3/.session-env"
assert_true "session-env: exports PLEACH_DB_NAME" \
  grep -q '^export PLEACH_DB_NAME=' "$SESSIONS/s3/.session-env"
assert_true "session-env: exports COMPOSE_PROJECT_NAME" \
  grep -q '^export COMPOSE_PROJECT_NAME=' "$SESSIONS/s3/.session-env"

SLUG=$(grep -m1 '^export PLEACH_SLUG=' "$SESSIONS/s3/.session-env" | cut -d= -f2-)
# A Postgres identifier and a compose project name cannot carry hyphens or case.
case "$SLUG" in
  *[!a-z0-9_]*) fail "slug '$SLUG' contains characters unsafe as a DB identifier" ;;
  "")           fail "slug is empty" ;;
  *)            ok "slug '$SLUG' is a safe identifier ([a-z0-9_])" ;;
esac
assert_contains "slug is namespaced by the workspace, not just the session" "$SLUG" "canon"

# The backfill must be idempotent: opening a session twice may not duplicate them.
run "$PLEACH" open s3 true
assert_rc "open s3 (backfill path): rc 0" "$RC" 0
assert_eq "backfill: PLEACH_SLUG appears exactly once" \
  "$(grep -c '^export PLEACH_SLUG=' "$SESSIONS/s3/.session-env" | tr -d ' ')" "1"

# ---------------------------------------------------------------------------
header "Test 21: ls --json (the machine-readable surface)"
# ---------------------------------------------------------------------------
run "$PLEACH" ls --json
assert_rc "ls --json: rc 0" "$RC" 0
assert_contains "ls --json: reports the canonical" "$OUT" '"canonical"'
assert_contains "ls --json: lists s3" "$OUT" '"name": "s3"'
assert_contains "ls --json: carries the branch" "$OUT" '"branch": "session/s3"'
assert_contains "ls --json: carries the mounted sub-repos" "$OUT" '"subs": ["subA", "subB", "subC"]'

# Valid JSON, not just a string that looks like it. Parsed by whatever is around;
# with no parser available the assertion is skipped rather than faked.
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "ls --json: output parses as JSON"
  else
    fail "ls --json: output is not valid JSON"
  fi
else
  echo "  (skipped: no python3 to validate the JSON)"
fi

# ---------------------------------------------------------------------------
header "Test 22: path, cd and the shell wrapper"
# ---------------------------------------------------------------------------
run "$PLEACH" path s3
assert_rc "path s3: rc 0" "$RC" 0
assert_eq "path s3: prints the session directory" "$OUT" "$SESSIONS/s3"

run "$PLEACH" path --canonical
assert_eq "path --canonical: prints the canonical" "$OUT" "$CANON"

run "$PLEACH" path nope
assert_rc "path nope: non-zero rc for an unknown session" "$RC" 1

# `cd` cannot work from a child process. It must say so, not fail obscurely.
run "$PLEACH" cd s3
assert_rc "cd without the wrapper: non-zero rc" "$RC" 1
assert_contains "cd without the wrapper: points at shell-init" "$OUT" "shell-init"

run "$PLEACH" shell-init
assert_rc "shell-init: rc 0" "$RC" 0
assert_contains "shell-init: defines the wrapper function" "$OUT" "pleach()"
printf '%s' "$OUT" > "$SANDBOX/shell-init.sh"
assert_true "shell-init: the emitted wrapper is valid shell" \
  bash -n "$SANDBOX/shell-init.sh"

# ---------------------------------------------------------------------------
header "Test 23: completions"
# ---------------------------------------------------------------------------
run "$PLEACH" completions bash
assert_rc "completions bash: rc 0" "$RC" 0
assert_contains "completions bash: registers the completion" "$OUT" "complete -F _pleach pleach"
printf '%s' "$OUT" > "$SANDBOX/completions.bash"
assert_true "completions bash: the emitted script is valid shell" \
  bash -n "$SANDBOX/completions.bash"

run "$PLEACH" completions zsh
assert_rc "completions zsh: rc 0" "$RC" 0
assert_contains "completions zsh: registers the completion" "$OUT" "compdef _pleach pleach"

run "$PLEACH" completions fish
assert_rc "completions fish: non-zero rc for an unsupported shell" "$RC" 1

# ---------------------------------------------------------------------------
header "Test 24: doctor detects and repairs"
# ---------------------------------------------------------------------------
run "$PLEACH" doctor
assert_rc "doctor: rc 0 on a healthy workspace" "$RC" 0
assert_contains "doctor: says so" "$OUT" "no problems found"

# A lock left behind by a run that died mid-way is invisible until the next
# create hangs for two minutes. doctor must name it.
mkdir -p "$SESSIONS/.pleach.lock"
run "$PLEACH" doctor
assert_rc "doctor: non-zero rc with a lock held" "$RC" 1
assert_contains "doctor: reports the lock" "$OUT" "lock held"

# A lock with NO owner recorded cannot be judged: it may come from a version that
# predates owners and still be held by a live run. Guessing wrong tears that run
# down, so --fix must refuse and hand over the manual escape hatch instead.
run "$PLEACH" doctor --fix
assert_rc "doctor --fix: still non-zero for an ownerless lock" "$RC" 1
assert_contains "doctor --fix: says it will not touch an ownerless lock" "$OUT" "no owner recorded"
assert_true "doctor --fix: the ownerless lock was NOT removed" [ -d "$SESSIONS/.pleach.lock" ]
rmdir "$SESSIONS/.pleach.lock"

# Drift between the conf and disk is the multi-repo failure mode: a sub-repo
# declared but absent makes every session silently incomplete.
mv "$CANON/subC" "$CANON/subC.moved"
run "$PLEACH" doctor
assert_rc "doctor: non-zero rc when a declared sub-repo is missing" "$RC" 1
assert_contains "doctor: names the missing sub-repo" "$OUT" "missing from disk: subC"
mv "$CANON/subC.moved" "$CANON/subC"

# ---------------------------------------------------------------------------
header "Test 25: conflicts sees across sessions"
# ---------------------------------------------------------------------------
# The blind spot worktrees create: work in another session is invisible to yours
# by construction, so an overlap only surfaces at merge. conflicts is the one
# place it can be seen before then.
run "$PLEACH" new s4 --no-bootstrap
assert_rc "new s4: rc 0" "$RC" 0

run "$PLEACH" conflicts
assert_rc "conflicts (no overlap yet): rc 0" "$RC" 0
assert_contains "conflicts: reports a clean state" "$OUT" "No file is being edited in more than one session"

# The same file, committed in two different sessions.
echo "from s3" > "$SESSIONS/s3/README.md"
git -C "$SESSIONS/s3" commit -q -am "s3 edits the README"
echo "from s4" > "$SESSIONS/s4/README.md"
git -C "$SESSIONS/s4" commit -q -am "s4 edits the README"
# And a file only one session touches - it must NOT be reported.
echo "only s4" > "$SESSIONS/s4/solo.txt"
git -C "$SESSIONS/s4" add solo.txt
git -C "$SESSIONS/s4" commit -q -m "s4 adds a file nobody else has"

run "$PLEACH" conflicts
assert_rc "conflicts (overlap present): still rc 0 - it informs, it does not fail" "$RC" 0
assert_contains "conflicts: names the overlapping file" "$OUT" "root/README.md"
assert_contains "conflicts: attributes it to s3" "$OUT" "s3"
assert_contains "conflicts: attributes it to s4" "$OUT" "s4"
if [ "${OUT#*solo.txt}" != "$OUT" ]; then
  fail "conflicts: reported solo.txt, which only one session touches"
else
  ok "conflicts: a file touched by a single session is not reported"
fi

# Uncommitted work counts too - it is just as invisible to the other sessions.
echo "uncommitted in s3" > "$SESSIONS/s3/subA/f.txt"
echo "uncommitted in s4" > "$SESSIONS/s4/subA/f.txt"
run "$PLEACH" conflicts
assert_contains "conflicts: uncommitted changes count as an overlap" "$OUT" "subA/f.txt"
git -C "$SESSIONS/s3/subA" checkout -- f.txt
git -C "$SESSIONS/s4/subA" checkout -- f.txt

# ---------------------------------------------------------------------------
header "Test 26: update defers to whoever owns the install"
# ---------------------------------------------------------------------------
# pleach ships through four channels. A copy installed by a package manager must
# never self-update over the top of it - it would write to ~/.local/bin, leaving
# the managed copy stale and a second one shadowing it. These assertions also
# prove `update` decides BEFORE reaching the network: nothing is downloaded here.
mkdir -p "$SANDBOX/fake/Cellar/pleach/1.1.0/bin"
cp "$PLEACH" "$SANDBOX/fake/Cellar/pleach/1.1.0/bin/pleach"
run "$SANDBOX/fake/Cellar/pleach/1.1.0/bin/pleach" update
assert_rc "update (Homebrew-managed): non-zero rc" "$RC" 1
assert_contains "update (Homebrew-managed): redirects to brew" "$OUT" "brew upgrade pleach"

mkdir -p "$SANDBOX/fake/node_modules/.bin"
cp "$PLEACH" "$SANDBOX/fake/node_modules/.bin/pleach"
run "$SANDBOX/fake/node_modules/.bin/pleach" update
assert_rc "update (npm-managed): non-zero rc" "$RC" 1
assert_contains "update (npm-managed): redirects to the package manager" "$OUT" "npm update -g"

# ---------------------------------------------------------------------------
header "Test 27: conflicts distinguishes a real conflict from a mere overlap"
# ---------------------------------------------------------------------------
# The whole point of asking git instead of guessing. Both sessions edit the SAME
# file: s3 at the top, s4 at the bottom. An overlap heuristic calls that a
# conflict; git merges it without complaint, and a tool that cries wolf here is a
# tool you stop reading.
printf 'top\nb\nc\nd\ne\nf\ng\nh\ni\nbottom\n' > "$CANON/subB/wide.txt"
git -C "$CANON/subB" add wide.txt
git -C "$CANON/subB" commit -q -m "a file with two distant regions"

run "$PLEACH" sync s3 --any-branch
assert_rc "sync s3 (setup): rc 0" "$RC" 0
run "$PLEACH" sync s4 --any-branch
assert_rc "sync s4 (setup): rc 0" "$RC" 0
assert_true "setup: both sessions received wide.txt" \
  [ -f "$SESSIONS/s3/subB/wide.txt" ] && [ -f "$SESSIONS/s4/subB/wide.txt" ]
printf 'TOP-s3\nb\nc\nd\ne\nf\ng\nh\ni\nbottom\n' > "$SESSIONS/s3/subB/wide.txt"
git -C "$SESSIONS/s3/subB" commit -q -am "s3 rewrites the top"
printf 'top\nb\nc\nd\ne\nf\ng\nh\ni\nBOTTOM-s4\n' > "$SESSIONS/s4/subB/wide.txt"
git -C "$SESSIONS/s4/subB" commit -q -am "s4 rewrites the bottom"

# Isolate the WOULD CONFLICT section. s3 and s4 already clash on README.md from an
# earlier scenario, so asking whether the word appears anywhere would prove
# nothing - the question is which files are inside that section.
conflict_block() { printf '%s\n' "$1" | awk '/WOULD CONFLICT/{f=1} /^(Also touched|Touched by)/{f=0} f'; }

run "$PLEACH" conflicts
assert_rc "conflicts: rc 0" "$RC" 0
assert_contains "conflicts: the distant-region file is still reported as an overlap" "$OUT" "wide.txt"
BLOCK=$(conflict_block "$OUT")
if [ "${BLOCK#*wide.txt}" != "$BLOCK" ]; then
  fail "conflicts: called wide.txt a real conflict, but git merges the two regions cleanly"
else
  ok "conflicts: distant regions of one file are NOT called a conflict"
fi

# Now the same region in both. This one git genuinely cannot resolve.
printf 'CLASH-s3\nb\nc\nd\ne\nf\ng\nh\ni\nbottom\n' > "$SESSIONS/s3/subB/wide.txt"
git -C "$SESSIONS/s3/subB" commit -q -am "s3 takes line 1"
printf 'CLASH-s4\nb\nc\nd\ne\nf\ng\nh\ni\nbottom\n' > "$SESSIONS/s4/subB/wide.txt"
git -C "$SESSIONS/s4/subB" commit -q -am "s4 takes line 1 too"

run "$PLEACH" conflicts
assert_rc "conflicts (real conflict): still rc 0 - it informs, it does not fail" "$RC" 0
BLOCK=$(conflict_block "$OUT")
assert_contains "conflicts: reports a real conflict" "$OUT" "WOULD CONFLICT"
assert_contains "conflicts: the same-region file IS in the conflict section" "$BLOCK" "wide.txt"
assert_contains "conflicts: names both sessions" "$BLOCK" "s3 <-> s4"
assert_contains "conflicts: names the repo it is in" "$BLOCK" "(subB)"
# Naming the file is not naming the change: a filename cannot tell two edits to
# adjacent lines from a rewrite, so the reader has to go and look anyway. The
# merged tree with the conflict markers is already in the object store — the
# command wrote it and threw the id away.
assert_contains "conflicts: says WHERE in the file" "$BLOCK" "line 1"
assert_contains "conflicts: and shows what each session put there" "$BLOCK" "CLASH-s3"
assert_contains "conflicts: from both sides" "$BLOCK" "CLASH-s4"

# ---------------------------------------------------------------------------
header "Test 28: new --from stacks a session on another one's unmerged work"
# ---------------------------------------------------------------------------
# s4 has commits that are not in main. A session cut from main cannot see them;
# one cut from s4 can. That is the difference between waiting for a merge and
# building on top of it.
echo "only in s4" > "$SESSIONS/s4/stacked-marker.txt"
git -C "$SESSIONS/s4" add stacked-marker.txt
git -C "$SESSIONS/s4" commit -q -m "work that has not landed on main"

run "$PLEACH" new s5 --no-bootstrap
assert_rc "new s5 (from the base): rc 0" "$RC" 0
assert_true "new s5: does NOT see s4's unmerged work" \
  [ ! -e "$SESSIONS/s5/stacked-marker.txt" ]

run "$PLEACH" new s6 --from s4 --no-bootstrap
assert_rc "new s6 --from s4: rc 0" "$RC" 0
assert_contains "new s6: says what it cut from" "$OUT" "cutting from 's4'"
assert_true "new s6: DOES see s4's unmerged work" \
  [ -e "$SESSIONS/s6/stacked-marker.txt" ]
assert_eq "new s6: still on its own branch, not s4's" \
  "$(git -C "$SESSIONS/s6" branch --show-current)" "session/s6"
assert_true "new s6: records its lineage in .session-env" \
  grep -q '^export PLEACH_BASE_REF=s4$' "$SESSIONS/s6/.session-env"

run "$PLEACH" ls -l
assert_contains "ls -l: marks the stacked session with what it was cut from" "$OUT" "cut from s4"

run "$PLEACH" ls --json
assert_contains "ls --json: carries the lineage" "$OUT" '"cut_from": "s4"'

# A ref that exists nowhere must fall back loudly, never silently.
run "$PLEACH" new s7 --from no-such-ref --no-bootstrap
assert_rc "new --from <missing ref>: rc 0 - falls back rather than blocking" "$RC" 0
assert_contains "new --from <missing ref>: says it fell back" "$OUT" "cutting from main instead"
# And the recorded lineage has to be the TRUTH: it fell back to the base, so the
# base is what lands in .session-env. Recording 'no-such-ref' would make `ls -l`
# claim the session came from somewhere it never did.
assert_true "lineage: records the base, not the ref that did not exist" \
  grep -q '^export PLEACH_BASE_REF=main$' "$SESSIONS/s7/.session-env"
run "$PLEACH" ls -l
assert_not_contains "ls -l: invents no lineage for s7" "$OUT" "cut from no-such-ref"

run "$PLEACH" new s8 --from
assert_rc "new --from with no value: non-zero rc" "$RC" 1
assert_contains "new --from with no value: says what it needs" "$OUT" "needs a session name or a git ref"

# ---------------------------------------------------------------------------
header "Test 29: a ref name must not be able to execute"
# ---------------------------------------------------------------------------
# git ACCEPTS branch names like 'feat/$(...)'. .session-env is read with `source`,
# so a double-quoted value would run on the next `open`. %q neutralises it without
# changing a byte of any ordinary value.
#
# The payload cannot contain spaces (git rejects those in refs); brace expansion
# `{touch,<path>}` yields the two words without a literal space in the name. The
# path must be normalised: on macOS $TMPDIR already ends in '/', so $SANDBOX
# carries a double slash, and git rejects refs containing '//' — which would make
# this scenario SKIP silently, passing green while measuring nothing.
SANDBOX_REF=$(cd "$SANDBOX" && pwd -P)
# shellcheck disable=SC2016  # single quotes deliberate: the $( ) MUST stay literal
PAYLOAD='feat/$({touch,'"$SANDBOX_REF"'/PWNED})'

# Sanity first: if the payload did not fire, the test would pass by measuring
# nothing. Prove the OLD form (double-quoted) really does execute.
printf 'export PLEACH_BASE_REF="%s"\n' "$PAYLOAD" > "$SANDBOX/vuln-probe.sh"
# shellcheck disable=SC1091  # generated at runtime — it does not exist for the linter
( . "$SANDBOX/vuln-probe.sh" ) >/dev/null 2>&1 || true
assert_true "sanity: the old (quoted) form really did fire" \
  [ -e "$SANDBOX_REF/PWNED" ]
rm -f "$SANDBOX_REF/PWNED"

if git -C "$CANON" branch "$PAYLOAD" >/dev/null 2>&1; then
  run "$PLEACH" new s9 --from "$PAYLOAD" --no-bootstrap
  assert_rc "new --from <ref with \$( )>: rc 0" "$RC" 0
  assert_true "the hostile ref did NOT execute while writing .session-env" \
    [ ! -e "$SANDBOX_REF/PWNED" ]

  # And the one that matters: open sources the file.
  run "$PLEACH" open s9 true
  assert_rc "open s9: rc 0" "$RC" 0
  assert_true "the hostile ref did NOT execute when open sourced it" \
    [ ! -e "$SANDBOX_REF/PWNED" ]
  # shellcheck disable=SC1091  # .session-env is generated by pleach at runtime
  assert_eq "the original value survives the escaping intact" \
    "$(cd "$SESSIONS/s9" && . ./.session-env && printf '%s' "$PLEACH_BASE_REF")" \
    "$PAYLOAD"
else
  echo "  (skipped: this git rejects the ref name used as the payload)"
fi

# ---------------------------------------------------------------------------
header "Test 30: distinct session identities must not collapse onto one slug"
# ---------------------------------------------------------------------------
# 'fix-login' and 'fix_login' are two valid, distinct names. If the slug merged
# them they would share PLEACH_DB_NAME — exactly the collision the runtime
# identity exists to prevent.
run "$PLEACH" new fix-login --no-bootstrap
assert_rc "new fix-login: rc 0" "$RC" 0
run "$PLEACH" new fix_login --no-bootstrap
assert_rc "new fix_login: rc 0" "$RC" 0
SLUG_A=$(grep -m1 '^export PLEACH_SLUG=' "$SESSIONS/fix-login/.session-env" | cut -d= -f2-)
SLUG_B=$(grep -m1 '^export PLEACH_SLUG=' "$SESSIONS/fix_login/.session-env" | cut -d= -f2-)
if [ "$SLUG_A" = "$SLUG_B" ]; then
  fail "slug: 'fix-login' and 'fix_login' both collapsed to [$SLUG_A] — they would share a database"
else
  ok "slug: 'fix-login' [$SLUG_A] != 'fix_login' [$SLUG_B]"
fi
case "$SLUG_B" in
  *[!a-z0-9_]*) fail "slug '$SLUG_B' is no longer a safe identifier" ;;
  *)            ok "slug '$SLUG_B' is still safe as an identifier ([a-z0-9_])" ;;
esac

# ---------------------------------------------------------------------------
header "Test 31: doctor --fix must not tear down a LIVE lock"
# ---------------------------------------------------------------------------
# --fix promises only the repairs that cannot lose work. Removing the lock of a
# run in progress would leave two invocations creating worktrees at once, which
# is precisely what the lock prevents.
mkdir -p "$SESSIONS/.pleach.lock"
printf '%s %s\n' "$$" "$(uname -n 2>/dev/null || echo '?')" > "$SESSIONS/.pleach.lock/owner"
run "$PLEACH" doctor --fix
assert_contains "doctor: recognises the lock as LIVE" "$OUT" "lock is LIVE"
assert_true "doctor --fix: the live lock was PRESERVED" [ -d "$SESSIONS/.pleach.lock" ]

# An owner that no longer exists is a different story: that one is dirt and goes.
# The pid comes from a process that has actually terminated — a hard-coded number
# like 999999 could be ALIVE on a machine with a high pid_max, and then the test
# would pass for the wrong reason.
( exit 0 ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true
printf '%s %s\n' "$DEAD_PID" "$(uname -n 2>/dev/null || echo '?')" > "$SESSIONS/.pleach.lock/owner"
run "$PLEACH" doctor --fix
assert_contains "doctor --fix: releases the lock whose owner died" "$OUT" "stale lock released"
assert_true "doctor --fix: the abandoned lock is gone" [ ! -d "$SESSIONS/.pleach.lock" ]

# ---------------------------------------------------------------------------
header "Test 32: conflicts sees sub-repos mounted outside the conf"
# ---------------------------------------------------------------------------
# conflicts exists to remove a blind spot; iterating PLEACH_SUBS alone gave it a
# blind spot of its own — a sub mounted with `add` and still outside the conf
# went unchecked.
setup_repo "$CANON/subD"
echo "base" > "$CANON/subD/shared.txt"
git -C "$CANON/subD" add shared.txt
git -C "$CANON/subD" commit -q -m "initial commit for subD"
assert_true "subD is on disk but OUTSIDE PLEACH_SUBS" \
  bash -c "! grep -q 'PLEACH_SUBS=(.*subD' '$CANON/.pleach.conf'"

run "$PLEACH" add s3 subD --no-bootstrap
assert_rc "add s3 subD: rc 0" "$RC" 0
run "$PLEACH" add s4 subD --no-bootstrap
assert_rc "add s4 subD: rc 0" "$RC" 0
printf 'from-s3\n' > "$SESSIONS/s3/subD/shared.txt"
git -C "$SESSIONS/s3/subD" commit -q -am "s3 rewrites shared"
printf 'from-s4\n' > "$SESSIONS/s4/subD/shared.txt"
git -C "$SESSIONS/s4/subD" commit -q -am "s4 rewrites shared"

run "$PLEACH" conflicts
BLOCK=$(conflict_block "$OUT")
assert_contains "conflicts: checks a sub mounted outside the conf" "$BLOCK" "(subD)"
assert_contains "conflicts: names the conflicting file in that sub" "$BLOCK" "shared.txt"

# ---------------------------------------------------------------------------
header "Test 33: the emitted skill is valid and cannot name a command that does not exist"
# ---------------------------------------------------------------------------
# A reference whose facts drift is worse than no reference, because an agent
# trusts it. These assertions fail the build the day the skill mentions a command
# the dispatcher lost, or loses the frontmatter its runtime needs to load it.
run "$PLEACH" skill
assert_rc "skill: rc 0" "$RC" 0
assert_eq "skill: opens with the frontmatter fence" "$(printf '%s' "$OUT" | head -1)" "---"
assert_contains "skill: declares its name" "$OUT" "name: pleach"
assert_contains "skill: the description says WHEN to use it" "$OUT" "description: Use when"

# The skill specification budgets 1024 characters for the frontmatter.
FM=$(printf '%s\n' "$OUT" | awk 'NR==1{next} /^---$/{exit} {print}')
assert_true "skill: frontmatter fits the 1024-character budget" [ "${#FM}" -le 1024 ]

# Anti-drift: every `pleach <command>` the skill names must exist in the dispatcher.
# Anchored to the final `case "$cmd"` block rather than matched by indentation, so
# a case label added elsewhere can never widen what counts as a real command.
DISPATCH=$(awk '/^case "\$cmd" in$/,/^esac$/' "$PLEACH" \
  | grep -oE '^  [a-zA-Z|-]+\)' | tr -d ' )' | tr '|' '\n' | sort -u)
NAMED=$(printf '%s\n' "$OUT" | grep -oE '`pleach [a-z-]+' | sed 's/`pleach //' | sort -u)
# A floor, not a content requirement: without it, an extraction that matched nothing would
# make the anti-drift assertion below pass vacuously. It was 10 while the skill still
# carried a command table; the skill dropped that table on purpose (`pleach help` already
# is one), so the floor follows the extraction's real purpose rather than pinning content.
assert_true "skill: names 8+ commands (proves the extraction is not silently empty)" \
  [ "$(printf '%s\n' "$NAMED" | grep -c .)" -ge 8 ]
UNKNOWN=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  printf '%s\n' "$DISPATCH" | grep -qx "$c" || UNKNOWN="$UNKNOWN $c"
done <<NAMED_EOF
$NAMED
NAMED_EOF
assert_eq "skill: every command it names is a real one" "$UNKNOWN" ""

# ---------------------------------------------------------------------------
header "Test 34: skill installs to each destination, and refuses two at once"
# ---------------------------------------------------------------------------
SKILLHOME="$SANDBOX/skill-home"
run env HOME="$SKILLHOME" "$PLEACH" skill --install
assert_rc "skill --install: rc 0" "$RC" 0
assert_true "skill --install: writes under HOME/.claude/skills/pleach" \
  [ -f "$SKILLHOME/.claude/skills/pleach/SKILL.md" ]
assert_true "skill --install: the file is byte-identical to stdout" \
  bash -c "\"$PLEACH\" skill | diff -q - \"$SKILLHOME/.claude/skills/pleach/SKILL.md\""

run "$PLEACH" skill --dir "$SANDBOX/runtimes"
assert_rc "skill --dir: rc 0" "$RC" 0
assert_true "skill --dir: writes <dir>/pleach/SKILL.md" \
  [ -f "$SANDBOX/runtimes/pleach/SKILL.md" ]

mkdir -p "$SANDBOX/projdir"
run bash -c "cd \"$SANDBOX/projdir\" && \"$PLEACH\" skill --project"
assert_rc "skill --project: rc 0" "$RC" 0
assert_true "skill --project: writes ./.claude/skills/pleach" \
  [ -f "$SANDBOX/projdir/.claude/skills/pleach/SKILL.md" ]

run "$PLEACH" skill --install --project
assert_rc "skill: two destinations is an error" "$RC" 1
assert_contains "skill: tells you to pick one" "$OUT" "pick a single destination"

run "$PLEACH" skill --dir
assert_rc "skill --dir with no path: error" "$RC" 1
assert_contains "skill --dir with no path: says which flag" "$OUT" "--dir needs a path"

# A following flag is a typo, not a directory. Without the guard this reached
# mkdir and failed in mkdir's words, having already accepted "--install" as a path.
run "$PLEACH" skill --dir --install
assert_rc "skill --dir swallowing a flag: error" "$RC" 1
assert_contains "skill --dir swallowing a flag: names the flag" "$OUT" "got the flag --install"
assert_not_contains "skill --dir swallowing a flag: does not reach mkdir" "$OUT" "mkdir"
assert_true "skill --dir swallowing a flag: created nothing" \
  bash -c "! [ -e '--install' ] && ! [ -e './--install' ]"

run "$PLEACH" skill --bogus
assert_rc "skill: unknown flag is an error" "$RC" 1
run "$PLEACH" skill stray-argument
assert_rc "skill: stray argument is an error" "$RC" 1

# `help skill` claims it needs no workspace. Strip both pleach variables and run
# from a bare directory: safe to drop the guard rail here because with no
# destination flag the command only writes to stdout.
mkdir -p "$SANDBOX/nowhere"
run bash -c "cd \"$SANDBOX/nowhere\" && env -u PLEACH_CANONICAL -u PLEACH_EXPECT_CANONICAL \"$PLEACH\" skill"
assert_rc "skill: works with no workspace and no config" "$RC" 0

env_val() { # <session dir> <variable> -> its value in .session-env, empty if absent
  # Tolerant on purpose: under `set -euo pipefail` a missing file here aborts the
  # whole run instead of failing one assertion, and a suite that dies reports less
  # than a suite that fails.
  grep "^export $2=" "$1/.session-env" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# ---------------------------------------------------------------------------
header "Test 35: two creations contend for the lock, and never take the same index"
# ---------------------------------------------------------------------------
# Launching two runs and hoping they overlap proves nothing: if the first releases
# the lock before the second reaches it, every assertion below passes without
# contention having happened at all — a test that measures nothing and reports
# green. So the overlap is manufactured rather than hoped for: hold the lock, start
# both, prove both are stuck, and only then let go.
mkdir "$SESSIONS/.pleach.lock"
printf '%s %s\n' "$$" "$(uname -n 2>/dev/null || echo '?')" > "$SESSIONS/.pleach.lock/owner"

( "$PLEACH" new conc-a --no-bootstrap >"$SANDBOX/conc-a.log" 2>&1; echo $? >"$SANDBOX/conc-a.rc" ) &
CONC_A=$!
( "$PLEACH" new conc-b --no-bootstrap >"$SANDBOX/conc-b.log" 2>&1; echo $? >"$SANDBOX/conc-b.rc" ) &
CONC_B=$!
sleep 3
assert_true "held lock: both runs are alive, waiting on it" \
  bash -c "kill -0 $CONC_A 2>/dev/null && kill -0 $CONC_B 2>/dev/null"
assert_true "held lock: neither created anything while it was held" \
  bash -c "[ ! -d '$SESSIONS/conc-a' ] && [ ! -d '$SESSIONS/conc-b' ]"

rm -f "$SESSIONS/.pleach.lock/owner"
rmdir "$SESSIONS/.pleach.lock"
wait "$CONC_A" 2>/dev/null || true
wait "$CONC_B" 2>/dev/null || true

# Now the invariant that matters, from two runs PROVEN to have contended. Note it
# is not "both succeeded" — that would pass even if the lock did nothing.
assert_eq "concurrent new: first run exits 0"  "$(cat "$SANDBOX/conc-a.rc")" "0"
assert_eq "concurrent new: second run exits 0" "$(cat "$SANDBOX/conc-b.rc")" "0"
assert_true "concurrent new: both sessions were created" \
  bash -c "[ -d '$SESSIONS/conc-a' ] && [ -d '$SESSIONS/conc-b' ]"

IDX_A=$(env_val "$SESSIONS/conc-a" PLEACH_INDEX)
IDX_B=$(env_val "$SESSIONS/conc-b" PLEACH_INDEX)
assert_true "concurrent new: the two runs took different indexes ($IDX_A vs $IDX_B)" \
  [ "$IDX_A" != "$IDX_B" ]

PB_A=$(env_val "$SESSIONS/conc-a" PLEACH_PORT_BASE)
PB_B=$(env_val "$SESSIONS/conc-b" PLEACH_PORT_BASE)
assert_true "concurrent new: the two port blocks differ ($PB_A vs $PB_B)" \
  [ "$PB_A" != "$PB_B" ]

# doctor is the independent judge here: it checks for duplicate indexes and
# overlapping blocks without knowing how they came about.
run "$PLEACH" doctor
assert_not_contains "concurrent new: doctor finds no duplicate index or block" \
  "$OUT" "is already taken by another session"
assert_true "concurrent new: the lock was released by both runs" lock_clear

# ---------------------------------------------------------------------------
header "Test 36: a run killed mid-creation leaves a lock doctor can name and --fix can clear"
# ---------------------------------------------------------------------------
# SIGKILL means the EXIT trap never runs, so the lock survives its owner — the
# "run that died mid-way" doctor's help promises to detect. Every earlier test
# planted that state by hand; this one causes it.
#
# POSIX only, and NOT because the assertion is unimportant on Windows. Under Git
# Bash the kill does not orphan the lock the same way: doctor still reads the
# owner as live, --fix leaves it alone, and the next creation sits out the full
# 120s lock timeout. Whether that is an artefact of MSYS pid semantics or a real
# gap in stale-lock recovery on Windows is UNKNOWN — this scenario raises the
# question rather than answering it, and skipping loudly beats a green tick.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    # The CRASH does not reproduce here — but the recovery logic can still be
    # exercised, by planting a lock whose owner is a pid that is definitely dead.
    # That answers "does doctor recognise a dead owner and release it on Windows",
    # and leaves exactly one thing unanswered: whether a real crash on Windows
    # produces this state in the first place.
    echo "  (Windows: the crash itself does not reproduce through Git Bash's process"
    echo "   model — planting a dead owner instead, to test the recovery path.)"
    ( exit 0 ) & DEAD_PID=$!
    wait "$DEAD_PID" 2>/dev/null || true
    mkdir -p "$SESSIONS/.pleach.lock"
    printf '%s %s\n' "$DEAD_PID" "$(uname -n 2>/dev/null || echo '?')" \
      > "$SESSIONS/.pleach.lock/owner"

    run "$PLEACH" doctor
    assert_rc "windows/dead owner: doctor exits non-zero" "$RC" 1
    assert_contains "windows/dead owner: doctor names it" "$OUT" "no longer running"

    run "$PLEACH" doctor --fix
    assert_true "windows/dead owner: --fix released the lock" \
      [ ! -d "$SESSIONS/.pleach.lock" ]

    run "$PLEACH" new after-crash --no-bootstrap
    assert_rc "windows/dead owner: a session can be created after the repair" "$RC" 0
    ;;
  *)
# Catching a run mid-lock is inherently a race: between spotting the lock and
# landing the kill, the run can finish on its own. On a loaded machine it does,
# and four assertions then fail in a cascade that says nothing about pleach. So
# retry, with a fresh session name each time, and fail loudly only if three
# attempts all lose the race — never silently.
CAUGHT=0
for attempt in 1 2 3; do
  "$PLEACH" new "crashy$attempt" --no-bootstrap >/dev/null 2>&1 &
  CRASHY=$!
  for _ in $(seq 1 400); do
    lock_held && break
    sleep 0.05
  done
  if lock_held && kill -0 "$CRASHY" 2>/dev/null; then
    kill -9 "$CRASHY" 2>/dev/null || true
    wait "$CRASHY" 2>/dev/null || true
    # It only counts if the lock outlived it — SIGKILL runs no EXIT trap.
    lock_held && { CAUGHT=1; break; }
  else
    wait "$CRASHY" 2>/dev/null || true
  fi
done

assert_eq "killed run: caught a run holding the lock, within 3 attempts" "$CAUGHT" "1"
assert_true "killed run: the lock outlived the process (SIGKILL runs no EXIT trap)" lock_held

# The whole point of composing the owner line first and hard-linking it into place:
# taking the lock and recording who holds it are ONE step, so a lock that exists
# always names an owner — wherever the kill lands. When they were two steps (mkdir,
# then write `owner`, with a fork in between) a kill inside that window left an
# owner-less lock, which doctor must refuse to clear and --fix declined; every later
# `new` in the suite then failed behind it, five scenarios away from the cause.
# That is the "intermittent" failure, about one run in nine.
assert_true "killed run: the orphaned lock still names its owner" \
  [ -s "$SESSIONS/.pleach.lock" ]

run "$PLEACH" doctor
assert_rc "killed run: doctor exits non-zero" "$RC" 1
assert_contains "killed run: doctor names the dead owner" "$OUT" "no longer running"

run "$PLEACH" doctor --fix
assert_true "killed run: --fix released the lock" lock_clear

# The point of a repair is that the workspace works again afterwards.
run "$PLEACH" new after-crash --no-bootstrap
assert_rc "killed run: a session can be created after the repair" "$RC" 0
assert_true "killed run: that session really exists" [ -d "$SESSIONS/after-crash" ]
# A clean run composes the owner line in a scratch file and links it into place;
# nothing of that may survive the run it belongs to.
assert_true "killed run: the scratch line leaves no litter behind a clean run" \
  bash -c "! ls '$SESSIONS'/.pleach.lock.* >/dev/null 2>&1"
    ;;
esac

# ---------------------------------------------------------------------------
header "Test 37: install puts a working copy in place, and refuses to install over itself"
# ---------------------------------------------------------------------------
# HOME is redirected into the sandbox: this scenario writes to ~/.local/bin, and a
# test that touches the real one is a test nobody can run twice.
INSTALL_HOME="$SANDBOX/install-home"
mkdir -p "$INSTALL_HOME"
run env HOME="$INSTALL_HOME" "$PLEACH" install
assert_rc "install: rc 0" "$RC" 0
assert_true "install: the script landed in ~/.local/bin" \
  [ -f "$INSTALL_HOME/.local/bin/pleach" ]
assert_true "install: and it is executable" \
  [ -x "$INSTALL_HOME/.local/bin/pleach" ]
assert_true "install: byte-identical to the source" \
  cmp -s "$PLEACH" "$INSTALL_HOME/.local/bin/pleach"
assert_eq "install: the installed copy actually runs" \
  "$("$INSTALL_HOME/.local/bin/pleach" version)" "pleach $PKG_VERSION"
assert_contains "install: warns that ~/.local/bin is not on PATH" "$OUT" "not on your PATH"

# Installing FROM the installed copy would be cp onto itself.
run env HOME="$INSTALL_HOME" "$INSTALL_HOME/.local/bin/pleach" install
assert_rc "install: refuses when run from the installed copy" "$RC" 1
assert_contains "install: and says which copy it is" "$OUT" "installed copy"

# The same, reached through a SYMLINKED home. Plain `pwd` is logical, so it would
# report the symlink on one side of the comparison and the real path on the other
# — the guard passes only if both sides are resolved physically.
ln -s "$INSTALL_HOME" "$SANDBOX/linked-home"
run env HOME="$SANDBOX/linked-home" "$SANDBOX/linked-home/.local/bin/pleach" install
assert_rc "install: refuses through a symlinked HOME too" "$RC" 1
assert_contains "install: and still names the installed copy" "$OUT" "installed copy"

# ---------------------------------------------------------------------------
header "Test 38: update verifies what it downloaded BEFORE replacing anything"
# ---------------------------------------------------------------------------
# The redirect-to-your-package-manager paths were already covered; the download
# path never was, because it reaches the network. A curl double closes that
# offline — and the property worth having is not "it updates", it is that a failed
# or corrupt download leaves a WORKING pleach behind.
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
# Test double for curl. Honours -o; serves $FAKE_CURL_PAYLOAD, or fails on demand.
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) shift; out="${1:-}" ;; esac
  shift
done
[ -n "${FAKE_CURL_FAIL:-}" ] && exit 22
[ -n "$out" ] || exit 2
cat "${FAKE_CURL_PAYLOAD:-/dev/null}" > "$out"
FAKE_CURL
chmod +x "$FAKEBIN/curl"

UPD_HOME="$SANDBOX/update-home"
mkdir -p "$UPD_HOME/.local/bin"
cp "$PLEACH" "$UPD_HOME/.local/bin/pleach"
chmod +x "$UPD_HOME/.local/bin/pleach"
UPD="$UPD_HOME/.local/bin/pleach"

# 1. The download fails outright.
run env HOME="$UPD_HOME" PATH="$FAKEBIN:$PATH" FAKE_CURL_FAIL=1 "$UPD" update
assert_rc "update (download fails): non-zero rc" "$RC" 1
assert_contains "update (download fails): says so" "$OUT" "download failed"
assert_true "update (download fails): the existing copy is untouched" \
  cmp -s "$PLEACH" "$UPD"

# 2. The download succeeds but is not valid bash. This is the one that matters:
#    without the syntax gate a corrupt fetch would overwrite a working tool.
printf 'if [ then\n' > "$SANDBOX/broken-payload"
run env HOME="$UPD_HOME" PATH="$FAKEBIN:$PATH" FAKE_CURL_PAYLOAD="$SANDBOX/broken-payload" "$UPD" update
assert_rc "update (corrupt payload): non-zero rc" "$RC" 1
assert_contains "update (corrupt payload): names the syntax check" "$OUT" "syntax check"
assert_contains "update (corrupt payload): says nothing was changed" "$OUT" "nothing was changed"
assert_true "update (corrupt payload): the existing copy STILL runs" \
  bash -c "\"$UPD\" version >/dev/null"
assert_true "update (corrupt payload): and is byte-identical to before" \
  cmp -s "$PLEACH" "$UPD"

# 3. The download is what we already have.
run env HOME="$UPD_HOME" PATH="$FAKEBIN:$PATH" FAKE_CURL_PAYLOAD="$PLEACH" "$UPD" update
assert_rc "update (same version): rc 0" "$RC" 0
assert_contains "update (same version): reports it is already current" "$OUT" "already on the latest"

# 4. A genuine, valid upgrade.
sed 's/^PLEACH_VERSION=.*/PLEACH_VERSION="9.9.9"/' "$PLEACH" > "$SANDBOX/newer-payload"
run env HOME="$UPD_HOME" PATH="$FAKEBIN:$PATH" FAKE_CURL_PAYLOAD="$SANDBOX/newer-payload" "$UPD" update
assert_rc "update (newer version): rc 0" "$RC" 0
assert_contains "update (newer version): reports the version it landed on" "$OUT" "9.9.9"
assert_eq "update (newer version): the installed copy is the new one" \
  "$("$UPD" version)" "pleach 9.9.9"
assert_true "update (newer version): and it is executable" [ -x "$UPD" ]

# ---------------------------------------------------------------------------
header "Test 39: conflicts sees two sessions claiming one numbered slot"
# ---------------------------------------------------------------------------
# The collision git structurally cannot report: different filenames, so the merge
# is clean, exits 0, and lands two migrations numbered the same. Everything else
# in this command answers "would the merge break"; this answers "would the result
# be wrong", which is a different question.
mkdir -p "$SESSIONS/s3/migrations" "$SESSIONS/s4/migrations"
echo "-- billing"    > "$SESSIONS/s3/migrations/0007_billing.sql"
echo "-- last_login" > "$SESSIONS/s4/migrations/0007_last_login.sql"
git -C "$SESSIONS/s3" add -A && git -C "$SESSIONS/s3" commit -q -m "s3 claims slot 0007"
git -C "$SESSIONS/s4" add -A && git -C "$SESSIONS/s4" commit -q -m "s4 claims slot 0007"

run "$PLEACH" conflicts
assert_rc "slot clash: conflicts still exits 0" "$RC" 0
assert_contains "slot clash: reports the shared slot" "$OUT" "slot 0007"
assert_contains "slot clash: names s3's file" "$OUT" "0007_billing.sql"
assert_contains "slot clash: names s4's file" "$OUT" "0007_last_login.sql"
assert_contains "slot clash: says git merges it cleanly anyway" "$OUT" "merges these CLEANLY"

# The decisive negative: one session using a slot twice is its own business, and a
# check that cried wolf on that is a check nobody reads.
echo "-- extra" > "$SESSIONS/s3/migrations/0008_a.sql"
echo "-- extra" > "$SESSIONS/s3/migrations/0008_b.sql"
git -C "$SESSIONS/s3" add -A && git -C "$SESSIONS/s3" commit -q -m "s3 takes 0008 twice, alone"
run "$PLEACH" conflicts
assert_not_contains "slot clash: one session using a slot twice is not reported" "$OUT" "slot 0008"

# ---------------------------------------------------------------------------
header "Test 40: doctor notices an installed agent skill that no longer matches"
# ---------------------------------------------------------------------------
# The skill is written as a COPY, so it ages the moment pleach is upgraded — and a
# stale one is not harmless: an earlier revision of it made agents refuse
# legitimate work. HOME is redirected so the real one is never touched.
DOC_HOME="$SANDBOX/doctor-home"
mkdir -p "$DOC_HOME"
run env HOME="$DOC_HOME" "$PLEACH" skill --install
assert_rc "doctor/skill: install into the redirected HOME" "$RC" 0

run env HOME="$DOC_HOME" "$PLEACH" doctor
assert_contains "doctor/skill: a fresh copy is reported as matching" "$OUT" "matches this pleach"

printf '\nstale text from an older pleach\n' >> "$DOC_HOME/.claude/skills/pleach/SKILL.md"
run env HOME="$DOC_HOME" "$PLEACH" doctor
assert_rc "doctor/skill: a stale copy makes doctor exit non-zero" "$RC" 1
assert_contains "doctor/skill: and names the refresh command" "$OUT" "pleach skill --install"

# A COMMITTED copy ages the same way, and doctor knows where the canonical is, so
# there is no excuse for only watching the personal one.
run bash -c "cd \"$CANON\" && \"$PLEACH\" skill --project"
assert_rc "doctor/skill: install a project copy in the canonical" "$RC" 0
printf '\nstale project text\n' >> "$CANON/.claude/skills/pleach/SKILL.md"
run env HOME="$SANDBOX/empty-home" "$PLEACH" doctor
assert_rc "doctor/skill: a stale PROJECT copy also fails doctor" "$RC" 1
assert_contains "doctor/skill: and names the project refresh flag" "$OUT" "pleach skill --project"
rm -f "$CANON/.claude/skills/pleach/SKILL.md"

# No copy installed at all must stay silent — most users have none.
mkdir -p "$SANDBOX/empty-home"
run env HOME="$SANDBOX/empty-home" "$PLEACH" doctor
assert_not_contains "doctor/skill: silent when no skill is installed" "$OUT" "agent skill"

# ---------------------------------------------------------------------------
header "Test 41: untracked files are pending work — the data-loss case"
# ---------------------------------------------------------------------------
# Found by an outsider running the PUBLISHED package against a project this suite
# had never seen. The pending-work check read --untracked-files=no, so a session
# whose only content was files never `git add`ed reported as empty: `ls -l` called
# it "fully integrated — removable" and `rm` deleted it, green tick, exit 0. The
# content had never entered the object store, so it was simply gone. `git worktree
# remove` refuses exactly this; pleach was going around it.
run "$PLEACH" new lossy --no-bootstrap
assert_rc "untracked: session created" "$RC" 0
printf 'the only copy of this\n' > "$SESSIONS/lossy/subA/brand-new.js"

run "$PLEACH" ls -l
assert_contains "untracked: ls -l counts it as a change" "$OUT" "✎1 changes"

# The decisive assertion: it must NOT be advertised as safe to delete.
LOSSY_BLOCK=$(printf '%s\n' "$OUT" | awk '/^● lossy /{p=1} p&&/^● /&&!/lossy/{p=0} p')
assert_not_contains "untracked: ls -l does NOT call it removable" \
  "$LOSSY_BLOCK" "fully integrated"

run "$PLEACH" rm lossy
assert_rc "untracked: rm refuses" "$RC" 1
assert_contains "untracked: and says why" "$OUT" "uncommitted or untracked changes"
assert_true "untracked: the file is still there" [ -f "$SESSIONS/lossy/subA/brand-new.js" ]

run "$PLEACH" prune
assert_not_contains "untracked: prune does not offer to remove it" "$OUT" "✓ lossy"

# The decisive one: run the destructive path for real. This is the exact command an
# outsider ran as documented post-merge hygiene, and it took the work with it.
run "$PLEACH" prune --apply
assert_true "untracked: prune --apply leaves the session standing" [ -d "$SESSIONS/lossy" ]
assert_true "untracked: and the only copy of the file is still there" \
  [ -f "$SESSIONS/lossy/subA/brand-new.js" ]
assert_eq "untracked: with its contents intact" \
  "$(cat "$SESSIONS/lossy/subA/brand-new.js")" "the only copy of this"

# The negative that keeps the fix honest: a genuinely empty session must still be
# removable, or this "fix" would have broken post-merge hygiene for everyone.
run "$PLEACH" new spotless --no-bootstrap
assert_rc "untracked: a clean session was created" "$RC" 0
run "$PLEACH" ls -l
SPOTLESS_BLOCK=$(printf '%s\n' "$OUT" | awk '/^● spotless /{p=1} p&&/^● /&&!/spotless/{p=0} p')
assert_contains "untracked: a clean session is STILL removable" \
  "$SPOTLESS_BLOCK" "fully integrated"

# .session-env lives inside the root worktree. Without the exclude, a `git add -A`
# at the session root commits this machine's ports and canonical path onto the
# branch — and under the rule above it would also make every session permanently
# dirty, breaking prune for everyone.
assert_eq "untracked: .session-env does not dirty the session root" \
  "$(git -C "$SESSIONS/spotless" status --porcelain -- .session-env)" ""

# ---------------------------------------------------------------------------
header "Test 42: a renamed session folder is refused, not guessed at"
# ---------------------------------------------------------------------------
# Identity came from the folder name, so renaming it (the ticket got renamed…)
# made the branch lookup miss, the session read as empty, and rm deleted it — with
# committed work surviving only as an orphan branch that nothing lists.
echo "committed work" > "$SESSIONS/spotless/subA/real-work.js"
git -C "$SESSIONS/spotless/subA" add -A
git -C "$SESSIONS/spotless/subA" commit -q -m "work that must not vanish"
mv "$SESSIONS/spotless" "$SESSIONS/spotless-renamed"

run "$PLEACH" rm spotless-renamed
assert_rc "renamed: rm refuses" "$RC" 1
assert_contains "renamed: names both the folder and the record" "$OUT" "says 'spotless'"
assert_contains "renamed: and how to undo it" "$OUT" "Rename it back"
assert_true "renamed: nothing was removed" [ -d "$SESSIONS/spotless-renamed" ]

# --force must not override this: the guard rails cannot be evaluated at all, so
# forcing would mean deleting blind.
run "$PLEACH" rm spotless-renamed --force
assert_rc "renamed: --force does not override it either" "$RC" 1
assert_true "renamed: still nothing removed" [ -d "$SESSIONS/spotless-renamed" ]

run "$PLEACH" doctor
assert_rc "renamed: doctor reports it" "$RC" 1
assert_contains "renamed: doctor names the mismatch" "$OUT" "says 'spotless'"

mv "$SESSIONS/spotless-renamed" "$SESSIONS/spotless"
run "$PLEACH" rm spotless --force
assert_rc "renamed: removable again once the name matches" "$RC" 0
assert_true "renamed: and the folder is actually gone" [ ! -d "$SESSIONS/spotless" ]

# ---------------------------------------------------------------------------
header "Test 43: a moved canonical is reported, not certified healthy"
# ---------------------------------------------------------------------------
# `branch --show-current` returns empty both for a detached HEAD and for a repo git
# cannot open, and doctor reported the second as the first — printing "✅ no problems
# found" over a workspace where every repo answered "fatal: not a git repository".
# Its own folders all still exist, so nothing is "registered but gone" either: the
# first version of the fix hung repair off the stale-registration branch and never
# ran at all.
#
# A separate mini workspace, because this scenario moves a canonical and the suite's
# own is pinned by PLEACH_EXPECT_CANONICAL.
MINI="$SANDBOX/mini"
mkdir -p "$MINI"
setup_repo "$MINI/canon"
echo "root" > "$MINI/canon/f.txt"
git -C "$MINI/canon" add -A && git -C "$MINI/canon" commit -q -m "initial"
setup_repo "$MINI/canon/svc"
echo "svc" > "$MINI/canon/svc/f.txt"
git -C "$MINI/canon/svc" add -A && git -C "$MINI/canon/svc" commit -q -m "initial"

run bash -c "cd '$MINI/canon' && env PLEACH_CANONICAL='$MINI/canon' PLEACH_EXPECT_CANONICAL='$MINI/canon' '$PLEACH' init"
assert_rc "moved canonical: mini workspace adopted" "$RC" 0
run env PLEACH_CANONICAL="$MINI/canon" PLEACH_EXPECT_CANONICAL="$MINI/canon" "$PLEACH" new relocate --no-bootstrap
assert_rc "moved canonical: session created" "$RC" 0

echo "must survive" > "$MINI/.sessions/relocate/svc/keepme.txt"
git -C "$MINI/.sessions/relocate/svc" add -A
git -C "$MINI/.sessions/relocate/svc" commit -q -m "work that must survive the move"

mv "$MINI/canon" "$MINI/canon-moved"

run env PLEACH_CANONICAL="$MINI/canon-moved" PLEACH_EXPECT_CANONICAL="$MINI/canon-moved" "$PLEACH" doctor
assert_rc "moved canonical: doctor exits non-zero" "$RC" 1
assert_contains "moved canonical: names it as unusable, not detached" \
  "$OUT" "not a usable git worktree"
assert_contains "moved canonical: hands over the repair command" "$OUT" "worktree repair"
assert_not_contains "moved canonical: does NOT certify it healthy" "$OUT" "no problems found"

run env PLEACH_CANONICAL="$MINI/canon-moved" PLEACH_EXPECT_CANONICAL="$MINI/canon-moved" "$PLEACH" doctor --fix
assert_rc "moved canonical: --fix repairs it" "$RC" 0
assert_contains "moved canonical: and says so" "$OUT" "no problems found"

# The point of a repair is what survives it.
assert_eq "moved canonical: the session's commit survived" \
  "$(git -C "$MINI/.sessions/relocate/svc" log --oneline -1 --format='%s')" \
  "work that must survive the move"
assert_true "moved canonical: and its file is still on disk" \
  [ -f "$MINI/.sessions/relocate/svc/keepme.txt" ]

# ---------------------------------------------------------------------------
header "Test 44: a repo on master still gets a session, and every service gets a port"
# ---------------------------------------------------------------------------
# Both from the outsider reports. PLEACH_BASE is one value for the whole workspace,
# so a single repo still on master meant NO session could be created at all — the
# error was git's raw "fatal: invalid reference: main", naming neither the repo nor
# the setting, and it left a half-built session behind. And the block is 100 ports
# wide but only one PORT was exported, so the second service in a session died on
# EADDRINUSE: the collision this tool exists to remove, inside a single session.
setup_repo "$CANON/subM"
echo "legacy service" > "$CANON/subM/f.txt"
git -C "$CANON/subM" add -A && git -C "$CANON/subM" commit -q -m "initial"
git -C "$CANON/subM" branch -m main master
assert_eq "master: the fixture repo really is on master" \
  "$(git -C "$CANON/subM" branch --show-current)" "master"

run "$PLEACH" new legacy subA subM --no-bootstrap
assert_rc "master: the session is created anyway" "$RC" 0
assert_contains "master: and names the repo that fell back" "$OUT" "cutting from 'master' instead"
assert_true "master: the legacy repo really got a worktree" [ -e "$SESSIONS/legacy/subM/.git" ]
assert_eq "master: on the session branch like every other repo" \
  "$(git -C "$SESSIONS/legacy/subM" branch --show-current)" "session/legacy"
assert_true "master: the session is complete, not half-built" \
  [ -f "$SESSIONS/legacy/.session-env" ]

PB=$(env_val "$SESSIONS/legacy" PLEACH_PORT_BASE)
PA=$(env_val "$SESSIONS/legacy" PLEACH_PORT_SUBA)
PM=$(env_val "$SESSIONS/legacy" PLEACH_PORT_SUBM)
assert_true "ports: subA got its own" [ -n "$PA" ]
assert_true "ports: subM got its own" [ -n "$PM" ]
assert_true "ports: the two services do not share one" [ "$PA" != "$PM" ]
assert_true "ports: neither is the root's PORT" \
  bash -c "[ '$PA' != '$PB' ] && [ '$PM' != '$PB' ]"
# Below +29, where WRANGLER_INSPECTOR_PORT lives — otherwise the fix would collide
# with offsets that were already reserved.
assert_true "ports: both sit inside the block, clear of the reserved offsets" \
  bash -c "[ $PA -gt $PB ] && [ $PA -lt $((PB + 29)) ] && [ $PM -gt $PB ] && [ $PM -lt $((PB + 29)) ]"

# Two repo names that differ only in their punctuation must not land on one
# variable: the second export would silently win and put both services back on the
# same port — the exact bug this whole allocation exists to prevent.
setup_repo "$CANON/pay-api"; setup_repo "$CANON/pay_api"
for r in pay-api pay_api; do
  echo "x" > "$CANON/$r/f.txt"
  git -C "$CANON/$r" add -A && git -C "$CANON/$r" commit -q -m "initial"
done
run "$PLEACH" new punct pay-api pay_api --no-bootstrap
assert_rc "ports: session with punctuation-colliding repo names" "$RC" 0
P1=$(env_val "$SESSIONS/punct" PLEACH_PORT_PAY_API)
P2=$(env_val "$SESSIONS/punct" PLEACH_PORT_PAY__API)
assert_true "ports: 'pay-api' got a variable" [ -n "$P1" ]
assert_true "ports: 'pay_api' got a DIFFERENT variable" [ -n "$P2" ]
assert_true "ports: and they are different ports" [ "$P1" != "$P2" ]

# ---------------------------------------------------------------------------
header "Test 45: inside a session, the session is not the canonical"
# ---------------------------------------------------------------------------
# `pleach init` writes a .pleach.conf that does NOT set PLEACH_CANONICAL, and that
# file is meant to be committed — it carries PLEACH_SUBS for the team. So every
# session's root worktree receives a copy, and resolve_canonical tested
# .pleach.conf BEFORE .session-env at the same level: the conf named no canonical,
# so the session folder itself became one. In a shell that had not sourced
# .session-env — a fresh terminal, or any agent running `pleach ls` in a session
# cwd — `ls` lost the very session it stood in, `rm` could not find it, `new` built
# a nested .sessions/.sessions with worktrees cut from the session instead of the
# canonical (and a DB/compose slug of `inner_*`), and `doctor` printed "no problems
# found" over all of it. The right answer was one line further down the same
# directory, in a file pleach wrote itself.
NOHOME="$SANDBOX/nohome"   # so a failed resolution cannot reach the real ~/.config
mkdir -p "$SANDBOX/nested" "$NOHOME"
# Collapsed on purpose: on macOS $TMPDIR ends in a slash, so $SANDBOX carries a
# doubled one — while the paths pleach prints come from $PWD, which the shell
# collapses. Comparing the two forms makes every path assertion below pass
# vacuously, which is how the first version of this test certified the defect.
MINI2=$(cd "$SANDBOX/nested" && pwd)
setup_repo "$MINI2/canon"
echo "root" > "$MINI2/canon/f.txt"
git -C "$MINI2/canon" add -A && git -C "$MINI2/canon" commit -q -m "initial"
setup_repo "$MINI2/canon/api"
echo "api" > "$MINI2/canon/api/f.txt"
git -C "$MINI2/canon/api" add -A && git -C "$MINI2/canon/api" commit -q -m "initial"

PIN2="env PLEACH_CANONICAL=$MINI2/canon PLEACH_EXPECT_CANONICAL=$MINI2/canon"
run bash -c "cd '$MINI2/canon' && $PIN2 '$PLEACH' init"
assert_rc "nested: mini workspace adopted" "$RC" 0
# The precondition of the whole bug: what init writes names no canonical.
assert_true "nested: the conf init writes sets no canonical of its own" \
  bash -c "! grep -q '^[[:space:]]*PLEACH_CANONICAL=' '$MINI2/canon/.pleach.conf'"
git -C "$MINI2/canon" add -A && git -C "$MINI2/canon" commit -q -m "adopt pleach"

run bash -c "$PIN2 '$PLEACH' new inner --no-bootstrap"
assert_rc "nested: session created" "$RC" 0
# And the carrier: the committed conf travels into the session's root worktree.
assert_true "nested: the session carries a copy of the committed conf" \
  [ -f "$MINI2/.sessions/inner/.pleach.conf" ]
assert_true "nested: and its .session-env records the real canonical" \
  bash -c "grep -q '^export PLEACH_CANONICAL=\"$MINI2/canon\"' '$MINI2/.sessions/inner/.session-env'"

# From here on: a clean shell inside the session. Nothing sourced, nothing pinned.
BARE="env -u PLEACH_CANONICAL -u PLEACH_EXPECT_CANONICAL HOME=$NOHOME"

run bash -c "cd '$MINI2/.sessions/inner' && $BARE '$PLEACH' ls"
assert_rc "nested: ls from inside the session works" "$RC" 0
assert_contains "nested: and it still sees the session it stands in" "$OUT" "inner"
assert_not_contains "nested: no doubled sessions directory" "$OUT" ".sessions/.sessions"

run bash -c "cd '$MINI2/.sessions/inner/api' && $BARE '$PLEACH' ls"
assert_rc "nested: ls from a sub-repo of the session works" "$RC" 0
assert_contains "nested: and sees the session from there too" "$OUT" "inner"

run bash -c "cd '$MINI2/.sessions/inner' && $BARE '$PLEACH' doctor"
assert_contains "nested: doctor resolves the real canonical" "$OUT" "canonical: $MINI2/canon"
assert_not_contains "nested: not the session it was run from" \
  "$OUT" "canonical: $MINI2/.sessions/inner"

# The write path is what makes this more than a display problem.
run bash -c "cd '$MINI2/.sessions/inner' && $BARE '$PLEACH' new sibling --no-bootstrap"
assert_rc "nested: new from inside a session succeeds" "$RC" 0
assert_true "nested: and lands beside the session, not under it" \
  [ -f "$MINI2/.sessions/sibling/.session-env" ]
assert_true "nested: nothing was built in a doubled sessions directory" \
  [ ! -d "$MINI2/.sessions/.sessions" ]
assert_eq "nested: its branch was cut from the canonical, not from the session" \
  "$(git -C "$MINI2/.sessions/sibling" branch --show-current)" "session/sibling"
# The runtime identity the git layer cannot isolate: DB names and compose projects.
# Doubled underscore by design, not a typo — sanitize_ident doubles the ones already
# present so that 'fix-login' and 'fix_login' cannot share a database, and the
# separator between canonical and session name goes through the same pass.
assert_eq "nested: the runtime slug names the canonical, not the sibling session" \
  "$(env_val "$MINI2/.sessions/sibling" PLEACH_SLUG)" "canon__sibling"

# Asserted, not assumed: without this the removal assertion below passes vacuously
# whenever creation failed — a green tick over a session that never existed.
SIB_BEFORE=no
[ -d "$MINI2/.sessions/sibling" ] && SIB_BEFORE=yes
assert_eq "nested: the sibling session exists before the removal" "$SIB_BEFORE" "yes"

run bash -c "cd '$MINI2/.sessions/sibling' && $BARE '$PLEACH' rm sibling --force"
assert_rc "nested: and rm can find the session it is standing in" "$RC" 0
assert_true "nested: which is really gone" [ ! -d "$MINI2/.sessions/sibling" ]

# Defence in depth: even with the order right, a canonical that is itself a session
# is a misresolution, and doctor's job is to refuse rather than certify it. This is
# the assertion that would have caught the original defect on its own.
run bash -c "$BARE PLEACH_CANONICAL='$MINI2/.sessions/inner' '$PLEACH' doctor"
assert_rc "nested: doctor refuses a canonical that is itself a session" "$RC" 1
assert_contains "nested: and says exactly that" "$OUT" "is itself a session"
assert_not_contains "nested: without certifying it healthy" "$OUT" "no problems found"

# ---------------------------------------------------------------------------
header "Test 46: a creation that never finished says so, and can be recovered"
# ---------------------------------------------------------------------------
# Measured by killing `new` for real at two points. Killed once .session-env is
# written but during bootstrap, the session is indistinguishable from a finished
# one: doctor said "✓ during: index 2, ports 10200+, 3 repo(s)" and `ls -l` called
# it "fully integrated — removable" over half-installed dependencies. Killed
# earlier, before .session-env, doctor did notice — and handed over advice that
# does not work: "recreate the session" is refused ("already exists"), and "copy
# one by hand" would duplicate another session's index and port block, which is
# the collision the whole design exists to prevent.
MINI3=$(cd "$SANDBOX" && mkdir -p incomplete && cd incomplete && pwd)
setup_repo "$MINI3/canon"
echo "root" > "$MINI3/canon/f.txt"
git -C "$MINI3/canon" add -A && git -C "$MINI3/canon" commit -q -m "initial"
setup_repo "$MINI3/canon/api"
echo "api" > "$MINI3/canon/api/f.txt"
git -C "$MINI3/canon/api" add -A && git -C "$MINI3/canon/api" commit -q -m "initial"
cat > "$MINI3/canon/.pleach.conf" <<'CONF'
PLEACH_SUBS=(api)
pleach_bootstrap() { sleep 25; }
CONF
PIN3="env PLEACH_CANONICAL=$MINI3/canon PLEACH_EXPECT_CANONICAL=$MINI3/canon"
S3="$MINI3/.sessions"
mark_of() { printf '%s' "$S3/.pleach-building.$1"; }

run bash -c "$PIN3 '$PLEACH' new finished --no-bootstrap"
assert_rc "incomplete: a session that finishes is created" "$RC" 0
assert_true "incomplete: and a finished creation leaves no marker behind" \
  [ ! -e "$(mark_of finished)" ]

# Planted from here, so the reporting is asserted on every platform; the real
# SIGKILL that produces this state is exercised further down, POSIX only.
: > "$(mark_of finished)"

run bash -c "$PIN3 '$PLEACH' doctor"
assert_rc "incomplete: doctor exits non-zero over an unfinished creation" "$RC" 1
assert_contains "incomplete: and names it as unfinished" "$OUT" "creation never finished"
assert_contains "incomplete: handing over the command that resumes it" \
  "$OUT" "pleach clean finished --bootstrap"
assert_not_contains "incomplete: without certifying the workspace healthy" \
  "$OUT" "no problems found"
# It used to print "✗ finished: creation never finished" and then, two lines down,
# "✓ finished: index 1, ports 10100+, 2 repo(s)" — a verdict contradicting itself,
# and a reader scanning the ticks sees whichever came last.
assert_not_contains "incomplete: and without a green verdict on the same session" \
  "$OUT" "✓ finished: index"

run bash -c "$PIN3 '$PLEACH' ls -l"
assert_contains "incomplete: ls -l flags it" "$OUT" "creation never finished"
# The decisive one: "fully integrated — removable" reads as "your work is merged,
# this is safe to drop". Over a session whose dependencies were never installed it
# is not a description of anything.
assert_not_contains "incomplete: and does NOT call it fully integrated" \
  "$OUT" "fully integrated"

run bash -c "$PIN3 '$PLEACH' rm finished --force"
assert_rc "incomplete: rm removes it" "$RC" 0
assert_true "incomplete: and the marker goes with it, not left as litter" \
  [ ! -e "$(mark_of finished)" ]

# --- a missing .session-env is repaired, not merely reported -----------------
run bash -c "$PIN3 '$PLEACH' new keeper --no-bootstrap"
assert_rc "incomplete: a second session for the index check" "$RC" 0
run bash -c "$PIN3 '$PLEACH' new lost --no-bootstrap"
assert_rc "incomplete: the session that will lose its .session-env" "$RC" 0
KEEPER_IDX=$(env_val "$S3/keeper" PLEACH_INDEX)
rm -f "$S3/lost/.session-env"

run bash -c "$PIN3 '$PLEACH' doctor"
assert_rc "incomplete: doctor reports the missing .session-env" "$RC" 1
assert_contains "incomplete: with advice that is a command" "$OUT" "pleach doctor --fix"
assert_not_contains "incomplete: not one that is refused when you try it" \
  "$OUT" "recreate the session"

run bash -c "$PIN3 '$PLEACH' doctor --fix"
assert_rc "incomplete: --fix restores it" "$RC" 0
assert_true "incomplete: .session-env is back" [ -f "$S3/lost/.session-env" ]
LOST_IDX=$(env_val "$S3/lost" PLEACH_INDEX)
assert_true "incomplete: with an index of its own" [ -n "$LOST_IDX" ]
assert_true "incomplete: which is not the one already taken" \
  [ "$LOST_IDX" != "$KEEPER_IDX" ]
assert_eq "incomplete: and the identity matches the session it belongs to" \
  "$(env_val "$S3/lost" PLEACH_NAME)" "lost"

# Two sessions that both lost their .session-env, restored in ONE --fix pass. The
# second free_index has to see the first restore already written, or both are handed
# the same index and the same block of 100 ports — the collision the index exists to
# prevent, arriving through the repair that was supposed to end it.
run bash -c "$PIN3 '$PLEACH' new twina --no-bootstrap"
assert_rc "incomplete: first twin created" "$RC" 0
run bash -c "$PIN3 '$PLEACH' new twinb --no-bootstrap"
assert_rc "incomplete: second twin created" "$RC" 0
rm -f "$S3/twina/.session-env" "$S3/twinb/.session-env"
run bash -c "$PIN3 '$PLEACH' doctor --fix"
assert_rc "incomplete: one --fix pass restores both" "$RC" 0
TA=$(env_val "$S3/twina" PLEACH_INDEX); TB=$(env_val "$S3/twinb" PLEACH_INDEX)
PA=$(env_val "$S3/twina" PLEACH_PORT_BASE); PB=$(env_val "$S3/twinb" PLEACH_PORT_BASE)
assert_true "incomplete: both twins got an index" bash -c "[ -n '$TA' ] && [ -n '$TB' ]"
assert_true "incomplete: and they are not the same index" [ "$TA" != "$TB" ]
assert_true "incomplete: nor the same port block" [ "$PA" != "$PB" ]
# doctor is the independent judge: it checks for duplicates without knowing how
# the indexes were assigned.
run bash -c "$PIN3 '$PLEACH' doctor"
assert_not_contains "incomplete: no session ends up sharing an index or a block" \
  "$OUT" "is already taken by another session"

# --- the real interruption, POSIX only --------------------------------------
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  (Windows: SIGKILL on a background job does not orphan the run the same"
    echo "   way through Git Bash — the reporting above is asserted from a planted"
    echo "   marker, so what goes untested here is only whether a real crash"
    echo "   produces one.)"
    ;;
  *)
    $PIN3 "$PLEACH" new slow >/dev/null 2>&1 &
    SLOW=$!
    for _ in $(seq 1 900); do [ -f "$S3/slow/.session-env" ] && break; sleep 0.05; done
    if [ -f "$S3/slow/.session-env" ] && kill -0 "$SLOW" 2>/dev/null; then
      kill -9 "$SLOW" 2>/dev/null || true
      wait "$SLOW" 2>/dev/null || true
    fi
    assert_true "incomplete: a run killed during bootstrap wrote .session-env" \
      [ -f "$S3/slow/.session-env" ]
    # It has everything a finished session has, so nothing else tells them apart.
    assert_true "incomplete: and left the marker that says it never finished" \
      [ -e "$(mark_of slow)" ]
    run bash -c "$PIN3 '$PLEACH' doctor"
    assert_rc "incomplete: doctor catches the real interruption too" "$RC" 1
    assert_contains "incomplete: naming that session" "$OUT" "slow: creation never finished"
    ;;
esac

# ---------------------------------------------------------------------------
header "Test 47: a conflict verdict expires when the conflict does"
# ---------------------------------------------------------------------------
# The pair check compares session tip against session tip and never consults the
# base, so a session whose work had already LANDED kept conflicting with everyone
# for as long as its folder existed. The overlap section below it did expire — it
# diffs against $BASE — so one run could report "WOULD CONFLICT s3 <-> s4" while
# saying nothing about that file in the overlap table it sat above.
#
# Its own mini workspace: this merges a session branch into the base, which the
# shared fixture's canonical has checked out.
MINI4=$(cd "$SANDBOX" && mkdir -p expiry && cd expiry && pwd)
setup_repo "$MINI4/canon"
printf 'one\ntwo\nthree\n' > "$MINI4/canon/shared.txt"
git -C "$MINI4/canon" add -A && git -C "$MINI4/canon" commit -q -m "initial"
PIN4="env PLEACH_CANONICAL=$MINI4/canon PLEACH_EXPECT_CANONICAL=$MINI4/canon"
S4D="$MINI4/.sessions"

# No `init` here: PLEACH_CANONICAL is pinned, so there is nothing for a conf to say.
run bash -c "$PIN4 '$PLEACH' new alpha --no-bootstrap"
assert_rc "expiry: alpha created" "$RC" 0
run bash -c "$PIN4 '$PLEACH' new beta --no-bootstrap"
assert_rc "expiry: beta created" "$RC" 0

printf 'ALPHA\ntwo\nthree\n' > "$S4D/alpha/shared.txt"
git -C "$S4D/alpha" commit -q -am "alpha takes line 1"
printf 'BETA\ntwo\nthree\n' > "$S4D/beta/shared.txt"
git -C "$S4D/beta" commit -q -am "beta takes line 1"

run bash -c "$PIN4 '$PLEACH' conflicts"
assert_contains "expiry: while both are open, it is a real conflict" "$OUT" "WOULD CONFLICT"
assert_contains "expiry: naming the pair" "$OUT" "alpha <-> beta"

# alpha lands. Nothing about beta changed, and nothing about alpha's tip changed
# either — which is exactly why the old check could not tell.
git -C "$MINI4/canon" merge --no-ff --no-edit -q session/alpha
run bash -c "$PIN4 '$PLEACH' conflicts"
assert_rc "expiry: still exits 0" "$RC" 0
assert_not_contains "expiry: the landed session is no longer in conflict with anyone" \
  "$OUT" "alpha <-> beta"
# But beta still cannot merge: main now carries alpha's line 1. A pair check answers
# "can these two land together"; once the counterpart has landed, the only question
# left is "can this one land at all". Skipping landed sessions WITHOUT asking that
# turned a stale report into "No file is being edited in more than one session" over
# a session git refuses to merge — trading a nuisance for a false all-clear.
assert_contains "expiry: the surviving session is checked against the base itself" \
  "$OUT" "beta <-> main"
# Refs and names are positional: crossing them attributes each side's content to the
# other, which reads as a coherent report and is a lie. beta's line is BETA.
assert_contains "expiry: and each side's content is attributed to the side that wrote it" \
  "$OUT" "beta │ BETA"
assert_contains "expiry: including the base's own" "$OUT" "main │ ALPHA"
assert_not_contains "expiry: and the run is not called clean" \
  "$OUT" "No file is being edited"

# And it must not have gone blind in the process: a pair that genuinely conflicts
# is still reported after the sweep.
run bash -c "$PIN4 '$PLEACH' new gamma --no-bootstrap"
assert_rc "expiry: gamma created" "$RC" 0
printf 'GAMMA\ntwo\nthree\n' > "$S4D/gamma/shared.txt"
git -C "$S4D/gamma" commit -q -am "gamma takes line 1 as well"
run bash -c "$PIN4 '$PLEACH' conflicts"
assert_contains "expiry: a live pair is still reported" "$OUT" "WOULD CONFLICT"
assert_contains "expiry: and it is the live one" "$OUT" "beta <-> gamma"

# ---------------------------------------------------------------------------
header "Test 48: a .session-env pleach cannot read is not a free port block"
# ---------------------------------------------------------------------------
# Measured while moving a real workspace over from another tool. Its sessions
# already had a .session-env, in a shape pleach does not read; free_index looked
# for `export PLEACH_INDEX=`, found none in any of them, concluded index 1 was
# free, and handed the new session the exact port block a live session was
# already serving on. `doctor` then printed "✓ alpha: index , ports +" — the
# empty values rendered as a tick — and closed with "no problems found".
# Both halves are one defect: reading "I could not parse it" as "nothing is there".
MINI4=$(cd "$SANDBOX" && mkdir -p unreadable && cd unreadable && pwd)
setup_repo "$MINI4/canon"
echo root > "$MINI4/canon/f.txt"
git -C "$MINI4/canon" add -A && git -C "$MINI4/canon" commit -q -m initial
printf 'PLEACH_SUBS=()\npleach_bootstrap() { :; }\n' > "$MINI4/canon/.pleach.conf"
PIN4="env PLEACH_CANONICAL=$MINI4/canon PLEACH_EXPECT_CANONICAL=$MINI4/canon"
S4="$MINI4/.sessions"

run bash -c "$PIN4 '$PLEACH' new alpha --no-bootstrap"
assert_rc "unreadable: alpha created" "$RC" 0
ALPHA_PORTS=$(env_val "$S4/alpha" PLEACH_PORT_BASE)

# Unreadable the way a foreign tool leaves it: every other line intact, and no
# line pleach recognises as the index.
grep -v '^export PLEACH_INDEX=' "$S4/alpha/.session-env" > "$S4/alpha/.env.tmp"
mv "$S4/alpha/.env.tmp" "$S4/alpha/.session-env"

run bash -c "$PIN4 '$PLEACH' doctor"
assert_rc "unreadable: doctor exits non-zero" "$RC" 1
assert_contains "unreadable: naming what it could not read" "$OUT" "no PLEACH_INDEX"
assert_contains "unreadable: and the session it belongs to" "$OUT" "alpha"
assert_not_contains "unreadable: without certifying the workspace healthy" \
  "$OUT" "no problems found"
assert_not_contains "unreadable: nor a tick over empty values" "$OUT" "index , ports"

run bash -c "$PIN4 '$PLEACH' new beta --no-bootstrap"
assert_rc "unreadable: new refuses rather than guess a port block" "$RC" 1
assert_contains "unreadable: saying which session blocks it" "$OUT" "alpha"
assert_contains "unreadable: and saying what is wrong with it" "$OUT" "no PLEACH_INDEX"
# It read "alphahas a .session-env" once: a one-name list has no trailing
# separator, so splicing it mid-sentence glued it to the next word.
assert_not_contains "unreadable: without gluing the name to the next word" "$OUT" "alphahas"
assert_true "unreadable: and leaves no half-made session behind" [ ! -d "$S4/beta" ]

printf 'export PLEACH_INDEX=1\n' >> "$S4/alpha/.session-env"
run bash -c "$PIN4 '$PLEACH' new beta --no-bootstrap"
assert_rc "unreadable: once readable again, new works" "$RC" 0
assert_true "unreadable: and beta did not land on alpha's block" \
  [ "$(env_val "$S4/beta" PLEACH_PORT_BASE)" != "$ALPHA_PORTS" ]

# Present but unusable is the same defect in a narrower form: `PLEACH_INDEX=` with
# nothing after it satisfies "the line is there" and then reports as a blank, which
# is the "index , ports +" tick all over again. Two declarations are worse than
# none: pleach reads the first and `source .session-env` exports the last, so the
# block it reports and the block the dev server binds are different numbers.
ALPHA_ENV="$S4/alpha/.session-env"
cp "$ALPHA_ENV" "$S4/alpha/env.good"
break_index() { # $1 = the PLEACH_INDEX line(s) that replace the good one
  grep -v '^export PLEACH_INDEX=' "$S4/alpha/env.good" > "$ALPHA_ENV"
  printf '%s\n' "$1" >> "$ALPHA_ENV"
}

break_index "export PLEACH_INDEX="
run bash -c "$PIN4 '$PLEACH' doctor"
assert_rc "unreadable: an empty index is not a readable one" "$RC" 1
assert_contains "unreadable: and is reported as unreadable" "$OUT" "no PLEACH_INDEX"

break_index "export PLEACH_INDEX=abc"
run bash -c "$PIN4 '$PLEACH' doctor"
assert_rc "unreadable: nor is one that is not a number" "$RC" 1

break_index "$(printf 'export PLEACH_INDEX=1\nexport PLEACH_INDEX=7')"
run bash -c "$PIN4 '$PLEACH' doctor"
assert_rc "unreadable: nor two of them disagreeing" "$RC" 1

cp "$S4/alpha/env.good" "$ALPHA_ENV"
run bash -c "$PIN4 '$PLEACH' doctor"
assert_rc "unreadable: and the workspace is healthy again once it is" "$RC" 0

# ---------------------------------------------------------------------------
header "Test 49: the skill leaves a pointer in the instruction file that already exists"
# ---------------------------------------------------------------------------
# `skill --project` writes .claude/skills/pleach/SKILL.md, which only the
# harnesses reading that directory ever see. The workspace this was measured on
# had seven harness directories and an AGENTS.md — and an AGENTS.md-based harness
# reads neither the skill nor the conf, so nothing told it the workspace had
# sessions at all. The pointer is the only part it does see. A marked block,
# because that is the shape that survives re-running: replaced, not stacked, and
# removing pleach is deleting it.
MINI5=$(cd "$SANDBOX" && mkdir -p skillptr && cd skillptr && pwd)
setup_repo "$MINI5/canon"
printf '# Acme\n\nRules the team already had.\n' > "$MINI5/canon/AGENTS.md"
git -C "$MINI5/canon" add -A && git -C "$MINI5/canon" commit -q -m initial
printf 'PLEACH_SUBS=()\n' > "$MINI5/canon/.pleach.conf"

run bash -c "cd '$MINI5/canon' && '$PLEACH' skill --project"
assert_rc "pointer: skill --project runs" "$RC" 0
assert_true "pointer: the skill file is written" \
  [ -f "$MINI5/canon/.claude/skills/pleach/SKILL.md" ]
assert_true "pointer: AGENTS.md gains the block" \
  grep -q 'pleach:begin' "$MINI5/canon/AGENTS.md"
assert_true "pointer: what the team already wrote survives" \
  grep -q 'Rules the team already had' "$MINI5/canon/AGENTS.md"
assert_contains "pointer: and it names where the boundary is" \
  "$(cat "$MINI5/canon/AGENTS.md")" ".session-env"

run bash -c "cd '$MINI5/canon' && '$PLEACH' skill --project"
assert_rc "pointer: a second run is fine" "$RC" 0
assert_eq "pointer: and does not stack a second copy" \
  "$(grep -c 'pleach:begin' "$MINI5/canon/AGENTS.md" || true)" "1"
assert_eq "pointer: the team's own text is still there once" \
  "$(grep -c 'Rules the team already had' "$MINI5/canon/AGENTS.md" || true)" "1"

# A file that is absent stays absent: pleach does not decide that a workspace
# ought to have a CLAUDE.md.
assert_true "pointer: no instruction file is invented" [ ! -f "$MINI5/canon/CLAUDE.md" ]

# One that exists gets it too — different harnesses read different files.
printf '# Claude\n' > "$MINI5/canon/CLAUDE.md"
run bash -c "cd '$MINI5/canon' && '$PLEACH' skill --project"
assert_true "pointer: an existing CLAUDE.md gets it as well" \
  grep -q 'pleach:begin' "$MINI5/canon/CLAUDE.md"

# Equal counts are not a valid pair. A closing marker sitting before an opening one
# passes a count check, and the rewrite then deletes from the opening marker to the
# end of the file — taking the team's text with it.
printf '# Acme\n<!-- pleach:end -->\n<!-- pleach:begin -->\nKeep me.\n' \
  > "$MINI5/canon/AGENTS.md"
run bash -c "cd '$MINI5/canon' && '$PLEACH' skill --project"
assert_true "pointer: a closing marker before an opening one is left alone" \
  grep -q 'Keep me' "$MINI5/canon/AGENTS.md"
assert_contains "pointer: and the file is named as needing a human" "$OUT" "markers"

# And init hands over the command, instead of leaving it to be discovered.
MINI6=$(cd "$SANDBOX" && mkdir -p initskill && cd initskill && pwd)
setup_repo "$MINI6/canon"
run bash -c "cd '$MINI6/canon' && env -u PLEACH_CANONICAL -u PLEACH_EXPECT_CANONICAL '$PLEACH' init"
assert_rc "pointer: init runs" "$RC" 0
assert_contains "pointer: and init names the skill command" "$OUT" "pleach skill"

# ---------------------------------------------------------------------------
header "Test 50: open does not create — a typo is not a request for a new session"
# ---------------------------------------------------------------------------
# `open` used to create the session when the name did not exist, which reads well
# in a README and badly at a keyboard: one slip of the fingers built worktrees, a
# branch, a port block and the whole dependency bootstrap, and then needed a
# `pleach rm` to undo. Creating is what `new` is for; `open` opens.
MINI7=$(cd "$SANDBOX" && mkdir -p noopen && cd noopen && pwd)
setup_repo "$MINI7/canon"
echo root > "$MINI7/canon/f.txt"
git -C "$MINI7/canon" add -A && git -C "$MINI7/canon" commit -q -m initial
printf 'PLEACH_SUBS=()\npleach_bootstrap() { :; }\n' > "$MINI7/canon/.pleach.conf"
PIN7="env PLEACH_CANONICAL=$MINI7/canon PLEACH_EXPECT_CANONICAL=$MINI7/canon"
S7="$MINI7/.sessions"

run bash -c "$PIN7 '$PLEACH' new fix-login --no-bootstrap"
assert_rc "noopen: a real session exists" "$RC" 0

run bash -c "$PIN7 '$PLEACH' open fix-login true"
assert_rc "noopen: opening the one that exists still works" "$RC" 0

run bash -c "$PIN7 '$PLEACH' open nosuchthing true"
assert_rc "noopen: opening one that does not exist fails" "$RC" 1
assert_contains "noopen: saying so" "$OUT" "does not exist"
assert_contains "noopen: and handing over the command that creates it" \
  "$OUT" "pleach new nosuchthing"
assert_true "noopen: without building anything" [ ! -d "$S7/nosuchthing" ]
assert_true "noopen: and without leaving a branch behind" \
  bash -c "! git -C '$MINI7/canon' rev-parse --verify -q session/nosuchthing >/dev/null"

# The typo is the whole reason this changed, so the error answers it.
run bash -c "$PIN7 '$PLEACH' open fix-logni true"
assert_rc "noopen: a near miss fails too" "$RC" 1
assert_contains "noopen: but names the session that was probably meant" "$OUT" "fix-login"
assert_true "noopen: and still builds nothing" [ ! -d "$S7/fix-logni" ]

# `--create` keeps the one-command flow for anyone who wants it, without it being
# what an unknown name means by default. Typing the flag is a decision; a typo is not.
run bash -c "$PIN7 '$PLEACH' open made-on-purpose --create true"
assert_rc "create: --create after the name builds the session" "$RC" 0
assert_true "create: and it is really there" [ -d "$S7/made-on-purpose" ]

run bash -c "$PIN7 '$PLEACH' open --create made-first true"
assert_rc "create: the flag is accepted before the name too" "$RC" 0
assert_true "create: and that one exists as well" [ -d "$S7/made-first" ]

run bash -c "$PIN7 '$PLEACH' open fix-login --create true"
assert_rc "create: on a session that exists it simply opens" "$RC" 0
assert_not_contains "create: without claiming to have created anything" \
  "$OUT" "does not exist"

# The flag belongs to pleach, not to the command being launched: everything after
# the session name is the command's own argv, and eating a lookalike out of it
# would change what the caller asked to run.
run bash -c "$PIN7 '$PLEACH' open fix-login printf '%s\\n' --create"
assert_rc "create: a command argument that looks like the flag still runs" "$RC" 0
assert_contains "create: and reaches the command untouched" "$OUT" "--create"

# Opening a session whose creation never finished used to say nothing at all, so a
# build failing on half-installed dependencies looked like the code's fault. It
# warns rather than refuses: `open` is also how you get in to look at the state,
# and the marker cannot tell "being created right now" from "interrupted yesterday".
: > "$S7/.pleach-building.fix-login"
run bash -c "$PIN7 '$PLEACH' open fix-login true"
assert_rc "noopen: an unfinished session still opens" "$RC" 0
assert_contains "noopen: but says the creation never finished" "$OUT" "creation never finished"
rm -f "$S7/.pleach-building.fix-login"
run bash -c "$PIN7 '$PLEACH' open fix-login true"
assert_not_contains "noopen: and a finished one is not nagged about it" \
  "$OUT" "creation never finished"

# A name nothing resembles must not have a suggestion invented for it.
run bash -c "$PIN7 '$PLEACH' open zzzzzzzz true"
assert_not_contains "noopen: no suggestion is invented for an unrelated name" \
  "$OUT" "did you mean"

# ---------------------------------------------------------------------------
header "Test 51: what is in the sessions folder but is not a session"
# ---------------------------------------------------------------------------
# `session_names` requires a .git at the root of the directory, so anything else
# living in the sessions folder is invisible to every command that lists sessions
# — `ls`, `doctor`, `prune`, `conflicts`. A real workspace had two stale
# .code-workspace files and a stray folder sitting there while doctor closed with
# "no problems found". The worse case is a directory that still has a .session-env
# and has lost its worktree: it is not "not a session", it is a broken one, and it
# is still holding a port block that no listing will show you.
MINI8=$(cd "$SANDBOX" && mkdir -p leftovers && cd leftovers && pwd)
setup_repo "$MINI8/canon"
echo root > "$MINI8/canon/f.txt"
git -C "$MINI8/canon" add -A && git -C "$MINI8/canon" commit -q -m initial
printf 'PLEACH_SUBS=()\npleach_bootstrap() { :; }\n' > "$MINI8/canon/.pleach.conf"
PIN8="env PLEACH_CANONICAL=$MINI8/canon PLEACH_EXPECT_CANONICAL=$MINI8/canon"
S8="$MINI8/.sessions"

run bash -c "$PIN8 '$PLEACH' new alive --no-bootstrap"
assert_rc "leftovers: a live session exists" "$RC" 0

run bash -c "$PIN8 '$PLEACH' doctor"
assert_rc "leftovers: a clean sessions folder is clean" "$RC" 0
assert_not_contains "leftovers: with nothing invented to note about it" "$OUT" "note(s) above"
assert_not_contains "leftovers: the live session is not called a leftover" "$OUT" "alive.code-workspace"
assert_not_contains "leftovers: and neither is the panorama" "$OUT" "panorama"

# A plain folder someone left there: reported, never touched. It could be anything.
mkdir -p "$S8/notasession/inner"
echo keep > "$S8/notasession/inner/f.txt"
# A generated file whose session is gone, and a marker whose session is gone. The
# workspace file carries the real generated content: an empty one would be deleted
# for the wrong reason, and would not be something pleach could ever have written.
printf '{\n  "folders": [\n    { "path": "ghost" }\n  ]\n}\n' > "$S8/ghost.code-workspace"
: > "$S8/.pleach-building.ghost"

run bash -c "$PIN8 '$PLEACH' doctor"
assert_contains "leftovers: the stray folder is named" "$OUT" "notasession"
# The verdict is the line people read. Printing a bare "no problems found" under
# three notes is the same reader-scanning-the-ticks failure as certifying an
# unfinished session: nothing is broken, but something was said and the summary
# swallowed it.
assert_contains "leftovers: and the verdict admits there were notes" "$OUT" "note(s) above"
assert_contains "leftovers: the orphaned workspace file is named" "$OUT" "ghost.code-workspace"
assert_contains "leftovers: the orphaned marker is named" "$OUT" "pleach-building.ghost"

# A .code-workspace is a generic name, and the sessions folder is somewhere people
# do leave things — the workspace this came from had a stray folder in it. Deleting
# a file somebody wrote by hand because its name has no matching directory would be
# the tool destroying work it did not create. pleach's own file lists the session as
# its first folder; that is what --fix requires before removing anything.
printf '{\n  "folders": [\n    { "path": "/somewhere/else" }\n  ]\n}\n' \
  > "$S8/handmade.code-workspace"

run bash -c "$PIN8 '$PLEACH' doctor --fix"
assert_rc "leftovers: --fix runs" "$RC" 0
assert_true "leftovers: a workspace file pleach did not generate is left alone" \
  [ -f "$S8/handmade.code-workspace" ]
assert_contains "leftovers: and is reported as not pleach's to delete" \
  "$OUT" "handmade.code-workspace"
assert_true "leftovers: the orphaned workspace file is gone" [ ! -e "$S8/ghost.code-workspace" ]
assert_true "leftovers: the orphaned marker is gone" [ ! -e "$S8/.pleach-building.ghost" ]
assert_true "leftovers: but the stray folder is untouched — it is not pleach's to delete" \
  [ -f "$S8/notasession/inner/f.txt" ]
assert_true "leftovers: and the live session still has its workspace file" \
  [ -f "$S8/alive.code-workspace" ]

# The lock composes its owner line in a scratch file before linking it into place.
# A run killed inside that window leaves .pleach.lock.<pid> behind, and nothing
# removed it — not `rm`, not `doctor --fix`, which releases the lock and walks
# past its scratch. Test 36 has been reporting exactly this whenever the kill
# landed in the window; it was read as a flake.
: > "$S8/.pleach.lock.999999"
: > "$S8/.pleach.lock.$$"
run bash -c "$PIN8 '$PLEACH' doctor"
assert_contains "leftovers: a scratch line from a dead run is named" "$OUT" "999999"
assert_not_contains "leftovers: but a live run's own scratch is left alone" "$OUT" ".pleach.lock.$$"

run bash -c "$PIN8 '$PLEACH' doctor --fix"
assert_true "leftovers: --fix clears the dead run's scratch" [ ! -e "$S8/.pleach.lock.999999" ]
assert_true "leftovers: and never the live one" [ -e "$S8/.pleach.lock.$$" ]
rm -f "$S8/.pleach.lock.$$"

# The serious one: a directory that kept its .session-env and lost its worktree is
# holding a port block, and every listing skips it.
mkdir -p "$S8/broken"
cp "$S8/alive/.session-env" "$S8/broken/.session-env"
run bash -c "$PIN8 '$PLEACH' doctor"
assert_rc "leftovers: a session with no worktree is a problem, not a note" "$RC" 1
assert_contains "leftovers: it is named" "$OUT" "broken"
assert_not_contains "leftovers: and the run is not certified clean" "$OUT" "no problems found"

# ---------------------------------------------------------------------------
header "Test 52: conflicts reads the branch a session is ON, not the one it was named after"
# ---------------------------------------------------------------------------
# Measured on a live ten-session workspace: 3 of the 10 root worktrees and 20 of
# the 81 sub-repo worktrees were checked out on some other branch — a PR branch, a
# fix branch, whatever the hour's work needed. Every conflict check looked up
# refs/heads/session/<name>, so the report described work those sessions had
# already moved on from.
#
# It errs in BOTH directions at once, which is why reading the output does not
# reveal it: current work goes unreported, abandoned work gets reported, and both
# carry the session's name. The overlap table further down already used
# $BASE...HEAD — so a single run could list a file as touched by two sessions and,
# three lines above, decline to call it a conflict.

MINI9=$(cd "$SANDBOX" && mkdir -p headref && cd headref && pwd)
setup_repo "$MINI9/canon"
printf 'one\ntwo\nthree\n' > "$MINI9/canon/shared.txt"
git -C "$MINI9/canon" add -A && git -C "$MINI9/canon" commit -q -m "initial"
PIN9="env PLEACH_CANONICAL=$MINI9/canon PLEACH_EXPECT_CANONICAL=$MINI9/canon"
S9="$MINI9/.sessions"

run bash -c "$PIN9 '$PLEACH' new alpha --no-bootstrap"
assert_rc "headref: alpha created" "$RC" 0
run bash -c "$PIN9 '$PLEACH' new beta --no-bootstrap"
assert_rc "headref: beta created" "$RC" 0

# What session/alpha holds is harmless and in another file. What alpha is actually
# DOING lives on another branch, and collides head-on with beta.
echo "harmless" > "$S9/alpha/other.txt"
git -C "$S9/alpha" add other.txt && git -C "$S9/alpha" commit -q -m "alpha: unrelated work"
git -C "$S9/alpha" checkout -q -b feature/live
printf 'ALPHA-LIVE\ntwo\nthree\n' > "$S9/alpha/shared.txt"
git -C "$S9/alpha" commit -q -am "alpha takes line 1, on the branch it is on"

printf 'BETA\ntwo\nthree\n' > "$S9/beta/shared.txt"
git -C "$S9/beta" commit -q -am "beta takes line 1 too"

run bash -c "$PIN9 '$PLEACH' conflicts"
assert_rc "headref: rc 0" "$RC" 0
BLOCK=$(conflict_block "$OUT")
assert_contains "headref: the collision on the CURRENT branch is reported" "$BLOCK" "shared.txt"
assert_contains "headref: with what alpha actually wrote" "$BLOCK" "ALPHA-LIVE"
assert_contains "headref: and what beta wrote" "$BLOCK" "BETA"
# The bare name is what misled the reader: "alpha" reads as session/alpha. When the
# session is somewhere else, the report has to say where.
assert_contains "headref: naming the branch, since it is not the session's own" \
  "$BLOCK" "feature/live"

# The other direction. gamma's NAMED branch took line 1 once; gamma itself moved on
# and is doing something else. Reporting that as gamma's conflict attributes to a
# session an edit it no longer has.
run bash -c "$PIN9 '$PLEACH' new gamma --no-bootstrap"
assert_rc "headref: gamma created" "$RC" 0
printf 'GAMMA-OLD\ntwo\nthree\n' > "$S9/gamma/shared.txt"
git -C "$S9/gamma" commit -q -am "gamma took line 1, once"
git -C "$S9/gamma" checkout -q -b quiet/branch main
echo "elsewhere" > "$S9/gamma/elsewhere.txt"
git -C "$S9/gamma" add elsewhere.txt
git -C "$S9/gamma" commit -q -m "gamma is doing something else now"

run bash -c "$PIN9 '$PLEACH' conflicts"
BLOCK=$(conflict_block "$OUT")
assert_not_contains "headref: work a session has left behind is no longer reported as its conflict" \
  "$BLOCK" "GAMMA-OLD"

# Detached HEAD is a real state — a bisect, a tag, a commit someone pasted. There
# is no branch name to read, and the commit is still the honest answer.
run bash -c "$PIN9 '$PLEACH' new delta --no-bootstrap"
assert_rc "headref: delta created" "$RC" 0
echo "harmless" > "$S9/delta/delta-other.txt"
git -C "$S9/delta" add delta-other.txt
git -C "$S9/delta" commit -q -m "delta: unrelated work"
git -C "$S9/delta" checkout -q --detach HEAD
printf 'DELTA-DETACHED\ntwo\nthree\n' > "$S9/delta/shared.txt"
git -C "$S9/delta" commit -q -am "delta takes line 1 while detached"

run bash -c "$PIN9 '$PLEACH' conflicts"
assert_rc "headref: rc 0 with a detached session present" "$RC" 0
BLOCK=$(conflict_block "$OUT")
assert_contains "headref: a detached worktree is compared by commit, not skipped" \
  "$BLOCK" "DELTA-DETACHED"
# The id handed to merge-tree is the FULL one: an abbreviation is only guaranteed
# unambiguous at the moment git prints it, and this string is a ref, not a label.
# What the report shows is the short form, because a 40-character label is not one.
DELTA_SHA=$(git -C "$S9/delta" rev-parse HEAD)
assert_contains "headref: the detached session is labelled by a readable id" \
  "$BLOCK" "delta (${DELTA_SHA:0:8})"
assert_not_contains "headref: and not by all forty characters" "$BLOCK" "$DELTA_SHA"

# ---------------------------------------------------------------------------
header "Test 53: pending work is judged on the branch the session is on"
# ---------------------------------------------------------------------------
# The same blind spot as Test 52, in the command that DELETES. session_problems
# counted commits on refs/heads/session/<name> only, so a session whose work sat
# on another branch reported as "fully integrated (removable)" — and prune says
# that with a green tick before removing it.
#
# What it costs depends on where the commits live. On a named branch they survive
# as a ref, and the loss is the worktree plus a false statement. Detached, nothing
# holds them at all: `worktree remove --force` and `worktree prune` leave them for
# the reflog to forget.

MINI10=$(cd "$SANDBOX" && mkdir -p pending && cd pending && pwd)
setup_repo "$MINI10/canon"
echo "base" > "$MINI10/canon/file.txt"
git -C "$MINI10/canon" add -A && git -C "$MINI10/canon" commit -q -m "initial"
PIN10="env PLEACH_CANONICAL=$MINI10/canon PLEACH_EXPECT_CANONICAL=$MINI10/canon"
S10="$MINI10/.sessions"

run bash -c "$PIN10 '$PLEACH' new onbranch --no-bootstrap"
assert_rc "pending: onbranch created" "$RC" 0
git -C "$S10/onbranch" checkout -q -b work/real
echo "work that is not in main" > "$S10/onbranch/work.txt"
git -C "$S10/onbranch" add work.txt
git -C "$S10/onbranch" commit -q -m "committed work, on the branch the session is on"

run bash -c "$PIN10 '$PLEACH' prune"
assert_rc "pending: prune runs" "$RC" 0
assert_not_contains "pending: a session with unintegrated commits is NOT called removable" \
  "$OUT" "onbranch — fully integrated"
assert_contains "pending: it is reported as pending work" "$OUT" "onbranch — pending work"
assert_contains "pending: naming the branch the commits are on" "$OUT" "work/real"

# Two outputs of one binary, on one session, in one state. `ls -l` already counted
# $BASE..HEAD in the worktree, so it printed "+1 commits" about the very session
# prune called fully integrated. A contradiction inside a tool is worse than either
# half being wrong: whichever one you read first is the one you believe.
run bash -c "$PIN10 '$PLEACH' ls -l"
assert_contains "pending: ls -l counts the commit" "$OUT" "+1 commits"
assert_contains "pending: on the branch the worktree is on" "$OUT" "work/real"

# rm must refuse for the same reason — prune only calls rm, so a guard that lives
# solely in prune is one flag away from being skipped.
run bash -c "$PIN10 '$PLEACH' rm onbranch"
assert_rc "pending: rm refuses too" "$RC" 1
assert_contains "pending: and says why" "$OUT" "pending work"
assert_true "pending: the session is still there" [ -d "$S10/onbranch" ]

# Detached is the case with no ref to fall back on.
run bash -c "$PIN10 '$PLEACH' new loose --no-bootstrap"
assert_rc "pending: loose created" "$RC" 0
git -C "$S10/loose" checkout -q --detach HEAD
echo "nothing points at this" > "$S10/loose/detached.txt"
git -C "$S10/loose" add detached.txt
git -C "$S10/loose" commit -q -m "a commit no branch holds"

run bash -c "$PIN10 '$PLEACH' prune"
assert_not_contains "pending: a detached commit is not 'fully integrated' either" \
  "$OUT" "loose — fully integrated"
assert_contains "pending: it is pending work" "$OUT" "loose — pending work"

# The decisive negative: a session that really IS integrated must stay removable,
# or the fix has just broken post-merge hygiene instead of the blind spot.
run bash -c "$PIN10 '$PLEACH' new clean --no-bootstrap"
assert_rc "pending: clean created" "$RC" 0
run bash -c "$PIN10 '$PLEACH' prune"
assert_contains "pending: an untouched session is still removable" "$OUT" "clean — fully integrated"

# ---------------------------------------------------------------------------
header "Test 54: status reports how far behind the local canonical each repo is"
# ---------------------------------------------------------------------------
# The signal exists so the person inside a session can decide whether now is the
# moment to integrate — never to integrate for them. It is per repo because a
# session touching only the api does not care that the docs moved.

MINI11=$(cd "$SANDBOX" && mkdir -p stale && cd stale && pwd)
setup_repo "$MINI11/canon"
echo "# canon" > "$MINI11/canon/README.md"
git -C "$MINI11/canon" add -A && git -C "$MINI11/canon" commit -q -m "initial"
setup_repo "$MINI11/canon/api"
echo "api" > "$MINI11/canon/api/f.txt"
git -C "$MINI11/canon/api" add -A && git -C "$MINI11/canon/api" commit -q -m "initial"
setup_repo "$MINI11/canon/web"
echo "web" > "$MINI11/canon/web/f.txt"
git -C "$MINI11/canon/web" add -A && git -C "$MINI11/canon/web" commit -q -m "initial"

# A repo still on master has no 'main' to be behind of. add_wt already cuts the
# session from that repo's own branch; the report must skip it, not error on it.
git init -q -b master "$MINI11/canon/legacy"
git -C "$MINI11/canon/legacy" config user.email "test@test"
git -C "$MINI11/canon/legacy" config user.name "test"
echo "legacy" > "$MINI11/canon/legacy/f.txt"
git -C "$MINI11/canon/legacy" add -A && git -C "$MINI11/canon/legacy" commit -q -m "initial"

PIN11="env PLEACH_CANONICAL=$MINI11/canon PLEACH_EXPECT_CANONICAL=$MINI11/canon"
S11="$MINI11/.sessions"

run bash -c "$PIN11 '$PLEACH' new work --no-bootstrap"
assert_rc "status: session created" "$RC" 0

run bash -c "$PIN11 '$PLEACH' status work"
assert_rc "status: rc 0 when in date" "$RC" 0
assert_contains "status: says so in one line" "$OUT" "(up to date with the local main)"
assert_not_contains "status: no per-repo lines when in date" "$OUT" "commit(s) behind"

# The canonical moves — twice in the root, once in api, not at all in web.
git -C "$MINI11/canon" commit -q --allow-empty -m "canon root moves"
git -C "$MINI11/canon" commit -q --allow-empty -m "canon root moves again"
git -C "$MINI11/canon/api" commit -q --allow-empty -m "api moves"

run bash -c "$PIN11 '$PLEACH' status work"
assert_rc "status: rc 0 even when behind — it is a report, not a check" "$RC" 0
assert_contains "status: the root's distance" "$OUT" "root: 2 commit(s) behind"
assert_contains "status: api's distance" "$OUT" "api: 1 commit(s) behind"
assert_not_contains "status: web is in date, so it is not listed" "$OUT" "web:"
assert_not_contains "status: no in-date line while something is behind" "$OUT" "up to date"
assert_not_contains "status: a repo with no base to measure is skipped" "$OUT" "legacy"
assert_not_contains "status: it reports, it does not instruct" "$OUT" "pleach sync"

# The branch a session was NAMED after is not the branch it is on: 3 of 10 root
# worktrees on a live workspace were somewhere else. Reading refs/heads/session/<name>
# answers about work nobody is doing.
git -C "$MINI11/canon/web" commit -q --allow-empty -m "web moves"
git -C "$MINI11/canon/web" commit -q --allow-empty -m "web moves again"

run bash -c "$PIN11 '$PLEACH' status work"
assert_contains "status: web is behind while it sits on session/work" "$OUT" "web: 2 commit(s) behind"

# Same session, same named branch, different HEAD — and this HEAD is caught up.
git -C "$S11/work/web" checkout -q -b feature/live
git -C "$S11/work/web" merge -q --no-edit main
run bash -c "$PIN11 '$PLEACH' status work"
assert_not_contains "status: measures the branch the worktree is ON, not session/work" \
  "$OUT" "web:"
assert_contains "status: and what really is behind is still reported" \
  "$OUT" "root: 2 commit(s) behind"
git -C "$S11/work/web" checkout -q session/work

# Scope, exactly as sync resolves it.
run bash -c "cd '$S11/work' && $PIN11 '$PLEACH' status"
assert_rc "status: inside a session, no name is needed" "$RC" 0
assert_contains "status: it resolved to the session it stands in" "$OUT" "● work"

run bash -c "cd '$MINI11/canon' && $PIN11 '$PLEACH' status"
assert_rc "status: no name in the canonical is a usage error" "$RC" 1
assert_contains "status: and it says how to ask" "$OUT" "usage: pleach status"

run bash -c "$PIN11 '$PLEACH' status nosuch"
assert_rc "status: an unknown session is refused" "$RC" 1
assert_contains "status: saying where it looked" "$OUT" "does not exist at"

# -q means nothing at all, in either state — not "less output".
run bash -c "$PIN11 '$PLEACH' status work -q"
assert_rc "status -q: rc 0 while behind" "$RC" 0
assert_eq "status -q: prints nothing while behind" "$OUT" ""
run bash -c "cd '$S11/work' && $PIN11 '$PLEACH' status --quiet"
assert_eq "status --quiet: the long spelling is the same flag" "$OUT" ""

# ---------------------------------------------------------------------------
header "Test 55: status --all sweeps every session"
# ---------------------------------------------------------------------------
run bash -c "$PIN11 '$PLEACH' new second --no-bootstrap"
assert_rc "status --all: a second session created" "$RC" 0
# 'second' was cut from the current main, so it needs the canonical to move again
# before it has anything to be behind of.
git -C "$MINI11/canon" commit -q --allow-empty -m "canon root moves once more"

run bash -c "$PIN11 '$PLEACH' status --all"
assert_rc "status --all: rc 0" "$RC" 0
assert_contains "status --all: reports the first session" "$OUT" "● work"
assert_contains "status --all: reports the second" "$OUT" "● second"
assert_contains "status --all: the first session's root distance" "$OUT" "root: 3 commit(s) behind"

run bash -c "$PIN11 '$PLEACH' status --all work"
assert_rc "status --all with a name: refused" "$RC" 1
assert_contains "status --all with a name: says why" "$OUT" "does not take a session name"

# --all is a scope, not a place: it works from inside a session too.
run bash -c "cd '$S11/work' && $PIN11 '$PLEACH' status --all"
assert_rc "status --all: works from inside a session" "$RC" 0
assert_contains "status --all: and still sees the others" "$OUT" "● second"

# An empty sessions folder is not an error.
MINI12=$(cd "$SANDBOX" && mkdir -p stale-empty && cd stale-empty && pwd)
setup_repo "$MINI12/canon"
echo "# canon" > "$MINI12/canon/README.md"
git -C "$MINI12/canon" add -A && git -C "$MINI12/canon" commit -q -m "initial"
PIN12="env PLEACH_CANONICAL=$MINI12/canon PLEACH_EXPECT_CANONICAL=$MINI12/canon"

run bash -c "$PIN12 '$PLEACH' status --all"
assert_rc "status --all: no sessions is rc 0" "$RC" 0
assert_contains "status --all: and says the folder is empty" "$OUT" "no sessions in"

# ---------------------------------------------------------------------------
header "Test 56: --exit-code is opt-in, and -q is the silent way to ask"
# ---------------------------------------------------------------------------
# A report that fails is a check, and callers start wrapping it in `|| true`. The
# exit code is therefore something you ask for, exactly as `git diff --exit-code`.
run bash -c "$PIN11 '$PLEACH' status work --exit-code"
assert_rc "status --exit-code: 1 when behind" "$RC" 1
assert_contains "status --exit-code: and still prints the report" "$OUT" "commit(s) behind"

run bash -c "$PIN11 '$PLEACH' status work"
assert_rc "status: the same state without the flag is rc 0" "$RC" 0

# -q on its own is covered by Test 54; what is new here is the pairing.
run bash -c "$PIN11 '$PLEACH' status work -q --exit-code"
assert_rc "status -q --exit-code: 1 when behind, silently" "$RC" 1
assert_eq "status -q --exit-code: still prints nothing" "$OUT" ""

# A session cut from the current base has nothing to be behind of.
run bash -c "$PIN11 '$PLEACH' new fresh --no-bootstrap"
assert_rc "status: a fresh session created" "$RC" 0
run bash -c "$PIN11 '$PLEACH' status fresh --exit-code"
assert_rc "status --exit-code: 0 when nothing is behind" "$RC" 0
run bash -c "$PIN11 '$PLEACH' status fresh -q --exit-code"
assert_rc "status -q --exit-code: 0 when nothing is behind" "$RC" 0
assert_eq "status -q: silent in that case too" "$OUT" ""

# ---------------------------------------------------------------------------
header "Test 57: status --json is the machine surface"
# ---------------------------------------------------------------------------
MINI13=$(cd "$SANDBOX" && mkdir -p stale-json && cd stale-json && pwd)
setup_repo "$MINI13/canon"
echo "# canon" > "$MINI13/canon/README.md"
git -C "$MINI13/canon" add -A && git -C "$MINI13/canon" commit -q -m "initial"
setup_repo "$MINI13/canon/api"
echo "api" > "$MINI13/canon/api/f.txt"
git -C "$MINI13/canon/api" add -A && git -C "$MINI13/canon/api" commit -q -m "initial"
setup_repo "$MINI13/canon/web"
echo "web" > "$MINI13/canon/web/f.txt"
git -C "$MINI13/canon/web" add -A && git -C "$MINI13/canon/web" commit -q -m "initial"
git init -q -b master "$MINI13/canon/legacy"
git -C "$MINI13/canon/legacy" config user.email "test@test"
git -C "$MINI13/canon/legacy" config user.name "test"
echo "legacy" > "$MINI13/canon/legacy/f.txt"
git -C "$MINI13/canon/legacy" add -A && git -C "$MINI13/canon/legacy" commit -q -m "initial"
PIN13="env PLEACH_CANONICAL=$MINI13/canon PLEACH_EXPECT_CANONICAL=$MINI13/canon"
S13="$MINI13/.sessions"

run bash -c "$PIN13 '$PLEACH' new j --no-bootstrap"
assert_rc "status --json: session created" "$RC" 0
git -C "$MINI13/canon" commit -q --allow-empty -m "root +1"
git -C "$MINI13/canon/api" commit -q --allow-empty -m "api +1"
git -C "$MINI13/canon/api" commit -q --allow-empty -m "api +2"

run bash -c "$PIN13 '$PLEACH' status j --json"
assert_rc "status --json: rc 0" "$RC" 0
assert_contains "status --json: names the base" "$OUT" '"base": "main"'
assert_contains "status --json: names the session" "$OUT" '"name": "j"'
assert_contains "status --json: the session total is the sum" "$OUT" '"behind": 3'
assert_contains "status --json: the root's distance" \
  "$OUT" '{"repo": "root", "branch": "session/j", "behind": 1}'
assert_contains "status --json: api's distance" \
  "$OUT" '{"repo": "api", "branch": "session/j", "behind": 2}'
# Measured and clean is not the same answer as not measured, so web is listed at 0
# and legacy — which has no main to be behind of — is absent.
assert_contains "status --json: a measured, clean repo is still listed" \
  "$OUT" '{"repo": "web", "branch": "session/j", "behind": 0}'
assert_not_contains "status --json: an unmeasurable repo is omitted" "$OUT" '"repo": "legacy"'

# The real HEAD, here too.
git -C "$S13/j/web" checkout -q -b feature/live
run bash -c "$PIN13 '$PLEACH' status j --json"
assert_contains "status --json: carries the branch the worktree is ON" "$OUT" '"branch": "feature/live"'
git -C "$S13/j/web" checkout -q session/j

# --exit-code answers the same question in either format.
run bash -c "$PIN13 '$PLEACH' status j --json --exit-code"
assert_rc "status --json --exit-code: 1 when behind" "$RC" 1
run bash -c "$PIN13 '$PLEACH' new k --no-bootstrap"
run bash -c "$PIN13 '$PLEACH' status k --json --exit-code"
assert_rc "status --json --exit-code: 0 when nothing is behind" "$RC" 0

run bash -c "$PIN13 '$PLEACH' status --all --json"
assert_rc "status --all --json: rc 0" "$RC" 0
assert_contains "status --all --json: carries both sessions" "$OUT" '"name": "k"'

# Valid JSON, not just a string that looks like it. Same treatment as ls --json:
# with no parser available the assertion is skipped rather than faked.
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "status --json: output parses as JSON"
  else
    fail "status --json: output is not valid JSON"
  fi
else
  echo "  (skipped: no python3 to validate the JSON)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "===================================="
echo "Tests: $TESTS   Failures: $FAILS"
if [ "$FAILS" -gt 0 ]; then
  echo ""
  echo "Failed:"
  printf '%s' "$FAILED_NAMES"
fi
echo "===================================="

[ "$FAILS" -eq 0 ]
