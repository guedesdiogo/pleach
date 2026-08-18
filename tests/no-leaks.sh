#!/usr/bin/env bash
# Leak gate for a public repository.
#
# pleach grew out of an internal tool built for a private multi-repo workspace.
# This test is the mechanical proof that nothing from that origin survived into
# the public code: no internal project names, no private package scopes, no
# corporate email addresses, and no leftover prose in the original language.
#
# It runs in CI on every push. If it ever fails, the repository is leaking.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FAILS=0
report() { echo "  FAIL - $1" >&2; FAILS=$((FAILS + 1)); }
pass()   { echo "  ok   - $1"; }

FILES_LIST=$(mktemp)
trap 'rm -f "$FILES_LIST"' EXIT

if git rev-parse --git-dir >/dev/null 2>&1; then
  git ls-files > "$FILES_LIST"
fi
# Fall back to the filesystem when git has nothing tracked yet. Without this, a
# fresh checkout with an empty index would scan zero files and pass vacuously -
# a green test that proves nothing is worse than no test at all.
if [ ! -s "$FILES_LIST" ]; then
  find . -type f -not -path './.git/*' | sed 's|^\./||' > "$FILES_LIST"
fi

FILE_COUNT=$(wc -l < "$FILES_LIST" | tr -d ' ')
echo "scanning $FILE_COUNT file(s)"
if [ "$FILE_COUNT" -lt 5 ]; then
  echo "  FAIL - only $FILE_COUNT file(s) to scan; the gate would pass vacuously" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Forbidden references
#
# The needles are stored split by a pipe and reassembled at runtime, on purpose:
# this file must not itself contain the strings it hunts for, or the scan would
# always trip over its own source.
# ---------------------------------------------------------------------------
echo ""
echo "--- forbidden references ---"
NEEDLE_PARTS='g|session
great|apps
great|softwares
great|clinic
g|billing
v4|company'

while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  needle=$(printf '%s' "$raw" | tr -d '|')
  hits=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if out=$(grep -n -i -I -H -- "$needle" "$f" 2>/dev/null); then
      hits="$hits$out
"
    fi
  done < "$FILES_LIST"
  if [ -n "$hits" ]; then
    report "reference to '$needle' found"
    printf '%s' "$hits" | sed 's/^/      /' >&2
  else
    pass "no reference to '$needle'"
  fi
done <<NEEDLES
$NEEDLE_PARTS
NEEDLES

# ---------------------------------------------------------------------------
# 2. English only
#
# Accented Latin letters are the fingerprint of the original language. We match
# them by their UTF-8 lead byte rather than by a literal character class, for the
# same reason the needles above are split: a literal class would contain the very
# characters it hunts for, and this file would always flag itself.
#
# U+00C0-U+00FF (the accented Latin letters) all encode as lead byte 0xC3.
# The glyphs the CLI uses on purpose are safe: the box and arrow symbols live in
# U+2xxx and encode with lead byte 0xE2, and the middle dot U+00B7 uses 0xC2.
# ---------------------------------------------------------------------------
echo ""
echo "--- english only ---"
ACCENT_LEAD=$(printf '\303')
accented=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # -a, not -I: a file wrongly judged "binary" would be skipped, and a silently
  # skipped file is exactly the leak this gate exists to catch.
  if out=$(LC_ALL=C grep -n -a -H -- "$ACCENT_LEAD" "$f" 2>/dev/null); then
    accented="$accented$out
"
  fi
done < "$FILES_LIST"
if [ -n "$accented" ]; then
  report "accented characters found (leftover prose in another language)"
  printf '%s' "$accented" | sed 's/^/      /' >&2
else
  pass "no accented characters in any tracked file"
fi

# ---------------------------------------------------------------------------
# 3. Package identity
# ---------------------------------------------------------------------------
echo ""
echo "--- package identity ---"
pkg_field() { sed -nE "s/.*\"$1\": *\"([^\"]+)\".*/\1/p" package.json | head -1; }

# The package is scoped under the author's own npm account because npm reserves
# the bare name. The scope is part of the identity, so it is pinned here: a
# different scope would mean the package was published somewhere unintended.
EXPECTED_PKG="@diogoaguedes/pleach"
if [ "$(pkg_field name)" = "$EXPECTED_PKG" ]; then
  pass "package name is '$EXPECTED_PKG'"
else
  report "package name is '$(pkg_field name)', expected '$EXPECTED_PKG'"
fi

if [ "$(pkg_field license)" = "MIT" ]; then
  pass "license is MIT"
else
  report "license is '$(pkg_field license)', expected MIT"
fi

if grep -q '"access": *"public"' package.json; then
  pass "publishConfig.access is public"
else
  report "publishConfig.access is not public"
fi

if [ -f LICENSE ]; then
  pass "LICENSE file present"
else
  report "LICENSE file missing"
fi

# ---------------------------------------------------------------------------
# 4. Commit authorship
#
# A clean working tree is not enough: the git history is public too.
# ---------------------------------------------------------------------------
echo ""
echo "--- commit authorship ---"
if git rev-parse --git-dir >/dev/null 2>&1 && git log -1 >/dev/null 2>&1; then
  authors=$(git log --format='%ae%n%ce' | sort -u)
  bad=""
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    needle=$(printf '%s' "$raw" | tr -d '|')
    if printf '%s' "$authors" | grep -q -i -- "$needle"; then
      bad="$bad$needle "
    fi
  done <<NEEDLES2
$NEEDLE_PARTS
NEEDLES2
  if [ -n "$bad" ]; then
    report "commit author/committer address matches: $bad"
    printf '%s\n' "$authors" | sed 's/^/      /' >&2
  else
    pass "no forbidden address in commit authorship"
  fi
else
  pass "no git history to scan (skipped)"
fi

# ---------------------------------------------------------------------------
# 5. pleach's own artefacts must not be tracked in pleach's repo
# ---------------------------------------------------------------------------
# `pleach init` writes .pleach.conf into $PWD, and a test that ran it without
# cd'ing first wrote one here — which a `git add -A` then committed to main. It
# carried an absolute path from the machine that generated it. Nothing pleach
# GENERATES belongs in the repository that ships pleach.
STRAY=0
for artefact in .pleach.conf .session-env panorama.code-workspace; do
  if grep -qxF "$artefact" "$FILES_LIST"; then
    report "$artefact is tracked — pleach generated it, it does not belong in the repo"
    STRAY=1
  fi
done
[ "$STRAY" -eq 0 ] && pass "no generated pleach artefacts are tracked"

# ---------------------------------------------------------------------------
echo ""
echo "===================================="
if [ "$FAILS" -eq 0 ]; then
  echo "Leak gate: clean"
else
  echo "Leak gate: $FAILS failure(s)"
fi
echo "===================================="
[ "$FAILS" -eq 0 ]
