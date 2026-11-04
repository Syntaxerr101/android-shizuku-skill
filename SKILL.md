---
name: android-shizuku-skill
description: >
  Use when working with Shizuku (moe.shizuku.privileged.api) from Termux or a
  PRoot Linux shell on any Android device: running privileged shell commands
  through rish, the application-id and first-time authorization model,
  shizuku.json, starting/restarting the server, wireless debugging, reading
  logcat/exit-info/dropbox/ANR/tombstone crashes, the manager's
  ForegroundServiceStartNotAllowedException and NoSuchMethodError crash classes,
  UI automation (ui-fast / ui-shell / ui-dump / ui-act / ui-wait), and the Java
  Shizuku API used by client modules (Shizuku, ShizukuBinderWrapper,
  SystemServiceHelper, UserServiceArgs, ShizukuProvider, Sui). Trigger on:
  shizuku, rish, RISH_APPLICATION_ID, shizuku_server, shizuku.json,
  ShizukuReceiver, SelfStarterService, RequestPermissionActivity, ShizukuProvider,
  ShizukuBinderWrapper, UserServiceArgs, ForegroundServiceStartNotAllowedException,
  mAllowStartForeground, wireless debugging, adb_wifi_enabled, ShizukuShellLoader,
  REQUEST_BINDER, Sui.
license: MIT — see LICENSE at the repository root
metadata:
  version: "2.0"
  mission: >
    Teach a new session to use Shizuku safely on any rooted or non-rooted
    Android device, from either native Termux or PRoot, to debug any app with
    shell-level visibility, and to integrate the Shizuku Java API.
  environment: >
    Generic. No device model, vendor package, uid, screen size or ABI is assumed;
    everything is detected at runtime.
  last-updated: "2026-11-04"
---

# Shizuku — rish, debugging, UI automation and the Java API

This skill is device-agnostic. It works from **native Termux** and from a
**PRoot/proot-distro Linux shell** because both see the Android filesystem and
both can execute `/system/bin/app_process`. Nothing below depends on a specific
phone model, ROM, uid, screen resolution, or vendor settings package.

What a new session should be able to do after reading this:

1. Run commands as the **Shizuku server identity** (`shell`/uid 2000 when
   started with adb, `root` when started with root) through `rish`.
2. Detect the terminal app's package automatically and recover when it is wrong.
3. Debug **any app** — logs, crashes, ANRs, tombstones, dropbox, exit reasons.
4. Recognize and survive the Shizuku manager's own crash classes.
5. Read and reason about the Shizuku permission store (`shizuku.json`).
6. Drive the UI safely with fresh dumps, package gates and post-action checks.
7. Integrate the public Java API in a client app.

```sh
SKILL=/path/to/android-shizuku-skill
export SKILL
```

## 1. First run — verify the environment

```sh
bash "$SKILL/scripts/shizuku-doctor.sh"       # health report, read-only
bash "$SKILL/scripts/rish-bootstrap.sh"       # only if rish/dex are missing
"$SKILL/scripts/rish" -c 'id; getprop ro.build.version.sdk'
```

`scripts/rish` auto-detects the terminal package and stages the bundled loader
into that app's private directory. Force a specific id when needed:

```sh
RISH_APPLICATION_ID=com.example.terminal "$SKILL/scripts/rish" -c id
# or persist it:
mkdir -p ~/.config/shizuku-skill
echo com.example.terminal > ~/.config/shizuku-skill/app-id
RISH_DEBUG=1 "$SKILL/scripts/rish" -c id      # show what was detected
```

### Termux vs PRoot — what differs

| | Native Termux | PRoot / proot-distro |
|---|---|---|
| `$HOME` | `/data/data/<terminal>/files/home` | container path, e.g. `/home/user` |
| `$PREFIX` | `/data/data/<terminal>/files/usr` | usually unset |
| Android tools | present in `PATH` | `/system/bin` and `/data/...` are bind-mounted |
| Loader path used by this skill | always `/data/data/<terminal>/files/home/.rish-skill` | same Android path (bind-mounted) |
| Host work dir | `$TMPDIR/shizuku-skill` | `$TMPDIR` (often `/tmp`) or `/tmp` |

The wrapper resolves the **Android-private home** on purpose: on Android 14+
`app_process` refuses to load a writable dex, and shared storage cannot satisfy
`chmod 400`. See `references/rish-shell.md`.

## 2. rish in one minute

```sh
RISH="$SKILL/scripts/rish"
"$RISH" -c 'id'
"$RISH" -c 'pm list packages | head'
printf 'echo one\necho two\n' | "$RISH"          # one session, many commands
```

- `rish` is a small `app_process` loader. Shizuku authorizes a **package** (the
  "application id"), not a process. `RISH_APPLICATION_ID` tells the loader which
  package owns the shell; the wrapper exports it for you.
- Fixed cost is per **invocation** (several seconds), not per command. Batch.
- Do **not** run rish calls in parallel. The loader uses an ordered broadcast
  with a short timeout; concurrency produces `Request timeout` noise and can
  trigger manager crashes.
- The rish session does **not** inherit your Linux environment. Inject values
  literally into the command string.

## 3. What the shell identity can do

Capabilities depend on whether the server runs as `shell` (adb) or `root`.
Probe instead of assuming:

```sh
"$RISH" -c 'id; getenforce; command -v su || echo no-su'
"$RISH" -c 'settings get global adb_enabled; service list | head'
```

Typical `shell`-level abilities (verified pattern, not a guarantee):

| Domain | Examples |
|---|---|
| Logs | `logcat -d`, `-b crash`, `-b events`, `--pid=$(pidof PKG)`, `-s TAG:*` |
| App crashes | `dumpsys activity exit-info PKG`, `dumpsys dropbox --print` |
| ANR / native | `ls /data/anr`, `head /data/anr/anr_*`, `ls /data/tombstones` |
| Processes | `ps -A`, `pidof`, `/proc/<pid>/maps`, `/proc/<pid>/status` |
| Packages | `pm list/path/dump`, `dumpsys package PKG`, `cmd package …` |
| Settings | `settings get/put global|secure|system KEY` |
| Activities | `dumpsys activity`, `dumpsys window`, `am start`, `am force-stop` |
| Input/UI | `input tap|swipe|text|keyevent`, `uiautomator dump`, `screencap -p` |
| AppOps | `appops get PKG`; `appops set` is mutating and can kill the target |
| Files | `/data/local/tmp` (shell-owned), world-readable app files, shared storage |

Limits on a non-rooted device: no `su`, other apps' `/data/data` is denied,
signature/system permissions are unavailable, and some `settings put` writes are
rejected. Root-started Shizuku lifts many of these; still probe.

## 4. Debug any app

```sh
PKG=com.example.app
"$RISH" -c "dumpsys activity exit-info $PKG | sed -n '1,40p'"
"$RISH" -c "logcat -b crash -d -v threadtime | grep -A30 '$PKG' | tail -60"
"$RISH" -c "logcat -d -v threadtime --pid=\$(pidof $PKG) | tail -100"
"$RISH" -c "dumpsys dropbox --print | grep -A12 -B2 '$PKG' | head -80"
"$RISH" -c "ls -la /data/anr /data/tombstones 2>/dev/null | head -20"
```

`ApplicationExitInfo.reason`:

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

Cross-check: Java crash → `reason=4` + stack in `logcat -b crash`; ANR →
`reason=6` + `/data/anr`; native → `reason=5` + tombstone. Use
`scripts/capture-crash.sh` for a packaged evidence file.

## 5. The manager's own crash classes

Two distinct uncaught exceptions have been observed in Shizuku 13.x builds.
Obfuscated class/method names differ per build; match on the **shape** of the
stack, not on exact letters.

### 5.1 Background foreground-service start (FGS)

```
java.lang.RuntimeException: Unable to start receiver …ShizukuReceiver:
  android.app.ForegroundServiceStartNotAllowedException:
  startForegroundService() not allowed due to mAllowStartForeground false:
  service moe.shizuku.privileged.api/…SelfStarterService
```

Trigger: the manager's **"Start on boot (wireless ADB)"** preference is ON,
the device is on Wi-Fi, and a `REQUEST_BINDER` broadcast (i.e. any `rish` call)
reaches the receiver while the manager is in the background. The receiver starts
`SelfStarterService` through `Context.startForegroundService` without a
`try/catch`; Android 14/15 throws, the app process dies, `exit-info` reports
`reason=4`. `shizuku_server` is not affected.

Fix / mitigation:

```sh
bash "$SKILL/scripts/shizuku-disable-selfstart.sh" --status
bash "$SKILL/scripts/shizuku-disable-selfstart.sh"          # turn OFF
bash "$SKILL/scripts/shizuku-disable-selfstart.sh" --enable # restore
```

This is a reversible, user-visible settings toggle; it does not modify the APK,
`shizuku.json`, or signatures. Trade-off: the server will not auto-start after a
reboot over wireless ADB.

### 5.2 Missing method during activity teardown

```
java.lang.NoSuchMethodError: No virtual method clear()V in class Lrikka/shizuku/W00;
  at …p1.p(…)
  at …Jj.c(…)
  at …AK.onActivityPreDestroyed(…)
```

The obfuscated class has only a few methods and no `clear()`. This is a manager
bug tied to activity lifecycle teardown; it can fire **even with the FGS
preference OFF** and is not caused by any particular rish command. Treat the
manager as crash-tolerant:

- expect the manager app process to recycle; `shizuku_server` survives;
- never treat a mutation's exit code as proof — verify with the UI/logs;
- update the manager if a newer build is available;
- after a crash, reopen the manager; no re-authorization is normally needed.

`scripts/capture-crash.sh --repro` can reproduce, but it force-stops only the
manager app process. See `references/logs-and-crashes.md` and
`references/troubleshooting.md`.

### 5.3 Boot receiver disabled

Some ROMs/setups disable the manager's boot receiver (visible as
`disabledComponents: …BootCompleteReceiver` in `dumpsys package`). That is not a
fault: the server simply will not auto-start on boot. Start Shizuku manually or
via wireless debugging. It is unrelated to `shizuku.json`.

## 6. Permissions and `shizuku.json`

Ground truth is the server's config file (path is fixed by the server identity):

```sh
"$RISH" -c 'ls -l /data/user_de/0/com.android.shell/shizuku.json; cat /data/user_de/0/com.android.shell/shizuku.json'
```

Schema (`version: 2`):

```json
{"version":2,"packages":[
  {"uid":10000,"flags":2,"packages":["com.example.client"]}
]}
```

| flags | meaning |
|---|---|
| `2` (`1 << 1`) | `FLAG_ALLOWED` — client may use the server |
| `4` (`1 << 2`) | `FLAG_DENIED` — explicit deny |
| `0` | no decision / legacy entry — do not assume allowed |

The app also needs the runtime permission
`moe.shizuku.manager.permission.API_V23`. A grant can be **one-time** (not
persisted). Revoking a grant force-stops the client app. Full flow, V3 provider
path and one-time semantics: `references/permission-model.md`.

Do not edit `shizuku.json` to grant access. Use the manager UI or the app's
`Shizuku.requestPermission()` flow.

## 7. UI automation — verify, act, confirm

Doctrine: **fresh dump → optional package gate → resolve → act → fresh dump**.

One session, self-verifying:

```sh
UI="$SKILL/scripts"
bash "$UI/ui-fast.sh" launch -a android.settings.SETTINGS
bash "$UI/ui-fast.sh" check  pkg:com.android.settings
bash "$UI/ui-fast.sh" read   text:Bluetooth
bash "$UI/ui-fast.sh" set    text:Bluetooth on  pkg:com.android.settings
bash "$UI/ui-fast.sh" set    text:Bluetooth off pkg:com.android.settings
bash "$UI/ui-fast.sh" tap    text:More settings pkg:com.android.settings
```

Targets: `text:<substring>`, `id:<substring>`, `xy:<x>,<y>`. A `text:`/`id:`
match resolves to the actionable element (the node itself if clickable/
checkable, otherwise its nearest clickable ancestor), so a row label hits the
row/switch rather than the title.

For high-cadence loops, keep one session open:

```sh
bash "$UI/ui-shell.sh" start
bash "$UI/ui-shell.sh" run "step com.android.settings text:Bluetooth"
bash "$UI/ui-shell.sh" run "curpkg"
bash "$UI/ui-shell.sh" ping
bash "$UI/ui-shell.sh" stop
```

Lower-level tools: `ui-dump.sh` (ui.xml/screen.json/screen.txt), `ui-act.sh`
(tap/type/key/swipe/scroll/launch), `ui-wait.sh` (poll `text:`, `gone:`,
`pkg:`), `screen-probe.sh` (screenshot + tree). Scrolling uses live `wm size`,
not a hard-coded resolution. Artifacts are pulled through shared storage when
the host can see it, with a verified gzip+base64 chunked fallback, so the same
scripts work in Termux and PRoot. Full playbook: `references/ui-automation.md`.

## 8. Java API for Shizuku client modules

Dependency: `dev.rikka.shizuku:api:13.1.5` (+ `:provider:13.1.5` for the
pre-11/content-provider path), `mavenCentral()`.

Minimal client:

```kotlin
Shizuku.addBinderReceivedListenerSticky {
    if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
        val pm = IPackageManager.Stub.asInterface(
            ShizukuBinderWrapper(SystemServiceHelper.getSystemService("package"))
        )
        // privileged calls now execute as the Shizuku server identity
    }
}
if (!Shizuku.pingBinder()) { /* ask the user to start Shizuku */ }
```

User services run **your** code as shell/root:

```kotlin
val args = Shizuku.UserServiceArgs(ComponentName(ctx, MyService::class.java))
    .processNameSuffix(":shizuku")   // required by UserServiceArgs
    .daemon(true)                    // default true
    .version(1)
    .tag("my-service")
    .debuggable(false)
Shizuku.bindUserService(args, connection)
```

Full method-by-method reference, manifest provider block, permission flow,
`ShizukuBinderWrapper`/`SystemServiceHelper`, `UserServiceArgs`, destroy
transaction ids, `Sui`, and version gates: `references/api-usage.md`.

## 9. Safety rules

1. **Default read-only.** Announce mutations before running them.
2. Never repack/re-sign/reinstall Shizuku casually — it breaks the manager ↔
   server wiring and client authorization.
3. `am force-stop` and crash repro kill only the target **app** process; the
   server is a separate process and survives.
4. **Never mutate app-ops/permissions of the terminal app or any process that
   hosts this shell.** Android force-stops the target when its appops/runtime
   permissions change. This can kill the session hosting the agent.
5. Don't run rish calls in parallel; batch them.
6. Verify with output/logs/UI, not with exit codes.
7. Treat `shizuku.json` and the manager app as read-only unless the task is
   explicitly about authorization.
8. When the manager is crash-looping, prefer `shizuku-doctor.sh`, log capture,
   and the UI toggle script over blind retries.

## Files

```
SKILL.md
bin/rish                         bundled Shizuku loader (PKG placeholder left intact)
bin/rish_shizuku.dex             loader dex (staged 0400 at runtime)
scripts/rish                     portable launcher: app-id detection + staging
scripts/rish-bootstrap.sh        extract rish/dex from the manager APK
scripts/lib.sh                   shared host helpers (work dir, dump transport)
scripts/shizuku-doctor.sh        read-only health report (--full)
scripts/shizuku-disable-selfstart.sh  FGS-crash mitigation toggle (--status/--enable/--label)
scripts/capture-crash.sh         crash evidence bundle (--repro)
scripts/screen-probe.sh          screenshot + tree (verified transfer)
scripts/ui-dump.sh               ui.xml + screen.json + screen.txt
scripts/ui-fast.sh               one-session dump/gate/resolve/act/verify
scripts/ui-shell.sh              persistent session (step/repl helpers)
scripts/ui-act.sh                low-level tap/type/key/swipe/scroll/launch
scripts/ui-wait.sh               poll text:/gone:/pkg: predicates
scripts/ui_parse.py              XML -> JSON + compact listing
scripts/ui_resolve.py            actionable target resolver
scripts/ui_toggle.py             row-aware switch finder
scripts/ui_wait_check.py         predicate evaluator
references/architecture.md       processes, binder transport, components
references/rish-shell.md         rish in Termux + PRoot, app id, bootstrap
references/permission-model.md   shizuku.json, flags, first-time flow
references/api-usage.md          device-side Java API reference
references/logs-and-crashes.md   debug any app + both manager crash classes
references/troubleshooting.md    rish/dex/timeout/crash remediation
references/wireless-debugging.md start methods and settings
references/advanced-capabilities.md  pro shell levers and limits
references/ui-automation.md      full UI playbook and gotchas
```

## 10. Reporting facts about the environment

Never hard-code the target's details into a new skill or script. Detect them:

```sh
"$RISH" -c 'getprop ro.product.manufacturer; getprop ro.product.model;
  getprop ro.build.version.release; getprop ro.build.version.sdk;
  getprop ro.product.cpu.abi; wm size; wm density'
```

If a coordinate, uid, package or path appears in a script, derive it at runtime
(`wm size`, `pm path`, `dumpsys package … | grep userId=`, app-id detection) or
make it an explicit flag.
