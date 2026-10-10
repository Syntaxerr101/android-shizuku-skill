# Troubleshooting

## 1. Android 15 FGS crash (`ForegroundServiceStartNotAllowedException`)

**Symptom**: the manager app crashes (`reason=4`) when a `REQUEST_BINDER`
broadcast (i.e. a `rish` call) lands while the manager is background **and** the
preference `start_on_boot_wireless` is enabled **and** the phone is on Wi‑Fi.
A burst can produce a crash cascade and intermittent `Request timeout`; `rish`
still works because `shizuku_server` is a separate process.

**Trigger — exact conditions (from the installed APK's smali, v1171):**

`ShizukuReceiver.onReceive` *always* falls through to the same tail (the branch is
outside the `REQUEST_BINDER` action check), so it runs on every broadcast:

```
if (prefs.getBoolean("start_on_boot_wireless", false)                 // jB.l
        && new Ht().r(contentResolver, ctx, false)) {                 // Wi-Fi gate
    Intent i = new Intent(ctx, SelfStarterService.class); ...
    rikka.shizuku.f7.j(ctx, i);   // == ctx.startForegroundService(i), NO try/catch
}
```

- `rikka.shizuku.Ht.r(..., false)` returns **true only if the active network
  transport is Wi‑Fi** (then it flips `adb_wifi_enabled`). Off Wi‑Fi it logs
  *"Wireless ADB auto-start condition not met: Not on Wi-Fi."* and returns false
  → **no crash**. This is why the crash looked intermittent.
- `rikka.shizuku.f7.j(Context,Intent)` is a bare bridge to
  `Context.startForegroundService`; nothing catches it.
- Android 15 (targetSdk 37) forbids the background FGS start
  (`mAllowStartForeground false`) → `ForegroundServiceStartNotAllowedException`
  (extends `IllegalStateException`) → uncaught → process dies.

**Signature** — see logs-and-crashes.md §4 (captured exit-info timestamp chain).

**Mitigations** (pick per task, no repack):

1. **⭐ Disable the crashing pref (root fix, now scripted & verified).**
   ```sh
   bash scripts/shizuku-disable-selfstart.sh            # OFF  (crash eliminated)
   bash scripts/shizuku-disable-selfstart.sh --status   # report
   bash scripts/shizuku-disable-selfstart.sh --enable   # restore auto-start
   ```
   It drives the manager's own Settings toggle **Start on boot (wireless ADB)**
   via UI automation (MainActivity → Settings → switch). With the pref off the
   receiver returns before `f7.j`, so no `rish` call can crash the manager at all
   (measured: 6 background calls, stable pid, zero new `reason=4`). Reversible;
   no repack/re-sign/`shizuku.json` change. Regression: after a reboot the manager
   no longer auto-starts the server over wireless ADB.
2. **Keep the manager foreground** while invoking rish (fallback when you cannot
   change settings): `am start -n
   moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity` immediately before
   the rish batch (background FGS start is allowed when the app is TOP, so the
   crash branch cannot fire). Note the very first call can still crash a cold
   manager; subsequent ones are safe.
3. **Batch rish calls** into fewer `-c '...'` invocations to reduce broadcast churn,
   and `sleep` between bursts to let the manager settle.
4. **Do not repack/re-sign** the APK casually to add a try/catch in
   `ShizukuReceiver.onReceive` / `rikka.shizuku.f7.j`: re-signing forces uninstall
   (new key) which breaks the `shizuku.json` linkage policies and needs re-granting
   every client. Only consider it as a last resort with explicit user approval.

**Crash-cascade recovery.** When timeouts start cascading: STOP issuing calls,
wait ~15–20 s for the manager to settle, then resume with ONE batched `-c '...'`
(single broadcast). Check current state with `ps -A | grep shizuku_server` and the
manager's latest `exit-info` before assuming anything is dead.

Root fix is upstream (a build that catches the exception in the receiver); the
receiver path here is unguarded while `BootCompleteReceiver` catches
`SecurityException` — which would **not** cover this either, since
`ForegroundServiceStartNotAllowedException` extends `IllegalStateException`.

## 2. "Binder not received in 5s" / permission dialogs close instantly

`ShizukuManager: Binder not received in 5s` (`RequestPermissionActivity`) =
the app could not fetch the server binder in 5 s. Causes:
- `shizuku_server` not running (check `ps -A | grep shizuku_server`).
- Dual-uid apps (grant each uid).

## 3. "RISH_APPLICATION_ID is not set"

rish loader couldn't map the uid to exactly one package and the env var was
unset/`PKG`. Fix: export the owner package:

```sh
export RISH_APPLICATION_ID=com.termux
```

## 4. "Request timeout ... disable battery optimization for both apps"

5 s watchdog hit after sending REQUEST_BINDER — the manager may be frozen/sleeping
(e.g. background restriction). Suggested by the message: keep both the terminal app
and the manager un-restricted. Verify: `dumpsys deviceidle whitelist | grep -iE
"termux|shizuku"` (note: this device's shell can query but the actual whitelist
entries are per-app).

On this device this message most often comes from a **manager crash cascade** (see
§1): with `start_on_boot_wireless` enabled, every rish call on Wi‑Fi re-triggers
the FGS crash while the manager is background, and an already-crashing/cold-
starting manager can't serve the binder inside the 5 s window. Recovery: run
`scripts/shizuku-disable-selfstart.sh` once (or stop, wait ~15–20 s, resume with a
single batched `-c`; for sustained automation foreground the manager first, §1).

## 5. Android 14+ "app_process cannot load writable dex"

`rish` refuses when `rish_shizuku.dex` is writable and forces `chmod 400`. On
Termux it normally already sits read-only under `/data/data/com.termux/...`. If it
fails, copy/deploy the files with read-only perms.

## 6. `logcat` returns nothing after `logcat -c`

Buffers were cleared by an earlier step — that is expected; note it in the report.
Use `dumpsys activity exit-info` and `/data/anr` + `/data/tombstones` for older
crashes that logcat can't show.

## 7. `am force-stop` vs server lifetime

- `am force-stop moe.shizuku.privileged.api` kills only the manager app.
- `shizuku_server` (uid 2000) persists (parent=init, CapEff 0).
- Check server health always with `ps -A | grep shizuku_server`, not app state.

## 8. Multi-uid apps and stale grants

App reinstalls/updates can change uids; `shizuku.json` entries are per uid. If an
app shows "not granted", inspect its current uid:
`dumpsys package <pkg> | grep -E "userId=|appId="` and compare to `shizuku.json`.

## 9. Debugging any *other* app that crashes (quick triage)

```sh
P=<pkg>
"$RISH" -c "dumpsys activity exit-info $P | sed -n '1,12p'"
"$RISH" -c "logcat -b crash -d -v threadtime | grep -A20 $P"
"$RISH" -c "dumpsys dropbox --print | grep -A10 -B2 $P"
"$RISH" -c "ls /data/anr; ls /data/tombstones"
```

## 10. ⚠️ App-ops / permission changes kill the target app — never target the host

`appops set` **works from shell on this device**, but Android force-stops the
target app so the new ops apply. On this setup the shell's host is Termux
(com.termux): running `appops set/reset com.termux …` killed Termux → killed the
PRoot/OpenCode session mid-command.

- Scope mutations to non-critical packages only.
- If you must touch an app's ops: announce it, expect the app to die, and never
  pick a package whose death breaks your own shell.
- Residual state from the incident: termux now has an explicit
  `POST_NOTIFICATION: allow` appop (behaviorally identical to its previous
  default-allow; permission was already `granted=true, USER_SET`).

## 11. `appops set … default` does not clear an explicit op

Verified on Android 15: `appops set <pkg> <op> default` returns rc=0 but the op
stays put. Only `appops reset <pkg>` clears overrides — which also kills the app.
Don't waste cycles on the `default` form.

## 12. Bursts of rish calls → "Request timeout … battery optimization"

The rish handshake is an ordered broadcast with a 5 s wait. Concurrent
invocations miss the window — and so do **sequential** calls issued while the
manager is crash-looping from the previous calls (see §1: with
`start_on_boot_wireless` enabled, every broadcast on Wi‑Fi re-triggers the FGS
crash while the manager is background).

- **Fix the cause first**: `bash scripts/shizuku-disable-selfstart.sh` (once).
- Inside a burst: batch many commands into one `-c '...'`, serialize, `sleep`
  between bursts.
- When timeouts start cascading: STOP, wait ~15–20 s, resume with one batched call.
- Sustained automation (if you must keep the pref on): `am start -n
  moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity` first — a foreground
  manager is exempt from the background-FGS ban, so no crash, no cascade.

## 13. `run-as` works only for debuggable apps

`run-as com.termux id` succeeds here (Termux ships `debuggable=true`) — useful for
repairing the termux-side rish deployment. Other apps → `not debuggable`.

## 14. UI automation taps the wrong thing / "screen changed" mid-flow

Seen on this device while driving the settings UI from Termux. Each cause maps to
a fix that `scripts/ui-fast.sh` (see `references/ui-automation.md`) applies for you:

- **Stale dump.** `uiautomator dump` can fail (animating screen, secure window,
  manager cold-start) while leaving the PREVIOUS xml on disk; an `RC=0 && file
  exists` check then resolves coords against a dead screen. Fix: only trust a dump
  whose own output says `dumped to`, and resolve on the dump taken *in the same
  session* as the tap. (All three ui scripts now check the message.)
- **Wrong wait package.** System-settings pages on XOS/Transsion live in
  `com.transsion.settings*` — the Bluetooth page is
  `com.transsion.settings.bluetooth`, not `com.android.settings`. A `pkg:` gate
  with the Transsion prefix catches this instantly; a wrong wait just times out.
- **Text match hit a dead label** (e.g. the ActionBar *title* "Bluetooth"). Fix:
  resolve to the **actionable** element — the matched node if clickable/checkable,
  else its nearest clickable ancestor — and tap that (`text:Bluetooth` → switch bar).
- **User actually went back to Termux** between steps. Fix: the pkg gate (or a
  `check pkg:…`) before each step; relaunch if it fails.
- **First call after idle** cold-starts the manager → retry once after ~3–5 s.