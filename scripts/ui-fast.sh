#!/bin/bash
# ui-fast.sh — one-session, self-verifying UI actions (the FAST+SAFE path).
#
# Doctrine (mandatory for every UI step):
#   1. dump a FRESH tree and confirm the dump actually succeeded (uiautomator dump
#      can fail silently and leave a STALE xml — acting on it = wrong taps).
#   2. optional pkg gate: make sure you are on the screen you think you are.
#   3. resolve the target against THAT fresh dump (on-device, so dump+resolve+tap
#      happen in the SAME instant — no stale coords possible).
#   4. act, then re-dump and verify (set verifies the state actually flipped).
#
# Every invocation = ONE rish session. rish costs ~3.5-4s on this device plus ~3s
# per uiautomator dump, so batching dump+resolve+act+verify into one session is
# the difference between ~11s and ~40s for the same safe action.
#
# Usage:
#   ui-fast.sh launch <am args...>                 start an activity; re-dump; report pkg
#   ui-fast.sh check  pkg:<SUB>                     fresh dump; OK iff current pkg contains SUB
#   ui-fast.sh read   <target> [pkg:<SUB>]          fresh dump (+gate); resolve; print state
#   ui-fast.sh tap    <target> [pkg:<SUB>]          resolve & tap the actionable element
#   ui-fast.sh set    <target> on|off [pkg:<SUB>]   flip a checkable switch; verify state changed
#   ui-fast.sh type   <text>                        input text into the focused field (spaces=%s)
#   ui-fast.sh replace <text>                       MOVE_END + ~60 DEL, then type (rename fields)
#   ui-fast.sh key    <NAME>                        input keyevent (ENTER OK BACK DEL DPAD_CENTER ...)
#
# Targets:
#   text:<SUBSTR>   matches node text OR content-desc (exact first, then substring).
#                   The ACTIONABLE element wins: a matching node that is clickable/
#                   checkable is used as-is; otherwise the nearest CLICKABLE ancestor
#                   is tapped (so "Bluetooth" hits the switch bar, not the title).
#   id:<SUBSTR>     matches resource-id substring (nodes only; clickable preferred).
#   xy:<x>,<y>      raw coordinates, no resolution.
#
# Output: OK:/ERR: lines plus a final RESULT:ok|err line on the LAST output line.
# Exit code: 0 on RESULT:ok, 1 on RESULT:err (or dump/pkg failures).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISH="$SCRIPT_DIR/rish"

CMD="${1:-}"; shift || true
[ -n "$CMD" ] || { echo "usage: ui-fast.sh launch|check|read|tap|set ..." >&2; exit 2; }

# ---- parse args ----
TGT=""; MODE=""; WANT=""; PKG=""
case "$CMD" in
  launch) TGT="$*" ;;
  check)  PKG="${1#pkg:}"; [ -n "$PKG" ] || { echo "check needs pkg:<SUB>" >&2; exit 2; } ;;
  type|replace)
    TGT="$*"
    TGT="${TGT// /%s}"
    case "$TGT" in *"'"*|*'\\'*|*$'\n'*) echo "unsupported char in text (quote, backslash, newline)" >&2; exit 2 ;; esac
    ;;
  key)
    TGT="${1:-}"
    case "$TGT" in ''|*"'"*|*'\\'*) echo "bad key name" >&2; exit 2 ;; esac
    ;;
  read|tap|set)
    case "${1:-}" in
      text:*) MODE=text; TGT="${1#text:}" ;;
      id:*)   MODE=id;   TGT="${1#id:}" ;;
      xy:*)   MODE=xy;   TGT="${1#xy:}" ;;
      *) echo "target must be text:.. | id:.. | xy:x,y" >&2; exit 2 ;;
    esac
    shift || true
    # join continuation words: text:More Settings (unquoted) -> TGT="More Settings".
    # stop at pkg:..., and at on|off (only meaningful for set).
    while [ $# -ge 1 ]; do
      a="${1:-}"
      case "$a" in
        pkg:*) PKG="${a#pkg:}"; break ;;
        on|off) shift || true; [ "$CMD" = set ] && [ -z "$WANT" ] && WANT="$a" ;;
        *) TGT="$TGT $a"; shift || true ;;
      esac
    done
    if [ "$CMD" = set ]; then
      case "$WANT" in on|off) ;; *) echo "set needs on|off" >&2; exit 2 ;; esac
    fi
    ;;
  *) echo "usage: ui-fast.sh launch|check|read|tap|set ..." >&2; exit 2 ;;
esac
# per-command target requirement
case "$CMD" in
  launch|check|type|replace|key) ;;
  *) [ -n "$TGT" ] || { echo "missing target" >&2; exit 2; } ;;
esac
# values injected via sed:%delim% into a quoted heredoc -> reject sed-special chars.
# (type/replace encode spaces as %s and are already sanitized above.)
case "$CMD" in
  type|replace|key) ;;
  *) case "$TGT$PKG$WANT" in *%*|*"'"*|*'\\'*|*$'\n'*) echo "unsupported char in args (%, quote, backslash, newline)" >&2; exit 2 ;; esac ;;
esac

# escape & for sed replacement
esc() { printf '%s' "$1" | sed 's/[&\\%]/\\&/g'; }

OUT=$( {
sed -e "s%@@CMD@@%${CMD}%g" \
    -e "s%@@TG@@%$(esc "$TGT")%g" \
    -e "s%@@MODE@@%${MODE}%g" \
    -e "s%@@WANT@@%$(esc "$WANT")%g" \
    -e "s%@@PKG@@%$(esc "$PKG")%g" <<'REMOTE_T'
# ---------------- on-device script (shell uid 2000) ----------------
input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
CMDA="@@CMD@@"; TGT="@@TG@@"; MODE="@@MODE@@"; WANT="@@WANT@@"; PKGREQ="@@PKG@@"

dump_ok() {
  local i out
  for i in 1 2 3 4 5; do
    out=$(uiautomator dump /sdcard/.uif.xml 2>&1)
    case "$out" in
      *"dumped to"*) sed 's/></>\n</g' /sdcard/.uif.xml > /sdcard/.uif.lines; return 0 ;;
    esac
    sleep 1
  done
  echo "ERR: uiautomator dump failed 5x (last: $(printf '%s' "$out" | cut -c1-100))"
  return 1
}
curpkg() { grep -m1 '<node ' /sdcard/.uif.lines | sed 's/.*package="\([^"]*\)".*/\1/'; }

resolve() {
  if [ "$MODE" = xy ]; then
    RX="${TGT%,*}"; RY="${TGT#*,}"; SWX=-1; SWY=-1; SCH=""; LB="xy"; VIA="xy"
    return 0
  fi
  awk -v TGTARG="$TGT" -v MODEARG="$MODE" '
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
  ' /sdcard/.uif.lines || return $?
}

if [ "$CMDA" = launch ]; then
  am start $TGT >/dev/null 2>&1
  sleep 2.5
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
  n=0; while [ $n -lt 60 ]; do input keyevent KEYCODE_DEL; n=$((n+1)); done
  input text "$TGT"
  echo "OK: cleared+typed '$TGT'"
  echo "RESULT:ok"; exit 0
fi

dump_ok || { echo "RESULT:err"; exit 1; }
P=$(curpkg)
if [ -n "$PKGREQ" ]; then
  case "$P" in *"$PKGREQ"*) ;; *) echo "ERR: on $P, need ~$PKGREQ"; echo "RESULT:err"; exit 3 ;; esac
fi
readout=$(resolve) || { echo "ERR: target '$TGT' not found on $P"; echo "RESULT:err"; exit 4; }
RX=$(echo "$readout" | cut -d'|' -f1 | cut -d',' -f1)
RY=$(echo "$readout" | cut -d'|' -f1 | cut -d',' -f2)
SWX=$(echo "$readout" | cut -d'|' -f1 | cut -d',' -f3)
SWY=$(echo "$readout" | cut -d'|' -f1 | cut -d',' -f4)
LB=$(echo "$readout" | cut -d'|' -f2); CUR=$(echo "$readout" | cut -d'|' -f3); VIA=$(echo "$readout" | cut -d'|' -f4)
SCH_HAS=$([ "$SWX" != "-1" ] && echo yes || echo no)
TAPX="$SWX"; TAPY="$SWY"; [ "$SCH_HAS" = yes ] || { TAPX="$RX"; TAPY="$RY"; }

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
if [ "$SCH_HAS" = no ]; then echo "ERR: row '$LB' has no checkable switch to flip"; echo "RESULT:err"; exit 5; fi
if [ "$CUR" = "$want" ]; then
  echo "OK: already $WANT (checked=$CUR), no tap"
  echo "RESULT:ok"; exit 0
fi
input tap "$SWX" "$SWY"
sleep 1.5
dump_ok || { echo "RESULT:err"; exit 1; }
r2=$(resolve) || { echo "ERR: target '$TGT' gone after tap (screen moved)"; echo "RESULT:err"; exit 6; }
c2=$(echo "$r2" | cut -d'|' -f3)
if [ "$c2" = "$want" ]; then
  echo "OK: set $WANT (checked=$c2)"
  echo "RESULT:ok"; exit 0
fi
echo "WARN: still checked=$c2 (want $WANT), retry tap"
input tap "$SWX" "$SWY"; sleep 1.5
dump_ok || { echo "RESULT:err"; exit 1; }
r3=$(resolve) || { echo "ERR: target '$TGT' gone after retry"; echo "RESULT:err"; exit 7; }
c3=$(echo "$r3" | cut -d'|' -f3)
if [ "$c3" = "$want" ]; then echo "OK: set $WANT (checked=$c3)"; echo "RESULT:ok"; exit 0; fi
echo "ERR: switch would not flip (now checked=$c3)"
echo "RESULT:err"; exit 8
REMOTE_T
} | "$RISH" 2>&1 )

printf '%s\n' "$OUT"
case "$OUT" in *RESULT:err*) exit 1 ;; *) exit 0 ;; esac