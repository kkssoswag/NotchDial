#!/bin/bash
# NotchDial status reporter.
#
# Claude Code knows exactly when a turn begins and ends; nothing NotchDial can
# observe from the outside is as good as being told. UserPromptSubmit -> working,
# Stop -> done, and the whole span between them — every tool call, every retry —
# stays "working", which is the one thing sampling a UI can never get right.
#
# Runs async, so it never delays the turn it is reporting on. Exits 0 always: a
# status indicator has no business failing anyone's session.

set -u
dir="${NOTCHDIAL_STATUS_DIR:-$HOME/.notchdial/status}"
slug="${NOTCHDIAL_SLUG:-claude-code}"
state="${1:-}"

mkdir -p "$dir" 2>/dev/null || exit 0

case "$state" in
  working|done)
    printf '%s\n' "$state" > "$dir/$slug" 2>/dev/null
    ;;
  clear)
    # The session is gone; leaving a stale "working" behind would strand a
    # spinner in the notch until the 30-minute staleness cutoff caught it.
    [ "$(cat "$dir/$slug" 2>/dev/null)" = "working" ] && rm -f "$dir/$slug" 2>/dev/null
    ;;
esac

exit 0
