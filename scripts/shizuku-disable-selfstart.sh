#!/bin/bash
# android-shizuku-skill: disable the manager's "Start on boot (wireless ADB)" preference.
#
# WHY: that preference is the root cause of the Android 15 Shizuku manager crash
# (reason=4, ForegroundServiceStartNotAllowedException). When it is true, EVERY
# REQUEST_BINDER broadcast (i.e. every rish call) makes ShizukuReceiver run the
# wireless branch; while on Wi-Fi it then calls
# rikka.shizuku.f7.j() == Context.startForegroundService(SelfStarterService) from a
# background receiver, which Android 15 forbids -> uncaught exception -> the
# manager app process dies. Turning the pref OFF makes the receiver return before
# that call, so *no* rish call can ever crash the manager again.
#
# Derived from the installed APK (13.6.1-RC2.r1171.f8c7bafa); see
# references/troubleshooting.md §1 and references/logs-and-crashes.md §4.
#
# This is a one-time, reversible, user-visible settings change (the same toggle a
# human would flip in Settings). It does NOT touch shizuku.json, the server, or
# any signature (no repack). Regression: after a reboot the manager will no longer
# auto-start the server over wireless ADB; start it from the manager UI if needed.
#
# Usage:
#   bash shizuku-disable-selfstart.sh            # disable (default)
#   bash shizuku-disable-selfstart.sh --status   # only report current state
#   bash shizuku-disable-selfstart.sh --enable   # re-enable (restores auto-start)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${UI_OUT:-/tmp/shizuku-skill/ui}"
LABEL="Start on boot (wireless ADB)"
PKG="moe.shizuku.privileged.api"
MAIN="moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity"

MODE="disable"
case "${1:-}" in
  --status) MODE="status" ;;
  --enable) MODE="enable" ;;
  --disable|"") MODE="disable" ;;
  *) echo "usage: $0 [--status|--disable|--enable]"; exit 2 ;;
esac

open_settings() {
  # open MainActivity (exported), then tap its top-right Settings icon
  local attempt i
  for attempt in 1 2 3; do
    for i in 1 2 3; do
      "$SCRIPT_DIR/ui-act.sh" launch "$MAIN" >/dev/null 2>&1
      sleep 3
      "$SCRIPT_DIR/ui-wait.sh" pkg:"$PKG" 8 >/dev/null 2>&1 && break
    done
    bash "$SCRIPT_DIR/ui-dump.sh" "$OUT" >/dev/null 2>&1
    "$SCRIPT_DIR/ui-act.sh" tap 'text:Settings' >/dev/null 2>&1
    sleep 2
    bash "$SCRIPT_DIR/ui-dump.sh" "$OUT" >/dev/null 2>&1
    if [ -f "$OUT/ui.xml" ] && python3 "$SCRIPT_DIR/ui_toggle.py" "$OUT/ui.xml" "$LABEL" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

if ! open_settings; then
  echo "ERR: could not open the manager Settings screen (manager crash-looping?)"
  exit 1
fi

read -r idx cx cy checked <<<"$(python3 "$SCRIPT_DIR/ui_toggle.py" "$OUT/ui.xml" "$LABEL")" || {
  echo "ERR: toggle '$LABEL' not found"; exit 1; }

echo "current: $LABEL = $checked (idx=$idx @ $cx,$cy)"

case "$MODE" in
  status) : ;;
  disable|enable)
    want="$([ "$MODE" = disable ] && echo False || echo True)"
    if [ "$checked" = "$want" ]; then
      echo "already $want — nothing to do"
    else
      "$SCRIPT_DIR/ui-act.sh" tap "$idx" >/dev/null 2>&1
      sleep 2
      bash "$SCRIPT_DIR/ui-dump.sh" "$OUT" >/dev/null 2>&1
      read -r idx cx cy checked <<<"$(python3 "$SCRIPT_DIR/ui_toggle.py" "$OUT/ui.xml" "$LABEL")"
      echo "after tap: $LABEL = $checked"
      [ "$checked" = "$want" ] || { echo "ERR: toggle did not reach $want"; exit 1; }
    fi
    ;;
esac

# restore the user's terminal
"$SCRIPT_DIR/ui-act.sh" launch com.termux/.app.TermuxActivity >/dev/null 2>&1
echo "done."
