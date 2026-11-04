#!/usr/bin/env bash
# ui-fast.sh — one-session, self-verifying UI actions (the FAST + SAFE path).
#
# Doctrine for every UI step:
#   1. dump a FRESH tree and require uiautomator's own "dumped to" message
#      (a failed dump can leave the previous XML behind = stale coordinates),
#   2. optional package gate: prove we are on the screen we think we are,
#   3. resolve the target against THAT dump, on-device, in the same session,
#   4. act, then re-dump and verify (set verifies the switch actually flipped).
#
# Every invocation = ONE rish session. rish costs several seconds of fixed
# overhead, so batching dump -> resolve -> act -> verify is much faster than
# separate ui-dump / ui-act / ui-wait calls.
#
# Usage:
#   ui-fast.sh launch  <am start args...>
#   ui-fast.sh check   pkg:<SUBSTRING>
#   ui-fast.sh read    <target> [pkg:<SUBSTRING>]
#   ui-fast.sh tap     <target> [pkg:<SUBSTRING>]
#   ui-fast.sh set     <target> on|off [pkg:<SUBSTRING>]
#   ui-fast.sh type    <text>          (spaces become %s)
#   ui-fast.sh replace <text>          (MOVE_END + DEL x60, then type)
#   ui-fast.sh key     <KEY_NAME>
#
# Targets:
#   text:<SUBSTR>   text or content-desc; exact match first, then substring.
#                   The actionable element wins: the node when clickable/
#                   checkable, otherwise its nearest clickable ancestor.
#   id:<SUBSTR>     resource-id substring.
#   xy:<x>,<y>      raw coordinates.
#
# Output: OK:/ERR: lines and a final RESULT:ok|err. Exit 0 only on RESULT:ok.
set -u

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
need_rish

CMD=${1:-}
shift || true
case "$CMD" in
  launch|check|read|tap|set|type|replace|key) ;;
  *) echo "usage: ui-fast.sh launch|check|read|tap|set|type|replace|key ..." >&2; exit 2 ;;
esac

TGT=""; MODE=""; WANT=""; PKG=""
case "$CMD" in
  launch) TGT="$*" ;;
  check)
    PKG=${1:-}; PKG=${PKG#pkg:}
    [ -n "$PKG" ] || { echo "check needs pkg:<SUBSTRING>" >&2; exit 2; }
    ;;
  type|replace)
    TGT="$*"
    TGT=${TGT// /%s}
    case "$TGT" in *$'\n'*) echo "ERR: newline is not supported" >&2; exit 2 ;; esac
    ;;
  key)
    TGT=${1:-}
    case "$TGT" in ''|*[!A-Za-z0-9_]*) echo "ERR: bad key name" >&2; exit 2 ;; esac
    ;;
  read|tap|set)
    case "${1:-}" in
      text:*) MODE=text; TGT=${1#text:} ;;
      id:*)   MODE=id;   TGT=${1#id:} ;;
      xy:*)   MODE=xy;   TGT=${1#xy:} ;;
      *) echo "ERR: target must be text:.. | id:.. | xy:x,y" >&2; exit 2 ;;
    esac
    shift || true
    while [ $# -gt 0 ]; do
      case "$1" in
        pkg:*) PKG=${1#pkg:}; shift ;;
        on|off)
          if [ "$CMD" = set ] && [ -z "$WANT" ]; then WANT=$1; fi
          shift ;;
        *) TGT="$TGT $1"; shift ;;
      esac
    done
    [ -n "$TGT" ] || { echo "ERR: missing target" >&2; exit 2; }
    if [ "$CMD" = set ]; then
      case "$WANT" in on|off) ;; *) echo "ERR: set needs on|off" >&2; exit 2 ;; esac
    fi
    case "$TGT" in *$'\n'*) echo "ERR: newline in target" >&2; exit 2 ;; esac
    ;;
esac

# All values travel as base64, so quotes/$, spaces and unicode cannot break or
# inject into the on-device shell script.
CMD_B64=$(b64 "$CMD")
TGT_B64=$(b64 "$TGT")
MODE_B64=$(b64 "$MODE")
WANT_B64=$(b64 "$WANT")
PKG_B64=$(b64 "$PKG")

OUT=$(sed \
  -e "s%@CMD@%$CMD_B64%g" \
  -e "s%@TGT@%$TGT_B64%g" \
  -e "s%@MODE@%$MODE_B64%g" \
  -e "s%@WANT@%$WANT_B64%g" \
  -e "s%@PKG@%$PKG_B64%g" <<'REMOTE'
# ---------------- on-device script (shell uid) ----------------
b64d() { printf '%s' "$1" | base64 -d; }
CMDA=$(b64d '@CMD@')
TGT=$(b64d '@TGT@')
MODE=$(b64d '@MODE@')
WANT=$(b64d '@WANT@')
PKGREQ=$(b64d '@PKG@')
TMP=/data/local/tmp

input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

dump_ok() {
  local i out
  out=""
  for i in 1 2 3 4 5; do
    out=$(uiautomator dump "$TMP/.uif.xml" 2>&1)
    case "$out" in
      *"dumped to"*) sed 's/></>\n</g' "$TMP/.uif.xml" > "$TMP/.uif.lines"; return 0 ;;
    esac
    sleep 1
  done
  echo "ERR: uiautomator dump failed 5x (last: $(printf '%s' "$out" | cut -c1-120))"
  return 1
}
curpkg() { grep -m1 '<node ' "$TMP/.uif.lines" | sed 's/.*package="\([^"]*\)".*/\1/'; }

resolve() {
  RX=""; RY=""; SWX=-1; SWY=-1; SCH=""; LB=""; VIA=""
  if [ "$MODE" = xy ]; then
    RX=${TGT%,*}; RY=${TGT#*,}; SWX=-1; SWY=-1; SCH=""; LB="xy"; VIA="xy"
    return 0
  fi
  awk -v TGTARG="$TGT" -v MODEARG="$MODE" '
  BEGIN{best=9999; nc=0; SWX=-1; SWY=-1}
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
  END{ if(RX=="")exit 1;
    for(i=0;i<nc;i++){ if(chx[i]>=rowx1&&chx[i]<=rowx2&&chy[i]>=rowy1&&chy[i]<=rowy2){SWX=chx[i]; SWY=chy[i]; SCH=(chck[i]?"true":"false"); break} }
    print RX "," RY "," SWX "," SWY "|" LB "|" SCH "|" VIA }
  ' "$TMP/.uif.lines"
}

split_res() {
  local o
  o=$(resolve) || return 1
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

if [ "$CMDA" = launch ]; then
  am start $TGT >/dev/null 2>&1
  sleep 2
  dump_ok || { echo "RESULT:err"; exit 1; }
  echo "OK: launched -> pkg=$(curpkg)"
  echo "RESULT:ok"; exit 0
fi

if [ "$CMDA" = check ]; then
  dump_ok || { echo "RESULT:err"; exit 1; }
  P=$(curpkg)
  case "$P" in *"$PKGREQ"*) echo "OK: pkg=$P matches ~$PKGREQ"; echo "RESULT:ok"; exit 0 ;; esac
  echo "ERR: pkg=$P, expected ~$PKGREQ"
  echo "RESULT:err"; exit 1
fi

if [ "$CMDA" = key ]; then
  input keyevent "$TGT"
  echo "OK: key '$TGT'"
  echo "RESULT:ok"; exit 0
fi

if [ "$CMDA" = type ]; then
  input text "$TGT"
  echo "OK: typed '$TGT'"
  echo "RESULT:ok"; exit 0
fi

if [ "$CMDA" = replace ]; then
  input keyevent KEYCODE_MOVE_END
  n=0; while [ "$n" -lt 60 ]; do input keyevent KEYCODE_DEL; n=$((n+1)); done
  input text "$TGT"
  echo "OK: cleared+typed '$TGT'"
  echo "RESULT:ok"; exit 0
fi

dump_ok || { echo "RESULT:err"; exit 1; }
P=$(curpkg)
if [ -n "$PKGREQ" ]; then
  case "$P" in *"$PKGREQ"*) ;; *) echo "ERR: on $P, need ~$PKGREQ"; echo "RESULT:err"; exit 3 ;; esac
fi
split_res || { echo "ERR: target '$TGT' not found on $P"; echo "RESULT:err"; exit 4; }

if [ "$CMDA" = read ]; then
  echo "OK: at $RX,$RY (switch $TAPX,$TAPY) label='$LB' checked='$CUR' via=$VIA"
  echo "RESULT:ok"; exit 0
fi

if [ "$CMDA" = tap ]; then
  input tap "$TAPX" "$TAPY"
  echo "OK: tapped $TAPX,$TAPY (label='$LB' via=$VIA)"
  echo "RESULT:ok"; exit 0
fi

# set
want=true; [ "$WANT" = off ] && want=false
if [ "$SWX" = "-1" ]; then echo "ERR: row '$LB' has no checkable switch"; echo "RESULT:err"; exit 5; fi
if [ "$CUR" = "$want" ]; then echo "OK: already $WANT (checked=$CUR), no tap"; echo "RESULT:ok"; exit 0; fi
input tap "$SWX" "$SWY"
sleep 1
dump_ok || { echo "RESULT:err"; exit 1; }
split_res || { echo "ERR: target '$TGT' gone after tap"; echo "RESULT:err"; exit 6; }
if [ "$CUR" = "$want" ]; then echo "OK: set $WANT (checked=$CUR)"; echo "RESULT:ok"; exit 0; fi
echo "WARN: still checked=$CUR (want $WANT), retry tap"
input tap "$TAPX" "$TAPY"
sleep 1
dump_ok || { echo "RESULT:err"; exit 1; }
split_res || { echo "ERR: target '$TGT' gone after retry"; echo "RESULT:err"; exit 7; }
if [ "$CUR" = "$want" ]; then echo "OK: set $WANT (checked=$CUR)"; echo "RESULT:ok"; exit 0; fi
echo "ERR: switch would not flip (now checked=$CUR)"
echo "RESULT:err"; exit 8
REMOTE
)

# Run the generated script in ONE rish session. Merge stderr into stdout: the
# loader splits them unpredictably, and merged output preserves ordering.
OUT=$(rish_c "$OUT" 2>&1)
printf '%s\n' "$OUT"
case "$OUT" in *RESULT:err*) exit 1 ;; *RESULT:ok*) exit 0 ;; *) exit 1 ;; esac
