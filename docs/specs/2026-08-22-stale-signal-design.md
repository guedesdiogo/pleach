# Stale signal: telling a session the local canonical moved

Status: approved design, not implemented. Phase 1 only.
Date: 2026-08-22. Against pleach 2.2.0.

## The problem

You `git pull` in the canonical. Every session is now some distance behind, per repo,
and nobody working inside one has any way to find out except by thinking to ask. The
ask is not "force a sync" — it is "tell the person in the session, so they can decide
whether now is the moment".

## What already exists

The measurement is not the missing piece. It is already computed three times:

- `ls_long()` (`pleach:1653`) runs `git rev-list --count "HEAD..$BASE"` per worktree and
  prints `↓N behind`, already per repo.
- `sync_session()` (`pleach:1113`) in `--dry-run` prints `would merge +N commits`, per repo.
- Everything is measured against the **local** base. `fetch_base()` only runs under an
  explicit `--fetch`. That is exactly the local canonical this feature is about, so no
  change of philosophy is required.

What is missing is delivery: a clean session-local surface to ask from, and the notice
arriving at the one moment nobody has to remember — entering the session.

## The approach we rejected

A `post-merge` hook in the canonical that writes a `.pleach-stale` marker into every
session. Rejected for three reasons:

1. **It caches a derived value, and the cache lies in the wrong direction.** The session
   merges `main` by hand and the file still says behind; you `git reset --hard` the
   canonical backwards and the file says behind when it is not. This contradicts the
   principle `session_head_ref()` (`pleach:183`) exists to enforce — its comment records
   that trusting the label instead of measuring made a quarter of the answers describe
   abandoned work.
2. **The trigger is holed at birth.** `git pull --rebase` fires `post-rewrite`, not
   `post-merge`. `git reset` fires neither.
3. **Fan-out of writes** into N sessions, some mid-creation (`.pleach-building.$name`),
   some with an unreadable `.session-env` (`session_env_unreadable`, `pleach:475`) —
   putting a write path where only a read is needed.

The rule that follows: **store only the acknowledged event, never the verdict.** The
verdict is cheap and always true when computed; only "what this session already knows"
cannot be recomputed. Phase 1 needs no stored state at all.

## Phase 1

### `pleach status`

Scope mirrors `sync`: `pleach status [<session>]`. No name inside a session resolves to
that session via `detect_session_name`; no name in the canonical is a usage error, and
`--all` sweeps every session. Consistency with `sync` matters more than convenience, and
`ls -l` already serves the human who wants the whole panorama.

Measurement: `git rev-list --count "HEAD..$BASE"` per mounted worktree (root plus subs),
against the worktree's **real HEAD** — never against `refs/heads/session/<name>`.

Output lists only the repos actually behind; a single line when none are.

```
$ pleach status
● fix-login  (behind the local main)
    root: 3 commits behind
    api:  12 commits behind

$ pleach status
(up to date with the local main)
```

Flags:

- `--exit-code` — opt-in, as `git diff --exit-code`: 1 when any repo is behind. **Without it
  the command exits 0 even when behind**, the same contract `conflicts` holds. It is a
  report; a report that fails is a check, and callers would start guarding it with `|| true`.
- `-q` / `--quiet` — no output at all, in every path and with no exception for `--json`.
  Exists to pair with `--exit-code`, so a hook can ask the question without printing
  anything. It never changes the exit status: the measurement still runs, only the output
  is dropped.
- `--json` — the machine surface. Every mounted repo appears, behind or not, because a
  consumer filtering the list needs to know a repo was measured and found clean rather
  than skipped. Repos that could not be measured are omitted, exactly as in the text output.
  A workspace with no sessions still answers in JSON — `{"base": …, "sessions": []}`, never
  the prose line the text path prints. A machine surface that degrades to English in one
  shape is not a machine surface.
- `--all` — every session; takes no session name, and is accepted from inside a session too.
  Same shape as `sync --all`.

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

`"behind"` on the session is the sum, so a caller can gate on one number. `"branch"` is the
worktree's real HEAD — the short commit id when detached, as `short_ref()` already renders it.

Omitted in silence, never an error: a worktree with no `.git`, a repo where `$BASE` does
not resolve (legacy repos still on `master`, which `add_wt` already accommodates), an
unreadable `.session-env`. Those are `doctor`'s subject.

It reports the number and the place. It does not recommend syncing — being behind is not
the same as being about to conflict, and the `conflicts` caveat applies unchanged.

### `pleach open`

Calls the same internal function immediately before `info "opening in …"` in `cmd_open`
(`pleach:880`), which today makes no git calls at all. Prints nothing when up to date;
silence is the normal state.

The suppressor is an environment variable, `PLEACH_NO_STATUS=1`, **not a flag**. The
comment at `pleach:882` settles this: everything after the session name is the launched
command's own argv, and consuming a lookalike out of it changes what the caller asked to
run.

Cost: 1+N git calls at an interactive entry point, well under 100ms for ~9 repos.

### `skill_doc()`

One line in the emitted skill (`pleach:2497`) so an agent learns the command exists. That
delivers the agent half of Phase 1 with no watermark and no hook. A hook is only required
for the notice to arrive *unprompted*.

## Out of scope, deliberately

- Suggesting or performing a sync.
- Relevance — whether the new commits touch files this session touched. More useful than a
  raw count, and a separate feature.
- Reaching for `origin`. The local canonical is the whole point.
- The acknowledgement watermark (see Phase 2).

## Tests

`tests/run.sh`, in its existing sandbox harness:

- behind in the root only — reports root, not the subs
- behind in one sub only — per-repo granularity is the requirement, so it gets its own test
- up to date — one line, no per-repo noise
- worktree checked out on another branch — measured against the real HEAD, not
  `session/<name>`
- a repo where `$BASE` does not resolve — skipped, no error
- `--exit-code` returns 1 when behind and 0 when clean
- the default exit is 0 even when behind
- `pleach open` prints nothing when up to date
- `PLEACH_NO_STATUS=1` silences it

## Docs

`usage()`, a `status` block in `help_topic()`, a README section documenting the command, and
the `skill_doc()` line. Linking *this spec* from the README is not part of the work — the
README documents shipped behaviour, and `docs/comparison.md` and `docs/design-notes.md` are
linked there on that basis.

## Deferred

**Phase 2 — the watermark.** A per-repo record of the base sha this session was last told
about, living beside the session in `$SESSIONS/` (the pattern `.pleach-building.$name`
already establishes), never inside the root worktree — a new dot-file there would have to
be added to the skip list in `worktree_dirt()` (`pleach:1271`) or `ls -l` would stop saying
"fully integrated — removable" and `rm` would start refusing. It buys a cheap gate:
`git rev-parse $BASE` per canonical repo, compared against the watermark; equal means
silence at almost no cost, and only a difference pays for the `rev-list`. That is what
makes a per-prompt agent hook viable, alongside `--since-ack` / `--ack` on `status` and an
`examples/pleach-stale-notice.sh` in the mould of the existing `pleach-guard.sh`.

Trigger to build it: Phase 1 proving noisy, or wanting the notice unprompted every turn.

**Phase 3 — relevance.** Cross the paths in the new commits with the paths this session has
touched, so "12 behind" becomes "12 behind, 2 of them in files you changed".
