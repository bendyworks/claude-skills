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
#               (after a crash or kill -9), without the checksum check,
#               or clear a lock left with no owner record for over a
#               minute
#
# The config directory is $CLAUDE_CONFIG_DIR when set, else ~/.claude:
# the directory Claude Code reads the user-level CLAUDE.md from.
#
# While parked, the file lives inside CLAUDE.md.park-lock/ beside the
# original, next to an owner record naming the checkout, process ID,
# and process start time of the session that parked it, and a
# fingerprint of the parked file. The start time tells a live holder
# from a reused process ID; the fingerprint shows whether the parked
# copy changed before it is put back.
# No -e: every failure here is checked by hand, and wait must hand back
# the command's status for the script to exit with.
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

# Judged from ps rather than kill -0, which also fails for a running
# process this user may not signal (another user's, or one outside a
# sandbox), and that must not read as stranded.
holder_alive() {
  local pid started
  pid="$(owner_field pid)"
  started="$(owner_field started)"
  [ -n "$pid" ] && [ -n "$started" ] && [ "$(start_time "$pid")" = "$started" ]
}

# Where ps reports no start times (some sandboxes), no holder can be
# judged running or stranded, and guessing "stranded" would send the
# user to --recover under a live batch.
can_judge_holders() { [ -n "$(start_time $$)" ]; }

UNKNOWN="cannot tell whether it is still running, because ps here reports no process start times; check from a shell where it does."

describe_holder() {
  echo "checkout $(owner_field checkout), process $(owner_field pid), started $(owner_field started)"
}

refuse_existing_lock() {
  [ -d "$LOCK" ] || die "could not create $LOCK; check that $CONFIG_DIR exists and is writable."
  if [ ! -f "$OWNER" ]; then
    die "$LOCK exists with no owner record; another session may be parking right now. Try again shortly."
  fi
  can_judge_holders || die "CLAUDE.md is parked by $(describe_holder); $UNKNOWN"
  if holder_alive; then
    die "CLAUDE.md is parked by a running session: $(describe_holder). Wait for it to finish."
  fi
  die "CLAUDE.md is parked by a session that is no longer running: $(describe_holder). Run $0 --recover to restore it."
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1
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
  rm -f "$OWNER.tmp"
  # The owner record stays until the lock can go, so a lock blocked by
  # a stray file still names its holder to every other session.
  if [ -n "$(ls -A "$LOCK" | grep -vx owner)" ]; then
    echo "park-claude-md: could not remove $LOCK; something else is in it. Check its contents, remove them, then run $0 --recover." >&2
    return 1
  fi
  rm -f "$OWNER"
  rmdir "$LOCK"
}

show_status() {
  if ! exists "$LOCK"; then
    echo "CLAUDE.md is not parked."
  elif [ ! -f "$OWNER" ]; then
    echo "$LOCK exists with no owner record: a session is parking right now, or one crashed while parking. If it persists, run $0 --recover."
  elif ! can_judge_holders; then
    echo "CLAUDE.md is parked by $(describe_holder); $UNKNOWN"
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
  if [ -f "$OWNER" ] && ! can_judge_holders; then
    die "CLAUDE.md is parked by $(describe_holder); $UNKNOWN"
  fi
  if holder_alive; then
    die "CLAUDE.md is parked by a running session: $(describe_holder). Let it finish; its exit restores the file."
  fi
  # A lock with no owner record is also what a session looks like for
  # the instant between creating the lock and recording itself, so only
  # one that has sat that way for over a minute counts as stranded.
  if [ ! -f "$OWNER" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +1)" ]; then
    die "$LOCK has no owner record yet; another session may be parking right now. Try again in a minute."
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
if [ -n "${CLAUDE_MD_PARK_HOLDER:-}" ] &&
  [ "$(owner_field pid)" = "$CLAUDE_MD_PARK_HOLDER" ] && holder_alive; then
  exec "$@"
fi

# The traps go in before the lock is taken, so no signal can land
# between parking the file and being ready to put it back. restore acts
# only once this process holds the lock, and every failure after that
# point exits through it, so it releases exactly what this run created.
held=0
recorded=0
restored=0
restore_failed=0
restore() {
  [ "$restored" -eq 0 ] || return 0
  restored=1
  [ "$held" -eq 1 ] || return 0
  if [ ! -f "$OWNER" ]; then
    if [ "$recorded" -eq 1 ]; then
      # Someone cleared this run's lock; any lock there now is theirs.
      echo "park-claude-md: the park lock was cleared while this run was parked; what it ran may have read $LIVE." >&2
      restore_failed=1
    else
      rm -f "$OWNER.tmp"
      rmdir "$LOCK" 2>/dev/null
    fi
    return
  fi
  # A --recover run while this one was mistaken for stranded, followed
  # by another session's park, leaves that session's file in the lock.
  if [ "$(owner_field pid)" != "$$" ]; then
    echo "park-claude-md: the park lock was taken over by $(describe_holder); left it alone." >&2
    restore_failed=1
    return
  fi
  put_back || restore_failed=1
}

finish() {
  restore
  [ "$restore_failed" -eq 0 ] || exit 2
  exit "$1"
}

# Reads a "pid ppid" process listing on stdin and prints the process
# IDs of every process descended from $1.
descendants() {
  awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      queue = root
      while (queue != "") {
        split(queue, ids, " "); queue = ""
        for (i in ids) {
          n = split(kids[ids[i]], found, " ")
          for (j = 1; j <= n; j++) { print found[j]; queue = queue " " found[j] }
        }
      }
    }'
}

# The command runs in the background because bash defers a trapped
# signal until a foreground command finishes, which would leave the
# file parked for as long as the command ignores the signal. A
# non-interactive shell also starts background commands with SIGINT
# ignored, and they pass that on to everything they start, so the traps
# stop the whole tree under the command with TERM: a batch's arms are
# usually its grandchildren, and one left running would read the
# restored file. The tree is listed before any of it is signalled,
# since a child that dies first leaves its own children unfindable.
# Background commands also get /dev/null for input unless told
# otherwise, hence the <&0.
child=
command_done=0
own_group=0
on_signal() {
  local pid ppid listing parent
  # A signal can land after the command starts but before child is set;
  # $! already names the command then, since nothing else here runs in
  # the background. bash 3.2 treats an unset $! as unbound under set -u
  # even inside ${!:-}, hence the subshell with -u off.
  if [ -z "$child" ] && [ "$command_done" -eq 0 ]; then
    child="$(set +u; printf %s "$!")"
  fi
  if [ -n "$child" ]; then
    # Once the command is reaped its process ID can be reused, so skip
    # it only when a process listing shows the ID gone or under another
    # parent. An empty listing (ps failed, or a second Ctrl-C cut it
    # short) proves nothing, and the command is signalled anyway. The
    # parent is read in this shell, where a signal cannot empty it.
    listing="$(ps -A -o pid= -o ppid= 2>/dev/null)"
    parent=
    while read -r pid ppid; do
      [ "$pid" = "$child" ] && parent="$ppid"
    done <<EOF
$listing
EOF
    if [ "$command_done" -eq 0 ] && { [ -z "$listing" ] || [ "$parent" = "$$" ]; }; then
      for pid in "$child" $(printf '%s\n' "$listing" | descendants "$child"); do
        kill -TERM "$pid" 2>/dev/null
      done
    fi
    wait "$child" 2>/dev/null
    # Whatever is left in the group, including arms that ignore TERM,
    # is gone before the file goes back.
    sweep_group
  fi
  finish "$1"
}
# Processes still in the command's group once it has exited: arms a
# batch started without waiting for them. They would read the file
# once it is back, so they are stopped first, and the batch is told.
group_members() {
  ps -A -o pid= -o pgid= -o stat= 2>/dev/null | awk -v g="$child" '$2 == g && $3 !~ /^Z/ { print $1 }'
}

# TERM to whatever is left in the command's group, then KILL after five
# seconds for anything that ignored it. The group is signalled only
# while it has members, since an empty group's ID can be reused.
sweep_group() {
  local tries=0
  [ "$own_group" -eq 1 ] && [ -n "$child" ] || return 0
  [ -n "$(group_members)" ] || return 0
  kill -TERM -- "-$child" 2>/dev/null
  while [ -n "$(group_members)" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -z "$(group_members)" ] || kill -KILL -- "-$child" 2>/dev/null
  return 0
}

stop_leftovers() {
  local left
  [ "$own_group" -eq 1 ] || return 0
  left="$(group_members)"
  [ -n "$left" ] || return 0
  echo "park-claude-md: the command left running process(es) $(echo $left); stopping them before putting $LIVE back. Have the batch wait for its arms." >&2
  sweep_group
}

trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap restore EXIT

mkdir "$LOCK" 2>/dev/null && held=1 || refuse_existing_lock
# Without a start time no other session could tell this run is alive,
# and a --recover would put the file back under it.
started="$(start_time $$)"
[ -n "$started" ] || die "could not read this process's start time from ps, which the lock needs; nothing was parked."
printf 'checkout=%s\npid=%s\nstarted=%s\nfingerprint=%s\n' \
  "$(checkout_root)" "$$" "$started" "$(fingerprint "$LIVE")" > "$OWNER.tmp" &&
  mv "$OWNER.tmp" "$OWNER" || die "could not write $OWNER"
recorded=1

if exists "$LIVE"; then
  mv "$LIVE" "$PARKED" || die "could not park $LIVE"
  echo "park-claude-md: parked $LIVE; Claude Code sessions started before it is restored run without it." >&2
elif [ "$none_ok" -eq 0 ]; then
  die "$LIVE does not exist and no park lock explains it; another tool may have moved it. Pass --none-ok if this machine has no user-level CLAUDE.md."
fi

# The command gets a process group of its own when perl is there to
# set one up, so arms it starts and leaves running can still be found
# after it exits, when they no longer descend from anything here. A
# command in a group of its own is stopped by the terminal if it reads
# from it, including through /dev/tty, so the group is used only where
# there is no controlling terminal: a headless batch, where arms are
# left running unseen. Attached to a terminal, the command shares this
# script's group and arms it leaves running cannot be found.
if command -v perl >/dev/null && ! (: </dev/tty) 2>/dev/null; then
  own_group=1
  CLAUDE_MD_PARK_HOLDER=$$ perl -e 'setpgrp(0, 0) or warn "park-claude-md: no process group of its own ($!); arms left running will not be found\n"; exec { $ARGV[0] } @ARGV or do { print STDERR "park-claude-md: cannot run $ARGV[0]: $!\n"; exit($!{ENOENT} ? 127 : 126) }' -- "$@" <&0 &
else
  if (: </dev/tty) 2>/dev/null; then
    echo "park-claude-md: attached to a terminal, so arms the command leaves running when it exits will not be stopped; have the batch wait for them." >&2
  fi
  CLAUDE_MD_PARK_HOLDER=$$ "$@" <&0 &
fi
child=$!
# bash's own report of a command killed by a signal quotes the whole
# launch line, perl wrapper included, so it is silenced and replaced
# with one that names the command.
wait "$child" 2>/dev/null
status=$?
if [ "$status" -gt 128 ] && signal="$(kill -l $((status - 128)) 2>/dev/null)"; then
  echo "park-claude-md: $1 ended by signal $signal" >&2
fi
command_done=1
stop_leftovers
child=
finish "$status"
