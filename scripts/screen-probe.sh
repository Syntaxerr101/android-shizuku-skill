#!/usr/bin/env bash
# screen-probe.sh — screenshot + accessibility tree, pulled into the host.
#
# Usage: bash screen-probe.sh [OUTDIR]
#
# Captures, in one rish session:
#   sz_screen.png   screenshot
#   sz_ui.xml       uiautomator hierarchy
#   screen.txt      compact node listing (printed)
#
# Transfer uses shared storage when the host can see it, otherwise a verified
# gzip+base64 chunked fallback. The UI dump is accepted only when uiautomator
# confirms it; a stale tree is never used.
#
# UI_LINES=N limits the node listing (default 40).
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
OUT=${1:-$WORK_DIR}
mkdir -p "$OUT"
need_rish

PNG="$OUT/sz_screen.png"
XML="$OUT/sz_ui.xml"
ROOT=$(shared_root 2>/dev/null || true)

raw=""
if [ -n "$ROOT" ]; then
  rm -f "$ROOT/$SHARED_SUBDIR/.sz.png" "$ROOT/$SHARED_SUBDIR/.sz.xml" 2>/dev/null || true
  raw=$(rish_c_t 60 "
rm -f $ANDROID_TMP/.sz.png $ANDROID_TMP/.sz.xml 2>/dev/null
screencap -p $ANDROID_TMP/.sz.png || exit 3
uiautomator dump $ANDROID_TMP/.sz.xml 2>&1 || exit 5
[ -s $ANDROID_TMP/.sz.png ] || exit 4
[ -s $ANDROID_TMP/.sz.xml ] || exit 5
cp -f $ANDROID_TMP/.sz.png '$ROOT/$SHARED_SUBDIR/.sz.png' 2>/dev/null || exit 6
cp -f $ANDROID_TMP/.sz.xml '$ROOT/$SHARED_SUBDIR/.sz.xml' 2>/dev/null || exit 7
echo P:\$(md5sum '$ROOT/$SHARED_SUBDIR/.sz.png' | cut -d' ' -f1)
echo U:\$(md5sum '$ROOT/$SHARED_SUBDIR/.sz.xml' | cut -d' ' -f1)
echo XFER_OK
" 2>&1) || true

  p_want=$(printf '%s\n' "$raw" | sed -n 's/^P:\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | tail -n1)
  u_want=$(printf '%s\n' "$raw" | sed -n 's/^U:\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | tail -n1)
  case "$raw" in
    *"dumped to"*XFER_OK*) ;;
    *) raw="" ;;
  esac
  if [ -n "$raw" ] \
     && cp -f "$ROOT/$SHARED_SUBDIR/.sz.png" "$PNG" 2>/dev/null \
     && cp -f "$ROOT/$SHARED_SUBDIR/.sz.xml" "$XML" 2>/dev/null \
     && [ "$(md5sum "$PNG" 2>/dev/null | cut -d' ' -f1)" = "$p_want" ] \
     && [ "$(md5sum "$XML" 2>/dev/null | cut -d' ' -f1)" = "$u_want" ]; then
    :
  else
    raw=""
  fi
  rm -f "$ROOT/$SHARED_SUBDIR/.sz.png" "$ROOT/$SHARED_SUBDIR/.sz.xml" 2>/dev/null || true
fi

if [ -z "$raw" ]; then
  # Fallback: capture on-device, then transfer each artifact separately.
  raw=$(rish_c_t 60 "
rm -f $ANDROID_TMP/.sz.png $ANDROID_TMP/.sz.xml 2>/dev/null
screencap -p $ANDROID_TMP/.sz.png || exit 3
uiautomator dump $ANDROID_TMP/.sz.xml 2>&1 || exit 5
[ -s $ANDROID_TMP/.sz.png ] || exit 4
[ -s $ANDROID_TMP/.sz.xml ] || exit 5
echo CAPTURE_OK
" 2>&1) || {
    echo "ERR: capture failed" >&2
    printf '%s\n' "$raw" >&2
    exit 1
  }
  case "$raw" in
    *"dumped to"*CAPTURE_OK*) ;;
    *) echo "ERR: capture output incomplete" >&2; printf '%s\n' "$raw" | head -20 >&2; exit 1 ;;
  esac
  device_get_file "$ANDROID_TMP/.sz.png" "$PNG" "" || { echo "ERR: screenshot transfer failed" >&2; exit 1; }
  device_get_file "$ANDROID_TMP/.sz.xml" "$XML" "" || { echo "ERR: UI dump transfer failed" >&2; exit 1; }
fi

[ -s "$PNG" ] || { echo "ERR: screenshot decode failed" >&2; exit 1; }
[ -s "$XML" ] || { echo "ERR: UI dump decode failed" >&2; exit 1; }

echo "=== artifacts ==="
ls -l "$PNG" "$XML"
echo
echo "=== nodes ==="
"$PY" "$SCRIPT_DIR/ui_parse.py" "$XML" "$OUT/screen.json" > "$OUT/screen.txt" || true
head -n "${UI_LINES:-40}" "$OUT/screen.txt"
echo
echo "Tap example: bash \"$SCRIPT_DIR/ui-act.sh\" tap xy:<x>,<y>"
