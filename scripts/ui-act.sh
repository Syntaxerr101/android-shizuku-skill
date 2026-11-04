#!/usr/bin/env bash
# ui-act.sh — low-level UI driver: dump / tap / type / key / swipe / scroll / launch.
#
# Pair it with ui-wait.sh for confirm: act -> wait -> branch on the result. An
# action's exit code only means "the input command was sent", not "the screen
# changed". For a one-session act+verify use ui-fast.sh instead.
#
# Usage:
#   bash ui-act.sh dump [OUTDIR]
#   bash ui-act.sh tap     <idx|text:SUB|id:SUB|xy:X,Y>
#   bash ui-act.sh longtap <idx|text:SUB|id:SUB|xy:X,Y>
#   bash ui-act.sh type "Hello World"          (spaces are sent as %s)
#   bash ui-act.sh key <ANDROID_KEY_NAME>      (HOME BACK ENTER DEL DPAD_CENTER ...)
#   bash ui-act.sh swipe X1 Y1 X2 Y2 [MS]
#   bash ui-act.sh scroll up|down|left|right [N]
#   bash ui-act.sh launch <am start args...>   e.g. -a android.settings.SETTINGS
#   bash ui-act.sh wake | back | home | focus
#
# Targets are resolved against OUTDIR/ui.xml (default $UI_OUT). Re-dump first if
# the screen may have changed; text:/id: hit the actionable element, not a title.
set -u
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
OUT=$UI_OUT

ACT=${1:-}
[ -n "$ACT" ] && shift

need_rish

run() { "$RISH" -c "$1" 2>&1 | grep -v '^$'; }

valid_int() { case "$1" in ''|*[!0-9-]*) return 1 ;; esac; return 0; }

resolve_coords() { # <target> -> "idx cx cy class label"
  local t=$1
  case "$t" in
    xy:*) return 0 ;;
  esac
  [ -f "$OUT/ui.xml" ] || { echo "ERR: no $OUT/ui.xml — run: bash ui-act.sh dump" >&2; return 2; }
  "$PY" "$SCRIPT_DIR/ui_resolve.py" "$OUT/ui.xml" "$t"
}

screen_size() {
  local s
  s=$(android_screen_size)
  case "$s" in [0-9]*x[0-9]*) printf '%s\n' "$s" ;; *) return 1 ;; esac
}

case "$ACT" in
  dump)
    exec bash "$SCRIPT_DIR/ui-dump.sh" "${1:-$OUT}"
    ;;
  tap|longtap)
    t=${1:-}; [ -n "$t" ] || { echo "ERR: missing target" >&2; exit 2; }
    if [ "$t" = "${t#xy:}" ]; then
      res=$(resolve_coords "$t") || { echo "$res" >&2; exit 1; }
      read -r idx cx cy _rest <<< "$res"
    else
      xy=${t#xy:}; cx=${xy%,*}; cy=${xy#*,}
      idx=xy
    fi
    valid_int "$cx" && valid_int "$cy" || { echo "ERR: bad coordinates: $t" >&2; exit 2; }
    if [ "$ACT" = tap ]; then
      echo "tap idx=$idx at $cx,$cy"
      run "input tap $cx $cy"
    else
      echo "longtap idx=$idx at $cx,$cy (800 ms)"
      run "input swipe $cx $cy $cx $cy 800"
    fi
    ;;
  type)
    txt="$*"
    [ -n "$txt" ] || { echo "ERR: missing text" >&2; exit 2; }
    case "$txt" in *"'"*|*\\*|*$'\n'*) echo "ERR: quote, backslash and newline are not supported" >&2; exit 2 ;; esac
    txt=${txt// /%s}
    echo "type: $txt"
    run "input text '$txt'"
    ;;
  key)
    k=${1:-}
    case "$k" in ''|*[!A-Za-z0-9_]*) echo "ERR: invalid key name" >&2; exit 2 ;; esac
    run "input keyevent $k"
    ;;
  swipe)
    [ $# -ge 4 ] || { echo "ERR: swipe needs X1 Y1 X2 Y2 [MS]" >&2; exit 2; }
    for v in "$1" "$2" "$3" "$4"; do valid_int "$v" || { echo "ERR: swipe needs integers" >&2; exit 2; }; done
    ms=${5:-400}; valid_int "$ms" || ms=400
    echo "swipe $1,$2 -> $3,$4 (${ms}ms)"
    run "input swipe $1 $2 $3 $4 $ms"
    ;;
  scroll)
    dir=${1:-down}; n=${2:-1}
    valid_int "$n" || n=1
    sz=$(screen_size) || { echo "ERR: cannot read 'wm size'; pass explicit swipe coordinates" >&2; exit 1; }
    W=${sz%x*}; H=${sz#*x}
    case "$dir" in
      down)  x1=$((W/2)); y1=$((H*75/100)); x2=$x1; y2=$((H*30/100)) ;;
      up)    x1=$((W/2)); y1=$((H*30/100)); x2=$x1; y2=$((H*75/100)) ;;
      left)  y1=$((H/2)); x1=$((W*85/100)); y2=$y1; x2=$((W*15/100)) ;;
      right) y1=$((H/2)); x1=$((W*15/100)); y2=$y1; x2=$((W*85/100)) ;;
      *) echo "ERR: scroll direction must be up|down|left|right" >&2; exit 2 ;;
    esac
    CMD=""
    i=0
    while [ "$i" -lt "$n" ]; do
      CMD="$CMD input swipe $x1 $y1 $x2 $y2 350;"
      i=$((i + 1))
    done
    echo "scroll $dir x$n on ${W}x${H}"
    run "$CMD"
    ;;
  launch)
    [ $# -ge 1 ] || { echo "ERR: launch needs am start arguments" >&2; exit 2; }
    echo "launch: am start $*"
    run "am start $*"
    ;;
  wake)  run 'input keyevent KEYCODE_WAKEUP' ;;
  back)  echo "back"; run 'input keyevent KEYCODE_BACK' ;;
  home)  echo "home"; run 'input keyevent KEYCODE_HOME' ;;
  focus) run 'dumpsys window 2>/dev/null | grep mCurrentFocus | head -1' ;;
  *)
    echo "usage: ui-act.sh dump|tap|longtap|type|key|swipe|scroll|launch|wake|back|home|focus" >&2
    exit 2
    ;;
esac
