#!/bin/bash
# ui-dump.sh — snapshot the current screen's accessibility tree:
#   ui.xml       raw uiautomator XML (the "exact screen UI" an agent can read)
#   screen.json  structured JSON model (all nodes + bounds + center)
#   screen.txt   condensed indexed listing (feed to an agent's context)
#   focus.txt    current focused window
#
# Android side is ONE broadcast using a FIXED path (/sdcard/.uic.xml) that gets
# overwritten every run — no cleanup broadcast needed. If the dump misses the
# window (manager crash-relay timeout / animating screen), it retries with fresh
# broadcasts; judge the result yourself, don't read too much into a timeout.
#
# Usage: bash ui-dump.sh [OUTDIR]   (default /tmp/shizuku-skill/ui)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"
PARSE="$SCRIPT_DIR/ui_parse.py"
OUT="${1:-/tmp/shizuku-skill/ui}"
mkdir -p "$OUT"

# first attempt: wake + capture focus + dump in one broadcast
"$RISH" -c '
input keyevent KEYCODE_WAKEUP 2>/dev/null
echo "FOCUS: $(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)"
uiautomator dump /sdcard/.uic.xml 2>&1
' > "$OUT/tmp.out" 2>&1

ok=0
for i in 1 2 3 4 5 6; do
  # DANGER: uiautomator dump can FAIL (animating/secure/manager cold-start) yet leave
  # the PREVIOUS .uic.xml on disk — an "RC=0 && file exists" test then happily reads
  # a STALE tree and you tap the wrong thing. Only trust a dump whose own output
  # says "dumped to".
  if grep -q "dumped to" "$OUT/tmp.out" && [ -s /mnt/sdcard/.uic.xml ]; then ok=1; break; fi
  sleep 2
  "$RISH" -c 'uiautomator dump /sdcard/.uic.xml 2>&1' > "$OUT/tmp.out" 2>&1
done
if [ "$ok" != 1 ]; then
  echo "ERR: dump failed after 6 broadcasts (manager cold-start / secure window / animating?)"
  cat "$OUT/tmp.out"
  exit 1
fi

if grep -q "FOCUS: Window" "$OUT/tmp.out"; then grep "FOCUS:" "$OUT/tmp.out" > "$OUT/focus.txt"; fi
cp /mnt/sdcard/.uic.xml "$OUT/ui.xml"
md5sum "$OUT/ui.xml" > "$OUT/ui.md5.proot"
python3 "$PARSE" "$OUT/ui.xml" "$OUT/screen.json" | tee "$OUT/screen.txt"
echo "artifacts: $OUT/{ui.xml,screen.json,screen.txt,focus.txt}"