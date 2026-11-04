#!/usr/bin/env bash
# ui-wait.sh — poll the screen until a predicate holds (the CONFIRM primitive).
#
# Use after an action to prove the device really changed state. Never trust an
# input command's exit code as success.
#
# Usage: bash ui-wait.sh <predicate> [timeout_s] [OUTDIR]
#   text:<sub>   any visible text/content-desc contains sub (case-insensitive)
#   gone:<sub>   no text/content-desc contains sub
#   pkg:<pkg>    foreground package equals pkg (or a sub-package of it)
#
# Each round is a full rish session + one uiautomator dump, so use a realistic
# timeout (default 15 s). Only dumps that uiautomator itself confirms are read.
# Exit 0 when the predicate holds, 1 on timeout (last snapshot is kept).
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PRED=${1:-}
TIMEOUT=${2:-15}
OUT=${3:-$UI_OUT}
T=$OUT/.wait
[ -n "$PRED" ] || { echo "usage: ui-wait.sh text:<s>|gone:<s>|pkg:<p> [timeout_s] [outdir]" >&2; exit 2; }
case "$PRED" in text:*|gone:*|pkg:*) ;; *) echo "ERR: unknown predicate" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=15 ;; esac
mkdir -p "$T"
need_rish

start=$(date +%s)
deadline=$((start + TIMEOUT))
while :; do
  if ui_dump_to "$T/wait.xml"; then
    if "$PY" "$SCRIPT_DIR/ui_wait_check.py" "$T/wait.xml" "$PRED" >/dev/null 2>&1; then
      echo "OK: $PRED (t=$(( $(date +%s) - start ))s)"
      exit 0
    fi
  fi
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "TIMEOUT after ${TIMEOUT}s waiting for '$PRED' — last snapshot: $T/wait.xml"
    exit 1
  fi
  sleep 1
done
