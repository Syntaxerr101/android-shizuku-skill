# Troubleshooting

## 1. Android 14/15 FGS crash (`ForegroundServiceStartNotAllowedException`)

**Symptom**: the manager app crashes (`reason=4`) when a `REQUEST_BINDER`
broadcast (i.e. a `rish` call) lands while the manager is in the background **and**
the preference `start_on_boot_wireless` is enabled **and** the device is on
Wi-Fi. A burst produces a crash cascade and intermittent `Request timeout`; `rish`
still works because `shizuku_server` is a separate process.

**Mechanism**: `ShizukuReceiver.onReceive` handles `REQUEST_BINDER` and then
falls through to a shared tail that reads `start_on_boot_wireless`. If it is true
and the active network is Wi-Fi, it calls `Context.startForegroundService` for
`SelfStarterService` **without a try/catch**. Android 14/15 forbids a background
FGS start (`mAllowStartForeground false`) → `ForegroundServiceStartNotAllowedException`
extends `IllegalStateException` → uncaught → the app process dies.

**Signature and full anatomy**: `logs-and-crashes.md` §4.1.

**Mitigations** (no repack):

1. **⭐ Turn the crashing pref OFF (root fix, scripted).**
   ```sh
   bash scripts/shizuku-disable-selfstart.sh --status
   bash scripts/shizuku-disable-selfstart.sh            # OFF
   bash scripts/shizuku-disable-selfstart.sh --enable   # restore auto-start
   ```
   It drives the manager's own Settings toggle **Start on boot (wireless ADB)**
   via UI automation (MainActivity → Settings → switch). With the pref off the
   receiver returns before the FGS call, so no `rish` call can crash the manager.
   Reversible; no repack, re-sign or `shizuku.json` change. Trade-off: after a
   reboot the manager no longer auto-starts the server over wireless ADB.

2. **Keep the manager foreground** while invoking rish (fallback when you cannot
   change settings):
   ```sh
   rish -c 'am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity'
   ```
   A foreground app is exempt from the background-FGS ban, so the crash branch
   cannot fire. The very first call can still crash a cold manager.

3. **Batch and serialize.** Fewer `-c '...'` invocations = fewer broadcasts.
   Add a short sleep between bursts.

4. **Do not repack/re-sign the APK casually** to add a `try/catch`: re-signing
   forces uninstall (new key), which breaks the `shizuku.json` linkage and the
   client authorizations, and requires re-granting every app. Last resort only,
   with explicit user approval.

**Crash-cascade recovery.** When timeouts start cascading: STOP issuing calls,
wait ~15–20 s for the manager to settle, then resume with ONE batched
`-c '...'`. Check `ps -A | grep shizuku_server` and the latest `exit-info`
before assuming the server is dead.

## 2. "Binder not received in 5s" / permission dialogs close instantly

`ShizukuManager: Binder not received in 5s` (`RequestPermissionActivity`) means
the app could not fetch the server binder within 5 s.

- Check the server: `rish -c 'pidof shizuku_server'` — but if rish is broken,
  start it from the terminal or another client.
- If the server is down, start Shizuku from the manager UI.
- Multi-uid apps must grant each uid.

## 3. "RISH_APPLICATION_ID is not set"

The loader could not map the current uid to exactly one package and the env var
was unset or still `PKG`.

```sh
export RISH_APPLICATION_ID=<your.terminal.package>
# or persist it:
mkdir -p ~/.config/shizuku-skill
echo <your.terminal.package> > ~/.config/shizuku-skill/app-id
RISH_DEBUG=1 bash scripts/rish -c id     # show what the wrapper detected
```

`scripts/rish` normally auto-detects this from the environment and process
ancestry; use the override only when detection fails.

## 4. "Request timeout … disable battery optimization for both apps"

The ~5 s watchdog fired after sending `REQUEST_BINDER`. Causes:

- the manager was frozen/suspended by battery optimisation → exclude both the
  terminal app and the Shizuku manager from battery optimisation;
- the manager was crash-looping (see §1) → apply the fix, or stop, wait
  ~15–20 s, and resume with a single batched call;
- you ran rish calls concurrently → serialize them.

Inspect the whitelist (names are device-specific):

```sh
rish -c 'dumpsys deviceidle whitelist'
```

## 5. Android 14+ "app_process cannot load writable dex"

`rish` refuses when `rish_shizuku.dex` is writable. The skill's wrapper stages
the dex into the terminal app's private dir and `chmod 400`s it. If that fails:

- the terminal app's private dir is not writable → start the shell from inside
  that app, or set `RISH_APPLICATION_ID` correctly;
- the skill lives on shared storage but the app-private dir is unavailable →
  move the skill into the app's home, or run `scripts/rish-bootstrap.sh` again.

Never "fix" this by loosening permissions on the source copy; fix the staging
directory.

## 6. `logcat` returns nothing after `logcat -c`

Buffers were cleared by an earlier step. Use `dumpsys activity exit-info`,
`/data/anr`, `/data/tombstones` and `dumpsys dropbox --print` for older events.

## 7. `am force-stop` vs server lifetime

- `am force-stop moe.shizuku.privileged.api` kills only the manager app.
- `shizuku_server` survives (it is a separate `app_process`).
- Always check server health with `ps -A | grep shizuku_server`, not app state.

## 8. Multi-uid apps and stale grants

App reinstalls/updates can change uids; `shizuku.json` entries are per uid. If an
app shows "not granted", compare its live uid to the file:

```sh
rish -c 'dumpsys package <pkg> | grep -E "userId=|appId="'
rish -c 'cat /data/user_de/0/com.android.shell/shizuku.json'
```

## 9. Quick triage for any crashing app

```sh
P=<pkg>
rish -c "dumpsys activity exit-info $P | sed -n '1,20p'"
rish -c "logcat -b crash -d -v threadtime | grep -A30 '$P'"
rish -c "dumpsys dropbox --print | grep -A12 -B2 '$P'"
rish -c "ls /data/anr; ls /data/tombstones"
```

## 10. ⚠️ App-ops / permission changes kill the target app

`appops set` and `pm grant/revoke` can force-stop the target app so new state
applies. If you target the app that hosts your shell (the terminal), you kill
your own session.

- Scope mutations to non-critical packages only.
- Announce mutations, expect the target to die, never pick a package whose death
  breaks your shell.
- `appops set <pkg> <op> default` usually does **not** clear an explicit op; only
  `appops reset <pkg>` does — and that also kills the app.
- Residual overrides persist; note them in your report.

## 11. Bursts of rish calls → timeouts

The handshake is an ordered broadcast with a ~5 s wait.

- Fix the cause first: `bash scripts/shizuku-disable-selfstart.sh`.
- Batch many commands into one `-c '...'`; serialize; sleep between bursts.
- On cascade: stop, wait ~15–20 s, resume with one batched call.
- For sustained automation with the pref ON, foreground the manager first (§1.2).

## 12. `run-as` works only for debuggable apps

`run-as <pkg> id` succeeds for apps built `debuggable=true`; other apps return
`not debuggable`. Useful for reading/repairing a debuggable app's private files
from the shell identity.

## 13. UI automation taps the wrong thing / "screen changed" mid-flow

Causes and the fixes the UI scripts already apply (`references/ui-automation.md`):

- **Stale dump.** `uiautomator dump` can fail (animating screen, secure window,
  manager cold-start) while leaving the previous XML on disk; an
  `RC=0 && file exists` check then resolves against a dead screen. Fix: only
  trust a dump whose own output contains `dumped to`, and resolve on the dump
  taken in the same session as the tap.
- **Wrong package gate.** System settings apps differ per OEM (some use
  `com.android.settings`, others a vendor package). Gate on the package the
  device actually shows — do not hard-code one. `ui-fast.sh check pkg:<sub>` and
  the post-`launch` package report tell you the real one.
- **Text match hit a dead label** (e.g. an ActionBar title). Fix: resolve to the
  actionable element — the matched node if clickable/checkable, else its nearest
  clickable ancestor — and tap that.
- **User returned to the terminal app** between steps. Fix: a pkg gate before
  each step; relaunch if it fails.
- **First call after idle** cold-starts the manager → retry once after ~3–5 s.
