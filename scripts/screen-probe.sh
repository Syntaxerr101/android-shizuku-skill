#!/bin/bash
# android-shizuku-skill: screen-probe — screenshot + UI hierarchy pulled into PRoot.
#
# Usage:
#   bash screen-probe.sh [OUTDIR]
#
# Takes a fresh screenshot AND dumps the accessibility UI tree, then pulls both
# into OUTDIR (default /tmp/shizuku-skill) via the verified /sdcard <-> /mnt/sdcard
# channel, and prints the clickable/text nodes so you can compute tap targets.
# Artifacts are removed from the device's shared storage afterwards.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"
OUT="${1:-/tmp/shizuku-skill}"
mkdir -p "$OUT"

"$RISH" -c 'screencap -p /sdcard/.sz_screen.png && uiautomator dump /sdcard/.sz_ui.xml >/dev/null 2>&1; echo DONE' || { echo "ERR: rish screencap failed"; exit 1; }

# md5 on both sides to prove a clean transfer
"$RISH" -c 'md5sum /sdcard/.sz_screen.png /sdcard/.sz_ui.xml' > "$OUT/md5.android" 2>/dev/null
cp /mnt/sdcard/.sz_screen.png "$OUT/sz_screen.png" 2>/dev/null || { echo "ERR: pull failed"; exit 1; }
cp /mnt/sdcard/.sz_ui.xml   "$OUT/sz_ui.xml"   2>/dev/null
md5sum "$OUT/sz_screen.png" "$OUT/sz_ui.xml" > "$OUT/md5.proot"

echo "=== artifacts ==="
ls -l "$OUT"/sz_screen.png "$OUT"/sz_ui.xml
echo "=== md5 (Android side vs PRoot side) ==="
echo "-- android: --"; cat "$OUT/md5.android" 2>/dev/null
echo "-- proot:   --"; cat "$OUT/md5.proot"

echo
echo "=== clickable / text nodes ==="
sed 's/<node/\n<node/g' "$OUT/sz_ui.xml" 2>/dev/null \
  | grep -oE '(text|content-desc)="[^"]+[^"]"|class="android.widget.[A-Za-z]+"|bounds="\[[0-9,]+\]\[[0-9,]+\]"' \
  | grep -v 'text=""' | paste -sd' ' | fold -w 100 | head -${UI_LINES:-25}
echo "(empty list = nothing clickable/textual on screen)"

# cleanup on-device temp files (tolerant: timeout is fine, files are hidden)
"$RISH" -c 'rm -f /sdcard/.sz_screen.png /sdcard/.sz_ui.xml' >/dev/null 2>&1 || true
echo
echo "Hint: tap a node via:  \"$RISH\" -c 'input tap CX CY'"