#!/usr/bin/env bash
# ui-dump.sh — snapshot the current screen's accessibility tree.
#
# Produces (default OUTDIR = $TMPDIR/shizuku-skill/ui):
#   ui.xml       raw uiautomator XML
#   screen.json  structured model (all nodes, bounds, centers)
#   screen.txt   compact indexed listing for an agent
#   focus.txt    current focused window (when available)
#
# Transport: one rish session dumps and copies the XML to shared storage, then
# the host reads it and checks md5. When shared storage is not visible to the
# host (e.g. native Termux before `termux-setup-storage`), it falls back to a
# verified gzip+base64 chunked transfer. See `device_get_file` in lib.sh.
# A dump is trusted only when uiautomator says "dumped to"; a failed dump can
# leave the previous file in place, and acting on that stale tree taps the wrong
# thing.
#
# Usage: bash ui-dump.sh [OUTDIR]
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
OUT=${1:-$UI_OUT}
mkdir -p "$OUT"

need_rish
if ! ui_dump_to "$OUT/ui.xml"; then
  echo "ERR: could not obtain a fresh UI dump" >&2
  exit 1
fi

printf '%s\n' "$UI_DUMP_RAW" | grep '^FOCUS:' | head -n1 > "$OUT/focus.txt" || true

"$PY" "$SCRIPT_DIR/ui_parse.py" "$OUT/ui.xml" "$OUT/screen.json" | tee "$OUT/screen.txt"
echo "artifacts: $OUT/{ui.xml,screen.json,screen.txt,focus.txt}"
