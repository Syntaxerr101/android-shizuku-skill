#!/bin/bash
# ui-shell.sh — PERSISTENT rish session driver. Kills the per-call handshake cost.
#
# Problem it solves: every ui-fast.sh invocation opens its OWN rish session, which
# on this device costs ~3.5-4s of fixed overhead even before one `uiautomator dump`
# (~3s). So a launch->read->tap->check loop pays that 4s repeatedly, and the wall
# time between "action" and "fresh dump for the next decision" is huge.
#
# Solution: ONE rish session stays alive reading commands from a FIFO. The host
# pushes a command string and waits for a unique marker line in the session log.
# Shell state PERSISTS across commands inside the session, so the dump/resolve/
# step/repl helpers are defined ONCE at `start` (boot script) and reused for every
# step. A navigation step is typically ONE run():
#     dump -> pkg gate -> resolve target -> tap -> sleep -> fresh dump
# and the host makes the next decision from that fresh dump. Fixed handshake cost:
# paid once. Dump cost (~3s): only when a read is actually needed.
#
# Usage:
#   ui-shell.sh start                        open FIFO + session + boot helpers
#   ui-shell.sh run '<commands>' [timeout]   push commands; wait for marker; print output
#   ui-shell.sh ping                         quick liveness check over the session
#   ui-shell.sh stop                         kill session + holder (logs kept)
#   ui-shell.sh status                       pid alive? log size?
#
# Session dumps live on device at /sdcard/.us.xml & /sdcard/.us.lines (mirrored
# into /mnt/sdcard/... inside Termux/PRoot for host-side parsing).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"
D=/tmp/shizuku-skill/ui
IN="$D/ushell.in"; OUT="$D/ushell.out"; POSF="$D/ushell.pos"
PIDF="$D/ushell.pid"; HOLD="$D/ushell.hold"
MARK='@@USHELL@@'
BOOT_MARK='@@UBOOT@@'

alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

wait_marker() {
  # wait for literal marker m in OUT after POSF; prints the new segment into
  # LAST_SEG (global) and stores new position in POSF.
  local m="$1" tmo="${2:-20}" pos end npos seg
  pos=$(cat "$POSF" 2>/dev/null || echo 0)
  end=$(( $(date +%s) + tmo ))
  LAST_SEG=""
  while :; do
    npos=$(wc -c < "$OUT" 2>/dev/null || echo 0)
    if [ "$npos" -gt "$pos" ]; then
      seg=$(tail -c +$((pos+1)) "$OUT" 2>/dev/null)
      if printf '%s' "$seg" | grep -qF "$m"; then
        LAST_SEG=$(printf '%s' "$seg" | sed "s/$m.*//")
        echo "$npos" > "$POSF"
        return 0
      fi
    fi
    [ "$(date +%s)" -ge "$end" ] && return 1
    sleep 0.1
  done
}

start() {
  if alive; then echo "already running pid=$(cat "$PIDF")"; return 0; fi
  rm -f "$IN"; mkfifo "$IN"
  : > "$OUT"; echo 0 > "$POSF"
  # holder: keep a write fd open so the session never sees EOF
  { exec 3>"$IN"; exec sleep 100000; } & echo $! > "$HOLD"
  "$RISH" < "$IN" >> "$OUT" 2>&1 & echo $! > "$PIDF"
  sleep 2   # let the loader come up before boot injection
  cat > "$IN" <<'BOOT_EOF'
input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
do_dump() {
  local i out
  for i in 1 2 3 4 5; do
    out=$(uiautomator dump /sdcard/.us.xml 2>&1)
    case "$out" in
      *"dumped to"*) sed 's/></>\n</g' /sdcard/.us.xml > /sdcard/.us.lines; return 0 ;;
    esac
    sleep 1
  done
  echo "ERR: dump failed 5x"
  return 1
}
curpkg() { grep -m1 '<node ' /sdcard/.us.lines | sed 's/.*package="\([^"]*\)".*/\1/'; }
resolve() {
  local m t o
  case "$1" in
    xy:*) RX="${1#xy:}"; RY="${RX#*,}"; RX="${RX%,*}"; SWX=-1; SWY=-1; LB=xy; VIA=xy; TAPX="$RX"; TAPY="$RY"; return 0 ;;
    text:*) m=text; t="${1#text:}" ;;
    id:*) m=id; t="${1#id:}" ;;
    *) echo "resolve: bad target '$1'"; return 2 ;;
  esac
  o=$(awk -v TGTARG="$t" -v MODEARG="$m" '
  BEGIN{best=9999; nc=0}
  function attr(s,n,  i,j,rest){i=index(s,n "=\""); if(i==0)return ""; rest=substr(s,i+length(n)+2); j=index(rest,"\""); return (j?substr(rest,1,j-1):"")}
  function bl(b,  p,q,a,c){p=b; sub(/^\[/,"",p); sub(/\]$/,"",p); split(p,q,"\\]\\["); split(q[1],a,","); split(q[2],c,","); x1=a[1]; y1=a[2]; x2=c[1]; y2=c[2]}
  /^<\/node/{depth--; next}
  /^<node/{d=depth;
    t=attr($0,"text"); dd=attr($0,"content-desc"); rid=attr($0,"resource-id");
    cl=(attr($0,"clickable")=="true"); ck=(attr($0,"checkable")=="true");
    ch=(attr($0,"checked")=="true"); b=attr($0,"bounds");
    sa=(cl||ck); stack[d]=(sa?b:stack[d-1]);
    if(ck){bl(b); chx[nc]=int((x1+x2)/2); chy[nc]=int((y1+y2)/2); chck[nc]=ch; nc++}
    m=0; ex=0; tt=tolower(t); ll=tolower(dd); TG=tolower(TGTARG);
    if(MODEARG=="id"){ if(index(tolower(rid),TG)>0){m=1;ex=1} }
    else { if(tt==TG||ll==TG){m=1;ex=1} else if(index(tt,TG)>0||index(ll,TG)>0){m=1} }
    if(m){act=(sa?b:stack[d-1]); if(act!=""){pri=(ex?0:2)+(!sa); if(pri<best){best=pri; bl(act); rowx1=x1; rowy1=y1; rowx2=x2; rowy2=y2; RX=int((x1+x2)/2); RY=int((y1+y2)/2); LB=(t!=""?t:dd); VIA=(sa?"self":"row")}}}
    if($0 !~ /\/>$/)depth=d+1; next}
  END{ if(RX=="")exit 1; SWX=-1; SWY=-1; SCH="";
    for(i=0;i<nc;i++){ if(chx[i]>=rowx1&&chx[i]<=rowx2&&chy[i]>=rowy1&&chy[i]<=rowy2){SWX=chx[i]; SWY=chy[i]; SCH=(chck[i]?"true":"false"); break} }
    print RX "," RY "," SWX "," SWY "|" LB "|" SCH "|" VIA }
  ' /sdcard/.us.lines) || return 1
  RX=$(echo "$o" | cut -d'|' -f1 | cut -d',' -f1)
  RY=$(echo "$o" | cut -d'|' -f1 | cut -d',' -f2)
  SWX=$(echo "$o" | cut -d'|' -f1 | cut -d',' -f3)
  SWY=$(echo "$o" | cut -d'|' -f1 | cut -d',' -f4)
  LB=$(echo "$o" | cut -d'|' -f2); CUR=$(echo "$o" | cut -d'|' -f3); VIA=$(echo "$o" | cut -d'|' -f4)
  TAPX="$SWX"; TAPY="$SWY"; [ "$SWX" != "-1" ] || { TAPX="$RX"; TAPY="$RY"; }
}
step() {
  # $1=pkg-sub $2=target: fresh dump -> pkg gate -> resolve -> tap -> sleep -> fresh dump
  do_dump || return 1
  case "$(curpkg)" in
    *"$1"*) ;;
    *) echo "ERR: gate pkg=$(curpkg) want ~$1"; return 1 ;;
  esac
  resolve "$2" || { echo "ERR: no '$2' -> $(curpkg)"; return 2; }
  echo "ACT '$2' @ $TAPX,$TAPY (label='$LB' via=$VIA)"
  input tap "$TAPX" "$TAPY"
  sleep 1
  do_dump
}
repl() {
  # $1=new text: clear focused field (MOVE_END + 60 DEL) then type; re-dump
  input keyevent KEYCODE_MOVE_END
  n=0; while [ $n -lt 60 ]; do input keyevent KEYCODE_DEL; n=$((n+1)); done
  input text "$1"
  sleep 0.6
  do_dump
}
echo @@UBOOT@@
BOOT_EOF
  if wait_marker "$BOOT_MARK" 15; then
    echo "started pid=$(cat "$PIDF") [boot ok]"
    return 0
  fi
  echo "boot failed; stopping" >&2
  stop
  return 1
}

run() {
  local payload="${1:-}" tmo="${2:-20}"
  [ -n "$payload" ] || { echo "usage: ui-shell.sh run '<commands>' [timeout]" >&2; return 2; }
  if ! alive; then echo "session not running (start first)" >&2; return 1; fi
  printf '%s\necho %s\n' "$payload" "$MARK" > "$IN"
  if wait_marker "$MARK" "$tmo"; then
    printf '%s' "$LAST_SEG"
    return 0
  fi
  echo "TIMEOUT (${tmo}s) waiting for marker; session may be stuck" >&2
  return 1
}

stop() {
  [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
  [ -f "$HOLD" ] && kill "$(cat "$HOLD")" 2>/dev/null
  rm -f "$IN" "$PIDF" "$HOLD"
  echo "stopped (logs kept in $OUT)"
}

status() {
  if alive; then echo "running pid=$(cat "$PIDF") log=$(wc -c < "$OUT" 2>/dev/null || echo 0)B"; else echo "not running"; fi
}

case "${1:-}" in
  start)  start ;;
  run)    shift; run "$@" ;;
  ping)   run 'echo PONG-OK' 8 || return 1 ;;
  stop)   stop ;;
  status) status ;;
  *) echo "usage: ui-shell.sh start|run '<cmd>'|stop|status|ping" >&2; exit 2 ;;
esac