# Wireless debugging & server lifecycle

## 1. Start methods (caller-side)

| Method | Server identity | Notes |
|---|---|---|
| Root | `root` | auto-start on boot possible |
| **ADB / wireless (this device)** | uid 2000 `shell` | requires pairing once; survives app kill |
| ADB (wired host) | `shell` | `adb shell sh /data/local/tmp/shizuku/start.sh` style |

## 2. How "wireless" works on this phone

- The manager bundles its own ADB client (`lib/arm64/libadb.so`).
- It holds **`WRITE_SECURE_SETTINGS granted=true`**, so it can flip
  `settings put global adb_wifi_enabled 1` itself.
- `settings get global adb_wifi_enabled` → `1` on this device.
- Once wireless debugging is on, the manager starts `shizuku_server` through the
  on-device adbd loopback, i.e. the server is a `shell`-uid `app_process64`
  (pid <pid> at capture time — PIDs change on every reboot/restart, always read the
  live value with `pidof shizuku_server`; parent=init on this device).
- Because the server is not an app component, `am force-stop moe.shizuku.privileged.api`
  never kills it; only reboot / `adb shell am crash`-style server restart does.

## 3. Live state checks

```sh
"$RISH" -c 'settings get global adb_wifi_enabled'          # 1 = wireless enabled
"$RISH" -c 'ps -A | grep shizuku_server'                    # server alive?
"$RISH" -c 'pidof moe.shizuku.privileged.api'               # manager running?
"$RISH" -c 'cat /data/user_de/0/com.android.shell/shizuku.json'   # auth intact?
"$RISH" -c 'service check shizuku'                           # expected: not found
```

## 4. Server restart (when needed)

Sanest user-facing way: open the manager UI → Start (wireless). Programmatically:

```sh
"$RISH" -c 'am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity'
# then the user taps Start, or:
"$RISH" -c 'am start -n moe.shizuku.privileged.api/moe.shizuku.manager.starter.StarterActivity'
```

After restart confirm: `ps -A | grep shizuku_server` returns the new pid and
`"$RISH" -c 'id'` returns `uid=2000(shell)`.

## 5. Boot behavior (state prefs → what happens)

Receiver `BootCompleteReceiver` on `LOCKED_BOOT_COMPLETED`/`BOOT_COMPLETED`:

- Reads prefs `start_on_boot` (root/adb path) and `start_on_boot_wireless`.
- If `start_on_boot` → tries to start the server directly (with its own error/rollout).
- Else, on SDK ≥ 33 with `WRITE_SECURE_SETTINGS` granted **and** `start_on_boot_wireless`
  true → log
  `ShizukuManager: WRITE_SECURE_SETTINGS is enabled and user has Start on boot is enabled for wireless ADB`
  → enable wireless → start `SelfStarterService` FGS.
- This branch wraps the FGS start in `catch (SecurityException)` — which does
  **not** actually cover `ForegroundServiceStartNotAllowedException` (it extends
  `IllegalStateException`); the boot path is instead guarded by its own conditions.
- That pref (`start_on_boot_wireless`) is therefore also the crash switch for every
  `rish` call (see troubleshooting §1); `scripts/shizuku-disable-selfstart.sh` turns
  it off. Note the regression: with it off, no auto-start of the server after boot.

## 6. Pairing inputs (for reference)

Android 11+ pairing requires a 6-digit code shown in Settings → Developer options →
Wireless debugging → Pair device. Pairing itself is handled by
`AdbPairingService` (exported=false, FGS `shortService`) + `AdbPairingClient` +
`libadb.so`; the manager's UI tutorial is `AdbPairingTutorialActivity`.
Do not need to re-pair for the server restart — pairing survives until wifi
resets / pairing is revoked (`settings get global adb_wifi_paired` is null here,
i.e. pairing is tracked elsewhere on 15).