#!/bin/bash
# NotchDial status reporter — usage: notchdial-status.sh <working|done|clear> [slug]
#
# The agent knows exactly when a turn begins and ends; nothing NotchDial can
# observe from outside is as good as being told. UserPromptSubmit -> working,
# Stop -> done, and the whole span between them — every tool call, every retry —
# stays "working", which is the one thing sampling a UI can never get right.
#
# One app runs several sessions at once, so each session reports into its own
# file (<slug>.<session-id>) and NotchDial aggregates: any session working means
# the app is working. Sharing one file meant whichever session finished first
# wrote "done" over the others and the notch stopped showing live work.
#
# Runs async, so it never delays the turn it is reporting on. Exits 0 always: a
# status indicator has no business failing anyone's session.

set -u
state="${1:-}"
slug="${2:-${NOTCHDIAL_SLUG:-claude-code}}"
dir="${NOTCHDIAL_STATUS_DIR:-$HOME/.notchdial/status}"

# The slug becomes a path component, and this script's environment is inherited
# from the agent — which a checked-in project config can influence. Without this,
# a slug of "../../.zshrc" is an arbitrary-file truncate: the word we write is
# fixed, but the file it lands in would not be ours to choose.
sanitize() {
  case "$1" in
    ""|.|..|*[!a-zA-Z0-9._-]*|.*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}
slug=$(sanitize "$slug" "claude-code")
case "$dir" in
  ""|*/..|*/../*) exit 0 ;;
esac

# Hooks receive their event as JSON on stdin; session_id is what separates one
# concurrent session from another. Falling back to the ppid keeps sessions apart
# even when the payload is missing or unparseable.
sid=""
if [ ! -t 0 ]; then
  # head -c, not cat: bounded, and present everywhere. (macOS has no `timeout`.)
  payload=$(head -c 65536 2>/dev/null || true)
  sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]\{1,64\}\)".*/\1/p' | head -1)
fi
[ -z "$sid" ] && sid="p$PPID"
sid=$(sanitize "$sid" "p$PPID")

mkdir -p "$dir" 2>/dev/null || exit 0
f="$dir/$slug.$sid"

case "$state" in
  working|done)
    printf '%s\n' "$state" > "$f" 2>/dev/null
    ;;
  clear)
    # This session is gone; leaving a stale "working" behind would strand a
    # spinner in the notch until the 30-minute staleness cutoff caught it.
    # A "done" nobody has looked at yet is left exactly where it is.
    [ "$(head -c 16 "$f" 2>/dev/null | tr -d '[:space:]')" = "working" ] && rm -f "$f" 2>/dev/null
    ;;
esac

exit 0
