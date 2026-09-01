#!/bin/bash
# NotchDial status reporter — usage: notchdial-status.sh <working|done|clear> [slug]
#
# The agent knows exactly when a turn begins and ends; nothing NotchDial can
# observe from outside is as good as being told. UserPromptSubmit -> working,
# Stop -> done, and the whole span between them — every tool call, every retry —
# stays "working", which is the one thing sampling a UI can never get right.
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
case "$slug" in
  ""|.|..|*[!a-z0-9._-]*|.*) slug="claude-code" ;;
esac
case "$dir" in
  ""|*/..|*/../*) exit 0 ;;
esac

mkdir -p "$dir" 2>/dev/null || exit 0
f="$dir/$slug"

case "$state" in
  working|done)
    printf '%s\n' "$state" > "$f" 2>/dev/null
    ;;
  clear)
    # The session is gone; leaving a stale "working" behind would strand a
    # spinner in the notch until the 30-minute staleness cutoff caught it.
    # A "done" nobody has looked at yet is left exactly where it is.
    [ "$(head -c 16 "$f" 2>/dev/null | tr -d '[:space:]')" = "working" ] && rm -f "$f" 2>/dev/null
    ;;
esac

exit 0
