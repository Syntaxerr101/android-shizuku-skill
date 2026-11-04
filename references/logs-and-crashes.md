# Logs & crashes — debugging ANY app

All sources below are reachable from a plain `rish` shell (adb-started server,
no root). Some need root; probe before assuming.

| Source | What it holds | Command |
|---|---|---|
| `logcat -b crash` | Last Java/Kotlin **FATAL EXCEPTION** stacks (all apps) | `logcat -b crash -d -v threadtime` |
| `logcat` (main/events) | Live app + system logs | `logcat -d [--pid=<pid>] [-s <Tag>:*]` |
| `dumpsys activity exit-info <pkg>` | Per-package **exit history** with reason codes | `dumpsys activity exit-info <pkg>` |
| `dumpsys dropbox --print` | **Crash / ANR / WTF** bullets with metadata | `dumpsys dropbox --print` |
| `/data/anr/*` | Full **ANR** traces | `ls /data/anr; head -40 /data/anr/anr_*` |
| `/data/tombstones/*` | **Native** crash dumps | `head -60 /data/tombstones/tombstone_*` |

## 1. Why every source is needed

- Java crash (`reason=4`) → stack in `logcat -b crash` and in dropbox.
- ANR (`reason=6`) → trace under `/data/anr/` and dropbox `*_anr`.
- Native crash (`reason=5`) → tombstone under `/data/tombstones/`; logcat may
  only show `SIGSEGV`/`Fatal signal`.
- Killed / OOM (`reason=3`) or system kill (`reason=13`) → only visible in
  `exit-info`; no stack anywhere.
Always cross-check `exit-info` + crash buffer + dropbox.

## 2. `exit-info` — reason codes

`ApplicationExitInfo.reason` values (from the platform constants):

| reason | meaning |
|---|---|
| 0 | UNKNOWN |
| 1 | EXIT_SELF |
| 2 | SIGNALED |
| 3 | LOW MEMORY |
| 4 | APP CRASH (uncaught Java/Kotlin exception) |
| 5 | NATIVE CRASH |
| 6 | ANR |
| 7 | INITIALIZATION FAILURE |
| 8 | PERMISSION CHANGE |
| 9 | EXCESSIVE RESOURCE USAGE |
| 10 | USER REQUESTED (force-stop / task removal) |
| 11 | USER STOPPED |
| 12 | DEPENDENCY DIED |
| 13 | OTHER (system kill / reclaim) |

`subreason` adds detail (for example `FORCE STOP`, `REMOVE TASK`, `crash`). Read
the `description` field too — it often names the trigger.

Format (illustrative; pids/timestamps/uids are per-run and must never be copied
into a script):

```
ACTIVITY MANAGER PROCESS EXIT INFO
  package: com.example.app
    Historical Process Exit for uid=10000
        ApplicationExitInfo #0:
          timestamp=... pid=... realUid=10000 ...
          process=com.example.app reason=4 (APP CRASH(EXCEPTION)) subreason=0 ...
          description=crash state=empty trace=null
```

## 3. End-to-end: debug a specific app

```sh
PKG=com.example.app                       # substitute the real package
"$RISH" -c "
echo '-- exit-info --';    dumpsys activity exit-info $PKG | sed -n '1,30p'
echo '-- crash buffer --'; logcat -b crash -d -v threadtime | grep -A30 -m1 '$PKG'
echo '-- dropbox --';      dumpsys dropbox --print | grep -A12 -B2 '$PKG'
echo '-- pid logs --';     pid=\$(pidof $PKG); [ -n \"\$pid\" ] && logcat -d -v threadtime --pid=\$pid | tail -60
"
```

Notes:

- Batch all of that into **one** rish session; each invocation costs seconds.
- If the process is dead, `pidof` is empty — use the crash buffer and
  `exit-info` instead.
- `logcat -c` clears history. This skill's scripts avoid it; if you clear, say
  so.

## 4. Shizuku's own crash classes

Two distinct uncaught exceptions have been observed in Shizuku 13.x builds.
Minified class names move between builds; match on the **shape** and on the
stable strings.

### 4.1 Background foreground-service start (FGS)

```
E AndroidRuntime: Process: moe.shizuku.privileged.api, PID: ...
E AndroidRuntime: java.lang.RuntimeException: Unable to start receiver moe.shizuku.manager.receiver.ShizukuReceiver:
    android.app.ForegroundServiceStartNotAllowedException: startForegroundService() not allowed
    due to mAllowStartForeground false:
    service moe.shizuku.privileged.api/moe.shizuku.manager.starter.SelfStarterService
E AndroidRuntime: Caused by: android.app.ForegroundServiceStartNotAllowedException ...
    at android.app.ContextImpl.startForegroundService(ContextImpl.java:...)
    at android.content.ContextWrapper.startForegroundService(ContextWrapper.java:...)
    at rikka.shizuku.<bridge>(SourceFile:1)
    at moe.shizuku.manager.receiver.ShizukuReceiver.onReceive(SourceFile:...)
```

Trigger conditions, all three required:

1. the manager preference **`start_on_boot_wireless`** is ON,
2. the device is on **Wi-Fi** (the receiver's network gate returns true only for
   a Wi-Fi transport; otherwise it logs
   `Wireless ADB auto-start condition not met: Not on Wi-Fi.` and returns),
3. the manager is in the **background** when a `REQUEST_BINDER` broadcast
   arrives — which happens on every `rish` call.

The receiver calls `startForegroundService` without a `try/catch`. Android 14/15
forbids a background FGS start, the exception is uncaught, the manager **app**
process dies (`reason=4`). `shizuku_server` is a separate process and survives.

Because every `rish` call sends the broadcast, a burst can produce a crash
cascade, one `reason=4` per call. While the manager cold-starts repeatedly,
later calls can miss the ~5 s binder window and fail with
`Request timeout … disable battery optimization`.

**Eliminate it (reversible, no repack):**

```sh
bash scripts/shizuku-disable-selfstart.sh --status
bash scripts/shizuku-disable-selfstart.sh            # turn the pref OFF
bash scripts/shizuku-disable-selfstart.sh --enable   # restore auto-start
```

With the pref off, the receiver tail returns before the FGS call, so no
broadcast can trigger the crash.

### 4.2 Missing method during activity teardown

```
java.lang.NoSuchMethodError: No virtual method clear()V in class L<class>;
    at ...<a>(...)
    at ...<b>(...)
    at ...onActivityPreDestroyed(...)
```

The obfuscated class has only a few methods and no `clear()`. This is a manager
bug tied to activity lifecycle teardown; it can fire **even with the FGS
preference OFF** and is not caused by a specific rish command. Treat the manager
as crash-tolerant:

- expect the manager app process to recycle; `shizuku_server` survives;
- never treat a mutation's exit code as proof — verify with the UI/logs;
- update the manager if a newer build is available;
- after a crash, reopen the manager; no re-authorization is normally needed.

## 5. Reproduce & capture (safe)

```sh
bash scripts/capture-crash.sh --repro            # manager, default package
bash scripts/capture-crash.sh --repro <pkg>      # any app
```

The script:

1. records the current crash-buffer length as a baseline,
2. `am force-stop`s **only the target app process** (never the server),
3. sends the target to the background (`KEYCODE_HOME`),
4. triggers one rish call and repeats up to 5 times,
5. dumps `exit-info`, the **new** crash-buffer lines, crash signatures,
   dropbox, and the process table into `$CAPTURE_OUT/<stamp>-evidence.txt`.

It does **not** clear `logcat`, so unrelated evidence is preserved.

Reproducing the FGS crash requires the `start_on_boot_wireless` pref to be ON
and the device to be on Wi-Fi. If you ran the fix, re-enable it first
(`--enable`), reproduce, then turn it OFF again.

Only the target **app** dies. Confirm the server survived with
`"$RISH" -c 'id'` and `ps -A | grep shizuku_server`.

## 6. Cleanup / hygiene

- If any buffer was cleared, report that history is gone.
- After an investigation, confirm current state:
  `ps -A | grep shizuku_server` and the latest `exit-info` entry.
- Do not delete `/data/anr` or `/data/tombstones` files — other tools may need
  them, and some ROMs keep them under different subdirectories.
