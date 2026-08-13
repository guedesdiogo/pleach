# Where pleach sits among the worktree tools

Worktree tooling multiplied through 2026, and most of it is very good. Almost all of it is
also **single-repo**, which is the line pleach is on the other side of.

| Tool | Shape | Multi-repo | Ports | Secrets | `main` → session | Runtime deps |
|---|---|:--:|:--:|:--:|:--:|---|
| **pleach** | bash CLI | ✅ | ✅ | ✅ | ✅ `sync` | git + bash |
| [worktrunk](https://github.com/max-sixty/worktrunk) | Rust CLI | — | template | — | — | binary |
| [workz](https://github.com/rohansx/workz) | Rust CLI | — | ✅ + DB, compose | ✅ | — | binary |
| [phantom](https://github.com/phantompane/phantom) | TS CLI | — | — | — | — | Node |
| [gwq](https://github.com/d-kuro/gwq) | Go CLI | — | — | — | — | binary |
| [git-worktree-manager](https://github.com/nanasess/git-worktree-manager) | bash CLI | ✅ | — | mise only | `pull` | git + bash |
| [canopy](https://github.com/ashmitb95/canopy) | Python + MCP | ✅ | — | — | — | Python 3.10+ |
| `claude --worktree`, Muse Code | agent-native | — | — | — | — | the agent |

<sub>Read from each project's own documentation, not from running them. Corrections welcome
as issues.</sub>

**When to reach for one of those instead.** One repo and you want the sharpest ergonomics:
worktrunk. One repo where the hard part is the *environment* — a database per branch,
namespaced compose projects: workz, which goes further there than pleach does. A dashboard
across many agents: Conductor, vibe-kanban, Claude Squad. Isolation that outranks startup
cost: container-use or Sculptor, which use containers rather than worktrees.

None of these are wrong; they solve neighbouring problems. What none of them compose is
**worktrees per repo + secrets + ports + runtime identity + bootstrap + lifecycle**, behind
one command.

---

## pleach and Meta's Muse Code

Muse Code is the interesting comparison, because it is the closest thing to pleach built by
someone else — and it arrived at nearly opposite answers. It fans a task out to child
agents, one git worktree each, and reported building six features simultaneously without
collisions.

### How it works

The parent agent splits the job and spawns a write-capable child per task. The runtime
creates each worktree under `.muse/worktrees/`, **in detached HEAD state, checked out from
the parent's HEAD** — not from `main`. Each child commits on its own branch, so the parent
can review or merge them one at a time; results drain back when the parent's turn goes idle,
or you block on one with `subagent_wait`. Every action lands in a replayable JSONL event log
per session, which is what makes `muse resume` work after a crash. Worktrees are tracked
with `base_commit`, `base_ref: HEAD` and `cleanup_policy: remove_if_clean`, and concurrency
is capped at roughly the host core count minus two.

### The shape of each

| | Muse Code | pleach |
|---|---|---|
| Who owns a worktree | the parent agent | you |
| Lifetime | one task, then discarded | the branch's |
| Ref | **detached HEAD** from the parent's HEAD | named branch `session/<name>` |
| Location | `.muse/worktrees/`, inside the repo | `.sessions/`, beside it |
| Scope | one repo | every repo in the workspace |
| Who decomposes the work | the parent agent, automatically | you |
| Integration | the parent merges children one at a time | your normal PR flow |
| Recovery | a replayable JSONL event log | the filesystem *is* the state |
| Cleanup | `cleanup_policy: remove_if_clean` | `prune`, dry run by default |
| Nesting | a child cannot spawn children | sessions stack freely (`--from`) |

### The load-bearing difference

**Detached HEAD versus a named branch — and both answers are right for their owner.**

Muse needs many children from one commit, and git refuses to check the same branch out
twice. So it gives up branches to get the fan-out. pleach *wants* that refusal: it is the
structural isolation, the rule the tool cannot forget. Muse can trade it away because a
child lives for one task and the parent is the only thing that ever looks at it. A pleach
session outlives any single task and is shared by your editor, your agent and your terminal
at once — two of them quietly sharing a branch is the exact failure the tool exists to
prevent.

Everything below follows from that one decision.

### Where pleach has the advantage

**Composite workspaces exist.** Muse isolates one repo. A workspace that is a root repo with
nested repos inside it has no representation in it at all; a worktree of the root arrives
without any of the sub-repos. That is the case pleach was built for.

**The isolation cannot be silently switched off.** Meta's own documentation notes that in a
non-git workspace the isolation flag is *silently ignored* and every child shares the lead
agent's workspace — the guarantee disappears with no error. pleach refuses to start at all:
`canonical '<path>' is not a git repo`. A safety property that can fail quietly is not a
safety property.

**git enforces the isolation, not the tool.** Named branches mean the guarantee is git's,
and you can verify it by hand: try to check `session/fix-login` out twice and git answers
`fatal: ... is already used by worktree at ...`. Detached HEAD gives that up by
construction.

**It serves every tool at once, and outlives all of them.** A session is an ordinary
directory. Your editor, your agent, your test runner and your shell can be in it
simultaneously, for days, across restarts. A Muse worktree exists inside one agent, for one
task.

**The state git cannot see is handled.** Ports, database name and compose project are
allocated per session (`PORT`, `PLEACH_DB_NAME`, `COMPOSE_PROJECT_NAME`). Muse's
documentation says nothing about any of them: N children each running a dev server collide
on port 3000 exactly like everyone else, and two children migrating the same dev database
corrupt it while git reports every file as clean.

**Untracked secrets arrive.** A fresh worktree has no `.env`, `.envrc` or `.npmrc` — git
never had them. pleach copies them from the canonical, preserving paths. This is the single
most common reason a freshly created worktree does not boot.

**No vendor.** git and bash. It works with Claude Code, Codex, Cursor, Muse Code, or no
agent at all — including several of them at once, in different sessions.

**Destruction is opt-in.** `remove_if_clean` is a sensible default for a worktree the
machine owns. For one you own, `prune` and `clean` are dry runs until you pass `--apply`,
and `rm` preserves any branch with unintegrated commits no matter what.

**Sessions stack; children do not.** In Muse, a child cannot spawn its own children — a plan
assuming recursive delegation quietly flattens. `pleach new x --from y` composes to any
depth.

**Cancelling actually frees the resource.** Muse cancellation is cooperative: a cancelled
child that never reaches a checkpoint keeps running. `pleach rm` reports every process still
listening in the session's port block, and `--reap` kills them.

### Where Muse Code is ahead

Saying this plainly is what makes the list above worth reading.

**It decomposes the work for you.** The parent splits a job into tasks and fans them out.
pleach never decides what a session is — that is entirely your call, which is freedom when
you know what you want and friction when you do not.

**It integrates automatically.** Children drain back to the parent, which merges them one at
a time. pleach hands you a normal PR flow and gets out of the way.

**It survives its own crash with the conversation intact.** The JSONL event log plus
`muse resume` rebuild the agent's state. pleach has no notion of what an agent was doing —
only of the files and branches it left behind.

**Inside a single repo it is zero setup.** One flag against a config file. If your work is
one repo and one agent, `muse` or `claude --worktree` is less to think about, and pleach is
not obviously worth adopting.

### What pleach took, and what it refused

Taken:

- **`pleach new <name> --from <session|ref>`.** Muse cuts children from the parent's HEAD.
  pleach only ever cut from the base, so work building on another session's *unmerged*
  commits had to wait for a merge. Now it does not.
- **Conflict prediction that is real.** `conflicts` used to report files touched by more than
  one session. That is a proxy, and it cries wolf: two sessions editing distant regions of
  one file merge cleanly. It now runs git's own three-way merge in memory
  (`merge-tree --write-tree`) and reports only what git itself cannot resolve.

Refused:

- **Detached HEAD.** It would trade away the structural isolation that is the entire point.
- **Auto-cleanup.** Right for a worktree the machine owns, wrong for one you own.
- **The event log.** It solves a problem pleach does not have: a session is a directory and a
  branch, which survives a crash with nothing to replay.

### They compose

Running Muse Code — or Claude Code, or Codex — *inside* a pleach session is the intended
stack, not a competing one. The agent fans out inside the repo it was given; pleach decides
which repos, on which branches, with which ports, secrets and database, and keeps all of
that alive after the agent exits.
