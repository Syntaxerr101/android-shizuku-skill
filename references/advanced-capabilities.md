# Advanced capabilities — beyond basic logging

Everything below is performed through `rish` with the identity the server was
started with (`shell` for adb). Probe each capability in your environment
instead of assuming it works; ROMs and server identities differ.

## 1. UI automation channel (eyes + hands, no root)

| Step | Command (via rish) | Output |
|---|---|---|
| See the screen | `screencap -p /data/local/tmp/.shot.png` | PNG (size depends on the device) |
| Read the UI tree | `uiautomator dump /data/local/tmp/.ui.xml` | full hierarchy: class, text, bounds per node |
| Act on it | `input tap X Y` / `input swipe` / `input keyevent` | needs the `input` group (shell has it) |
| Current focus | `dumpsys window \| grep mCurrentFocus` | `pkg/activity` |
| Top activity | `dumpsys activity top \| grep "ACTIVITY "` | task stack incl. other apps |

- The UI XML gives exact `bounds="[x1,y1][x2,y2]"` per node → compute the centre
  and `input tap`. Never hard-code coordinates; derive them from a fresh dump
  (`scripts/ui-fast.sh` / `ui-act.sh`).
- Prefer the wrapper scripts for automation: `ui-dump.sh` (read),
  `ui-act.sh` (act), `ui-wait.sh` (confirm), `ui-fast.sh` (one session),
  `ui-shell.sh` (persistent session). Playbook: `references/ui-automation.md`.
- `uiautomator dump` needs a focused, alive window. Secure windows (PIN entry,
  banking, keyguard) refuse the dump; wake the device first if the screen is off.

### Moving artifacts between the device and the host

`rish`'s stdout is not a safe bulk channel: the loader may split output across
fd1/fd2, and writes above a few KB can be truncated. The bundled scripts use a
two-tier transfer (`device_get_file` in `scripts/lib.sh`):

1. **Shared storage (primary).** The device writes the artifact under a probe
   directory on `/sdcard` (or `/storage/emulated/0`, `/mnt/sdcard`,
   `/storage/self/primary`), the host reads it at the *same absolute path*, and
   both sides compare md5. The first working root is cached in
   `$WORK_DIR/.shared_root`; `SHIZUKU_REPROBE_SHARED=1` forces a re-probe.
2. **Verified chunked stdout (fallback).** The device gzips the file, the host
   pulls it as base64 in small chunks (one short rish session per chunk), and
   every chunk plus the reassembled file is checked against its md5. Slower, but
   it works with nothing but the rish pipe.

`/data/local/tmp` is owned by the shell identity and is used as the on-device
staging area. Do not assume the host sees the same `/data` tree: inside PRoot
or a chroot, host `/data` may be a different filesystem or may not include
`/data/local/tmp`.

Shared storage is usually visible from PRoot as well. In native Termux, run
`termux-setup-storage` once and grant the prompt so `/sdcard` is readable; the
fallback keeps working even without it.

## 2. `run-as` into debuggable apps

```sh
rish -c 'run-as <pkg> id'
```

Succeeds only for apps built `debuggable=true`; other apps return
`not debuggable`. Useful for reading/repairing a debuggable app's private files
from the shell identity.

## 3. AppOps — read any app, mutate cautiously

- **Read any app:** `appops get <pkg>`.
- **Write any app:** `appops set <pkg> <OP> allow|ignore|deny` may work from the
  shell identity.
- **⚠️ Writing ops can kill the target app's processes** so the new ops apply.
  Mutating the terminal app kills your shell. **Never mutate ops/permissions of
  the app hosting your session.**
- **Quirk:** `appops set <pkg> <OP> default` often prints success but does not
  clear an explicit op. Only `appops reset <pkg>` clears — and that also kills
  the app.
- `pm grant` / `pm revoke` may have no effect without root/privileged paths.

## 4. Process & `/proc` visibility

- `ps -A -o PID,PPID,USER,ARGS` (toybox) shows full command lines, including
  container/proot invocations if present.
- `pidof <pkg>` / `pidof shizuku_server` for quick lookups.
- `/proc/<pid>/maps` is readable only for same-uid processes (plus some
  `readproc`/`readtracefs` exceptions). Expect `Permission denied` for other
  apps' entries.

## 5. Device-wide runtime stats for any app (read-only)

| Source | What |
|---|---|
| `dumpsys meminfo` | per-process RSS / PSS table |
| `dumpsys gfxinfo <pkg>` | frame stats / jank |
| `dumpsys battery` | level, status, temperature |
| `dumpsys netstats` | per-interface usage |
| `dumpsys activity top` | task stack of all apps |
| `dumpsys activity exit-info <pkg>` / `dumpsys dropbox` | crashes (see `logs-and-crashes.md`) |

## 6. Network visibility

- `ip addr` — interfaces.
- `dumpsys connectivity` — L3 details (SSID, BSSID, IP, gateway, DNS, RSSI,
  link speed), subject to the ROM's redaction rules.
- `ping` works when the process has the `inet` group (shell does).

## 7. Package inventory for any app

- `pm list packages`, `pm list packages -3` (third party), `pm list packages -d`
  (disabled).
- `dumpsys package <pkg>` → versionName/Code, codePath, minSdk/targetSdk,
  requested + granted permissions.
- `pm path <pkg>`, `cmd package list features`, `pm list libraries`.

## 8. Concurrency behaviour (important)

Parallel `rish` invocations intermittently fail with
`Request timeout. The connection between the current app (<terminal>) and Shizuku
app … disable all battery optimization for both apps.`

- Each run sends an ordered `REQUEST_BINDER` broadcast with a ~5 s wait;
  pile-ups time out. **Batch many commands into ONE `-c '...'`** (the doctor
  script does this).
- The manager app can die on any background broadcast while
  `start_on_boot_wireless` is ON and the device is on Wi-Fi.
  **Eliminate it once** with `bash scripts/shizuku-disable-selfstart.sh`
  (reversible with `--enable`). Or, for terminal-only bursts, foreground the
  manager first:
  `am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity`.
- For UI automation (target app must stay foreground) run the fix script first;
  otherwise keep each script to one broadcast and confirm every action with
  `ui-wait.sh` / the verify step in `ui-fast.sh`.

## Safety recap

- Read-only by default.
- Mutating powers seen in practice: `input`, `am`, `appops set` (kills target),
  writes to shared storage / `/data/local/tmp`, some `settings put` calls.
- Never target the terminal app (or any process your shell depends on) with
  appop or permission mutations.
