# pleach

> **pleach** *(verb)* — to interweave the living branches of separate trees so they grow
> into a single structure.

**Parallel, isolated work sessions for multi-repo workspaces.** One bash script, no
dependencies beyond git. Run several coding agents or editors on the same project at the
same time without them overwriting each other, without directory replicas, and at
essentially zero disk cost.

[![ci](https://github.com/guedesdiogo/pleach/actions/workflows/ci.yml/badge.svg)](https://github.com/guedesdiogo/pleach/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/pleach?color=cb3837&logo=npm)](https://www.npmjs.com/package/pleach)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)
![runtime deps](https://img.shields.io/badge/runtime%20deps-git%20%2B%20bash-lightgrey)

```bash
pleach open fix-login              # create an isolated session and start working in it
pleach open feat-search codex      # a second session, a different agent, at the same time
pleach ls                          # what exists, which ports, how many repos
pleach sync fix-login              # bring the session up to date with main
pleach rm fix-login                # safe cleanup after the merge
```

---

## The problem

Point two coding agents at the same checkout and they will quietly destroy each other's
work. Not dramatically — silently:

- **Files overwrite.** Two processes edit the same working tree and the last write wins.
  Nobody sees a conflict, because there was never a merge.
- **Build state bleeds.** `node_modules`, caches, build output and dev servers from one
  task contaminate the next.
- **Ports collide.** Two dev servers fight over 3000, 5173, 8787.

The obvious fix — copy the whole directory N times — works and costs a fortune: every
replica duplicates dependencies and build output (easily gigabytes each), multiplies RAM
(watchers, language servers, OS indexing), and replaces one problem with a worse one: N
independent clones you now have to keep in sync by hand.

## The insight

`git worktree` already solves this properly for one repo. Worktrees share the object
store, so disk cost is roughly the checkout alone — and git **guarantees that a branch is
checked out in at most one worktree at a time**. That is the important part: the isolation
is *structural*, not disciplinary. It cannot be forgotten, and it does not depend on anyone
being careful.

But plenty of real workspaces are **composite**: a root repo carrying docs, config and
tooling, with several nested git repos inside it that the root ignores. There, plain
`git worktree` falls short — a worktree of the root arrives without any of the sub-repos.
Assembling one usable session by hand means a worktree *per repo* on the matching branch,
plus the untracked `.env` files no worktree carries, plus ports that do not collide, plus a
dependency bootstrap.

That orchestration is pleach. Conflicts do not disappear — they **move to where they
belong**: two sessions touching the same file now conflict at merge time, with a diff and a
deliberate resolution, instead of overwriting each other in a working tree.

## What a session is

```
<parent-of-canonical>/.sessions/<name>/
├── (worktree of the root repo, branch session/<name>)
├── .session-env             # identity + an exclusive block of 100 ports
├── api/                     # worktree of sub-repo api,  branch session/<name>
├── web/                     # worktree of sub-repo web,  branch session/<name>
└── .env, api/.env.local, …  # untracked secrets, copied from the canonical
```

- Every worktree shares the object store of the **canonical** checkout — the one permanent
  copy of the workspace.
- Every repo in the session sits on the same branch, `session/<name>`.
- Integration is whatever your project already does: commit in the session, push, open a
  PR, merge, then `pleach rm`.
- A session is an ordinary directory. Any editor or agent can work in it without knowing
  pleach exists.

## It is actually isolated

Not a claim — the transcript below is real output:

```console
$ pleach new fix-login --no-bootstrap
→ creating session 'fix-login' (index 1, ports 10100-10199) at ~/code/.sessions/fix-login
→ copying secrets (.env*, .dev.vars*, extras from the conf)…
→ 1 env file(s) copied

✅ Session 'fix-login' ready:
   cd ~/code/.sessions/fix-login
   branch session/fix-login in: root api infra web
   ports: source .session-env  (PORT=10100)

# an agent working in fix-login commits into the api repo:

$ ls .sessions/feat-search/api/auth.js      # the other session
ls: auth.js: No such file or directory
$ ls acme-platform/api/auth.js              # the canonical
ls: auth.js: No such file or directory

$ git -C acme-platform/api worktree add /tmp/x session/fix-login
fatal: 'session/fix-login' is already used by worktree at '~/code/.sessions/fix-login/api'

$ pleach ls -l
● feat-search  (index 2, ports 10200+)  ~/code/.sessions/feat-search/
    root: session/feat-search
    api: session/feat-search
    infra: session/feat-search
    web: session/feat-search
    ✓ fully integrated — removable (pleach prune) · last activity: 2026-08-12
● fix-login  (index 1, ports 10100+)  ~/code/.sessions/fix-login/
    root: session/fix-login
    api: session/fix-login +1 commits
    infra: session/fix-login
    web: session/fix-login
```

That `fatal:` is git refusing to hand the same branch to a second worktree. pleach did not
implement the isolation — it arranged for git to enforce it.

## Why the usual answers don't cover this

| Approach | What it gets right | Where it stops |
|---|---|---|
| **Full directory replicas** | Simple, obvious | Duplicates deps and builds (GBs each), multiplies RAM, and leaves you syncing N clones by hand |
| **Copy-on-write clones** (`cp -c` on APFS) | Kills the *initial* disk cost | Still N independent clones with the same manual syncing; they diverge as builds rematerialize blocks; no structural isolation — two clones can work the same branch and collide on push. macOS only |
| **Plain `git worktree`** | The right primitive, and what pleach uses underneath | Covers one repo. In a composite workspace the root's worktree arrives with no sub-repos, no secrets, colliding ports and no bootstrap |
| **An agent's built-in worktrees** | Zero setup for that one tool | Isolates a single repo and serves only that tool. Does not assemble the composite, copy secrets or resolve ports — and does nothing for the editor open beside it |
| **"Just be disciplined with branches"** | No tooling required | One working tree holds one branch. Two sessions in one folder would swap each other's checkout on every `git switch`, and still share `node_modules`, builds and dev servers. There is no real concurrency to be disciplined about |
| **A container per session** | Strong isolation, ports included | Each session costs a VM's worth of RAM on macOS, starts slowly, and adds credential and tooling friction — the opposite of many cheap sessions on one machine |

None of these are wrong; they solve neighbouring problems. What none of them compose is
**worktrees per repo + secrets + ports + bootstrap + lifecycle**, behind one command.

## Install

```bash
npm install -g pleach          # or: bun add -g pleach
```

Or without a package manager:

```bash
curl -fsSL https://raw.githubusercontent.com/guedesdiogo/pleach/main/install.sh | bash
pleach update                  # self-updates from main; push is release
```

`pleach update` detects npm/bun-managed installs and redirects to the package manager, so
the two paths never fight.

Requirements: git >= 2.15 (worktrees) and bash >= 3.2 (the bash macOS ships).

## Adopt it in your project

From the root of your workspace's canonical checkout:

```bash
pleach init                    # detects first-level sub-repos, writes .pleach.conf
pleach init --default          # and records this project as the machine default
pleach open first-session
```

**Single-repo projects work too** — without sub-repos, pleach is a worktree manager with
ports and secrets solved, which already removes the collisions between parallel agents.

### `.pleach.conf`

A bash file, sourced, at the canonical's root. Everything optional:

| Variable | Default | Purpose |
|---|---|---|
| `PLEACH_CANONICAL` | the conf's directory | Point at the real canonical when this checkout is a replica |
| `PLEACH_SUBS=(a b)` | auto-detected | Sub-repos to mount per session (first-level dirs with `.git`) |
| `PLEACH_BASE` | `main` | Base branch for sessions |
| `PLEACH_DIR` | `<parent>/.sessions` | Where sessions live |
| `PLEACH_PORT_START` | `10000` | Start of the port blocks (session N gets `START + N*100`) |
| `PLEACH_SECRETS_EXTRA=(…)` | `(.claude/settings.local.json)` | Extra relative paths to copy into each session |
| `pleach_bootstrap() {…}` | `bun install` where a `package.json` is | Post-creation hook: `npm ci`, `go mod download`, `make setup`, whatever the project needs |

The canonical is resolved in order: the `PLEACH_CANONICAL` env var, then `.pleach.conf`
walking up from the cwd, then `.session-env` walking up (you are inside a session), then
`~/.config/pleach/config`. With a machine default recorded, `pleach ls`/`new` work from
anywhere.

## Daily use

```bash
pleach open fix-x                    # create if needed + open your tool inside
pleach open fix-x claude -r          # resume that session's previous conversation
pleach open fix-x code               # VS Code on the session's multi-root workspace

pleach new fix-x api web             # a focused session: only these sub-repos
pleach new fix-x --fetch             # update the base from origin first

pleach ls                            # instant: name, index, ports, repo count
pleach ls -l                         # branch, commits ahead, changes, integration status

pleach sync fix-x                    # merge the local main into every repo of the session
pleach sync fix-x --dry-run          # show what would happen, touch nothing
pleach sync --all --yes              # every session (explicit --yes outside a TTY)

pleach add fix-x payments            # mount a new sub-repo into an existing session
pleach repos --sync                  # adopt a new workspace repo across ALL sessions

pleach each 'git log --oneline -1'   # run a command in the canonical + every session
pleach clean fix-x --apply           # delete git-ignored artifacts (node_modules, builds)
pleach prune --apply                 # remove every fully integrated session

pleach help sync                     # detailed help per command (and `help config`)
```

### Ports

Each session gets an exclusive block of 100 ports written to `.session-env` (`PORT`,
`PLEACH_PORT_BASE`, and derivatives). `pleach open` exports them before launching, so dev
servers that honour `PORT` never collide without any manual step. For the rest,
`source .session-env` and pass the flag.

### VS Code

A window opened on the canonical **will not show what the sessions are editing** — and that
is not a bug: Source Control only covers repos inside the open workspace, and each session
is a separate working tree elsewhere. So every session gets a multi-root workspace file
beside its folder (`.sessions/<name>.code-workspace`, outside the worktrees, so it never
dirties `git status`):

```bash
pleach open fix-x code                     # opens that workspace
code .sessions/panorama.code-workspace     # one window listing every session's repos
```

## Design notes

The parts worth arguing about, and why they landed where they did.

**Isolation is structural, not disciplinary.** pleach does not police concurrent access; it
arranges the tree so git refuses it. A rule the tool cannot forget beats a rule the user
must remember.

**Anything destructive is a dry run by default.** `prune` and `clean` list and total up what
they *would* remove; deletion requires `--apply`. You opt into destruction, never out of it.

**`clean` only removes what git ignores.** A tracked `dist/` is reported and preserved. The
question "is this disposable?" already has an authoritative answer in the repo — asking
`.gitignore` beats hardcoding a guess.

**A skipped repo never blocks the others.** In a multi-repo tool, partial success is the
normal outcome, not an error state. `sync` reports precisely what it skipped and why, and
carries on.

**There is never an automatic stash.** A repo with uncommitted changes is skipped, loudly. A
tool that quietly moves your work somewhere clever is a tool you stop trusting.

**`sync` integrates the *local* base, not `origin`.** The canonical is where you run
`git pull`; sync only propagates a decision you already made. `--fetch` will try to advance
the local base first, and tells you when it can't rather than guessing.

**Only the session's own branch is touched.** If you switched a worktree to `feat/x`, sync
leaves it alone unless you pass `--any-branch`. An unrequested merge into a feature branch
is expensive — it shows up in the PR.

**Destructive operations cannot destroy the only copy.** `rm --force` removes worktrees, but
any branch holding unintegrated commits is *always* preserved, with the exact command to
delete it printed. Branches are cheap; work is not.

**Non-interactive callers must be explicit.** `sync --all` prompts on a TTY and hard-errors
without `--yes` when stdin is not one. A script or an autonomous agent should never sail
through a confirmation prompt just because nobody was there to answer it.

**`PLEACH_EXPECT_CANONICAL` lets a caller declare what it expects.** If the resolved
canonical differs, pleach aborts before writing anything. This exists because of a real
incident: an unpinned test harness resolved to a live workspace and ran `sync --all`
against it. The fix was not "be more careful" — it was a guard rail that makes the mistake
impossible to repeat.

**The lock is a `mkdir`.** Atomic on every filesystem that matters, and unlike `flock` it is
present on a stock macOS.

## Numbers from a real workspace

A composite workspace of 1 root repo + 7 nested sub-repos, spanning ~20 bun/Next.js/Go
sub-projects. The previous model was **6 full directory replicas: ~21.6 GB** — while the git
data across every repo totalled ~165 MB. The rest was duplicated `node_modules` and build
output.

After moving to pleach:

- two complete sessions created **in parallel in 60 seconds**;
- disk cost per session: **~0 in practice** (APFS clonefile plus a global package-manager
  cache with hardlinks — bun and pnpm both qualify);
- isolation verified: a commit in one session invisible to the others and to the canonical;
- 6 sessions now cost about what 1 replica used to.

## Guard hooks for coding agents

Two optional hooks live in [`examples/`](examples/), both path-agnostic — they find the
session and the canonical by their markers rather than by hardcoded directories:

- [`pleach-guard.sh`](examples/pleach-guard.sh) — a `SessionStart` hook that warns when an
  agent is opened in the canonical instead of in a session.
- [`pleach-deploy-guard.sh`](examples/pleach-deploy-guard.sh) — a `PreToolUse` hook that
  blocks shipping commands from inside a session. Two sessions shipping to the same target
  collide in the *environment*, not in the files, and git will not save you there. This is
  what gives that rule teeth instead of leaving it to discipline.

## Tests

```bash
tests/run.sh          # 100 assertions across 19 scenarios, in a throwaway sandbox
tests/no-leaks.sh     # repository hygiene gate
shellcheck pleach install.sh tests/*.sh examples/*.sh
```

`tests/run.sh` builds an ephemeral composite workspace and exercises the real lifecycle:
creation, listing, sync (including the dry run, the dirty-repo skip and the wrong-branch
skip), the non-interactive `--yes` requirement, removal, prune, clean, `each`, `add`,
`repos --sync`, help coverage for every command, and that `open` really runs inside the
session. It pins `PLEACH_EXPECT_CANONICAL` to its own sandbox so it cannot escape.

CI runs the suite on ubuntu and macOS on every push.

## Limitations

- Sub-repo names containing newlines are not supported.
- Sub-repo auto-detection is one level deep; declare anything deeper in `PLEACH_SUBS`.
- The lock is per `PLEACH_DIR` (atomic `mkdir`); on an NFS share between machines there are
  no guarantees.
- `rm` and `prune` judge "integrated" against the **local** base. If the merge only landed
  on the remote, `git fetch` in the repo first — or use `--force`, which preserves the
  branch.

## License

MIT — see [LICENSE](LICENSE).
