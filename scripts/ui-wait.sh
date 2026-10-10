#!/bin/bash
# ui-wait.sh — poll the screen until a predicate holds (the CONFIRM primitive).
# Pair it with ui-act.sh: act → ui-wait → branch on exit code. This is how you
# verify the device actually did what you asked; never trust the action exit code.
# (Run shizuku-disable-selfstart.sh once to stop the manager's Android 15 FGS crash;
# with the pref left on it can crash mid-relay, harmless — shizuku_server survives.)
#
# Usage: ui-wait.sh <predicate> [timeout_s=12] [OUTDIR]
#   text:<sub>   true if any node text/content-desc contains sub (case-insensitive)
#   gone:<sub>   true if no node contains sub
#   pkg:<pkg>    true if the current UI's package == pkg
#
# Each round = one broadcast to the fixed path /sdcard/.uiw.xml (overwritten, no
# cleanup needed). WARNING: every round is a FULL rish session (~4 s) + a dump
# (~3 s), so a timeout of 12 s means only ~1-2 rounds. Only a dump whose output
# says "dumped to" is trusted — otherwise the previous file lingers and you judge
# a stale screen. For cheap one-shot verifies prefer ui-fast.sh (verifies inside
# the same session as the action). Exit 0 when it holds, 1 on timeout (last
# snapshot kept for inspection).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"
CHECK="$SCRIPT_DIR/ui_wait_check.py"
OUT="${3:-/tmp/shizuku-skill/ui}"
T="$OUT/.wait"
PRED="${1:-}"; TIMEOUT="${2:-12}"
[ -n "$PRED" ] || { echo "usage: ui-wait.sh text:<s>|gone:<s>|pkg:<p> [timeout_s]"; exit 2; }
mkdir -p "$T"

start=$(date +%s)
while :; do
  now=$(date +%s)
  if [ $((now-start)) -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${TIMEOUT}s waiting for '$PRED' — last snapshot: $T/wait.xml"
    exit 1
  fi
  "$RISH" -c 'uiautomator dump /sdcard/.uiw.xml 2>&1' > "$T/out" 2>&1
  if grep -q "dumped to" "$T/out" && [ -s /mnt/sdcard/.uiw.xml ]; then
    cp /mnt/sdcard/.uiw.xml "$T/wait.xml"
    if [ "$(python3 "$CHECK" "$T/wait.xml" "$PRED")" = "YES" ]; then
      echo "OK: $PRED (t=$((now-start))s)"
      exit 0
    fi
  fi
  sleep 1
done