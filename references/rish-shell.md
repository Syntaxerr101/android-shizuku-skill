# rish — a privileged shell from Termux or PRoot

`rish` is Shizuku's terminal loader. It starts
`/system/bin/app_process` with `rish_shizuku.dex` on the classpath and enters
`rikka.shizuku.shell.ShizukuShellLoader`, which asks the Shizuku server for a
shell running as the server identity (`shell`/uid 2000 for adb, `root` for a
root start). No root, no adb cable, no `su` is required on the device.

## 1. The three moving parts

| Part | Where it lives | Notes |
|---|---|---|
| `rish` | bundled at `bin/rish`, staged to `<app-home>/.rish-skill/rish` | a `/system/bin/sh` script that starts `app_process` |
| `rish_shizuku.dex` | bundled at `bin/rish_shizuku.dex`, staged beside it | must be non-writable on Android 14+; staged mode `0400` |
| application id | `RISH_APPLICATION_ID` | package name of the terminal app, not the uid |

The bundled `rish` keeps the upstream `PKG` placeholder. The wrapper always
exports `RISH_APPLICATION_ID`, so the placeholder is never used. If you run
`bin/rish` directly, export the id yourself.

## 2. Why the app id matters

Shizuku records authorization per **package** (and uid) in `shizuku.json`.
When the loader attaches, the server verifies that the requested package belongs
to the calling uid. A wrong id produces an authorization failure even though
the server is healthy.

`scripts/rish` resolves the id in this order:

1. `SHIZUKU_APP_ID` (skill-specific override),
2. `RISH_APPLICATION_ID` (upstream variable),
3. `$SKILL/.app-id`,
   `${XDG_CONFIG_HOME:-$HOME/.config}/shizuku-skill/app-id`,
   `$HOME/.rish-app-id`,
4. any of `$PREFIX`, `$HOME`, `$SHELL`, `$TMPDIR`, `$PROOT_*` that contains
   `/data/data/<pkg>/...` or `/data/user/<n>/<pkg>/...`,
5. the process ancestry (up to 8 parents) — this catches proot-distro, whose
   process command line contains `/data/data/<terminal>/...` even after the
   environment is scrubbed,
6. `com.termux` as a last resort, only if `/data/data/com.termux/files/home`
   exists.

Force it when auto-detection is wrong:

```sh
RISH_APPLICATION_ID=com.example.terminal bash scripts/rish -c id
# persistent:
mkdir -p ~/.config/shizuku-skill
printf '%s\n' com.example.terminal > ~/.config/shizuku-skill/app-id
# inspect:
RISH_DEBUG=1 bash scripts/rish -c id
```

## 3. Why the loader is staged into app-private storage

Android 14+ (`sdk >= 34`) refuses to load a writable dex through `app_process`.
Shared storage (`/sdcard`) is FUSE-backed; `chmod 400` there does not produce a
read-only file from `app_process`'s point of view. The only portable location is
the terminal app's private data directory, which is:

- writable by the terminal app (so the wrapper can chmod),
- readable by `app_process` (same uid),
- visible unchanged from PRoot (the Android filesystem is bind-mounted), so the
  Android path and the PRoot path are identical.

The wrapper resolves `<app-home>` as:

1. `/data/data/<id>/files/home` if it exists and is writable,
2. `$HOME` when it is already under `/data/data/<id>/files/`,
3. `/data/data/<id>/files` if writable,
4. `$HOME` as a last resort (prints no error, but Android 14+ may reject it).

Runtime layout:

```
/data/data/<terminal-app>/files/home/.rish-skill/
├── rish                 (0700)
└── rish_shizuku.dex     (0400)
```

The wrapper compares the bundled files with the staged copies (`cmp`) and
re-copies when they differ, so updating the skill's `bin/` is enough.

## 4. Native Termux vs PRoot

**Termux**

```sh
pkg install python        # once, for the parser helpers
bash ~/android-shizuku-skill/scripts/shizuku-doctor.sh
bash ~/android-shizuku-skill/scripts/rish -c 'id'
```

`$HOME` is already the app-private home; `$PREFIX` is
`/data/data/<pkg>/files/usr`; the wrapper sees both.

**PRoot / proot-distro Ubuntu**

```sh
apt install python3        # once
bash /path/to/android-shizuku-skill/scripts/shizuku-doctor.sh
bash /path/to/android-shizuku-skill/scripts/rish -c 'id'
```

Inside PRoot, `$HOME` is a container path (for example `/home/user`), but
`/data/data/<pkg>/...`, `/system`, `/dev` and `/proc` are bind-mounted. The
wrapper therefore uses the **Android** home
(`/data/data/<pkg>/files/home/.rish-skill`), not `$HOME`. This is what makes
the same staged dex usable by `app_process`.

If a chroot does **not** bind-mount `/system`, `app_process` is unavailable and
`rish` cannot run there. Use native Termux or a PRoot that exposes `/system`.

## 5. Bootstrap / recovery

If `bin/rish` or `bin/rish_shizuku.dex` is missing, or you suspect corruption:

```sh
bash scripts/rish-bootstrap.sh                 # pm path -> extract -> verify
bash scripts/rish-bootstrap.sh --apk /path/to/base.apk
bash scripts/rish-bootstrap.sh --check         # test only
bash scripts/rish-bootstrap.sh --force         # overwrite bin/
```

What it does:

1. runs `pm path moe.shizuku.privileged.api` through the current wrapper,
2. if the APK is not host-readable, pulls it through `rish` (`cat`),
3. extracts `assets/rish` and `assets/rish_shizuku.dex` with Python's `zipfile`,
4. validates the script (`ShizukuShellLoader`, `app_process`) and the dex magic,
5. installs them into `bin/` and runs a self-test.

### Manual extraction (no rish, no adb)

Use any unzip/file-manager app (or the MT Manager MCP server):

1. locate the Shizuku manager APK (`/data/app/.../base.apk`),
2. extract `assets/rish` and `assets/rish_shizuku.dex`,
3. copy both into `<skill>/bin/`,
4. `chmod 755 bin/rish; chmod 644 bin/rish_shizuku.dex`,
5. run `bash scripts/rish-bootstrap.sh --check`.

Never use `librish.so` as a substitute for the dex: the Java loader in current
builds does not load it. `librish.so` is for native (JNI) shell clients.

## 6. Command forms and cost

```sh
RISH=scripts/rish

"$RISH" -c 'id'                         # one command
"$RISH" -c 'echo a; echo b | head'      # one shell line, one session
printf 'id\npidof shizuku_server\n' | "$RISH"   # scripted session
"$RISH"                                 # interactive (avoid in automation)
```

- Cost is per **invocation**: several seconds for the broadcast handshake plus
  process start, regardless of the number of commands in the script.
- Combine dump/resolve/act/verify into one invocation (see `ui-fast.sh`).
- Environment variables from the host do **not** reach the rish shell. Inject
  values into the script text; `scripts/ui-fast.sh` does this with base64 to
  avoid quoting/injection problems.
- Never run two rish invocations concurrently. Each uses an ordered broadcast
  with a short timeout; concurrency yields `Request timeout` and extra manager
  churn.

## 7. Capability probes

```sh
"$RISH" -c 'id; getenforce'
"$RISH" -c 'command -v su || echo no-su'
"$RISH" -c 'cat /proc/self/status | grep -E "Uid|Gid|CapEff"'
"$RISH" -c 'ls -ld /data/local/tmp /data/anr /data/tombstones 2>&1'
"$RISH" -c 'settings get global adb_enabled'
```

Expected for an adb-started server: uid 2000, `u:r:shell:s0`, groups including
`input`, `log`, `adb`, `sdcard_rw`, `readproc`, `inet`. A root-started server
shows uid 0 and a root SELinux context (often `u:r:magisk:s0`).

## 8. Pitfalls

| Symptom | Cause / fix |
|---|---|
| `RISH_APPLICATION_ID is not set` | run through `scripts/rish`, or export the terminal package |
| `Cannot find …rish_shizuku.dex` | run bootstrap; keep both files together |
| `app_process cannot load writable dex` | stage into app-private storage; ensure mode `0400` |
| `Request timeout … disable battery optimization` | parallel calls / server suspended; serialize, whitelist both apps |
| `Binder not received in 5s` | server is not running; start Shizuku |
| Works in Termux, fails in PRoot | PRoot lacks `/system` or access to `/data/data`; use the bundled wrapper, not a copied path |
| Manager app dies during bursts | see the FGS and `NoSuchMethodError` crash classes; run the self-start toggle and keep actions crash-tolerant |

## 9. Pulling files off the device

Do not stream large artifacts through rish stdout: the loader may split them
across fd1/fd2 and truncate writes above a few KB. Use `device_get_file` from
`scripts/lib.sh`, which tries:

1. **Shared storage** — the device copies the file under a probe directory on
   `/sdcard` (or `/storage/emulated/0`, `/mnt/sdcard`, `/storage/self/primary`),
   the host reads the same path, and md5 is compared on both sides. The usable
   root is cached in `$WORK_DIR/.shared_root` (`SHIZUKU_REPROBE_SHARED=1`
   re-probes). In native Termux, run `termux-setup-storage` once to make
   `/sdcard` readable.
2. **Verified chunked stdout** — gzip on device, base64 in small chunks (one
   short rish session each), md5 per chunk and for the whole file. Slow but
   portable; used when shared storage is unavailable.

`/data/local/tmp` is only the on-device staging area (`ANDROID_TMP`); it is not
assumed to be shared with the host.
