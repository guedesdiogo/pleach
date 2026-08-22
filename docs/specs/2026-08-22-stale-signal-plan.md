# Stale signal (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a session a way to ask, and a moment to be told, how far behind the local canonical each of its repos has drifted — per repo, without ever forcing a sync.

**Architecture:** One new read-only command, `pleach status`, built on a single measuring
helper (`session_behind`) shared by the text, JSON and `pleach open` paths. No stored state
of any kind: the verdict is computed fresh every time, because a cached "you are behind"
lies the moment the session merges by hand. `pleach open` calls the same helper immediately
before it `exec`s, and prints nothing when everything is in date.

**Tech Stack:** bash (single-file `pleach`, 3284 lines), git plumbing (`rev-list --count`,
`rev-parse --verify`), the project's own sandboxed test harness in `tests/run.sh`.

**Spec:** `docs/specs/2026-08-22-stale-signal-design.md`. Read it before Task 1.

## Global Constraints

- The script runs under `set -euo pipefail`. Never end a function, an `if` body or a loop
  body with `cmd_a && cmd_b || cmd_c`; use `if`/`fi`. A bare `[ test ] && cmd` is safe only
  because a short-circuited AND-list is exempt — prefer `if`/`fi` in all new code anyway.
- Measure against the **local** `$BASE` only. Never invoke `git fetch`, and never read
  `origin/*`. `pleach sync --fetch` is the only thing in this tool that reaches for origin.
- Measure against the worktree's **real HEAD**, never `refs/heads/session/<name>`.
- A worktree that cannot be measured is **omitted**, never reported as `0`.
- Silence is the normal state: nothing is printed when everything is in date, except the
  single `(up to date with the local <base>)` line that `pleach status` prints on its own.
- `pleach status` exits **0** by default even when behind. Only `--exit-code` returns 1.
- The report never recommends syncing. No output may contain the string `pleach sync`.
- A new dispatcher case label must be indented with exactly **two spaces** — `tests/run.sh`
  Test 33 extracts real commands with `grep -oE '^  [a-zA-Z|-]+\)'`, and a differently
  indented label is invisible to it.
- Exact base name in all user-facing strings: use `$BASE`, never a hardcoded `main`.
- Every test in `tests/run.sh` runs under `PLEACH_EXPECT_CANONICAL` pinned to the sandbox.
  Never point a test at a real workspace.
- Run the full suite with `npm test` (`tests/run.sh && tests/no-leaks.sh`) before each commit.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `pleach` | the whole tool | add `session_behind()`, `status_report()`, `status_json()`, `cmd_status()`; wire the dispatcher, `usage()`, `help_topic()`; one call site in `cmd_open()`; one line in `skill_doc()` |
| `tests/run.sh` | the sandboxed suite | extend Test 18's command list; add Tests 54–58 |
| `README.md` | user documentation | one line in `## Daily use` |

All new shell functions go in one block immediately after the closing `}` of `cmd_sync()`
(currently ends at `pleach:1155`, just before the `# ---` divider that precedes
`conf_subs_line()`). They belong next to `sync` because they answer the question `sync`
acts on.

---

### Task 1: `pleach status` for a single session

**Files:**
- Modify: `pleach` — new block after `cmd_sync()` closes (`pleach:1155`)
- Modify: `pleach` — dispatcher `case "$cmd" in` (`pleach:3260`), its `err` fallback list (`pleach:3282`)
- Modify: `pleach` — `usage()` (`pleach:2762`), `help_topic()` (`pleach:2803`) and its `*)` fallback list (`pleach:3250`)
- Test: `tests/run.sh` — Test 18's command list (`tests/run.sh:446`), new Test 54 appended before the `# Summary` divider (`tests/run.sh:2216`)

**Interfaces:**
- Consumes: `session_subs`, `session_names`, `detect_session_name`, `load_config`, `err`, and the globals `$SESSIONS` and `$BASE` — all already in `pleach`.
- Produces:
  - `session_behind <session>` → stdout, one `"<label>\t<behind>"` line per **measurable** worktree. `<label>` is `root` or the sub-repo directory name. Unmeasurable worktrees produce no line.
  - `status_report <session> <quiet 0|1>` → prints the human report; **returns 1 when anything is behind, 0 when nothing is** (git's `--exit-code` polarity).
  - `cmd_status` → the command entry point.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`, immediately before the `# Summary` divider:

```bash
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
git -C "$S11/web" checkout -q -b feature/live
git -C "$S11/web" merge -q --no-edit main
run bash -c "$PIN11 '$PLEACH' status work"
assert_not_contains "status: measures the branch the worktree is ON, not session/work" \
  "$OUT" "web:"
assert_contains "status: and what really is behind is still reported" \
  "$OUT" "root: 2 commit(s) behind"
git -C "$S11/web" checkout -q session/work

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
```

Then add `status` to Test 18's command list at `tests/run.sh:446`. The line currently reads:

```bash
for c in init new open ls path cd add sync rm prune clean each conflicts repos doctor shell-init completions install update version; do
```

Replace it with:

```bash
for c in init new open ls path cd add sync status rm prune clean each conflicts repos doctor shell-init completions install update version; do
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test 2>&1 | tail -40`
Expected: FAIL. Test 18 reports `help status: missing or errored (rc=1)`, and Test 54's
first `run` reports `unknown command: status`.

- [ ] **Step 3: Write the implementation**

Insert this block in `pleach` immediately after the closing `}` of `cmd_sync()`:

```bash
# ---------------------------------------------------------------------------
# Staleness — how far a session has drifted from the LOCAL canonical
# ---------------------------------------------------------------------------
session_behind() { # $1 name — echoes "<label>\t<behind>" per measurable worktree
  # Measured against the worktree's REAL HEAD, never refs/heads/session/<name>. A
  # worktree sitting on a PR branch or a detached bisect is ordinary — 3 of 10 root
  # worktrees and 20 of 81 sub-worktrees on a live workspace were somewhere else —
  # and asking the named branch answers about work nobody is doing. Same reason
  # session_head_ref exists.
  #
  # A worktree that cannot be measured is OMITTED, never reported as 0. "Nothing to
  # see" and "we could not look" are different answers, and only the second one is
  # doctor's business.
  local dir="$SESSIONS/$1" s wt behind
  local -a present=()
  while IFS= read -r s; do [ -n "$s" ] && present+=("$s"); done < <(session_subs "$dir")
  for s in "" ${present[@]+"${present[@]}"}; do
    wt="$dir${s:+/$s}"
    [ -e "$wt/.git" ] || continue
    # $BASE is not universal: a repo still on master has no 'main' to be behind of,
    # and add_wt already cuts such a session from that repo's own branch.
    git -C "$wt" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 || continue
    behind=$(git -C "$wt" rev-list --count "HEAD..$BASE" 2>/dev/null) || continue
    printf '%s\t%s\n' "${s:-root}" "${behind:-0}"
  done
}

status_report() { # $1 name, $2 quiet(0|1) — rc 1 when something is behind, 0 when nothing is
  # The polarity is git's, not an accident: `git diff --exit-code` returns 1 for
  # "there is a difference". --exit-code hands this straight back to the caller.
  local name="$1" quiet="${2:-0}" label behind titled=0 rc=0
  while IFS=$'\t' read -r label behind; do
    [ -n "$label" ] || continue
    [ "${behind:-0}" -gt 0 ] || continue
    rc=1
    if [ "$quiet" -eq 0 ]; then
      if [ "$titled" -eq 0 ]; then
        echo "● $name  (behind the local $BASE)"
        titled=1
      fi
      printf '    %s: %s commit(s) behind\n' "$label" "$behind"
    fi
  done < <(session_behind "$name")
  return "$rc"
}

cmd_status() {
  local name="" quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--quiet) quiet=1 ;;
      -*)         err "unknown flag: $1 (usage: pleach status [<session>] [-q])" ;;
      *)          [ -z "$name" ] && name="$1" || err "too many arguments" ;;
    esac
    shift
  done
  load_config

  local -a targets=()
  if [ -z "$name" ]; then
    name=$(detect_session_name 2>/dev/null) \
      || err "usage: pleach status <session> [-q]"
  fi
  [ -d "$SESSIONS/$name" ] || err "session '$name' does not exist at $SESSIONS/$name"
  targets=("$name")

  local behind_rc=0 n
  for n in ${targets[@]+"${targets[@]}"}; do
    status_report "$n" "$quiet" || behind_rc=1
  done
  if [ "$behind_rc" -eq 0 ] && [ "$quiet" -eq 0 ]; then
    echo "(up to date with the local $BASE)"
  fi
  return 0
}
```

Wire the dispatcher. In the `case "$cmd" in` block, add this line directly after the
`sync)` line, with **exactly two leading spaces**:

```bash
  status)  cmd_status "$@" ;;
```

In the same block's `*)` arm, the message currently reads
`unknown command: $cmd (init|new|open|add|sync|repos|...)`. Insert `status|` after `sync|`
so it reads `...|sync|status|repos|...`.

In `usage()`, add this line directly after the `sync` line in the `Sessions` group:

```
  status [<session>]        How far behind the canonical's local main each of the session's repos is.
```

In `help_topic()`, add a `status)` arm directly after the `sync)` arm:

```bash
    status) cat <<'EOF'
pleach status [<session>] [-q]

How far behind the canonical's LOCAL base each of the session's repos has drifted.
Per repo, because a session touching only the api does not care that the docs moved.

  <session>    Defaults to the session containing the current directory. Outside a
               session the name is required.
  -q, --quiet  Print nothing.

Only the repos that are behind are listed; when none are, it says so in one line and
nothing else. It measures the branch each worktree is really ON, not the branch the
session was named after.

It exits 0 whether or not anything is behind. It is a report: it tells you the number
and the place, and leaves the decision to sync — or not to — with you.

Never reaches for origin. The target is the base ref in your canonical checkout, which
moves when you pull there and at no other time.
EOF
    ;;
```

In the `*)` arm of `help_topic()`, the message lists the commands. Insert ` status` after
` sync` so it reads `... add sync status rm prune ...`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test 2>&1 | tail -20`
Expected: PASS, `Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add pleach tests/run.sh
git commit -m "feat: pleach status says how far behind the local canonical each repo is"
```

---

### Task 2: `--all`

**Files:**
- Modify: `pleach` — `cmd_status()` flag loop and target resolution
- Test: `tests/run.sh` — new Test 55

**Interfaces:**
- Consumes: `session_names` (already in `pleach`), `status_report` from Task 1.
- Produces: no new functions. `cmd_status` now accepts `--all`, which is mutually exclusive with a session name and is accepted from inside a session too.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`, immediately before the `# Summary` divider. It reuses `MINI11`,
`PIN11` and `S11` from Test 54.

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test 2>&1 | tail -40`
Expected: FAIL with `unknown flag: --all`.

- [ ] **Step 3: Write the implementation**

In `cmd_status`, add an `--all` arm to the flag loop, directly above the `-q|--quiet` arm:

```bash
      --all)      all=1 ;;
```

and change the `local` declaration on the first line of the function from:

```bash
  local name="" quiet=0
```

to:

```bash
  local name="" quiet=0 all=0
```

Then replace the whole target-resolution block — from `local -a targets=()` down to and
including `targets=("$name")` — with:

```bash
  local -a targets=()
  local n
  if [ "$all" -eq 1 ]; then
    [ -z "$name" ] || err "--all does not take a session name"
    while IFS= read -r n; do [ -n "$n" ] && targets+=("$n"); done < <(session_names)
    if [ ${#targets[@]} -eq 0 ]; then
      if [ "$quiet" -eq 0 ]; then echo "(no sessions in $SESSIONS)"; fi
      return 0
    fi
  else
    if [ -z "$name" ]; then
      name=$(detect_session_name 2>/dev/null) \
        || err "usage: pleach status <session> [-q]  (or --all)"
    fi
    [ -d "$SESSIONS/$name" ] || err "session '$name' does not exist at $SESSIONS/$name"
    targets=("$name")
  fi
```

`n` is now declared here, so delete it from the `local behind_rc=0 n` line further down,
leaving `local behind_rc=0`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test 2>&1 | tail -20`
Expected: PASS, `Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add pleach tests/run.sh
git commit -m "feat: pleach status --all sweeps every session"
```

---

### Task 3: `--exit-code`

**Files:**
- Modify: `pleach` — `cmd_status()` flag loop and its final return
- Test: `tests/run.sh` — new Test 56

**Interfaces:**
- Consumes: `status_report`'s return value from Task 1.
- Produces: `pleach status --exit-code` returns 1 when any measured repo in any target session is behind, 0 otherwise. Without the flag the command still returns 0.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`, before the `# Summary` divider. Reuses `MINI11` and `PIN11`.

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test 2>&1 | tail -40`
Expected: FAIL with `unknown flag: --exit-code`.

- [ ] **Step 3: Write the implementation**

In `cmd_status`, add an arm to the flag loop directly above the `-q|--quiet` arm:

```bash
      --exit-code) exit_code=1 ;;
```

Change the first line of the function from:

```bash
  local name="" quiet=0 all=0
```

to:

```bash
  local name="" quiet=0 all=0 exit_code=0
```

Update the usage strings in the same function so the flag is discoverable. The `-*)` arm
becomes:

```bash
      -*)         err "unknown flag: $1 (usage: pleach status [<session>|--all] [--exit-code] [-q])" ;;
```

and the `detect_session_name` fallback becomes:

```bash
      name=$(detect_session_name 2>/dev/null) \
        || err "usage: pleach status <session> [--exit-code] [-q]  (or --all)"
```

Finally, replace the function's tail — the `if [ "$behind_rc" -eq 0 ] …` block and the
`return 0` after it — so it reads:

```bash
  if [ "$behind_rc" -eq 0 ] && [ "$quiet" -eq 0 ]; then
    echo "(up to date with the local $BASE)"
  fi
  if [ "$exit_code" -eq 1 ]; then return "$behind_rc"; fi
  return 0
}
```

In `help_topic()`'s `status)` arm, add the flag to the option list, directly after the
`-q, --quiet` line:

```
  --exit-code  Return 1 when something is behind (as `git diff --exit-code`).
```

and change the sentence `It exits 0 whether or not anything is behind.` to:

```
It exits 0 whether or not anything is behind, unless you ask for --exit-code.
```

Add the flag to `usage()`'s `status` line so it reads:

```
  status [<session>|--all]  How far behind the canonical's local main each of the session's repos is.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test 2>&1 | tail -20`
Expected: PASS, `Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add pleach tests/run.sh
git commit -m "feat: pleach status --exit-code, opt-in as git's own"
```

---

### Task 4: `--json`

**Files:**
- Modify: `pleach` — new `status_json()` beside `status_report()`; `cmd_status()` flag loop and output branch
- Test: `tests/run.sh` — new Test 57

**Interfaces:**
- Consumes: `session_behind` (Task 1), `session_head_ref`, `short_ref`, `json_escape` — the last three already in `pleach`.
- Produces: `status_json <session>...` → prints the JSON document; **returns 1 when anything is behind**, matching `status_report`'s polarity so `--exit-code` works identically in both formats.

The document shape, fixed by the spec:

```json
{
  "base": "main",
  "sessions": [
    {"name": "fix-login", "behind": 15, "repos": [
      {"repo": "root", "branch": "session/fix-login", "behind": 3},
      {"repo": "api",  "branch": "feat/tokens",       "behind": 12},
      {"repo": "web",  "branch": "session/fix-login", "behind": 0}
    ]}
  ]
}
```

Every **measured** repo appears, behind or not — a consumer filtering the list has to tell
"measured and clean" from "not measured". Unmeasurable repos are omitted, exactly as in the
text output. `"behind"` on the session is the sum, so a caller can gate on one number.
`"branch"` is the worktree's real HEAD, shortened to 8 characters when detached.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`, before the `# Summary` divider. It builds its own workspace so the
counts do not depend on any earlier test.

```bash
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
git -C "$S13/web" checkout -q -b feature/live
run bash -c "$PIN13 '$PLEACH' status j --json"
assert_contains "status --json: carries the branch the worktree is ON" "$OUT" '"branch": "feature/live"'
git -C "$S13/web" checkout -q session/j

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test 2>&1 | tail -40`
Expected: FAIL with `unknown flag: --json`.

- [ ] **Step 3: Write the implementation**

Insert `status_json()` in `pleach` directly after the closing `}` of `status_report()`:

```bash
status_json() { # $@ = session names — rc 1 when something is behind, as status_report
  local first=1 n label behind total repos sub branch any=0
  printf '{\n'
  printf '  "base": "%s",\n' "$(json_escape "$BASE")"
  printf '  "sessions": [\n'
  for n in "$@"; do
    repos=""
    total=0
    while IFS=$'\t' read -r label behind; do
      [ -n "$label" ] || continue
      total=$((total + behind))
      # Every MEASURED repo appears, behind or not: a consumer filtering the list has
      # to tell "measured and clean" from "not measured". session_behind has already
      # dropped the ones that could not be measured.
      sub=""
      [ "$label" = "root" ] || sub="$label"
      branch=$(short_ref "$(session_head_ref "$n" "$sub")")
      repos="$repos${repos:+, }"
      repos="$repos{\"repo\": \"$(json_escape "$label")\", \"branch\": \"$(json_escape "$branch")\", \"behind\": $behind}"
    done < <(session_behind "$n")
    [ "$total" -gt 0 ] && any=1
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    {"name": "%s", "behind": %s, "repos": [%s]}' \
      "$(json_escape "$n")" "$total" "$repos"
  done
  printf '\n  ]\n}\n'
  return "$any"
}
```

A sub-repo directory literally named `root` would be indistinguishable from the root
worktree here. `ls_long` already lives with the same ambiguity via `${s:-root}`; matching it
is better than inventing a second convention.

In `cmd_status`, add an arm to the flag loop directly above the `-q|--quiet` arm:

```bash
      --json)     as_json=1 ;;
```

Change the first line of the function to:

```bash
  local name="" quiet=0 all=0 exit_code=0 as_json=0
```

and the `-*)` arm to:

```bash
      -*)         err "unknown flag: $1 (usage: pleach status [<session>|--all] [--json] [--exit-code] [-q])" ;;
```

Then replace the output block — from `local behind_rc=0` down to the `fi` that closes the
`(up to date …)` branch — with:

```bash
  local behind_rc=0
  if [ "$as_json" -eq 1 ]; then
    status_json ${targets[@]+"${targets[@]}"} || behind_rc=1
  else
    for n in ${targets[@]+"${targets[@]}"}; do
      status_report "$n" "$quiet" || behind_rc=1
    done
    if [ "$behind_rc" -eq 0 ] && [ "$quiet" -eq 0 ]; then
      echo "(up to date with the local $BASE)"
    fi
  fi
```

The `if [ "$exit_code" -eq 1 ]; then return "$behind_rc"; fi` and `return 0` lines from
Task 3 stay exactly as they are, below this block.

In `help_topic()`'s `status)` arm, add to the option list after the `--exit-code` line:

```
  --json       The machine surface: every measured repo, behind or not.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test 2>&1 | tail -20`
Expected: PASS, `Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add pleach tests/run.sh
git commit -m "feat: pleach status --json, the machine surface for the staleness signal"
```

---

### Task 5: the aviso arrives on the way in

**Files:**
- Modify: `pleach` — `cmd_open()` (`pleach:880`), immediately before `info "opening in $dir: $*"`
- Modify: `pleach` — `help_topic()`'s `open)` arm, and the `config` topic's env-var list
- Test: `tests/run.sh` — new Test 58

**Interfaces:**
- Consumes: `status_report` from Task 1.
- Produces: no new functions. `pleach open` prints the behind-report before it `exec`s, and `PLEACH_NO_STATUS=1` suppresses it.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`, before the `# Summary` divider. Reuses `MINI11` and `PIN11`, where
`work` is behind and `fresh` is not.

```bash
# ---------------------------------------------------------------------------
header "Test 58: open carries the aviso, and says nothing when there is none"
# ---------------------------------------------------------------------------
# Entering the session is the one moment the signal reaches the person deciding
# without anyone having to remember to ask.
run bash -c "$PIN11 '$PLEACH' open work pwd"
assert_rc "open: rc 0" "$RC" 0
assert_contains "open: the aviso arrives on the way in" "$OUT" "commit(s) behind"
assert_contains "open: and the command still runs in the session" "$OUT" "$S11/work"
assert_not_contains "open: it reports, it does not instruct" "$OUT" "pleach sync"

# Silence is the normal state.
run bash -c "$PIN11 '$PLEACH' open fresh pwd"
assert_rc "open (in date): rc 0" "$RC" 0
assert_not_contains "open: nothing printed when every repo is in date" "$OUT" "commit(s) behind"
assert_not_contains "open: and it does not announce being in date either" "$OUT" "up to date"

# The suppressor is an env var, not a flag: everything after the session name is
# the launched command's own argv.
run bash -c "$PIN11 PLEACH_NO_STATUS=1 '$PLEACH' open work pwd"
assert_rc "open PLEACH_NO_STATUS=1: rc 0" "$RC" 0
assert_not_contains "open: PLEACH_NO_STATUS silences the aviso" "$OUT" "commit(s) behind"
assert_contains "open: and the command still runs" "$OUT" "$S11/work"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test 2>&1 | tail -40`
Expected: FAIL on `open: the aviso arrives on the way in` — the output has no
`commit(s) behind` in it.

- [ ] **Step 3: Write the implementation**

In `cmd_open`, insert this immediately before the line `info "opening in $dir: $*"`:

```bash
  # The one moment the aviso reaches the person deciding without anyone remembering
  # to ask. Silence is the normal state: nothing is printed when every repo is in
  # date, and nothing is ever recommended — being behind is not being about to
  # conflict.
  #
  # The suppressor is an env var and not a flag on purpose: everything past the
  # session name is the launched command's own argv, and eating a lookalike out of it
  # would change what the caller asked to run (see --create at the top of this
  # function).
  if [ -z "${PLEACH_NO_STATUS:-}" ]; then
    status_report "$name" 0 || true
  fi
```

In `help_topic()`'s `open)` arm, add at the end of the prose:

```
On the way in it reports any repo of the session that is behind the canonical's local
base, and says nothing when none are. Set PLEACH_NO_STATUS=1 to suppress it.
```

In `help_topic()`'s `config)` arm, in the block headed
`Guard rail for automation/harnesses (env, not conf):`, add:

```
  PLEACH_NO_STATUS=1              Suppresses the behind-the-base report `open` prints
                                  on the way in. A flag would be ambiguous: everything
                                  after the session name is the launched command's argv.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test 2>&1 | tail -20`
Expected: PASS, `Failures: 0`.

- [ ] **Step 5: Commit**

```bash
git add pleach tests/run.sh
git commit -m "feat: open says which repos drifted from the canonical, and nothing when none did"
```

---

### Task 6: tell the agent and the reader

**Files:**
- Modify: `pleach` — `skill_doc()` (`pleach:2497`), the `## The blind spot isolation buys` section
- Modify: `README.md` — `## Daily use` (`README.md:251`)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new. Documentation only — but Test 33 already enforces that every
  `` `pleach <command>` `` named in the skill exists in the dispatcher, so this task is
  covered by the existing suite.

- [ ] **Step 1: Run the existing anti-drift test to see it still passes**

Run: `npm test 2>&1 | grep -E 'skill:|Failures'`
Expected: `skill: every command it names is a real one` passes, `Failures: 0`. This is the
guard that will catch a typo in the next step.

- [ ] **Step 2: Add the skill entry**

In `skill_doc()`, in the `## The blind spot isolation buys` section, add this bullet
immediately after the `pleach conflicts` bullet and before the `pleach each` bullet:

```markdown
- `pleach status` — how far behind the canonical's LOCAL base each repo of a session is,
  measured on the branch the worktree is ON. The canonical moves when someone pulls there,
  and nothing inside a session notices. `pleach open` reports this on the way in; ask
  directly when you have been working a while. It is a report, not an instruction:
  being behind is not being about to conflict, and whether to `sync` is the human's call.
  `--json` and `--exit-code` for scripting; it exits 0 without the latter.
```

- [ ] **Step 3: Add the README line**

In `## Daily use`, inside the fenced block, add this line directly after the
`pleach sync --all --yes` line and before the blank line that precedes `pleach add`:

```
pleach status fix-x                  # which of its repos drifted behind the local main
```

- [ ] **Step 4: Run the tests to verify nothing drifted**

Run: `npm test 2>&1 | tail -20`
Expected: PASS, `Failures: 0`. In particular `skill: every command it names is a real one`
and `skill: frontmatter fits the 1024-character budget` must both still pass — the new
bullet is in the body, not the frontmatter, so the budget is unaffected.

- [ ] **Step 5: Commit**

```bash
git add pleach README.md
git commit -m "docs: teach the skill and the README about pleach status"
```

---

## Done when

- `npm test` passes with `Failures: 0`.
- `pleach status` from inside a session names only the repos that are behind, and one line
  when none are.
- `pleach open` on a drifted session prints the same report before launching, and prints
  nothing on a session that is in date.
- No output anywhere contains the string `pleach sync`.
- No new file is written into any session directory, and `pleach ls -l` still reports an
  untouched session as `fully integrated — removable`.
