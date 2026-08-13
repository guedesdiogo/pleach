#!/usr/bin/env bash
# Install pleach without cloning the repo:
#
#   curl -fsSL https://raw.githubusercontent.com/guedesdiogo/pleach/main/install.sh | bash
#
# Overrides: PLEACH_REPO (owner/name), PLEACH_BRANCH, PLEACH_INSTALL_DIR.
set -euo pipefail
REPO="${PLEACH_REPO:-guedesdiogo/pleach}"
BRANCH="${PLEACH_BRANCH:-main}"
DEST_DIR="${PLEACH_INSTALL_DIR:-$HOME/.local/bin}"
TARGET="$DEST_DIR/pleach"

command -v curl >/dev/null 2>&1 \
  || { echo "pleach install: curl is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 \
  || echo "  ! git not found - pleach needs git >= 2.15 at runtime" >&2

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/pleach" -o "$tmp" \
  || { echo "pleach install: download failed (is $REPO@$BRANCH reachable?)" >&2; exit 1; }
bash -n "$tmp" 2>/dev/null \
  || { echo "pleach install: the downloaded script failed its syntax check - aborted" >&2; exit 1; }
chmod +x "$tmp"
mkdir -p "$DEST_DIR"
mv "$tmp" "$TARGET"
trap - EXIT

echo "-> pleach installed at $TARGET ($("$TARGET" version))"
case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *) echo "  ! $DEST_DIR is not on your PATH - add to your shell rc: export PATH=\"$DEST_DIR:\$PATH\"" >&2 ;;
esac
echo "Next: run 'pleach init' at your workspace root, then 'pleach open <name>'."
