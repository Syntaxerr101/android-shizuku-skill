---
name: android-shizuku-skill
description: >
  Use when working with Shizuku (moe.shizuku.privileged.api) on this specific
  NON-ROOTED Android device — shelling out through rish / rikka.shizuku.shell,
  the permission & first-time authorization model (RequestPermissionActivity,
  shizuku.json, RISH_APPLICATION_ID), reading logcat + dumpsys exit-info
  crashes, decoding the ForegroundServiceStartNotAllowedException, restarting
  shizuku_server, wireless debugging, and everyday device admin from inside a
  Termux/PRoot/Ubuntu shell. Covers both runtime use and static APK analysis
  (manifest/components/dex) via MT Manager MCP. Trigger on: shizuku, rish,
  RISH_APPLICATION_ID, shizuku_server, shizuku.json, ShizukuReceiver, SelfStarter,
  RequestPermissionActivity, ShizukuProvider, ShizukuBinderWrapper, UserServiceArgs,
  ForegroundServiceStartNotAllowedException, "mAllowStartForeground", wireless
  debugging, adb_wifi_enabled, ShizukuShellLoader, REQUEST_BINDER.
license: MIT — see LICENSE at the repository root
metadata:
  version: "1.3"
  mission: "Teach a NEW session how to (1) use Shizuku and its shell context, (2) use it to debug ANY app — reading logs, crashes, ANRs, tombstones, dropbox, exit-info — and (3) know what is possible on this non-rooted device."
  environment: "<device model> · Android 15 (SDK 35) · NO ROOT · PRoot-Ubuntu inside Termux · uid 2000 via rish"
  last-updated: "2026-10-09"
  evidence: "all commands below were run on this device and outputs captured in references/*.md"
---

# Shizuku — usage, permissions, logs & crashes on a non-rooted device

Goal of this skill: in any **new session**, teach the agent

1. **How to shell out** as `uid 2000 (shell)` on this non-rooted device (via `rish`).
2. **What Shizuku makes possible** — the full catalog of device-bearing commands.
3. **How to debug ANY app** — not just Shizuku — by reading its logs, crashes, ANRs,
   tombstones, dropbox entries and process-exit history.
4. **How Shizuku's own permission model works** (first-time authorization, `shizuku.json`).
5. **How to read, explain and reproduce Shizuku's own crashes** (incl. the known
   Android 15 FGS crash).
6. **Safety**: default read-only; this device has **NO ROOT**.

## 1. Environment facts (this device, verified)

| Fact | Value |
|---|---|
| Device / OS | <device model> · Android 15 · SDK 35 · security patch <patch level> |
| Root | **none** (`su` absent) |
| Shizuku | `moe.shizuku.privileged.api`, vCode 1171, `13.6.1-RC2.r1171.f8c7bafa`, minSdk 24, targetSdk 37, arm64-v8a |
| Server process | `shizuku_server` — uid **2000 (shell)**, parent=init, `app_process64`, CapEff 0 |
| Manager uid | <uid> |
| rish on device | `/data/data/com.termux/files/home/rish` (installed by Shizuku for Termux) |
| Our wrapper | `scripts/rish` → `RISH_APPLICATION_ID=com.termux` → termux rish |
| Server auth list | `/data/user_de/0/com.android.shell/shizuku.json` (readable by shell) |
| Wireless ADB | enabled (`adb_wifi_enabled`=1); manager holds `WRITE_SECURE_SETTINGS granted=true` |

## 2. Quick start

```sh
RISH=<SKILL_DIR>/scripts/rish

"$RISH" -c 'id'                                   # uid=2000(shell) … context=u:r:shell:s0
bash <SKILL_DIR>/scripts/shizuku-doctor.sh   # health report
"$RISH" -c 'cat /data/user_de/0/com.android.shell/shizuku.json'                     # who is authorized
```

`RISH_APPLICATION_ID` **must** name the app that owns the shell (Termux here =
`com.termux`). If unset, rish refuses with:
`RISH_APPLICATION_ID is not set, set this environment variable to the id of current application (package name)`.

## 3. What is possible (verified catalog — all work as uid 2000 shell)

| Domain | Read-only examples | Mutating examples (use with care) |
|---|---|---|
| **Logs** | `logcat -d`, `logcat -b crash -d`, `logcat -b events -d`, `logcat --pid=$(pidof <pkg>)`, `logcat -s <Tag>:*` | `logcat -c` (clear) |
| **Crashes (any app)** | `dumpsys activity exit-info <pkg>`, `dumpsys dropbox --print`, `logcat -b crash -d` | — |
| **Native crashes** | `head /data/tombstones/tombstone_*` | — |
| **ANRs** | `ls /data/anr`, `head /data/anr/anr_*` | — |
| **Processes** | `ps -A`, `/proc/<pid>/maps`, `/proc/<pid>/status`, `pidof` | `am force-stop <pkg>`, `kill <pid>` |
| **Packages** | `dumpsys package <pkg>`, `pm list packages`, `pm path <pkg>`, `pm dump <pkg>` | `pm install`, `pm uninstall`, `pm grant` |
| **Settings** | `settings get global/secure/system <k>` | `settings put …` |
| **Services/binders** | `service list`, `service check <name>`, `cmd -l` | `service call …` |
| **Activity/UI** | `dumpsys window`, `dumpsys activity activities`, `dumpsys activity services` | `am start`, `input keyevent/tap/swipe`, `am broadcast` |
| **Per-app runtime state** | `appops get <pkg>`, `dumpsys <service>`, `cmd package …`, `cmd activity …` | `appops set …` |
| **Battery/device-idle** | `dumpsys deviceidle` | `cmd deviceidle whitelist …` |
| **Files** | `/data/local/tmp/*`, `/data/anr`, `/data/tombstones`, sdcard | write in `/data/local/tmp` only |
| **UI automation** | `screencap -p /sdcard/x`, `uiautomator dump`, `dumpsys window`, `dumpsys activity top` | `input tap/keyevent/swipe/text` |
| **AppOps** | `appops get <pkg>` (any app) | `appops set <pkg> <op> allow\|ignore\|deny` — ⚠️ **kills the target app** |
| **App identity** | `run-as com.termux id` (debuggable apps only; termux works) | — |
| **Shared channel** | `/sdcard` (Android) **==** `/mnt/sdcard` (PRoot) — binary-safe file exchange (md5-verified) | write then delete scratch files |

Powers NOT granted to uid 2000 here: reading another app's `/data/data/<pkg>`
(`Permission denied`), `su`, most `WRITE_SECURE_SETTINGS`-style paths, and anything
needing system/root signature.

## 4. Debug ANY app — logs & crashes (procedure)

Every source below was verified readable from `rish` on this device.

```sh
# 1) Per-app exit/crash history (works for ANY package)
"$RISH" -c 'dumpsys activity exit-info <package.name>'

# 2) Global crash log buffer (Java FATAL EXCEPTION for all apps)
"$RISH" -c 'logcat -b crash -d -v threadtime | grep -A25 "<package.name>"'

# 3) Only this app's live logs
"$RISH" -c 'logcat -d -v threadtime --pid=$(pidof <package.name>)'

# 4) System dropbox (crash/ANR/WTF bullets with full metadata)
"$RISH" -c 'dumpsys dropbox --print | grep -A10 -B2 data_app_crash'

# 5) Native crashes (tombstones) and kernel/ANR traces
"$RISH" -c 'ls -la /data/tombstones/; head -40 /data/tombstones/tombstone_00'
"$RISH" -c 'ls /data/anr/; head -25 /data/anr/anr_*'

# 6) App facts / permissions / versions
"$RISH" -c 'dumpsys package <package.name> | grep -E "versionName|versionCode|codePath|primaryCpuAbi"'
```

`ApplicationExitInfo.reason` quick reference (from `dumpsys activity exit-info`):

| reason | meaning |
|---|---|
| 1 | ANR |
| 3 | LOW_MEMORY (lru-kill under pressure) |
| 4 | APP CRASH(EXCEPTION) — uncaught Java/kotlin exception |
| 9 | SIGNALED — signal kill (e.g. SIGKILL/SIGSEGV) |
| 10 | USER REQUESTED (force-stop / app-initiated) |

An ANR shows up as `reason=1`, native crashes often as `reason=9` with a matching
tombstone in `/data/tombstones/`, Java crashes as `reason=4` with the stack in
`logcat -b crash`. Cross-check all three for the full picture.

## 5. Shizuku's own known crash (Android 15) — signature & how to read it

Reproduced many times on this device. Stack:

```
java.lang.RuntimeException: Unable to start receiver moe.shizuku.manager.receiver.ShizukuReceiver:
  android.app.ForegroundServiceStartNotAllowedException: startForegroundService() not allowed
  due to mAllowStartForeground false: service moe.shizuku.privileged.api/moe.shizuku.manager.starter.SelfStarterService
  at rikka.shizuku.f7.j(SourceFile:1)
  at moe.shizuku.manager.receiver.ShizukuReceiver.onReceive(SourceFile:62)
```

**Root cause — verified in the smali of the installed APK** (v1171), not inferred:

- `ShizukuReceiver.onReceive` → after the `REQUEST_BINDER` check it *always*
  falls through to a `start_on_boot_wireless` branch (the branch is **outside**
  the action test, so it runs for every broadcast this receiver gets):
  ```
  boolean auto = prefs.getBoolean("start_on_boot_wireless", false);   // jB.l
  if (auto && new Ht().r(contentResolver, ctx, false)) {              // gate
      Intent i = new Intent(ctx, SelfStarterService.class);
      ... putExtra(...); rikka.shizuku.f7.j(ctx, i);                  // ← crash
  }
  ```
- `rikka.shizuku.f7.j(Context, Intent)` is a 2-instruction bridge:
  `ctx.startForegroundService(intent)` — **no try/catch**.
- `rikka.shizuku.Ht.r(..., false)` returns **true only when the active network
  transport is Wi‑Fi** (it then flips `adb_wifi_enabled` and returns true;
  otherwise it logs *"Wireless ADB auto-start condition not met: Not on Wi-Fi."*
  and returns false). So the full trigger is:
  **`start_on_boot_wireless == true`  AND  the phone is on Wi‑Fi  AND  the
  broadcast arrives while the manager is not exempt from background-FGS start**
  (i.e. background and not recently foreground). Off Wi‑Fi, the crash **cannot**
  fire — this is why it looked intermittent.
- Android 15 (targetSdk 37) forbids that background FGS start
  (`mAllowStartForeground false`) → `ForegroundServiceStartNotAllowedException`
  (extends `IllegalStateException`) → uncaught → app process dies, `reason=4`.
- `BootCompleteReceiver` wraps the *same* call in `catch (SecurityException)`,
  which would **not** catch it either (wrong exception type) — the boot path is
  instead gated by different conditions.

**The fix (applied on this device, verified):** turn the preference **off**.
`scripts/shizuku-disable-selfstart.sh` does exactly that through the manager's own
Settings toggle (**Start on boot (wireless ADB)** → OFF) — no repack, no re-sign,
no `shizuku.json` change, fully reversible (`--enable` / `--status`). With the pref
off, the receiver returns before `f7.j`, so **no `rish` call can crash the manager
at all**; measured: 6 background `rish` calls, manager pid stable, zero new
`reason=4` entries. Cost: after a reboot the manager no longer auto-starts the
server over wireless ADB (start it from the UI / with the script's `--enable`).

- Harmless to reproduce either way (manager **app** process only;
  `shizuku_server` survives).
- Read it:
  `dumpsys activity exit-info moe.shizuku.privileged.api` (reason=4) +
  `logcat -b crash -d | grep -A25 moe.shizuku`.
- If the pref is (re-)enabled, the manager dies with `reason=4` when a background
  `REQUEST_BINDER` broadcast lands on Wi‑Fi — even one warm for minutes. It
  restarts lazily, so bursts recycle the crash. `shizuku_server` (uid 2000) is
  never affected.
- Consequence: unless the pref is disabled, automation must be **crash-tolerant**
  — expect the crash, confirm every action with `ui-wait.sh`, never rely on an
  action's exit code.

## 6. Permission model & first-time authorization

Server-side ground truth (read-only):

```sh
"$RISH" -c 'cat /data/user_de/0/com.android.shell/shizuku.json'
```

Authorized on this device: `com.termux` (uid <uid>), `com.example.logviewer`,
`com.example.debloater`, `com.example.filemanager.canary`, `com.example.appdumper`,
`com.example.filemanager`, `com.example.hibernator`, `com.example.patcher`,
`com.example.themer`.

First-time flow: app calls `Shizuku.requestPermission(code)` → manager shows
`RequestPermissionActivity` (waits ≤5 s for the server binder — on timeout logs
`ShizukuManager: Binder not received in 5s`) → user Allow →
`dispatchPermissionConfirmationResult` → **server** records it in `shizuku.json`
(entry `{uid, flags:2, packages:[...]}`). Detailed doc: `references/permission-model.md`.

## 7. UI automation — drive ANY app: verify current UI → act → confirm

Full playbook: `references/ui-automation.md`. **Lead with the fast self-verifying
path.** Every step = ONE rish session that (1) dumps a FRESH tree and only trusts
it if `uiautomator dump` actually said "dumped to" — a failed dump silently leaves
the PREVIOUS tree on disk, and acting on that stale tree taps the wrong thing;
(2) optionally gates on the foreground **package**, so a tap on the wrong screen is
impossible; (3) resolves the target ON-DEVICE against that same fresh dump (no
stale coords); (4) after acting, re-dumps and verifies the state changed. This is
"check the current UI, then go next" — every step.

```sh
UI=<SKILL_DIR>/scripts
bash "$UI/ui-fast.sh"  launch -a android.settings.BLUETOOTH_SETTINGS   # start, then state the pkg
bash "$UI/ui-fast.sh"  read text:Bluetooth pkg:com.transsion.settings  # gate: we are on the RIGHT screen
bash "$UI/ui-fast.sh"  set  text:Bluetooth on    pkg:com.transsion.settings   # flips + VERIFIES checked=true
bash "$UI/ui-fast.sh"  set  text:Bluetooth off   pkg:com.transsion.settings   # flips + VERIFIES checked=false
bash "$UI/ui-fast.sh"  tap  text:More Settings   pkg:com.transsion.settings   # row tap (actionable element)
bash "$UI/ui-fast.sh"  check pkg:com.termux                          # confirm we're home
```

For **high-cadence loops** (launch → read UI → tap → check, different screen every
step) use the persistent driver instead: `scripts/ui-shell.sh start` opens ONE rish
session reading a FIFO — after that every `run '<cmd>'` round-trips in ~0.3 s (no
per-call ~4 s handshake) and the helpers are defined once (`run "step '<pkg>' '<target>'"`
= fresh dump → gate → resolve → tap → fresh dump for the next decision; `repl '<text>'`
clears+types). Same freshness doctrine; the XOS task-removal quirk makes "reuse the
last dump" a wrong-tap trap. Details: `references/ui-automation.md §1b`.

- **Targets** `text:<SUB>` | `id:<SUB>` | `xy:<x>,<y>`. A `text:` match resolves to
  the **actionable** element: the matched node if it is clickable/checkable,
  otherwise its nearest clickable ancestor — so `text:Bluetooth` taps the switch
  bar, **never** the ActionBar title. `set` also finds the inner checkable widget
  (switch) and verifies `checked` flipped (retries once).
- **Multi-word text** is fine unquoted (`text:More Settings`).
- The older read→act→confirm trio is still there for rich reads and raw control:
  `ui-dump.sh` (ui.xml/screen.txt/screen.json), `ui-act.sh` (tap/type/key/swipe/
  scroll/…), `ui-wait.sh` (poll predicates). `ui-act.sh tap text:…` resolves from
  whatever `ui.xml` exists — if it could be stale, re-`dump` first or use ui-fast.
- **Transsion/XOS device note**: system-settings sub-pages live in
  `com.transsion.settings*` (e.g. Bluetooth page = `com.transsion.settings.bluetooth`,
  NOT `com.android.settings`) — always use a `pkg:` gate with the Transsion prefix.
- Confirm with the result, not the exit code, and prefer to first run
  `scripts/shizuku-disable-selfstart.sh` so the manager-FGS crash (§5) cannot fire.

## 8. Safety rules

1. Default read-only. Mutations only when the task demands it and you announce them.
2. Don't repack/re-sign/reinstall Shizuku casually — it breaks the manager ↔ server
   wiring and the client-authorization linkage.
3. `am force-stop` / crash repro kills only the manager **app** process;
   `shizuku_server` survives — safe to reproduce crashes for docs.
4. `/data/local/tmp` is writable. Other apps' `/data/data` is not.
5. Evidence from live output, not memory.
6. **Never mutate app-ops/permissions of `com.termux`** (or any process this shell
   depends on). Android kills the target app's processes when its app-ops or
   runtime permissions change — Termux hosts this PRoot session, so mutating it
   kills this session. Real incident: `appops reset com.termux` killed Termux.
7. **Never run rish calls in parallel** — each one uses a 5 s ordered
   ORDERED broadcast; concurrency → `Request timeout … disable battery
   optimization`. Batch commands into ONE `-c '...'`.
8. Full power list + the "pro" levers (UI automation, appops, run-as, /proc,
   network recon, file channel): `references/advanced-capabilities.md`.

## 9. Static APK analysis (optional, via MT Manager MCP)

The Shizuku APK can be fully analyzed with the MCP server: decoded manifest, smali
of `ShizukuReceiver`/`BootCompleteReceiver`/`RequestPermissionActivity`, the
`assets/rish` script and `assets/rish_shizuku.dex`, and the `lib/` ABIs. Map from
components to behavior in `references/architecture.md`.

## Files

```
SKILL.md
references/architecture.md        — processes, binderless server, REQUEST_BINDER, components
references/rish-shell.md          — using rish from Termux/PRoot, capabilities & limits
references/logs-and-crashes.md    — debug ANY app: logcat/exit-info/dropbox/ANR/tombstones + FGS crash
references/permission-model.md    — shizuku.json format, first-time flow, client lib API
references/api-usage.md           — public Shizuku API for app developers
references/wireless-debugging.md  — start methods, WRITE_SECURE_SETTINGS, on-device adb
references/troubleshooting.md     — crash mitigation, timeouts, Android 14+ R/O dex note
references/advanced-capabilities.md — PRO levers: UI automation, appops, run-as, /proc, network, file channel
references/ui-automation.md      — read→act→confirm playbook, action + predicate cheat-sheets, gotchas
scripts/rish                      — wrapper: RISH_APPLICATION_ID=com.termux → termux rish
scripts/shizuku-doctor.sh         — read-only health report (device, server, permissions, crashes)
scripts/shizuku-disable-selfstart.sh — FIX the Android 15 manager crash: toggle OFF "Start on boot (wireless ADB)" (--status/--enable)
scripts/capture-crash.sh          — dump crash buffers/exit-info/dropbox; optional --repro
scripts/screen-probe.sh           — screenshot + UI hierarchy pulled into PRoot, tap-ready nodes
scripts/ui-dump.sh                — screen → ui.xml + screen.txt/screen.json (retries, freshness-checked)
scripts/ui-fast.sh                — FAST+SAFE path: fresh dump → pkg gate → on-device resolve → act → verify (1 session)
scripts/ui-shell.sh               — PERSISTENT session driver: 1 rish + FIFO; `run '<cmd>'` ~0.3s round-trip; step/repl helpers (start|run|stop|status|ping)
scripts/ui-act.sh                 — raw UI driver: tap/longtap/type/key/swipe/scroll/launch/back/home/wake
scripts/ui-wait.sh                — confirm: poll until text:/gone:/pkg: predicate holds (each round = 1 session)
scripts/ui_toggle.py              — find the switch/checkbox (checkable node) for a labelled settings row
scripts/ui_resolve.py             — tap-target resolver used by ui-act.sh
scripts/ui_parse.py               — ui.xml → JSON model + condensed agent listing
scripts/ui_wait_check.py          — predicate evaluator for ui-wait.sh
```