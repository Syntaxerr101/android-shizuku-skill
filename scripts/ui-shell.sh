#!/usr/bin/env bash
# ui-shell.sh — persistent rish session driver (removes the per-call handshake).
#
# One rish process stays alive reading a FIFO. Helpers (do_dump, curpkg,
# resolve, step, repl) are defined once at `start`; every `run` reuses them, so
# a navigation step costs one dump instead of one full rish session per command.
#
# Usage:
#   bash ui-shell.sh start                    open the FIFO + session + helpers
#   bash ui-shell.sh run '<commands>' [tmo]   execute; print output (default 25 s)
#   bash ui-shell.sh ping                     liveness test
#   bash ui-shell.sh status                   pid / log size
#   bash ui-shell.sh stop                     close session (log is kept)
#
# Inside `run` these helpers exist:
#   step '<pkg-substr>' '<target>'   fresh dump -> pkg gate -> resolve -> tap -> fresh dump
#   do_dump                          fresh dump (fails on stale/failed dump)
#   curpkg                           package of the last dump
#   resolve '<target>'               sets RX RY TAPX TAPY LB CUR VIA from last dump
#   repl '<text>'                    clear focused field (MOVE_END + 60 DEL) + type + dump
#   target forms: text:<sub> | id:<sub> | xy:<x>,<y>
#
# Dumps are written on-device to /data/local/tmp, so this works identically in
# Termux and PRoot (no /sdcard path translation).
set -u

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
need_rish

D=$UI_OUT
IN=$D/ushell.in
OUTLOG=$D/ushell.out
POSF=$D/ushell.pos
PIDF=$D/ushell.pid
HOLD=$D/ushell.hold
MARK='@@USHELL@@'
BOOT_MARK='@@UBOOT@@'
mkdir -p "$D"

alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

wait_marker() { # <marker> <timeout>; sets LAST_SEG
  local m=$1 tmo=${2:-25} pos end npos seg
  pos=$(cat "$POSF" 2>/dev/null || echo 0)
  end=$(( $(date +%s) + tmo ))
  LAST_SEG=""
  while :; do
    npos=$(wc -c < "$OUTLOG" 2>/dev/null || echo 0)
    if [ "${npos:-0}" -gt "$pos" ]; then
      seg=$(tail -c +$((pos + 1)) "$OUTLOG" 2>/dev/null)
      if printf '%s' "$seg" | grep -qF "$m"; then
        LAST_SEG=$(printf '%s' "$seg" | sed "s/$(printf '%s' "$m" | sed 's/[.[\*^$]/\\&/g').*//")
        printf '%s\n' "$npos" > "$POSF"
        return 0
      fi
    fi
    [ "$(date +%s)" -ge "$end" ] && return 1
    sleep 0.1
  done
}

start() {
  if alive; then echo "already running pid=$(cat "$PIDF")"; return 0; fi
  rm -f "$IN"; mkfifo "$IN" || return 1
  : > "$OUTLOG"; echo 0 > "$POSF"
  # Hold a write fd so the reader never sees EOF between commands.
  { exec 3>"$IN"; exec sleep 100000; } >/dev/null 2>&1 &
  echo $! > "$HOLD"
  "$RISH" < "$IN" >> "$OUTLOG" 2>&1 &
  echo $! > "$PIDF"
  sleep 2

  cat > "$IN" <<'BOOT_EOF'
input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
TMP=/data/local/tmp
do_dump() {
  local i out
  out=""
  for i in 1 2 3 4 5; do
    out=$(uiautomator dump "$TMP/.us.xml" 2>&1)
    case "$out" in
      *"dumped to"*) sed 's/></>\n</g' "$TMP/.us.xml" > "$TMP/.us.lines"; return 0 ;;
    esac
    sleep 1
  done
  echo "ERR: dump failed 5x (last: $(printf '%s' "$out" | cut -c1-120))"
  return 1
}
curpkg() { grep -m1 '<node ' "$TMP/.us.lines" | sed 's/.*package="\([^"]*\)".*/\1/'; }
resolve() {
  RX=""; RY=""; SWX=-1; SWY=-1; SCH=""; LB=""; VIA=""
  case "$1" in
    xy:*) RX=${1#xy:}; RY=${RX#*,}; RX=${RX%,*}; TAPX="$RX"; TAPY="$RY"; LB=xy; VIA=xy; return 0 ;;
    text:*) m=text; t=${1#text:} ;;
    id:*)   m=id;   t=${1#id:} ;;
    *) echo "resolve: bad target '$1'"; return 2 ;;
  esac
  o=$(awk -v TGTARG="$t" -v MODEARG="$m" '
  BEGIN{best=9999; nc=0}
  function attr(s,n,  i,j,rest){i=index(s,n "=\""); if(i==0)return ""; rest=substr(s,i+length(n)+2); j=index(rest,"\""); return (j?substr(rest,1,j-1):"")}
  function bl(b,  p,q,a,c){p=b; sub(/^\[/,"",p); sub(/\]$/,"",p); split(p,q,"\\]\\["); split(q[1],a,","); split(q[2],c,","); x1=a[1]; y1=a[2]; x2=c[1]; y2=c[2]}
  /^<\/node/{depth--; next}
  /^<node/{d=depth;
    tt0=attr($0,"text"); dd=attr($0,"content-desc"); rid=attr($0,"resource-id");
    cl=(attr($0,"clickable")=="true"); ck=(attr($0,"checkable")=="true");
    ch=(attr($0,"checked")=="true"); b=attr($0,"bounds");
    sa=(cl||ck); stack[d]=(sa?b:stack[d-1]);
    if(ck){bl(b); chx[nc]=int((x1+x2)/2); chy[nc]=int((y1+y2)/2); chck[nc]=ch; nc++}
    m=0; ex=0; tt=tolower(tt0); ll=tolower(dd); TG=tolower(TGTARG);
    if(MODEARG=="id"){ if(index(tolower(rid),TG)>0){m=1;ex=1} }
    else { if(tt==TG||ll==TG){m=1;ex=1} else if(index(tt,TG)>0||index(ll,TG)>0){m=1} }
    if(m){act=(sa?b:stack[d-1]); if(act!=""){pri=(ex?0:2)+(!sa); if(pri<best){best=pri; bl(act); rowx1=x1; rowy1=y1; rowx2=x2; rowy2=y2; RX=int((x1+x2)/2); RY=int((y1+y2)/2); LB=(tt0!=""?tt0:dd); VIA=(sa?"self":"row")}}}}
    if($0 !~ /\/>$/)depth=d+1; next}
  END{ if(RX=="")exit 1;
    for(i=0;i<nc;i++){ if(chx[i]>=rowx1&&chx[i]<=rowx2&&chy[i]>=rowy1&&chy[i]<=rowy2){SWX=chx[i]; SWY=chy[i]; SCH=(chck[i]?"true":"false"); break} }
    print RX "," RY "," SWX "," SWY "|" LB "|" SCH "|" VIA }
  ' "$TMP/.us.lines") || return 1
  RX=$(printf '%s' "$o" | cut -d'|' -f1 | cut -d',' -f1)
  RY=$(printf '%s' "$o" | cut -d'|' -f1 | cut -d',' -f2)
  SWX=$(printf '%s' "$o" | cut -d'|' -f1 | cut -d',' -f3)
  SWY=$(printf '%s' "$o" | cut -d'|' -f1 | cut -d',' -f4)
  LB=$(printf '%s' "$o" | cut -d'|' -f2)
  CUR=$(printf '%s' "$o" | cut -d'|' -f3)
  VIA=$(printf '%s' "$o" | cut -d'|' -f4)
  [ "$SWX" != "-1" ] && { TAPX=$SWX; TAPY=$SWY; } || { TAPX=$RX; TAPY=$RY; }
  return 0
}
step() {
  do_dump || return 1
  case "$(curpkg)" in
    *"$1"*) ;;
    *) echo "ERR: gate pkg=$(curpkg) want ~$1"; return 1 ;;
  esac
  resolve "$2" || { echo "ERR: no '$2' -> $(curpkg)"; return 2; }
  echo "ACT '$2' @ $TAPX,$TAPY (label='$LB' via=$VIA checked='${CUR:-}')"
  input tap "$TAPX" "$TAPY"
  sleep 1
  do_dump
}
repl() {
  input keyevent KEYCODE_MOVE_END
  n=0; while [ "$n" -lt 60 ]; do input keyevent KEYCODE_DEL; n=$((n+1)); done
  input text "$1"
  sleep 0.6
  do_dump
}
echo @@UBOOT@@
BOOT_EOF

  if wait_marker "$BOOT_MARK" 20; then
    echo "started pid=$(cat "$PIDF") [helpers ready]"
    return 0
  fi
  echo "ERR: session boot failed" >&2
  stop
  return 1
}

run() {
  local payload=${1:-} tmo=${2:-25}
  [ -n "$payload" ] || { echo "usage: ui-shell.sh run '<commands>' [timeout]" >&2; return 2; }
  alive || { echo "ERR: session not running (start first)" >&2; return 1; }
  printf '%s\necho %s\n' "$payload" "$MARK" > "$IN"
  if wait_marker "$MARK" "$tmo"; then
    printf '%s\n' "$LAST_SEG"
    return 0
  fi
  echo "TIMEOUT (${tmo}s) waiting for marker; session may be stuck" >&2
  return 1
}

stop() {
  [ -f "$PIDF" ] && kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
  [ -f "$HOLD" ] && kill "$(cat "$HOLD" 2>/dev/null)" 2>/dev/null
  rm -f "$IN" "$PIDF" "$HOLD"
  echo "stopped (log: $OUTLOG)"
}

status() {
  if alive; then
    echo "running pid=$(cat "$PIDF") log=$(wc -c < "$OUTLOG" 2>/dev/null || echo 0)B"
  else
    echo "not running"
  fi
}

case "${1:-}" in
  start)  start ;;
  run)    shift; run "$@" ;;
  ping)
    PINGF=$WORK_DIR/.ping.$$
    if run 'echo PONG-OK' 10 >"$PINGF" 2>&1 && grep -q PONG-OK "$PINGF"; then
      echo "pong"
      rm -f "$PINGF"
      exit 0
    fi
    cat "$PINGF" 2>/dev/null
    rm -f "$PINGF"
    exit 1
    ;;
  stop)   stop ;;
  status) status ;;
  *) echo "usage: ui-shell.sh start|run '<cmd>'|ping|stop|status" >&2; exit 2 ;;
esac
