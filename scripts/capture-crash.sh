#!/bin/bash
# android-shizuku-skill: capture crash evidence for any package (default: Shizuku manager).
#
# Usage:
#   bash capture-crash.sh                     # dump current crash buffers (read-only)
#   bash capture-crash.sh --repro [PKG]       # force-stop + background + one rish trigger,
#                                             # then dump. Only kills the target APP process.
#   bash capture-crash.sh PKG [OUTDIR]        # read-only capture for a specific package
#
# NOTE (Shizuku manager): the FGS crash this reproduces requires the manager's
# "Start on boot (wireless ADB)" preference to be ON and the phone on Wi-Fi. If you
# ran scripts/shizuku-disable-selfstart.sh (the fix), the crash cannot fire here —
# re-enable it first with `shizuku-disable-selfstart.sh --enable`, reproduce, then
# turn it OFF again. See references/troubleshooting.md §1.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"

REPRO=0
PKG="moe.shizuku.privileged.api"
for a in "$@"; do
  case "$a" in
    --repro) REPRO=1 ;;
    -*) echo "unknown flag: $a"; exit 2 ;;
    *) PKG="$a" ;;
  esac
done
OUTDIR="/tmp/shizuku-skill/captures"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ "$REPRO" = 1 ]; then
  echo "[repro] force-stop $PKG (app process only; shizuku_server survives)"
  "$RISH" -c "am force-stop $PKG" >/dev/null 2>&1
  sleep 1
  "$RISH" -c 'input keyevent KEYCODE_HOME' >/dev/null 2>&1
  sleep 1
  "$RISH" -c 'logcat -c' >/dev/null 2>&1
  echo "[repro] triggering REQUEST_BINDER (up to 5 tries; Android 15 FGS crash is intermittent)"
  caught=0
  for i in 1 2 3 4 5; do
    "$RISH" -c 'echo TRIGGERED' >/dev/null 2>&1
    sleep 2
    n=$("$RISH" -c "logcat -b crash -d 2>/dev/null | grep -c '$PKG' | tr -d ' '")
    if [ "${n:-0}" -gt 0 ]; then caught=1; echo "[repro] fresh crash captured on try $i"; break; fi
  done
  [ "$caught" = 0 ] && echo "[repro] NOTE: no fresh crash in window this run — expected if the manager's 'Start on boot (wireless ADB)' pref is OFF (run shizuku-disable-selfstart.sh --enable first), if you're off Wi-Fi, or just intermittent by design; exit-info below still shows the force-stop + history"
fi

{
  echo "### exit-info $PKG"
  "$RISH" -c "dumpsys activity exit-info $PKG 2>/dev/null | sed -n '1,18p'"
} > "$OUTDIR/$STAMP-exitinfo.txt"

{
  echo "### crash buffer (grep $PKG)"
  "$RISH" -c "logcat -b crash -d -v threadtime 2>/dev/null | grep -A25 $PKG | tail -40"
} > "$OUTDIR/$STAMP-crashbuf.txt"

{
  echo "### dropbox ($PKG)"
  "$RISH" -c "dumpsys dropbox --print 2>/dev/null | grep -A10 -B2 $PKG | head -60"
} > "$OUTDIR/$STAMP-dropbox.txt"

{
  echo "### process state"
  "$RISH" -c 'ps -A 2>/dev/null | grep -iE "shizuku_server|moe.shizuku" | grep -v grep'
} > "$OUTDIR/$STAMP-proc.txt"

echo "Captured:"
ls -la "$OUTDIR"/*"$STAMP"* 2>/dev/null
echo
echo "Hint: read exit-info reason codes = 4=APP CRASH, 1=ANR, 3=LOW_MEMORY, 9=SIGNALED, 10=USER REQUESTED"