#!/usr/bin/env bash
# Park the user-level CLAUDE.md for the length of one command, so a
# headless dry run started inside it cannot read the author's personal
# rules. Every checkout of this repo on a machine shares one config
# directory, so the park is guarded by a lock that names its holder.
#
# Usage:
#   scripts/park-claude-md.sh [--none-ok] -- <command> [args...]
#
#   --none-ok   run the command even when there is no CLAUDE.md to
#               park (for a machine that has never had one)
#
# The config directory is $CLAUDE_CONFIG_DIR when set, else ~/.claude:
# the directory Claude Code reads the user-level CLAUDE.md from.
#
# While parked, the file lives inside CLAUDE.md.park-lock/ beside the
# original, next to an owner record naming the checkout, process ID,
# and process start time of the session that parked it. The start time
# tells a live holder from a reused process ID.
set -uo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LIVE="$CONFIG_DIR/CLAUDE.md"
LOCK="$CONFIG_DIR/CLAUDE.md.park-lock"
PARKED="$LOCK/CLAUDE.md"
OWNER="$LOCK/owner"

die() { echo "park-claude-md: $*" >&2; exit 2; }

usage() { die "usage: $0 [--none-ok] -- <command> [args...]"; }

start_time() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

owner_field() { sed -n "s/^$1=//p" "$OWNER" 2>/dev/null; }

holder_alive() {
  local pid started
  pid="$(owner_field pid)"
  started="$(owner_field started)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$(start_time "$pid")" = "$started" ]
}

describe_holder() {
  echo "checkout $(owner_field checkout), process $(owner_field pid), started $(owner_field started)"
}

refuse_existing_lock() {
  if [ ! -f "$OWNER" ]; then
    die "$LOCK exists with no owner record; another session may be parking right now. Try again shortly."
  fi
  if holder_alive; then
    die "CLAUDE.md is parked by a running session: $(describe_holder). Wait for it to finish."
  fi
  die "CLAUDE.md is parked by a session that is no longer running: $(describe_holder). Run $0 --recover to restore it."
}

checkout_root() {
  local here
  here="$(cd "$(dirname "$0")" && pwd)"
  git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo "$here"
}

none_ok=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --none-ok) none_ok=1; shift ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ "$#" -gt 0 ] || usage

# A batch that fans out parallel arms, each wrapped in this script,
# shares the batch's park: the holder exports its process ID, and a
# nested call that finds that same live holder runs its command as is.
if [ -n "${CLAUDE_MD_PARK_HOLDER:-}" ] && [ -f "$OWNER" ] &&
  [ "$(owner_field pid)" = "$CLAUDE_MD_PARK_HOLDER" ] && holder_alive; then
  exec "$@"
fi

mkdir "$LOCK" 2>/dev/null || refuse_existing_lock
printf 'checkout=%s\npid=%s\nstarted=%s\n' "$(checkout_root)" "$$" "$(start_time $$)" > "$OWNER.tmp" &&
  mv "$OWNER.tmp" "$OWNER" || { rm -rf "$LOCK"; die "could not write $OWNER"; }

if [ -e "$LIVE" ] || [ -L "$LIVE" ]; then
  mv "$LIVE" "$PARKED" || { rm -f "$OWNER"; rmdir "$LOCK"; die "could not park $LIVE"; }
elif [ "$none_ok" -eq 0 ]; then
  rm -f "$OWNER"; rmdir "$LOCK"
  die "$LIVE does not exist and no park lock explains it; another tool may have moved it. Pass --none-ok if this machine has no user-level CLAUDE.md."
fi

restored=0
restore() {
  [ "$restored" -eq 0 ] || return 0
  restored=1
  if [ -e "$PARKED" ] || [ -L "$PARKED" ]; then
    mv "$PARKED" "$LIVE" || return 1
  fi
  rm -f "$OWNER" && rmdir "$LOCK"
}

# The command runs in the background because bash defers a trapped
# signal until a foreground command finishes, which would leave the
# file parked for as long as the command ignores the signal. A
# non-interactive shell also starts background commands with SIGINT
# ignored, so both traps stop the command with TERM, and gives them
# /dev/null for input unless told otherwise, hence the <&0.
child=
on_signal() {
  [ -z "$child" ] || { kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; }
  restore
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap restore EXIT

CLAUDE_MD_PARK_HOLDER=$$ "$@" <&0 &
child=$!
wait "$child"
status=$?
child=
restore
exit "$status"
