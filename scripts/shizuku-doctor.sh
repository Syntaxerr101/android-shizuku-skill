#!/usr/bin/env bash
# shizuku-doctor.sh — read-only Shizuku health report.
#
# Usage: bash shizuku-doctor.sh [--full]
#
# A single rish session collects identity, server state, authorization, crash
# history and capability probes. Nothing is modified. Everything is derived at
# runtime, so the report is valid on any device/ROM.
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
need_rish

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

PKG=moe.shizuku.privileged.api
BODY='
PKG=moe.shizuku.privileged.api
echo "==== SHELL IDENTITY ===="
id
echo
echo "==== DEVICE (runtime) ===="
echo "$(getprop ro.product.manufacturer) $(getprop ro.product.model)"
echo "Android $(getprop ro.build.version.release) SDK $(getprop ro.build.version.sdk) patch $(getprop ro.build.version.security_patch) abi $(getprop ro.product.cpu.abi)"
echo
echo "==== SHIZUKU PACKAGE ===="
dumpsys package $PKG 2>/dev/null | grep -E "versionName|versionCode|codePath|primaryCpuAbi|userId=" | head -8
echo
echo "==== SERVER / MANAGER PROCESSES ===="
ps -A 2>/dev/null | grep -E "shizuku_server|$PKG" | grep -v grep || echo "none"
pidof shizuku_server >/dev/null 2>&1 && echo "shizuku_server: UP" || echo "shizuku_server: DOWN"
echo
echo "==== WIRELESS DEBUGGING FLAGS ===="
echo "adb_wifi_enabled=$(settings get global adb_wifi_enabled 2>/dev/null) adb_enabled=$(settings get global adb_enabled 2>/dev/null)"
echo
echo "==== AUTHORIZATION (shizuku.json) ===="
JSON=/data/user_de/0/com.android.shell/shizuku.json
ls -l "$JSON" 2>&1
cat "$JSON" 2>&1
echo
echo "==== MANAGER EXIT HISTORY (first 20 lines) ===="
dumpsys activity exit-info $PKG 2>/dev/null | sed -n "1,20p"
echo
echo "==== WRITE_SECURE_SETTINGS ===="
dumpsys package $PKG 2>/dev/null | grep -A1 "WRITE_SECURE_SETTINGS" | head -4
echo
echo "==== BINDER SANITY (expected: not found; server is binderless) ===="
service check shizuku 2>&1
'
if [ "$FULL" = 1 ]; then
  BODY="$BODY"'
echo
echo "==== CRASH BUFFER (tail) ===="
logcat -b crash -d -v brief 2>/dev/null | tail -20
echo
echo "==== DROPBOX (recent) ===="
dumpsys dropbox 2>/dev/null | head -5
echo
echo "==== ANR / TOMBSTONES ===="
ls -la /data/anr 2>/dev/null | head -6
ls -la /data/tombstones 2>/dev/null | head -6
'
fi

echo "==== RISH RUNTIME (host side) ===="
for f in "$SKILL_ROOT/bin/rish" "$SKILL_ROOT/bin/rish_shizuku.dex"; do
  if [ -f "$f" ]; then
    printf '%s  %s bytes  mode=%s\n' "$f" "$(wc -c < "$f")" "$(stat -c %a "$f" 2>/dev/null || echo '?')"
  else
    printf '%s  MISSING\n' "$f"
  fi
done
echo

RISH_DEBUG=1 "$RISH" -c "$BODY" 2>&1
rc=$?
echo
echo "Doctor done (rc=$rc)."
exit "$rc"
