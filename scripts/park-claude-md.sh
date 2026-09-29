#!/usr/bin/env bash
# Park the user-level CLAUDE.md for the length of one command, so a
# headless dry run started inside it cannot read the author's personal
# rules. Every checkout of this repo on a machine shares one config
# directory, so the park is guarded by a lock that names its holder.
#
# Usage:
#   scripts/park-claude-md.sh -- <command> [args...]
#
# The config directory is $CLAUDE_CONFIG_DIR when set, else ~/.claude:
# the directory Claude Code reads the user-level CLAUDE.md from.
set -uo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LIVE="$CONFIG_DIR/CLAUDE.md"
LOCK="$CONFIG_DIR/CLAUDE.md.park-lock"
PARKED="$LOCK/CLAUDE.md"

die() { echo "park-claude-md: $*" >&2; exit 2; }

[ "${1:-}" = "--" ] || die "usage: $0 -- <command> [args...]"
shift
[ "$#" -gt 0 ] || die "no command given"

mkdir "$LOCK" 2>/dev/null || die "could not create $LOCK"
mv "$LIVE" "$PARKED" || { rmdir "$LOCK"; die "could not park $LIVE"; }

restore() {
  mv "$PARKED" "$LIVE" && rmdir "$LOCK"
}

"$@"
status=$?
restore
exit "$status"
