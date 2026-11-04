# Wireless debugging & server lifecycle

## 1. Start methods

| Method | Server identity | Notes |
|---|---|---|
| Root | `root` (uid 0) | auto-start on boot possible; broadest privileges |
| ADB over Wi-Fi ("wireless debugging") | `shell` (uid 2000) | pair once; server survives app kill |
| ADB over USB from a host | `shell` | start via the manager or a `start.sh` pushed by the host |

The server identity determines what `rish` can do. Probe it, don't assume:

```sh
rish -c 'id; getenforce'
```

## 2. How wireless debugging works

- The manager bundles its own ADB client (`lib/<abi>/libadb.so`), so it does not
  need a host machine to start the server over the loopback adb connection.
- If the manager holds `WRITE_SECURE_SETTINGS`, it can toggle
  `settings put global adb_wifi_enabled 1` itself. Whether it does is
  device/user specific:

  ```sh
  rish -c 'settings get global adb_wifi_enabled'
  rish -c 'dumpsys package moe.shizuku.privileged.api | grep -A2 WRITE_SECURE_SETTINGS'
  ```

- Once wireless debugging is on, the manager starts `shizuku_server` as a
  `shell`-uid `app_process` through the on-device adbd. PIDs change on every
  reboot/restart — always read the live value with `pidof shizuku_server`.
- Because the server is not an app component,
  `am force-stop moe.shizuku.privileged.api` never kills it. Only a reboot, an
  explicit server stop, or a process kill ends it.

## 3. Live state checks

```sh
rish -c 'settings get global adb_wifi_enabled'                     # 1 = wireless on
rish -c 'ps -A | grep shizuku_server'                              # server alive?
rish -c 'pidof moe.shizuku.privileged.api'                         # manager running?
rish -c 'cat /data/user_de/0/com.android.shell/shizuku.json'       # auth intact?
rish -c 'service check shizuku'                                    # expected: not found
```

## 4. Server restart

The safest user-facing way is the manager UI → Start (wireless). Programmatic
navigation:

```sh
rish -c 'am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity'
# or the dedicated starter screen:
rish -c 'am start -n moe.shizuku.privileged.api/moe.shizuku.manager.starter.StarterActivity'
```

After a restart, confirm the server is up and the identity matches:

```sh
rish -c 'pidof shizuku_server; id'
```

## 5. Boot behaviour (preferences → what happens)

On `LOCKED_BOOT_COMPLETED` / `BOOT_COMPLETED`, `BootCompleteReceiver` reads:

- `start_on_boot` — root/adb path: start the server directly (with its own
  error handling);
- `start_on_boot_wireless` — on SDK >= 33 with `WRITE_SECURE_SETTINGS` granted,
  enable wireless debugging and start `SelfStarterService` as a foreground
  service.

The `start_on_boot_wireless` preference is also the switch that makes every
`rish` call able to crash the manager (see `troubleshooting.md` §1).
`scripts/shizuku-disable-selfstart.sh` turns it off. Trade-off: with it off, the
server does not auto-start after a reboot; start it manually from the manager.

## 6. Pairing

Android 11+ wireless debugging requires a one-time pairing: Settings →
Developer options → Wireless debugging → **Pair device with pairing code**. The
6-digit code is entered by the manager (or a host `adb pair`).

- Pairing is handled by `AdbPairingService` (foreground `shortService`) +
  `AdbPairingClient` + `libadb.so`; the UI tutorial is
  `AdbPairingTutorialActivity`.
- You do **not** need to re-pair for a server restart. Pairing survives until
  Wi-Fi resets or the pairing is revoked.
