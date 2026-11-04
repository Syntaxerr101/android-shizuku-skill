# shellcheck shell=bash
# android-shizuku-skill — shared helpers for the host-side scripts.
# Source this from bash:  . "$(dirname "$0")/lib.sh"
#
# Everything here is deliberately device-agnostic: no model names, no fixed
# uids, no hard-coded screen resolutions, no vendor package names.

SKILL_ROOT=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS_DIR="$SKILL_ROOT/scripts"
RISH="$SCRIPTS_DIR/rish"

# Work directory. Override with SHIZUKU_WORK. TMPDIR is set by Termux; /tmp is
# bind-mounted by proot-distro, so this works in both environments.
WORK_DIR=${SHIZUKU_WORK:-${TMPDIR:-/tmp}/shizuku-skill}
UI_OUT=${UI_OUT:-$WORK_DIR/ui}
CAPTURE_OUT=${CAPTURE_OUT:-$WORK_DIR/captures}

mkdir -p "$UI_OUT" "$CAPTURE_OUT" 2>/dev/null || true

die() { printf 'ERR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# python: Termux and Ubuntu both ship python3; fall back to python for odd ROMs.
PY=""
for _c in python3 python; do
  if have "$_c"; then PY=$_c; break; fi
done
[ -n "$PY" ] || die "python3 is required (pkg install python / apt install python3)"

need_rish() {
  [ -x "$RISH" ] || die "rish wrapper missing or not executable: $RISH"
  case "$RISH" in /*) ;; *) RISH="$PWD/$RISH" ;; esac
}

# Print stdout of one rish session. All arguments are joined with newlines and
# fed to `rish -c`; keep related commands in ONE call (~3-5 s fixed cost/session).
rish() { "$RISH" "$@"; }

rish_c() { "$RISH" -c "$1"; }

# Run a rish snippet with an optional timeout (seconds). `timeout` exists in
# Termux (coreutils) and in PRoot; without it the call runs unbounded.
rish_c_t() { # <seconds> <script>
  if have timeout; then
    timeout "$1" "$RISH" -c "$2"
  else
    "$RISH" -c "$2"
  fi
}

# Screen geometry from the device, e.g. 1080x2400. Prints nothing on failure.
android_screen_size() {
  rish_c 'wm size 2>/dev/null' | sed -n 's/.*: *\([0-9][0-9]*x[0-9][0-9]*\).*/\1/p' | tail -n1
}

# Base64 helpers (present in Termux, Ubuntu, and Android toybox).
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# The Android-side scratch dir. /data/local/tmp is shell-owned and visible to
# app_process. It is NOT necessarily shared with the host (a PRoot/chroot has
# its own /data tree), so it is only used as a staging area on the device.
ANDROID_TMP=/data/local/tmp

# ---------------------------------------------------------------------------
# Artifact transport
#
# Pulling large files out of `rish` through stdout is unreliable: the loader
# may split the stream between fd1 and fd2 (merge with 2>&1), and writes above
# a few KB get truncated or interleaved. So:
#
#   1. PRIMARY — shared storage. Android's /sdcard is usually visible at the
#      same absolute path inside Termux and PRoot. We probe it by writing a
#      token on the device and reading it back on the host, then copy files
#      through it and verify md5 on both sides.
#   2. FALLBACK — gzip + base64 pulled in small, individually verified chunks,
#      each in its own short rish session. Slow, but works with nothing but
#      the rish pipe (e.g. native Termux without storage permission).
# ---------------------------------------------------------------------------

# Candidate shared-storage roots. The same string must resolve on both sides.
SHARED_CANDIDATES=${SHARED_CANDIDATES:-'/sdcard /storage/emulated/0 /mnt/sdcard /storage/self/primary'}
SHARED_SUBDIR=.shizuku-skill
CHUNK=3072                     # raw bytes per chunk in the stdout fallback

_shared_probe_one() { # <candidate> -> 0 if host and device see the same file
  local cand=$1 token out hostval
  token="@@SZ$RANDOM$RANDOM$$@@"
  out=$(rish_c_t 20 "mkdir -p '$cand/$SHARED_SUBDIR' 2>/dev/null || exit 1
printf '%s' '$token' > '$cand/$SHARED_SUBDIR/.probe' 2>/dev/null || exit 1
cat '$cand/$SHARED_SUBDIR/.probe'" 2>&1) || return 1
  case "$out" in *"$token"*) ;; *) return 1 ;; esac
  hostval=$(cat "$cand/$SHARED_SUBDIR/.probe" 2>/dev/null) || return 1
  [ "$hostval" = "$token" ] || return 1
  return 0
}

# Print a usable shared-storage root, or nothing. Cached in WORK_DIR; the
# cache is re-probed if the path disappears. A cached "NONE" (storage not
# reachable) avoids paying for the probe on every call; set
# SHIZUKU_REPROBE_SHARED=1 to force a fresh probe after granting storage access.
shared_root() {
  local cache="$WORK_DIR/.shared_root" r
  if [ -s "$cache" ] && [ "${SHIZUKU_REPROBE_SHARED:-0}" != 1 ]; then
    r=$(cat "$cache" 2>/dev/null)
    if [ "$r" = NONE ]; then return 1; fi
    if [ -n "$r" ] && [ -d "$r/$SHARED_SUBDIR" ] && [ -r "$r/$SHARED_SUBDIR" ]; then
      printf '%s' "$r"; return 0
    fi
  fi
  for r in $SHARED_CANDIDATES; do
    if _shared_probe_one "$r"; then
      printf '%s\n' "$r" > "$cache" 2>/dev/null || true
      printf '%s' "$r"; return 0
    fi
  done
  printf 'NONE\n' > "$cache" 2>/dev/null || true
  return 1
}

# _shared_get <device-src> <host-dst> <root>
_shared_get() {
  local src=$1 dst=$2 root=$3
  local name=".xfer.$$.$RANDOM$RANDOM" out want got
  out=$(rish_c_t 90 "cp -f '$src' '$root/$SHARED_SUBDIR/$name' 2>/dev/null || exit 1
echo M:\$(md5sum '$root/$SHARED_SUBDIR/$name' | cut -d' ' -f1)" 2>&1) || return 1
  want=$(printf '%s\n' "$out" | sed -n 's/^M:\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | tail -n1)
  [ -n "$want" ] || return 1
  if ! cp -f "$root/$SHARED_SUBDIR/$name" "$dst" 2>/dev/null; then
    rm -f "$root/$SHARED_SUBDIR/$name" 2>/dev/null || true
    return 1
  fi
  rm -f "$root/$SHARED_SUBDIR/$name" 2>/dev/null || true
  got=$(md5sum "$dst" 2>/dev/null | cut -d' ' -f1)
  [ "$want" = "$got" ]
}

# _chunked_get <device-src> <host-dst>: gzip + base64, chunk by chunk.
_chunked_get() {
  local src=$1 dst=$2
  local base="$ANDROID_TMP/.xfer.$$" meta comp want total i n attempt out ok
  local part="$dst.part" cb="$dst.chunk.b64" cf="$dst.chunk"
  rm -f "$part" "$cb" "$cf" 2>/dev/null || true

  meta=$(rish_c_t 60 "rm -f '$base.gz' '$base.raw' '$base.chunk' 2>/dev/null
if gzip -c '$src' > '$base.gz' 2>/dev/null; then echo C:1; else cp -f '$src' '$base.raw' 2>/dev/null || exit 1; echo C:0; fi
if [ -s '$base.gz' ]; then echo M:\$(md5sum '$base.gz' | cut -d' ' -f1); echo S:\$(wc -c < '$base.gz'); else echo M:\$(md5sum '$base.raw' | cut -d' ' -f1); echo S:\$(wc -c < '$base.raw'); fi" 2>&1) || return 1

  comp=$(printf '%s\n' "$meta" | sed -n 's/^C:\([01]\).*/\1/p' | tail -n1)
  want=$(printf '%s\n' "$meta" | sed -n 's/^M:\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | tail -n1)
  total=$(printf '%s\n' "$meta" | sed -n 's/^S:\([0-9][0-9]*\).*/\1/p' | tail -n1)
  case "$comp" in 0|1) ;; *) return 1 ;; esac
  [ -n "$want" ] || return 1
  case "$total" in ''|*[!0-9]*) return 1 ;; esac

  : > "$part"
  i=0
  while [ $((i * CHUNK)) -lt "$total" ]; do
    n=$((total - i * CHUNK))
    [ "$n" -gt "$CHUNK" ] && n=$CHUNK
    ok=0
    for attempt in 1 2 3 4 5 6; do
      out=$(rish_c_t 30 "dd if='$base.gz' bs=$CHUNK skip=$i count=1 of='$base.chunk' 2>/dev/null || dd if='$base.raw' bs=$CHUNK skip=$i count=1 of='$base.chunk' 2>/dev/null
echo D:\$(md5sum '$base.chunk' | cut -d' ' -f1)
base64 '$base.chunk'" 2>&1)
      # Keep only base64 alphabet lines so loader chatter cannot poison the data.
      printf '%s\n' "$out" | grep -E '^[A-Za-z0-9+/=]+$' | tr -d '\n' > "$cb" 2>/dev/null || true
      ch_md5=$(printf '%s\n' "$out" | sed -n 's/^D:\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | tail -n1)
      if base64 -d < "$cb" > "$cf" 2>/dev/null \
         && [ "$(wc -c < "$cf" 2>/dev/null)" -eq "$n" ] \
         && [ -n "$ch_md5" ] \
         && [ "$(md5sum "$cf" 2>/dev/null | cut -d' ' -f1)" = "$ch_md5" ]; then
        ok=1; break
      fi
    done
    [ "$ok" = 1 ] || { rm -f "$part" "$cb" "$cf" 2>/dev/null; return 1; }
    cat "$cf" >> "$part"
    i=$((i + 1))
  done

  if [ "$(md5sum "$part" 2>/dev/null | cut -d' ' -f1)" != "$want" ]; then
    rm -f "$part" "$cb" "$cf" 2>/dev/null; return 1
  fi
  if [ "$comp" = 1 ]; then
    gzip -dc < "$part" > "$dst" 2>/dev/null || { rm -f "$part" "$cb" "$cf"; return 1; }
  else
    mv -f "$part" "$dst" 2>/dev/null || return 1
  fi
  rm -f "$part" "$cb" "$cf" 2>/dev/null || true
  # Temp files stay in $ANDROID_TMP and are overwritten by the next transfer
  # (the metadata step removes them first). Cleaning them here would cost one
  # extra rish session (~5 s) for no benefit.
  [ -s "$dst" ]
}

# device_get_file <device-path> <host-path> [shared-root]
# Pull one file from the device and verify it. Uses shared storage when it is
# available and falls back to a verified chunked stdout transfer.
device_get_file() {
  local src=$1 dst=$2 root=${3-}
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  if [ -z "${3+x}" ]; then root=$(shared_root 2>/dev/null) || root=""; fi
  if [ -n "$root" ] && _shared_get "$src" "$dst" "$root" && [ -s "$dst" ]; then
    return 0
  fi
  _chunked_get "$src" "$dst" && [ -s "$dst" ]
}

# ui_dump_to <host-file> [pkg-gate]: fresh accessibility dump + transfer.
# The dump is trusted only when uiautomator's own output contains "dumped to"
# (a failed dump can leave the previous file on disk). Retries up to 5x because
# animating screens can report "could not get idle state". Returns non-zero on a
# failed/stale dump.
ui_dump_to() {
  local host_file=$1 gate=${2:-} root raw attempt
  UI_DUMP_RAW=""
  root=$(shared_root 2>/dev/null) || root=""

  for attempt in 1 2 3 4 5; do
    raw=""
    rm -f "$host_file" 2>/dev/null || true
    if [ -n "$root" ]; then
      # Remove any previous copy first so a silent copy failure cannot leave a
      # stale tree behind for the host to read.
      rm -f "$root/$SHARED_SUBDIR/.ui.xml" 2>/dev/null || true
      raw=$(rish_c_t 30 "
echo 'FOCUS: '\$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
uiautomator dump $ANDROID_TMP/.ui.xml 2>&1 || exit 3
cp -f $ANDROID_TMP/.ui.xml '$root/$SHARED_SUBDIR/.ui.xml' 2>/dev/null || exit 4
echo XFER_OK
" 2>&1) || true
      UI_DUMP_RAW=$raw
      case "$raw" in
        *"dumped to"*XFER_OK*)
          if [ -s "$root/$SHARED_SUBDIR/.ui.xml" ] \
             && cp -f "$root/$SHARED_SUBDIR/.ui.xml" "$host_file" 2>/dev/null \
             && [ -s "$host_file" ]; then
            rm -f "$root/$SHARED_SUBDIR/.ui.xml" 2>/dev/null || true
            break
          fi
          ;;
      esac
      rm -f "$root/$SHARED_SUBDIR/.ui.xml" 2>/dev/null || true
      # The dump itself may be fine but the copy failed; try the verified
      # transfer path before retrying the whole dump.
      case "$raw" in
        *"dumped to"*)
          if device_get_file "$ANDROID_TMP/.ui.xml" "$host_file" "$root" && [ -s "$host_file" ]; then
            break
          fi
          ;;
      esac
    else
      raw=$(rish_c_t 30 "
echo 'FOCUS: '\$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
uiautomator dump $ANDROID_TMP/.ui.xml 2>&1 || exit 3
" 2>&1) || true
      UI_DUMP_RAW=$raw
      case "$raw" in
        *"dumped to"*)
          if device_get_file "$ANDROID_TMP/.ui.xml" "$host_file" "" && [ -s "$host_file" ]; then
            break
          fi
          ;;
      esac
    fi
    [ "$attempt" -lt 5 ] && sleep 1
  done

  if [ ! -s "$host_file" ]; then
    printf 'ERR: uiautomator dump failed 5x (last: %s)\n' \
      "$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-160)" >&2
    return 1
  fi
  if [ -n "$gate" ] && ! "$PY" "$SCRIPTS_DIR/ui_wait_check.py" "$host_file" "pkg:$gate" >/dev/null 2>&1; then
    printf 'ERR: current UI is not %s (gate failed)\n' "$gate" >&2
    return 4
  fi
  return 0
}

# ui_dump_meta <host-file>: print "pkg=<pkg>" for the dumped tree.
ui_pkg_of() {
  "$PY" - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    print("?"); raise SystemExit
for el in root.iter():
    p = el.attrib.get("package")
    if p:
        print(p); break
else:
    print("?")
PY
}
