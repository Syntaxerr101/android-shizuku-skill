# Logs & crashes — debugging ANY app (verified on this device)

All four crash/log sources work from plain `rish` (uid 2000, no root):

| Source | What it holds | Command |
|---|---|---|
| `logcat -b crash` | Last Java/kotlin **FATAL EXCEPTION** stacks (all apps) | `logcat -b crash -d -v threadtime` |
| `logcat` (main/events) | Live app + system logs | `logcat -d [--pid=<pid>] [-s <Tag>:*]` |
| `dumpsys activity exit-info <pkg>` | Per-package **exit history** with reason codes | `dumpsys activity exit-info <pkg>` |
| `dumpsys dropbox --print` | **Crash/ANR/WTF bullets** with metadata | `dumpsys dropbox --print` |
| `/data/anr/*` | Full **ANR** trace files | `ls /data/anr; head -40 /data/anr/anr_*` |
| `/data/tombstones/*` | **Native** crash dumps | `head -60 /data/tombstones/tombstone_00` |

## 1. Why every source is needed

- Java crash (`reason=4`) → stack in `logcat -b crash`.
- Native crash → `reason=9`, tombstone under `/data/tombstones/` (not in logcat).
- ANR (`reason=1`) → trace under `/data/anr/` and dropbox `system_app_anr`/`data_app_anr`.
- Killed/OOM (`reason=3`) → only visible in `exit-info`, no stack anywhere.
Always cross-check `exit-info` + crash buffer + dropbox.

## 2. `exit-info` — reason codes (real samples)

> All pids/timestamps in the samples below are **historical captures** (that run's
> process at that time). They turn over on every crash/force-stop/reboot — treat
> them as format examples, never as live values.

`dumpsys activity exit-info com.termux` (captured):

```
package: com.termux
  Historical Process Exit for uid=<uid>
    ApplicationExitInfo #0:
      timestamp=2026-10-09 18:13:47.699 pid=<pid> realUid=<uid> ...
      process=com.termux reason=3 (LOW_MEMORY) ... importance=125 pss=0.00 rss=89MB
```

`dumpsys activity exit-info moe.shizuku.privileged.api` (captured):

```
    ApplicationExitInfo #0:
      timestamp=2026-10-09 18:37:28.727 pid=<pid> ...
      process=moe.shizuku.privileged.api reason=4 (APP CRASH(EXCEPTION)) ... rss=131MB description=crash
    ApplicationExitInfo #1:
      ... reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) ... description=stop moe.shizuku.privileged.api
```

| reason | meaning |
|---|---|
| 1 | ANR |
| 3 | LOW_MEMORY (lru-kill under memory pressure) |
| 4 | APP CRASH(EXCEPTION) — uncaught exception |
| 9 | SIGNALED — killed by signal (SIGKILL/SIGSEGV/ABRT) |
| 10 | USER REQUESTED — force-stop or app-initiated exit |

## 3. End-to-end: debug a specific app

```sh
PGK=com.example.hibernator   # or ANY package
"$RISH" -c "
echo '-- exit-info --';      dumpsys activity exit-info $PGK | sed -n '1,14p'
echo '-- crash buffer --';   logcat -b crash -d -v threadtime | grep -A20 -m1 $PGK
echo '-- dropbox --';        dumpsys dropbox --print | grep -A12 -B2 $PGK
echo '-- logs --';           logcat -d -v threadtime --pid=\$(pidof $PGK) | tail -40
"
```

Real dropbox crash entry (hibernator service, captured):

```
2026-10-07 00:49:24 data_app_crash (text, 2008 bytes)
SystemUptimeMs: <ms>
Process: com.example.hibernator:service
PID: <pid>
UID: <uid>
Package: com.example.hibernator v<version> (5.0)
Foreground: No
```

Real ANR trace header (captured):

```
Subject: Input dispatching timed out (7b4d2a9 NavigationBar0 (server) is not responding.
Waited 10001ms for MotionEvent).
RssHwmKb: <kb> ...
```

Real tombstone header (captured):

```
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
Build fingerprint: '<build-fingerprint>'
ABI: 'arm64'
Timestamp: 2026-07-22 05:59:46.536165017+0100
Process uptime: 2s
```

## 4. Shizuku's own crash — anatomy

Signature (captured, reproduced many times):

```
E AndroidRuntime: Process: moe.shizuku.privileged.api, PID: <pid>
E AndroidRuntime: java.lang.RuntimeException: Unable to start receiver moe.shizuku.manager.receiver.ShizukuReceiver:
  android.app.ForegroundServiceStartNotAllowedException: startForegroundService() not allowed
  due to mAllowStartForeground false: service moe.shizuku.privileged.api/moe.shizuku.manager.starter.SelfStarterService
E AndroidRuntime: Caused by: android.app.ForegroundServiceStartNotAllowedException: startForegroundService() …
  at android.app.ContextImpl.startForegroundService(ContextImpl.java:2067)
  at android.content.ContextWrapper.startForegroundService(ContextWrapper.java:832)
  at rikka.shizuku.f7.j(SourceFile:1)
  at moe.shizuku.manager.receiver.ShizukuReceiver.onReceive(SourceFile:62)
```

Decoded trigger path (from smali, v1171):

1. Any rish / Shizuku client fires ordered broadcast `rikka.shizuku.intent.action.REQUEST_BINDER`
   (the loader does this on every run — see architecture.md).
2. `ShizukuReceiver.onReceive`: REQUEST_BINDER branch → `LA.l(ctx, intent)` (binder hand-off).
   **Then, unconditionally** (this tail is outside the action check, so it runs on
   every broadcast the receiver gets), it reads SharedPreferences
   **`start_on_boot_wireless`** (default false).
3. If the pref is true → `rikka.shizuku.Ht.r(contentResolver, ctx, false)` must
   return true. That method returns **true only when the active network transport
   is Wi‑Fi** (it then flips `adb_wifi_enabled`); otherwise it logs
   *"Wireless ADB auto-start condition not met: Not on Wi-Fi."* and returns false
   → **no crash**. So the crash needs *pref true AND on Wi‑Fi AND manager
   background*.
4. Builds `Intent(SelfStarterService)` with
   `AUTO_ENABLE_WIRELESS_DEBUGGING=true, FORCE_RESTART=false, DISABLE_WIRELESS_DEBUGGING_WHEN_FINISHED=true`.
5. `rikka.shizuku.f7.j(ctx, intent)` is a 2-instruction bridge →
   `Context.startForegroundService(...)` — **uncaught** here.

`BootCompleteReceiver` has the same FGS start but wraps it in `catch (SecurityException)`
— which does **not** cover `ForegroundServiceStartNotAllowedException` (it extends
`IllegalStateException`), so the class is fragile there too; the `ShizukuReceiver`
path is the one every `rish` call exercises.

### Every rish call can re-trigger it (burst behaviour)

On this device (pref enabled + on Wi‑Fi) *every* `rish` invocation fires the
`REQUEST_BINDER` broadcast while the manager app is in the background, so each
call is a potential trigger. Under a burst of calls you get a **crash cascade** —
`exit-info` fills with one `reason=4` per call (captured chain: 19:51:39, 19:52:28,
19:53:43, 19:56:10, 19:56:52, 19:59:48 — one per rish batch, timestamps matching
the command run).

While the manager crash-loops / cold-starts, later calls can miss the 5 s binder
window and fail with `Request timeout … disable battery optimization for both
apps`. `shizuku_server` is unaffected (separate process).

**Eliminate it (verified):** `bash scripts/shizuku-disable-selfstart.sh` turns the
manager's **Start on boot (wireless ADB)** setting OFF; the receiver then returns
before `f7.j`, so the crash cannot fire at all. Recovery + full mitigation list:
see troubleshooting.md §1.

## 5. Reproduce & capture (safe)

```sh
bash scripts/capture-crash.sh --repro
```

Steps performed: `am force-stop moe.shizuku.privileged.api` → `input keyevent KEYCODE_HOME`
→ `logcat -c` → one `rish` call (sends REQUEST_BINDER, cold-starts the manager in the
background) → wait → dump crash buffer + `exit-info` to files.

**Precondition**: this only reproduces while the manager's `start_on_boot_wireless`
pref is ON **and** you are on Wi‑Fi. After running the fix
(`scripts/shizuku-disable-selfstart.sh`) the crash cannot fire, so to capture a
fresh sample you must first `shizuku-disable-selfstart.sh --enable`, reproduce, then
turn it OFF again. (There is no timestamp-vs-run mismatch bug in the script: it
clears the crash buffer with `logcat -c` first, then greps it.)

Only the manager **app** dies (reason=4). `shizuku_server` (uid 2000) survives, so
`rish` keeps working afterwards — verify with `"$RISH" -c 'id'`.

## 6. Cleanup / hygiene

- If you cleared buffers with `logcat -c`, say so — history is gone.
- After any crash investigation, confirm current state: `ps -A | grep shizuku_server`
  and the manager's latest `exit-info` entry.
- Don't delete `/data/anr` or `/data/tombstones` files — other tools may still need them.