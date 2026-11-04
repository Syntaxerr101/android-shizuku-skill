#!/usr/bin/env bash
# capture-crash.sh — collect crash evidence for any package (read-only by default).
#
# Usage:
#   bash capture-crash.sh [PKG] [OUTDIR]
#   bash capture-crash.sh --repro [PKG] [OUTDIR]
#
# PKG defaults to the Shizuku manager (moe.shizuku.privileged.api).
#
# --repro force-stops PKG's APP process (never the Shizuku server), triggers one
# rish call, and captures only log lines generated after the baseline. It does
# NOT clear logcat, so unrelated evidence is preserved. The Shizuku manager FGS
# crash only fires when its "start on boot (wireless ADB)" preference is ON and
# the device is on Wi-Fi; see references/troubleshooting.md.
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
need_rish

REPRO=0
PKG=moe.shizuku.privileged.api
OUT=$CAPTURE_OUT
ARGS=()
for a in "$@"; do
  case "$a" in
    --repro) REPRO=1 ;;
    -*) echo "ERR: unknown flag: $a" >&2; exit 2 ;;
    *) ARGS+=("$a") ;;
  esac
done
case ${#ARGS[@]} in
  0) ;;
  1) PKG=${ARGS[0]} ;;
  *) PKG=${ARGS[0]}; OUT=${ARGS[1]} ;;
esac
case "$PKG" in ''|*[!A-Za-z0-9_.]*) echo "ERR: invalid package name" >&2; exit 2 ;; esac
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M%S)

baseline=$("$RISH" -c 'logcat -b crash -d 2>/dev/null | wc -l' 2>/dev/null | tr -dc '0-9')
baseline=${baseline:-0}
echo "[baseline] crash buffer lines: $baseline"

if [ "$REPRO" = 1 ]; then
  echo "[repro] force-stop $PKG (app process only; shizuku_server is untouched)"
  "$RISH" -c "am force-stop '$PKG'" >/dev/null 2>&1
  sleep 1
  "$RISH" -c 'input keyevent KEYCODE_HOME' >/dev/null 2>&1
  sleep 1
  echo "[repro] triggering one rish call (up to 5 tries)"
  caught=0
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    "$RISH" -c 'echo TRIGGERED' >/dev/null 2>&1
    sleep 2
    now=$("$RISH" -c 'logcat -b crash -d 2>/dev/null | wc -l' 2>/dev/null | tr -dc '0-9')
    now=${now:-0}
    if [ "$now" -gt "$baseline" ]; then
      caught=1
      echo "[repro] new crash buffer lines after try $i (total $now)"
      break
    fi
  done
  if [ "$caught" = 0 ]; then
    echo "[repro] no new crash lines. Expected when the manager pref is OFF,"
    echo "        the device is not on Wi-Fi, or the crash is intermittent."
  fi
fi

echo "[capture] exit-info / crash / dropbox / processes / signatures"
CAP_DEV="$ANDROID_TMP/.capture.$$"
"$RISH" -c "
PKG='$PKG'
{
echo '### exit-info'
dumpsys activity exit-info \"\$PKG\" 2>/dev/null | sed -n '1,30p'
echo
echo '### crash buffer (new since baseline $baseline)'
logcat -b crash -d -v threadtime 2>/dev/null | tail -n +$((baseline + 1)) | grep -A30 \"\$PKG\" | tail -60
echo
echo '### crash buffer (signatures, last 80)'
logcat -b crash -d -v brief 2>/dev/null | grep -E 'FATAL EXCEPTION|ForegroundServiceStartNotAllowedException|NoSuchMethodError|Process:' | tail -80
echo
echo '### dropbox'
dumpsys dropbox --print 2>/dev/null | grep -A12 -B2 \"\$PKG\" | head -80
echo
echo '### processes'
ps -A 2>/dev/null | grep -E 'shizuku_server|\$PKG' | grep -v grep
} > '$CAP_DEV' 2>&1
" >/dev/null 2>&1
if ! device_get_file "$CAP_DEV" "$OUT/$STAMP-evidence.txt"; then
  echo "ERR: could not transfer crash evidence" >&2
  exit 1
fi
"$RISH" -c "rm -f '$CAP_DEV'" >/dev/null 2>&1 || true

cp "$OUT/$STAMP-evidence.txt" "$OUT/$STAMP-exitinfo.txt" 2>/dev/null || true
{
  echo "### crash buffer (new since baseline $baseline)"
  sed -n '/### crash buffer (new/,/### crash buffer (signatures/p' "$OUT/$STAMP-evidence.txt" | sed '1d;$d'
} > "$OUT/$STAMP-crashbuf.txt"
{
  echo "### dropbox"
  sed -n '/### dropbox/,/### processes/p' "$OUT/$STAMP-evidence.txt" | sed '1d;$d'
} > "$OUT/$STAMP-dropbox.txt"

echo
echo "Captured:"
ls -l "$OUT"/*"$STAMP"* 2>/dev/null
echo
echo "Reason codes: 1=EXIT_SELF 2=SIGNALED 3=LOW_MEMORY 4=CRASH 5=NATIVE_CRASH 6=ANR 10=USER_REQUESTED 13=OTHER"
echo "Read: $OUT/$STAMP-evidence.txt"
