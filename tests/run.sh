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
for c in init new open ls path cd add sync rm prune clean each conflicts repos doctor shell-init completions install update version; do
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

env_val() { # <session dir> <variable> -> its value in .session-env
  grep "^export $2=" "$1/.session-env" | head -1 | cut -d= -f2-
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
assert_true "concurrent new: the lock was released by both runs" \
  [ ! -d "$SESSIONS/.pleach.lock" ]

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
    [ -d "$SESSIONS/.pleach.lock" ] && break
    sleep 0.05
  done
  if [ -d "$SESSIONS/.pleach.lock" ] && kill -0 "$CRASHY" 2>/dev/null; then
    kill -9 "$CRASHY" 2>/dev/null || true
    wait "$CRASHY" 2>/dev/null || true
    # It only counts if the lock outlived it — SIGKILL runs no EXIT trap.
    [ -d "$SESSIONS/.pleach.lock" ] && { CAUGHT=1; break; }
  else
    wait "$CRASHY" 2>/dev/null || true
  fi
done

assert_eq "killed run: caught a run holding the lock, within 3 attempts" "$CAUGHT" "1"
assert_true "killed run: the lock outlived the process (SIGKILL runs no EXIT trap)" \
  [ -d "$SESSIONS/.pleach.lock" ]

run "$PLEACH" doctor
assert_rc "killed run: doctor exits non-zero" "$RC" 1
assert_contains "killed run: doctor names the dead owner" "$OUT" "no longer running"

run "$PLEACH" doctor --fix
assert_true "killed run: --fix released the lock" [ ! -d "$SESSIONS/.pleach.lock" ]

# The point of a repair is that the workspace works again afterwards.
run "$PLEACH" new after-crash --no-bootstrap
assert_rc "killed run: a session can be created after the repair" "$RC" 0
assert_true "killed run: that session really exists" [ -d "$SESSIONS/after-crash" ]
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
