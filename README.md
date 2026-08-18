# pleach

> **pleach** *(verb)* — to interweave the living branches of separate trees so they grow
> into a single structure.

**Parallel, isolated work sessions for multi-repo workspaces.** One bash script, no
dependencies beyond git. Run several coding agents or editors on the same project at the
same time without them overwriting each other, without directory replicas, and at
essentially zero disk cost.

[![ci](https://github.com/guedesdiogo/pleach/actions/workflows/ci.yml/badge.svg)](https://github.com/guedesdiogo/pleach/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/%40diogoaguedes%2Fpleach?color=cb3837&logo=npm)](https://www.npmjs.com/package/@diogoaguedes/pleach)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)
![runtime deps](https://img.shields.io/badge/runtime%20deps-git%20%2B%20bash-lightgrey)

```bash
pleach new fix-login               # an isolated session: a worktree per repo, its own ports
pleach open fix-login              # start working in it, with your tool of choice
pleach new feat-search && pleach open feat-search codex   # a second one, a different agent
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
| **"Just be disciplined with branches"** | No tooling required | One working tree holds one branch. Two sessions in one folder would swap each other's checkout on every `git switch`, and still share `node_modules`, builds and dev servers. There is no real concurrency to be disciplined about |
| **A container per session** | Strong isolation, ports included | Each session costs a VM's worth of RAM on macOS, starts slowly, and adds credential and tooling friction — the opposite of many cheap sessions on one machine |

## Where it sits among the worktree tools

Worktree tooling multiplied through 2026 and most of it is very good — and almost all of it
is **single-repo**, which is the line pleach is on the other side of.

| | Multi-repo | Ports | Secrets | `main` → session |
|---|:--:|:--:|:--:|:--:|
| **pleach** | ✅ | ✅ | ✅ | ✅ |
| worktrunk, phantom, gwq | — | template | — | — |
| workz | — | ✅ + DB, compose | ✅ | — |
| `claude --worktree`, Muse Code | — | — | — | — |

What none of them compose is **worktrees per repo + secrets + ports + runtime identity +
bootstrap + lifecycle**, behind one command.

**The agent-native ones compose with pleach rather than replace it.** `claude --worktree`
and Muse Code's parallel subagents create worktrees *inside* one repo, owned by the agent
and discarded when it finishes. A pleach session is the durable, multi-repo floor those
agents stand on. Meta's **Muse Code** is the closest thing to pleach built by someone else,
and it reached nearly opposite answers — detached HEAD instead of named branches, one repo
instead of many, the machine owning the worktree instead of you. Running Muse Code *inside*
a pleach session is the intended stack, not a competing one.

→ **[The full comparison](docs/comparison.md)** — eight named tools, when to reach for each
one instead, and a detailed look at Muse Code: how its fan-out works, where pleach has the
advantage, where Muse is ahead, and what pleach took from it.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/guedesdiogo/pleach/main/install.sh | bash
pleach update                  # self-updates from main; push is release
```

Or through a package manager:

```bash
brew install guedesdiogo/tap/pleach     # completions included
npm install -g @diogoaguedes/pleach     # or: bun add -g @diogoaguedes/pleach
```

The npm package is scoped because npm reserves the bare name `pleach`, judging it too
close to `preact`. The command it installs is still `pleach`.

`pleach update` recognises installs owned by Homebrew, npm or bun and redirects to that
package manager rather than self-updating over the top of them — which would leave the
managed copy stale and a second one shadowing it. Four channels that never fight is a
property worth testing, so it is: the suite asserts each redirect fires before any network
call is made.

Then, optionally, in `~/.zshrc` or `~/.bashrc`:

```bash
eval "$(pleach shell-init)"          # enables `pleach cd <session>`
eval "$(pleach completions zsh)"     # or: completions bash
```

`shell-init` exists because `cd` is the one command a binary cannot perform: only a
function running in your own shell can change that shell's directory. Rather than
pretend otherwise, `pleach cd` without the wrapper prints the one line that fixes it.

If a coding agent will be using this workspace, `pleach skill --install` teaches it how —
see [Teach your agent to drive it](#teach-your-agent-to-drive-it).

### Platforms

Requirements: git >= 2.15 (worktrees) and bash >= 3.2 (the bash macOS ships).

| Platform | Status |
|---|---|
| macOS | Supported. CI runs the suite on `macos-latest` |
| Linux | Supported. CI runs the suite on `ubuntu-latest` |
| **Windows** (Git Bash / WSL) | Supported. CI runs the suite on `windows-latest` under the Git Bash that ships with Git for Windows |
| Windows (`cmd`, PowerShell natively) | Not supported, and not planned — it would be a rewrite, not a port |

The repository pins `eol=lf` in `.gitattributes`: Git for Windows checks out CRLF by
default, and a carriage return at the end of a shebang makes the interpreter unfindable.
Port detection uses `lsof` where it exists, falls back to `ss -lntp` on Linux and to
`netstat -ano` under Git Bash — `-ano` is Windows syntax, and on Linux those flags mean
something else entirely.

## Adopt it in your project

From the root of your workspace's canonical checkout:

```bash
pleach init                    # detects first-level sub-repos, writes .pleach.conf
pleach init --default          # and records this project as the machine default
pleach new first-session       # then: pleach open first-session
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

The canonical is resolved in order: the `PLEACH_CANONICAL` env var, then `.session-env`
walking up from the cwd (you are inside a session), then `.pleach.conf` walking up, then
`~/.config/pleach/config`. With a machine default recorded, `pleach ls`/`new` work from
anywhere.

`.session-env` before `.pleach.conf` on purpose: both files sit in a session's root
worktree, since the conf is meant to be committed and travels with the branch. Reading
the conf first made a session its own canonical.

## Daily use

```bash
pleach open fix-x                    # open your tool inside an existing session
pleach open fix-x claude -r          # resume that session's previous conversation
pleach open fix-x --create           # the one-command flow, asked for explicitly
# `open` opens: by default it does not create. A name that does not exist is answered
# with the `new` command to run — and, when it is one edit away from a session you
# have, with a "did you mean". Creating on any unknown name turned a typo into a whole
# session: worktrees, a branch, a port block and the dependency bootstrap, then a `rm`
# to undo. `--create` keeps that flow for anyone who wants it, because typing the flag
# is a decision and a typo is not. The refusal deliberately does not mention it: a
# mistyped name should not be answered with how to build it anyway.
pleach open fix-x code               # VS Code on the session's multi-root workspace

pleach new fix-x api web             # a focused session: only these sub-repos
pleach new fix-x --fetch             # update the base from origin first
pleach new fix-y --from fix-x        # stack on fix-x's unmerged work, not on main

pleach ls                            # instant: name, index, ports, repo count
pleach ls -l                         # branch, commits ahead, changes, integration status
pleach ls --json                     # the same map, machine-readable

pleach cd fix-x                      # change into the session (needs shell-init)
pleach path fix-x                    # print where it lives; --canonical for the canonical
pleach doctor                        # drift, stale locks, port clashes; --fix repairs safely

pleach sync fix-x                    # merge the local main into every repo of the session
pleach sync fix-x --dry-run          # show what would happen, touch nothing
pleach sync --all --yes              # every session (explicit --yes outside a TTY)

pleach add fix-x payments            # mount a new sub-repo into an existing session
pleach repos --sync                  # adopt a new workspace repo across ALL sessions

pleach conflicts                     # what sessions would break in each other at merge
pleach each 'git log --oneline -1'   # run a command in the canonical + every session
pleach each --repos 'git status -s'  # ...and inside every mounted sub-repo
pleach clean fix-x --apply           # delete git-ignored artifacts (node_modules, builds)
pleach rm fix-x --reap               # remove the session; --reap kills leftover listeners
pleach prune --apply                 # remove every fully integrated session

pleach skill --install               # teach your coding agent to drive all of the above
pleach help sync                     # detailed help per command (and `help config`)
```

### Ports, and the state git cannot see

Each session gets an exclusive block of 100 ports written to `.session-env` (`PORT`,
`PLEACH_PORT_BASE`, and derivatives). `pleach open` exports them before launching, so dev
servers that honour `PORT` never collide without any manual step. For the rest,
`source .session-env` and pass the flag.

**One `PORT` is not enough for a workspace with several services**, and pretending otherwise
made the headline promise half-true: three services all reading `$PORT` meant the second one
died on `EADDRINUSE` *inside a single session* — exactly the collision this tool claims to
remove. So the block is fanned out: the root gets `PORT`, and every mounted sub-repo gets its
own `PLEACH_PORT_<SUB>` at base+1, base+2, and so on (up to 28 repos, which is where the
reserved offsets begin). Point each service's dev script at its own variable — pleach
allocates the ports, it does not start your servers.

```bash
source .session-env
(cd api && PORT=$PLEACH_PORT_API npm run dev) &
(cd web && PORT=$PLEACH_PORT_WEB npm run dev) &
```

`pleach open` sources that file for you, and so does `pleach cd` once the `shell-init`
wrapper is installed. A shell you opened yourself has not, which is the quietest way to bind
port 3000 on top of a colleague.

Ports are only the visible half. Worktrees isolate **files**; they do nothing about the
shared state around them — the dev database two sessions both migrate, the compose
project two sessions both bring up. So the same file carries a runtime identity:

```bash
export PLEACH_SLUG=acme__fix_login
export PLEACH_DB_NAME=acme__fix_login        # unique, and a valid SQL identifier
export COMPOSE_PROJECT_NAME=acme__fix_login  # docker compose namespaces everything by it
```

It is namespaced by the workspace, not just the session, so two projects that both have a
`fix-login` never meet. Session names map injectively: they are validated as `[a-z0-9_-]`,
and the underscores already present are doubled first, so `fix-login` and `fix_login` never
collapse onto one name. The workspace half is a plain directory name and gets no such
guarantee — `acme-app` and `acme.app` both reduce to `acme_app`, so two workspaces whose
directory names differ only in punctuation or case would share a slug. Closing that would
mean hex-escaping every separator, and a database called `acme_2dapp__fix_2dlogin` is a
worse daily cost than a collision nobody has hit; rename one of the directories if you are
in that position. pleach does not create the database for you — it hands your tooling a
name, which is the part that has to be decided centrally.

A `.session-env` pleach cannot read is treated as a claim it cannot verify, not as an
absence. If a session directory holds one with no `PLEACH_INDEX` — a file another tool
wrote, or one edited by hand — then the block that session is serving on cannot be named,
so no other block can be certified free either. `pleach new` refuses before it writes
anything and names the file; `doctor` reports it instead of ticking it. This is not
hypothetical: adopting pleach over sessions a previous tool had created handed the new
session the exact block a live one was already serving on, and the same `doctor` run
closed with `no problems found`, printing `✓ alpha: index , ports +` — the empty values
rendered as a tick.

Sockets also outlive worktrees: a dev server started in a session keeps its port after
the session is removed. `pleach rm` reports any process still listening in the freed
block, and `--reap` kills them. Reporting is the default, because a cleanup command
should not kill processes behind your back.

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

The parts worth arguing about: isolation that is **structural rather than disciplinary**;
destructive commands that are dry runs until you say otherwise; `clean` asking `.gitignore`
what is disposable instead of guessing; a skipped repo never blocking the others; no
automatic stash, ever; `rm` refusing to destroy the only copy of unintegrated work; the
guard rail that exists because a test harness once resolved to a live workspace and ran
`sync --all` against it; and why there is deliberately **no MCP server**.

Each one is a trade with a reason, and the reasons are the interesting part.

→ **[All of them, with the arguments](docs/design-notes.md)**

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

## Teach your agent to drive it

```bash
pleach skill --install       # ~/.claude/skills/pleach/SKILL.md — personal, every project
pleach skill --project       # ./.claude/skills/pleach/ — commit it, the whole team's agents get it
pleach skill --dir <path>    # any other runtime's skills folder
pleach skill                 # just print it: pipe into any tool, any model
```

`--project` also leaves a short pointer in an `AGENTS.md` or `CLAUDE.md` that the repo
**already has**, between `<!-- pleach:begin -->` and `<!-- pleach:end -->`. It never creates
either file — whether a project should have one is the team's call, not a side effect of
adopting a tool — and everything outside the markers is copied through untouched, so
re-running after an upgrade refreshes the block instead of stacking copies of it. Removing
pleach is deleting the block. The pointer exists because the skill file only reaches
harnesses that read `.claude/skills`: a workspace this was measured on had seven harness
directories and an `AGENTS.md`, and the harnesses reading that file saw neither the skill
nor the conf — nothing told them the workspace had sessions at all.

`pleach skill` emits a Markdown skill, frontmatter and all. It carries what `--help` cannot:
that removing the session you stand in pulls the ground from under you — and that
`pleach prune --apply` will do it for you once the work has landed; that shipping from
inside a session collides in the *environment* rather than in the files; and that a green
`conflicts` rules out a textual merge conflict and a duplicated numbered slot — and nothing
beyond those two. Duplicate route paths, one feature-flag name taken twice, the same port
hardcoded in two sessions: all merge clean, none of them show up there.

What it deliberately does **not** carry is a second copy of the command reference. The skill
was tested the way this project tests code: four agents were given realistic tasks in a
throwaway pleach workspace *without* it, to find out which mistakes they actually make. They
made almost none. Unprompted, they sourced `.session-env` rather than hardcoding a port,
reached for `ls --json` because `pleach help ls` says outright that it is the agent surface,
ran the destructive commands as dry runs first, and refused to take the next migration
number from a single worktree's directory listing. `pleach help` is opinionated enough to
carry all of that, so the skill points at it rather than restating it — and is a third
shorter for it. What the exercise *did* find went in: one rule had been broader than the
hazard it named, and the `conflicts` caveat had been missing entirely.

It lives inside the script rather than beside it, exactly like `completions` and
`shell-init`. A skill shipped as a separate file is a path that is right in the repo and
wrong in every install; one emitted by the binary is right everywhere the binary is. What
gets written is a copy, so re-run it after upgrading.

The suite holds the skill to its own claims: every command it names must exist in the
dispatcher or the build fails. That assertion was mutation-tested in both directions — a
skill citing a command that does not exist, and a dispatcher losing a command the skill
still cites — and it caught both.

The skill teaches; the hooks below enforce.

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
tests/run.sh          # 470 assertions across 50 scenarios, in a throwaway sandbox
tests/no-leaks.sh     # repository hygiene gate
shellcheck pleach install.sh tests/*.sh examples/*.sh
```

`tests/run.sh` builds an ephemeral composite workspace and exercises the real lifecycle:
creation, listing, sync (including the dry run, the dirty-repo skip and the wrong-branch
skip), the non-interactive `--yes` requirement, removal, prune, clean, `each`, `add`,
`repos --sync`, the runtime identity and its idempotent backfill, `ls --json` (parsed, not
pattern-matched), `path`/`cd`/`shell-init`/`completions` (the emitted scripts are syntax
checked), `doctor` against a planted stale lock and a planted conf/disk drift, `conflicts` against both a real
conflict and a mere overlap (the decisive assertion is that a file two sessions edit in
*distant regions* is reported as an overlap and **not** as a conflict — the exact case the
old heuristic got wrong), every command run from *inside* a session with nothing sourced (the
shape an agent arrives in), `new --from` stacking a session on another's unmerged commits,
help coverage for every command, the emitted agent skill (frontmatter, its
character budget, all three install destinations and the anti-drift check), and that `open`
really runs inside the session.

It pins `PLEACH_EXPECT_CANONICAL` to its own sandbox so it cannot escape.

Two scenarios exercise the lock rather than describe it, because until they landed it was
only ever tested by *planting* a lock directory — never by contention, never by a crash.

The first **manufactures the overlap instead of hoping for it**: it holds the lock by hand,
starts two `new` invocations, asserts both are alive and have created nothing, and only then
lets go. Launching two runs and hoping they collide proves nothing — a first run that
releases the lock before the second reaches it passes every assertion without contention
having happened at all. With the overlap guaranteed, it then asserts the two runs took
*different indexes*: deliberately not "both succeeded", which would pass even if the lock did
nothing, because the port block is derived from the index and two sessions on one block is
the exact collision the design exists to prevent.

The second **SIGKILLs a run mid-creation**. SIGKILL runs no `EXIT` trap, so the lock outlives
its owner: precisely the "run that died mid-way" `doctor` promises to detect. It asserts
`doctor` exits non-zero and names the dead owner, that `--fix` releases it, and — the part
that matters — that a session can be created again afterwards. A repair whose only evidence
is its own success message is not a repair.

`conflicts` reports the change, not just the file. A filename cannot tell two edits to
adjacent lines from a rewrite, so the reader had to go and look anyway — while the merged
tree, conflict markers and all, was already in the object store: `merge-tree --write-tree`
writes it, and the command printed its id and discarded it. It now reads it back and shows
how many conflicting regions there are, where each begins, and what both sides put in the
first one.

Every session is also merged against the base on its own, reported as
`<session> <-> <base>`. A pair check answers *can these two land together*; it never answered
*can this one land at all*, and once a session's counterpart has landed that is the only
question left.

And a verdict expires with the conflict it describes. The pair check compared session tip
against session tip and never consulted the base, so a session whose work had already landed
kept conflicting with everyone for as long as its folder existed — while the overlap table
directly below it, which does diff against the base, had already gone quiet about the same
file. Landed sessions are now skipped. That is exact for a true merge, where the branch
becomes an ancestor of the base; after a **squash** it is not, and the fallback (branch and
base holding identical content) stops being true once the base moves on. A squash-landed
session can still be reported — remove it with `pleach rm`. Said here rather than left to be
discovered.

`each --repos` descends into every mounted sub-repo. Without it, `pleach each 'git status'`
in a composite workspace answers for the root worktrees only, which is not where most of the
work lives. It is opt-in on purpose: `each` runs *your* command, so widening where it lands
is a change of blast radius. The commands that always descend — `sync`, `ls -l`, `doctor` —
are running operations pleach itself defines.

A creation that is interrupted no longer looks finished. `new` records a marker beside the
session and removes it only on success, so a run that is killed — or that fails partway —
leaves evidence. Without it, a session killed during bootstrap was indistinguishable from a
complete one: `doctor` reported `✓ during: index 2, ports 10200+, 3 repo(s)` and `ls -l`
called it *fully integrated — removable* over dependencies that were never installed. Both
now name it, and name the two commands that finish the job.

`doctor --fix` also writes a fresh `.session-env` for a session that lost one, taking a free
index. The advice it printed before was two things that do not work: `new` refuses a name
whose folder already exists, and copying another session's file hands this one that session's
port block — the collision the whole design exists to prevent.

That scenario earned its keep. It failed about one run in nine, and the failure it reported
was five scenarios downstream of its cause — which is what made it look like flakiness worth
waiting out. It was not: taking the lock and recording its owner were two steps with a `fork`
between them, and a kill landing in that window left a lock with no owner. An owner-less lock
is the one shape `doctor` must refuse to clear, because it cannot be told from a live run's,
so `--fix` declined and every later creation queued behind it. The owner line is now composed
in a scratch file and **hard-linked** into place, so the lock is complete at the instant it
begins to exist, and the scenario asserts that a lock which exists always names who holds it.

A symlink carrying the owner in its target is atomic too, and was the first fix — the Windows
job rejected it. Under Git Bash as CI runs it, `ln -s` did not produce a link `[ -L ]` would
recognise, so `pleach new` failed outright and the next one sat out the full 120-second lock
timeout. Real symlinks there depend on `MSYS=winsymlinks:nativestrict` plus the privilege to
create them, which is not something a tool can assume of the shell it is invoked from. Hard
links need no such opt-in.

Catching a run mid-lock is inherently a race, and on a loaded machine it is lost: the run
finishes before the kill lands and four assertions fail in a cascade that says nothing about
pleach. So it retries up to three times with a fresh session name, and fails loudly only if
every attempt loses. On **Windows** the crash does not reproduce at all through Git Bash's
process model, so there the scenario plants a lock owned by a pid that is provably dead
instead — which still answers *"does `doctor` recognise a dead owner and release it here"*,
and leaves exactly one thing open: whether a real crash on Windows produces that state in the
first place.

Two more scenarios cover what the tool now catches for you: `conflicts` reporting **one
numbered slot claimed by two sessions** — `0004_billing.sql` against `0004_last_login.sql`,
different files, so git merges them clean and lands two migrations numbered 0004 — with the
decisive negative that one session using a slot twice is its own business and is *not*
reported; and `doctor` noticing an **installed agent skill that no longer matches the
binary**, since the skill is written as a copy and ages silently the moment pleach is
upgraded.

Two scenarios exist because the suite could not have written them. They came from running
the **published npm package** against a project it had never seen, with someone who was told
not to read the source. The pending-work check used `--untracked-files=no`, so a session
whose only content was files never `git add`ed reported as empty: `ls -l` called it *"fully
integrated — removable"* and `rm` deleted it, green tick, exit 0, content gone. And identity
came from the folder name, so renaming a session folder made the branch lookup miss and the
same deletion happen to committed work. Both now refuse, and both scenarios assert the
negative that keeps the fix honest — a genuinely empty session must still be removable, or
the fix would just have broken post-merge hygiene instead.

`install` and `update` are covered too, with `HOME` redirected into the sandbox — a test that
writes to your real `~/.local/bin` is a test nobody can run twice. `update` reaches the
network, so a `curl` double stands in for it, and the property under test is not "it updates"
but that a **failed or corrupt download leaves a working `pleach` behind**: a payload that is
not valid bash must be rejected by the syntax gate with the old copy untouched. Writing these
found a real defect on the first run — the "you are running the installed copy" guard
compared raw path strings, so any non-normalised `HOME` (a doubled slash, a trailing slash, a
symlink) walked straight past it, and `cp` refused in its own words instead of pleach's.

The suite earns its keep: `conflicts` shipped with a defect its own test caught — an `EXIT`
trap referencing a variable that was `local` to a function already returned, which under
`set -u` turned cleanup into a non-zero exit code. Every command reported the right thing
and then lied about it in `$?`.

`tests/no-leaks.sh` is the gate that keeps this repository honest about its origins. It was
itself mutation-tested: seven defects were planted — a forbidden reference, leftover prose
in another language, a private scope, the wrong licence, a missing LICENSE, a restricted
publish, and a near-empty scan that would have passed vacuously — and all seven were
caught. Its needles are reassembled at runtime, because a gate that contains the strings it
hunts for would only ever find itself.

CI runs the suite on ubuntu, macOS and Windows on every push.

## Limitations

- Sub-repo names containing newlines are not supported.
- Sub-repo auto-detection is one level deep; declare anything deeper in `PLEACH_SUBS`.
- The lock is per `PLEACH_DIR` (atomic `mkdir`); on an NFS share between machines there are
  no guarantees.
- `rm` and `prune` judge "integrated" against the **local** base. If the merge only landed
  on the remote, `git fetch` in the repo first — or use `--force`, which preserves the
  branch.
- Detecting processes that hold a session's ports needs `lsof` (macOS, Linux), `ss` (Linux)
  or `netstat` (Git Bash on Windows). With none of them, `rm` and `doctor` say nothing rather
  than guess — the ports are still freed, you just are not told who is holding them.
- `PLEACH_DB_NAME` is a name, not a database. pleach never creates, migrates or drops one;
  provisioning belongs to the project's own bootstrap.

## License

MIT — see [LICENSE](LICENSE).
