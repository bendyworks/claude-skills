#!/usr/bin/env bash
# Park the user-level CLAUDE.md for the length of one command, so a
# headless dry run started inside it cannot read the author's personal
# rules. Every checkout of this repo on a machine shares one config
# directory, so the park is guarded by a lock that names its holder.
#
# Usage:
#   scripts/park-claude-md.sh [--none-ok] -- <command> [args...]
#   scripts/park-claude-md.sh --status
#   scripts/park-claude-md.sh --recover
#
#   --none-ok   run the command even when there is no CLAUDE.md to
#               park (for a machine that has never had one)
#   --status    say whether the file is parked, and by whom
#   --recover   put back a file whose holder is no longer running
#               (after a crash or kill -9), without the checksum check
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

usage() { die "usage: $0 [--none-ok] -- <command> [args...] | --status | --recover"; }

# Fixed to the C locale and UTC: ps formats the start time in the
# caller's language and time zone, and a --status or --recover run from
# another terminal must read a live holder's time the way it was written.
start_time() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

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

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# A symlinked CLAUDE.md is compared by where it points, not by content,
# since its target (a dotfiles checkout, say) may change while parked.
fingerprint() {
  if [ -L "$1" ]; then
    echo "link:$(readlink "$1")"
  elif [ -e "$1" ]; then
    echo "sha256:$(sha256 "$1")"
  fi
}

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Moves the parked file back and releases the lock, or explains why
# not and leaves both in place: a CLAUDE.md that appeared while parked
# is never overwritten, and a parked copy that changed is kept for a
# person to look at. --recover passes "unchecked" to skip the checksum,
# since a person has looked by then.
put_back() {
  if exists "$PARKED"; then
    if exists "$LIVE"; then
      echo "park-claude-md: a new $LIVE appeared while parked; kept it, and kept the parked copy at $PARKED. Copy anything you need from the parked copy into $LIVE, delete $PARKED, then run $0 --recover to clear the lock." >&2
      return 1
    fi
    if [ "${1:-}" != unchecked ] && [ "$(fingerprint "$PARKED")" != "$(owner_field fingerprint)" ]; then
      echo "park-claude-md: the parked copy's checksum changed while parked; kept it at $PARKED. Check it, then run $0 --recover." >&2
      return 1
    fi
    # mv -n reports a skipped move differently across platforms, so
    # the parked file still existing is what shows it was skipped.
    mv -n "$PARKED" "$LIVE"
    if exists "$PARKED"; then
      echo "park-claude-md: could not move $PARKED back to $LIVE; kept it. Run $0 --recover." >&2
      return 1
    fi
  fi
  rm -f "$OWNER" "$OWNER.tmp" && rmdir "$LOCK"
}

show_status() {
  if ! exists "$LOCK"; then
    echo "CLAUDE.md is not parked."
  elif [ ! -f "$OWNER" ]; then
    echo "$LOCK exists with no owner record: a session is parking right now, or one crashed while parking. If it persists, run $0 --recover."
  elif holder_alive; then
    echo "CLAUDE.md is parked by a running session: $(describe_holder)."
  else
    echo "CLAUDE.md is parked by a session that is no longer running: $(describe_holder). Run $0 --recover to restore it."
  fi
  exit 0
}

recover() {
  if ! exists "$LOCK"; then
    echo "CLAUDE.md is not parked; nothing to recover."
    exit 0
  fi
  if [ -f "$OWNER" ] && holder_alive; then
    die "CLAUDE.md is parked by a running session: $(describe_holder). Let it finish; its exit restores the file."
  fi
  put_back unchecked || exit 2
  echo "Restored $LIVE and cleared the park lock."
  exit 0
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
    --status) show_status ;;
    --recover) recover ;;
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
printf 'checkout=%s\npid=%s\nstarted=%s\nfingerprint=%s\n' \
  "$(checkout_root)" "$$" "$(start_time $$)" "$(fingerprint "$LIVE")" > "$OWNER.tmp" &&
  mv "$OWNER.tmp" "$OWNER" || { rm -rf "$LOCK"; die "could not write $OWNER"; }

if exists "$LIVE"; then
  mv "$LIVE" "$PARKED" || { rm -f "$OWNER"; rmdir "$LOCK"; die "could not park $LIVE"; }
  echo "park-claude-md: parked $LIVE; Claude Code sessions started before it is restored run without it." >&2
elif [ "$none_ok" -eq 0 ]; then
  rm -f "$OWNER"; rmdir "$LOCK"
  die "$LIVE does not exist and no park lock explains it; another tool may have moved it. Pass --none-ok if this machine has no user-level CLAUDE.md."
fi

restored=0
restore_failed=0
restore() {
  [ "$restored" -eq 0 ] || return 0
  restored=1
  put_back || restore_failed=1
}

finish() {
  restore
  [ "$restore_failed" -eq 0 ] || exit 2
  exit "$1"
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
  finish "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap restore EXIT

CLAUDE_MD_PARK_HOLDER=$$ "$@" <&0 &
child=$!
wait "$child"
status=$?
child=
finish "$status"
