#!/usr/bin/env bash
# android-shizuku-skill — restore / refresh the bundled rish loader.
#
# The skill ships bin/rish + bin/rish_shizuku.dex. If those are missing (e.g. the
# skill was copied without them), this script extracts them from the installed
# Shizuku manager APK. The APK path is discovered with `pm path`, so it works on
# any device and any Shizuku install location.
#
# Usage:
#   bash rish-bootstrap.sh                  # auto: pm path -> extract -> verify
#   bash rish-bootstrap.sh --apk <apk>      # use a specific APK/base.apk
#   bash rish-bootstrap.sh --check          # only test the current rish
#   bash rish-bootstrap.sh --force          # overwrite bin/ even if present
#   bash rish-bootstrap.sh --no-check       # skip the post-install rish test
#
# Manual fallback (no rish, no adb): open the Shizuku APK in any unzip tool,
# extract "assets/rish" and "assets/rish_shizuku.dex", and put both files in
# this skill's bin/ directory (rish mode 755, dex mode 644).
set -u

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
SKILL_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
BIN="$SKILL_ROOT/bin"
RISH="$SCRIPT_DIR/rish"
MANAGER=moe.shizuku.privileged.api

APK=""
DO_CHECK=1
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK=${2:-}; [ -n "$APK" ] || { echo "ERR: --apk needs a path" >&2; exit 2; }; shift 2 ;;
    --check) APK="__CHECK_ONLY__"; shift ;;
    --no-check) DO_CHECK=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "ERR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY=$c; break; }; done
[ -n "$PY" ] || { echo "ERR: python3 is required" >&2; exit 1; }

extract_apk() { # <apk> <outdir>
  "$PY" - "$1" "$2" <<'PY'
import os, sys, zipfile
apk, out = sys.argv[1], sys.argv[2]
want = {"assets/rish": "rish", "assets/rish_shizuku.dex": "rish_shizuku.dex"}
os.makedirs(out, exist_ok=True)
with zipfile.ZipFile(apk) as z:
    names = set(z.namelist())
    for src, dst in want.items():
        if src not in names:
            sys.exit("missing entry in APK: " + src)
        data = z.read(src)
        with open(os.path.join(out, dst), "wb") as f:
            f.write(data)
        print("%-28s %6d bytes" % (dst, len(data)))
PY
}

verify_files() { # <dir>
  local dir=$1
  [ -s "$dir/rish" ] && [ -s "$dir/rish_shizuku.dex" ] || return 1
  grep -q "ShizukuShellLoader" "$dir/rish" 2>/dev/null || return 1
  grep -q "app_process" "$dir/rish" 2>/dev/null || return 1
  head -c 4 "$dir/rish_shizuku.dex" | grep -q "dex" || return 1
  [ "$(wc -c < "$dir/rish_shizuku.dex")" -gt 1000 ] || return 1
  return 0
}

check_rish() {
  echo "== rish self-test =="
  if "$RISH" -c 'echo RISH_OK; id' 2>&1; then
    return 0
  fi
  cat <<'EOF'

The loader is present but could not connect. Common causes:
  1. Shizuku server is not running            -> start it in the Shizuku app.
  2. This terminal app is not authorized      -> approve its permission prompt.
  3. Wrong application id                     -> export RISH_APPLICATION_ID=<pkg>
                                                 (or write it to ~/.config/shizuku-skill/app-id)
  4. rish_shizuku.dex is writable (SDK 34+)   -> the wrapper chmods it to 400;
                                                 move the skill to app-private storage if chmod fails.
  5. No Wi-Fi / manager crashed               -> see references/troubleshooting.md
EOF
  return 1
}

if [ "$APK" = "__CHECK_ONLY__" ]; then
  exit $([ -x "$RISH" ] && "$RISH" -c 'echo RISH_OK' >/dev/null 2>&1; echo $?)
fi

if [ -z "$APK" ]; then
  echo "== locating Shizuku manager APK =="
  out=$("$RISH" -c "pm path $MANAGER 2>/dev/null" 2>&1) || true
  APK=$(printf '%s\n' "$out" | sed -n 's/^package://p' | head -n1)
  if [ -z "$APK" ]; then
    printf '%s\n' "$out" | sed 's/^/  /'
    cat <<EOF

ERR: could not resolve the manager APK through rish.

Do one of these:
  * start Shizuku and authorize this terminal app, then re-run this script;
  * bash "$0" --apk /path/to/base.apk
  * manually copy "assets/rish" and "assets/rish_shizuku.dex" from the Shizuku
    APK into "$BIN/" (use any unzip/file-manager app).

The manager package is $MANAGER.
EOF
    exit 1
  fi
  echo "APK: $APK"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rish-bootstrap.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

SRC=$APK
if [ ! -r "$SRC" ]; then
  echo "== APK not readable from this shell; pulling it through rish =="
  case "$APK" in *"'"*) echo "ERR: unsupported quote in APK path" >&2; exit 1 ;; esac
  if ! "$RISH" -c "cat '$APK'" > "$TMP/base.apk" 2>"$TMP/cat.err"; then
    cat "$TMP/cat.err" >&2
    echo "ERR: could not read the APK. Use --apk with a readable copy." >&2
    exit 1
  fi
  SRC="$TMP/base.apk"
fi

echo "== extracting assets =="
if ! extract_apk "$SRC" "$TMP/out"; then
  echo "ERR: extraction failed (is this the Shizuku manager APK?)" >&2
  exit 1
fi
if ! verify_files "$TMP/out"; then
  echo "ERR: extracted files failed validation" >&2
  exit 1
fi

echo "== installing into $BIN =="
mkdir -p "$BIN" || { echo "ERR: cannot create $BIN" >&2; exit 1; }
for f in rish rish_shizuku.dex; do
  if [ -f "$BIN/$f" ] && [ "$FORCE" = 0 ] && cmp -s "$TMP/out/$f" "$BIN/$f"; then
    echo "$f: already up to date"
    continue
  fi
  cp -f "$TMP/out/$f" "$BIN/$f" || { echo "ERR: cannot write $BIN/$f" >&2; exit 1; }
  echo "$f: installed"
done
chmod 755 "$BIN/rish" 2>/dev/null
chmod 644 "$BIN/rish_shizuku.dex" 2>/dev/null

echo "== md5 =="
md5sum "$BIN/rish" "$BIN/rish_shizuku.dex" 2>/dev/null || true

# Force the launcher to restage the new copies.
rm -rf "$HOME/.rish-skill" 2>/dev/null || true

[ "$DO_CHECK" = 1 ] && check_rish
echo "bootstrap done."
