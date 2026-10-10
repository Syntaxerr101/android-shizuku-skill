#!/bin/bash
# ui-act.sh — drive the UI. Combines with ui-dump.sh / ui-wait.sh for a
# read → act → confirm loop. Mutating actions fire ONE rish broadcast and
# print its output; judge success with ui-wait.sh afterwards (not by exit code).
# Run shizuku-disable-selfstart.sh once to remove the manager's Android 15 FGS
# crash (see references/troubleshooting.md §1); with the pref left on, the manager
# app can crash mid-relay (harmless — shizuku_server stays alive).
#
# Usage:
#   bash ui-act.sh dump [OUTDIR]                      refresh ui.xml/screen.txt/screen.json
#   bash ui-act.sh tap <idx|"text:SUBSTR">            tap center of a node
#   bash ui-act.sh longtap <idx|"text:SUBSTR">        long-press hold (800 ms)
#   bash ui-act.sh type "Hello World"                 type text (spaces ok)
#   bash ui-act.sh key <NAME>                         keyevent (BACK HOME ENTER TAB DEL ESC ...)
#   bash ui-act.sh swipe X1 Y1 X2 Y2 [MS]             swipe/scroll between points
#   bash ui-act.sh scroll <up|down|left|right> [N]    scroll N times (default 1)
#   bash ui-act.sh launch <am start args...>          e.g. com.termux/.app.TermuxActivity
#                                                     e.g. -a android.settings.SETTINGS
#   bash ui-act.sh wake                               wake the screen
#   bash ui-act.sh back | home                        shortcuts
#   bash ui-act.sh focus                              show current focused window
#
# OUTDIR defaults to /tmp/shizuku-skill/ui (tap/type need a fresh ui.xml).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"
RESOLVE="$SCRIPT_DIR/ui_resolve.py"
OUT="${UI_OUT:-/tmp/shizuku-skill/ui}"

ACT="${1:-}"; [ -n "$ACT" ] && shift

run() { "$RISH" -c "$1" 2>&1 | grep -v '^$'; }   # print rish output (incl. timeouts)

resolve_coords() {  # <target> -> idx cx cy
  [ -f "$OUT/ui.xml" ] || { echo "no ui.xml yet — run: bash ui-act.sh dump"; return 2; }
  python3 "$RESOLVE" "$OUT/ui.xml" "$1" 2>/dev/null
}

case "$ACT" in
  dump)
    bash "$SCRIPT_DIR/ui-dump.sh" "${1:-$OUT}"
    ;;
  tap|longtap)
    res=$(resolve_coords "${1:-}") || { echo "$res"; exit $?; }
    set -- $res
    if [ "$#" -lt 3 ]; then echo "$res"; exit 1; fi
    idx=$1; cx=$2; cy=$3
    if [ "$ACT" = "tap" ]; then
      echo "tap idx=$idx at $cx,$cy"
      run "input tap $cx $cy"
    else
      echo "longtap idx=$idx at $cx,$cy (800 ms)"
      run "input swipe $cx $cy $cx $cy 800"
    fi
    ;;
  type)
    txt="$*"; txt=${txt// /%s}; txt=${txt//\'/}
    echo "type: $txt"
    run "input text '$txt'"
    ;;
  key)
    run "input keyevent $1"
    ;;
  swipe)
    ms="${4:-400}"
    run "input swipe $1 $2 $3 $ms"
    ;;
  scroll)
    dir="${1:-down}"; n="${2:-1}"
    case "$dir" in
      down)  args=(360 1100 360 500 400);;
      up)    args=(360 500 360 1100 400);;
      left)  args=(600 800 120 800 400);;
      right) args=(120 800 600 800 400);;
      *) echo "scroll dir: up|down|left|right"; exit 2;;
    esac
    CMD=""
    for i in $(seq 1 "$n"); do CMD="$CMD input swipe ${args[@]}; "; done
    echo "scroll $dir x$n"
    run "$CMD"
    ;;
  launch)
    echo "launch: am start $*"
    run "am start $*"
    ;;
  wake)
    run 'input keyevent KEYCODE_WAKEUP'
    ;;
  back) echo "back"; run 'input keyevent KEYCODE_BACK';;
  home) echo "home"; run 'input keyevent KEYCODE_HOME';;
  focus) run 'dumpsys window 2>/dev/null | grep mCurrentFocus | head -1';;
  *)
    echo "unknown action: $ACT"
    echo "actions: dump tap longtap type key swipe scroll launch wake back home focus"
    exit 2
    ;;
esac