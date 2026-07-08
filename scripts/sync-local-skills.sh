#!/usr/bin/env bash
# One-way sync: this repo's skills -> your personal ~/.claude/skills/.
#
# For contributors who also keep un-namespaced local copies of these
# skills (instead of installing the plugin). The repo is the source of
# truth: edit skills HERE, merge, then sync outward. A local edit that
# never lands in the repo is drift -- the only remedy this script offers
# is showing you the diff so you can move the edit into the repo.
#
# Usage:
#   scripts/sync-local-skills.sh --check   # show drift, change nothing
#   scripts/sync-local-skills.sh           # copy repo -> ~/.claude/skills
#
# Also updates $HOME/.claude/bin/linear from bin/linear when that file
# already exists locally (created the first time you opt in by copying
# it yourself).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

drift=0
for dir in skills/*/; do
  name="$(basename "$dir")"
  if [ ! -d "$DEST/$name" ]; then
    echo "missing locally: $name"
    drift=1
    [ "$CHECK_ONLY" -eq 1 ] || { mkdir -p "$DEST"; cp -R "$dir" "$DEST/$name"; echo "  -> installed"; }
    continue
  fi
  if ! diff -rq "$dir" "$DEST/$name" >/dev/null 2>&1; then
    echo "drift: $name"
    diff -rq "$dir" "$DEST/$name" | sed 's/^/  /' || true
    drift=1
    if [ "$CHECK_ONLY" -eq 0 ]; then
      rm -rf "$DEST/$name"
      cp -R "$dir" "$DEST/$name"
      echo "  -> synced from repo"
    fi
  fi
done

if [ -f "$HOME/.claude/bin/linear" ] && ! diff -q bin/linear "$HOME/.claude/bin/linear" >/dev/null 2>&1; then
  echo "drift: bin/linear"
  drift=1
  if [ "$CHECK_ONLY" -eq 0 ]; then
    cp -p bin/linear "$HOME/.claude/bin/linear"
    echo "  -> synced from repo"
  fi
fi

if [ "$drift" -eq 0 ]; then
  echo "sync-local-skills: no drift"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  echo "sync-local-skills: drift found (run without --check to sync repo -> local)"
fi
