#!/usr/bin/env bash
# shizuku-disable-selfstart.sh — turn OFF the manager's wireless auto-start pref.
#
# WHY: in several Shizuku 13.x builds the manager's receiver starts a foreground
# service from the background on every binder request while the pref
# "Start on boot (wireless ADB)" is enabled and the device is on Wi-Fi. Android
# 14/15 forbids that background FGS start and the uncaught exception kills the
# manager app process (reason=4). Turning the pref OFF makes the receiver return
# before that call. It does not touch the server, shizuku.json, or app signatures.
#
# Trade-off: after a reboot the manager no longer auto-starts the server over
# wireless ADB; start it from the manager UI (or re-enable this pref).
#
# Usage:
#   bash shizuku-disable-selfstart.sh                 # disable (default)
#   bash shizuku-disable-selfstart.sh --status        # report only
#   bash shizuku-disable-selfstart.sh --enable        # restore auto-start
#   bash shizuku-disable-selfstart.sh --label "TEXT"  # localized toggle label
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
need_rish

PKG=moe.shizuku.privileged.api
MAIN="$PKG/moe.shizuku.manager.MainActivity"
LABEL="Start on boot (wireless ADB)"
MODE=disable

while [ $# -gt 0 ]; do
  case "$1" in
    --status) MODE=status; shift ;;
    --enable) MODE=enable; shift ;;
    --disable) MODE=disable; shift ;;
    --label) LABEL=${2:-}; [ -n "$LABEL" ] || { echo "ERR: --label needs text" >&2; exit 2; }; shift 2 ;;
    *) echo "usage: $0 [--status|--disable|--enable] [--label TEXT]" >&2; exit 2 ;;
  esac
done

dump_toggle() {
  bash "$SCRIPT_DIR/ui-dump.sh" "$UI_OUT" >/dev/null 2>&1 || return 1
  "$PY" "$SCRIPT_DIR/ui_toggle.py" "$UI_OUT/ui.xml" "$LABEL" 2>/dev/null
}

open_settings() {
  local attempt i
  for attempt in 1 2 3; do
    for i in 1 2 3; do
      "$RISH" -c "am start -n '$MAIN'" >/dev/null 2>&1
      sleep 2
      if bash "$SCRIPT_DIR/ui-wait.sh" "pkg:$PKG" 8 >/dev/null 2>&1; then break; fi
    done
    # The gear/Settings entry may be a content-desc or a text node.
    for target in 'text:Settings' 'text:Settings ' 'id:settings'; do
      bash "$SCRIPT_DIR/ui-fast.sh" tap "$target" "pkg:$PKG" >/dev/null 2>&1 && break
    done
    sleep 1
    dump_toggle >/dev/null 2>&1 && return 0
  done
  return 1
}

if ! open_settings; then
  echo "ERR: could not reach the manager Settings screen or find toggle '$LABEL'." >&2
  echo "      The manager may be crash-looping, or the label is localized." >&2
  echo "      Try: $0 --status --label \"<localized label>\"" >&2
  echo "      Last UI: $UI_OUT/screen.txt" >&2
  exit 1
fi

read -r idx cx cy checked <<<"$(dump_toggle)" || { echo "ERR: toggle '$LABEL' not found" >&2; exit 1; }
echo "current: $LABEL = $checked (idx=$idx @ $cx,$cy)"

case "$MODE" in
  status) ;;
  disable|enable)
    want=False
    [ "$MODE" = enable ] && want=True
    if [ "$checked" = "$want" ]; then
      echo "already $want — nothing to do"
    else
      bash "$SCRIPT_DIR/ui-fast.sh" tap "text:$LABEL" "pkg:$PKG" >/dev/null 2>&1 || true
      sleep 1
      read -r idx cx cy checked <<<"$(dump_toggle)" || true
      echo "after:   $LABEL = $checked"
      [ "$checked" = "$want" ] || { echo "ERR: toggle did not reach $want" >&2; exit 1; }
    fi
    ;;
esac

# Leave the manager without hardcoding a terminal package: BACK twice returns to
# whatever app was in front (manager main -> previous app).
"$RISH" -c 'input keyevent KEYCODE_BACK; input keyevent KEYCODE_BACK' >/dev/null 2>&1 || true
echo "done."
