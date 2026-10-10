#!/bin/bash
# android-shizuku-skill: read-only Shizuku health report.
# Usage: bash shizuku-doctor.sh [--full]
#
# One rish invocation (=> one REQUEST_BINDER broadcast), then nothing else.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"

if [ ! -x "$RISH" ]; then
  echo "ERR: rish wrapper missing: $RISH"; exit 1
fi

BODY='
echo "==== IDENTITY ===="
id
echo
echo "==== DEVICE ===="
echo "$(getprop ro.product.manufacturer) $(getprop ro.product.model) | Android $(getprop ro.build.version.release) SDK $(getprop ro.build.version.sdk) | patch $(getprop ro.build.version.security_patch)"
echo
echo "==== SHIZUKU PACKAGE ===="
dumpsys package moe.shizuku.privileged.api 2>/dev/null | grep -E "versionName|versionCode|codePath|primaryCpuAbi" | head -6
echo
echo "==== PROCESSES ===="
ps -A 2>/dev/null | grep -iE "shizuku_server|moe.shizuku" | grep -v grep || echo "none running"
pidof shizuku_server >/dev/null 2>&1 && echo "shizuku_server: UP" || echo "shizuku_server: DOWN"
echo
echo "==== WIRELESS / SETTINGS ===="
echo "adb_wifi_enabled=$(settings get global adb_wifi_enabled)  adb_enabled=$(settings get global adb_enabled)"
echo
echo "==== AUTHORIZED APPS (shizuku.json) ===="
cat /data/user_de/0/com.android.shell/shizuku.json 2>&1
echo
echo "==== LATEST EXIT-INFO (manager, first 8 lines) ===="
dumpsys activity exit-info moe.shizuku.privileged.api 2>/dev/null | sed -n "1,8p"
echo
echo "==== MANAGER PERMISSIONS (WRITE_SECURE_SETTINGS) ===="
dumpsys package moe.shizuku.privileged.api 2>/dev/null | grep "WRITE_SECURE_SETTINGS" | head -4
echo
echo "==== BINDER SANITY (expected: not found) ===="
service check shizuku 2>&1
'
if [ "${1:-}" = "--full" ]; then
  BODY="$BODY"'
echo
echo "==== CRASH BUFFER (tail) ===="
logcat -b crash -d -v brief 2>/dev/null | tail -12
echo
echo "==== DROPBOX ===="
dumpsys dropbox 2>/dev/null | head -3
echo
echo "==== ANR / TOMBSTONES ===="
ls -la /data/anr 2>/dev/null | head -5
ls -la /data/tombstones 2>/dev/null | head -5
'
fi

"$RISH" -c "$BODY" 2>&1
echo
echo "Doctor done."