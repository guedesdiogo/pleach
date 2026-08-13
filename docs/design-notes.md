# Design notes

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

**There is no MCP server, and that is the decision — not an omission.** Most of the 2026
worktree tooling ships one, so the absence is worth defending. Ask who would call it: the
agent lives *inside* a session, and a session's lifecycle is decided from outside and
before it. An agent in `fix-login` calling `rm fix-login` is sawing the branch it sits on.
What an in-session agent legitimately needs is to *read* the map, and `ls --json` through a
shell-out does that in any tool that can run a command. The cost on the other side is real:
MCP is JSON-RPC over stdio, which in pure bash means hand-rolling a JSON parser, and in any
other language means giving up `runtime deps: git + bash`. MCP is the right shape for an
orchestrator. pleach is the substrate underneath one — git does not ship an MCP server
either.

**Isolation buys a blind spot, so `conflicts` sells it back — and it asks git rather than
guessing.** Moving collisions to merge time is the entire point, but the same move hides
them until then: work in another session is invisible to yours by construction. The first
version of this command reported files touched by more than one session. That is a proxy,
and a proxy that cries wolf — two sessions editing distant regions of one file merge
cleanly, and a tool that calls that a conflict is a tool you stop reading. It now runs
git's own three-way merge without a checkout (`merge-tree --write-tree`, git >= 2.38)
between each pair of session branches, and separates what *would actually conflict* from
what merely overlaps. The working tree, the index and the branches are left untouched —
only loose objects enter the object store, unreferenced and subject to garbage collection.
It always exits 0, because an overlap is a normal, resolvable state — the value is finding
out early enough to split the work differently. Below git 2.38 the real check is skipped
and says so, rather than quietly reporting less than it claims.

**`doctor` asks out loud what a multi-repo tool otherwise gets wrong quietly.** A lock left
by a run that died, a worktree git still believes in whose folder is gone, two sessions
whose port blocks overlap, a sub-repo declared in the conf and absent from disk — each one
surfaces later as a confusing failure somewhere else. It exits non-zero when it finds
something, so it fits in CI or a prompt, and `--fix` performs only the two repairs that
cannot lose work.

**A stacked session is allowed to be a bad idea.** `new --from <session>` cuts from another
session's tip, which means integrating against a moving target: `sync` still brings the base
in, not the parent, and a parent rebased or squashed at merge leaves the child carrying
commits that no longer exist upstream. The tool does not forbid it — it records in
`.session-env` the ref it was *actually* cut from (a `--from` no repo could resolve falls
back to the base, and the record then says the base) and marks it in `ls -l`, so the cost
stays visible at the moment you would otherwise forget it.

---

See also: [comparison.md](comparison.md) — where pleach sits among the 2026 worktree tools,
and a detailed comparison with Meta's Muse Code.
