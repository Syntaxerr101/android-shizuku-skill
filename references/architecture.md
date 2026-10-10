# Architecture

How Shizuku is built and how it runs on this device. Everything here is from
**live observation** (`dumpsys`, `/proc`, logcat) or **static analysis** of the
installed APK (`shizuku.apk`, `13.6.1-RC2.r1171.f8c7bafa`).

## 1. Two processes, one "server"

| Process | What it is | Identity |
|---|---|---|
| `shizuku_server` | The privileged worker. Runs system-facing operations. | uid **2000 (shell)** · pid <pid> at capture time (**never rely on the number — re-resolve with `pidof shizuku_server`**) · parent=init · comm `main` · exe → `/system/bin/app_process64` · CapEff `0` |
| `moe.shizuku.privileged.api` | The manager app (UI, authorization, FGS, receiver). | uid <uid> · targetSdk 37 |

Key consequences:

- The server is **not an app** — it is a background process owned by the `shell`
  user, launched via `app_process64`. It has **exactly shell privileges and no
  more** (CapEff 0, no seccomp games). It survives `am force-stop
  moe.shizuku.privileged.api`.
- Because the server is started through ADB/wireless debugging, it persists until
  the device reboots or the server is forcibly restarted.
- The server loads its native code (`librish.so`) and dex from the manager APK's
  on-disk install dir (confirmed via `/proc/<pid>/maps`):
  `<apk-install-path>/lib/arm64/...`.

## 2. The server has NO servicemanager binder (confirmed)

```sh
$ rish -c 'service check shizuku'
Service shizuku: not found
$ rish -c 'service list | grep -i shizuku'   # (empty)
    Found 354 services: ...
```

`shizuku_server` is **not reachable by name** through the native servicemanager.
Clients never `ServiceManager.getService("shizuku")`; they always go through the
manager app (provider / REQUEST_BINDER broadcast) which hands back the server
binder. This is why "is Shizuku running?" = **check the process**, not the services.

## 3. `rish` and the REQUEST_BINDER dance (decoded)

`rish` (installed by Shizuku into `/data/data/com.termux/files/home/rish`) is:

```sh
#!/system/bin/sh
BASEDIR=$(dirname "$0")
DEX="$BASEDIR"/rish_shizuku.dex
[ -z "$RISH_APPLICATION_ID" ] && export RISH_APPLICATION_ID="PKG"
/system/bin/app_process -Djava.class.path="$DEX" /system/bin --nice-name=rish rikka.shizuku.shell.ShizukuShellLoader "$@"
```

Notes: the script refuses to run on Android 14+ if `rish_shizuku.dex` is writable
(`app_process` cannot load a writable dex there → it forces `chmod 400` or tells you
to copy the files into the terminal app's private dir — which is exactly why the
files live under `/data/data/com.termux/...`).

`ShizukuShellLoader.main` (from `assets/rish_shizuku.dex`):

1. Resolve the application id:
   - If the current uid maps to exactly one package → use it.
   - Else read `RISH_APPLICATION_ID` env; abort if empty or still `"PKG"`.
2. `b()`: build `Intent("rikka.shizuku.intent.action.REQUEST_BINDER")`
   `.setPackage("moe.shizuku.privileged.api")`, flags `0x20` (FOREGROUND receiver),
   extra `data` = Bundle containing the caller's **reply binder**.
   Send it as an **ordered** broadcast directly through
   `IActivityManager.broadcastIntent(...)` (no app task needed).
   - Android 8.0/8.1 fallback: `startActivityAsUser` with a chooser.
3. The manager's `ShizukuReceiver.onReceive` handles the action:
   - `rikka.shizuku.LA.l(context, intent)` → server binder returned through the
     reply binder; then the loot (server binder) reaches the loader's handler.
   - Then (unconditionally) it runs the `start_on_boot_wireless` branch → while on
     Wi‑Fi it may start `SelfStarterService` and crash (see logs-and-crashes).
4. Loader receives the server binder, then loads the **manager APK dex** with
   `BaseDexClassLoader` (native lib path = `<apk>/lib/<abi>`) and calls
   `moe.shizuku.manager.shell.Shell.main(args, appId, serverBinder, handler)`.
5. 5 s watchdog → `Request timeout. The connection between the current app (%s) and
   Shizuku app may be blocked by your system …` then `System.exit(1)`.

So every `rish` invocation sends an ordered `REQUEST_BINDER` broadcast to the
manager — which is exactly why the manager **crashes** on Android 15 in the
background (see logs-and-crashes), yet rish itself still works: the server is
already running and returns its binder regardless.

## 4. APK layout & components (from decoded manifest)

Manifest decode of `moe.shizuku.privileged.api` v1171:

- **Permissions used**: `RECEIVE_BOOT_COMPLETED`, `FOREGROUND_SERVICE`,
  `INTERNET`, `POST_NOTIFICATIONS`, `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE`,
  `ACCESS_LOCAL_NETWORK`, `WRITE_SECURE_SETTINGS`.
- **Permissions defined**: `moe.shizuku.manager.permission.MANAGER` (protection
  `signature`), `moe.shizuku.manager.permission.API_V23` (dangerous, group
  `moe.shizuku.manager.permission-group.API`).
- **Application**: `moe.shizuku.manager.ShizukuApplication`, `directBootAware`,
  `allowBackup=true`, `extractNativeLibs=true`, `enableOnBackInvokedCallback=true`.

Activities:

| Activity | Notes |
|---|---|
| `moe.shizuku.manager.MainActivity` | launcher, exported |
| `moe.shizuku.manager.management.AppsManagementActivity` | authorized-apps management |
| `moe.shizuku.manager.adb.AdbPairingTutorialActivity` | pairing tutorial |
| `moe.shizuku.manager.shell.ShellTutorialActivity` | rish install tutorial |
| `moe.shizuku.manager.settings.SettingsActivity` | `APPLICATION_PREFERENCES` |
| `moe.shizuku.manager.starter.StarterActivity` | start UI |
| `moe.shizuku.manager.authorization.RequestPermissionActivity` | **permission dialog**, exported; handles `moe.shizuku.privileged.api.intent.action.REQUEST_PERMISSION` |
| `moe.shizuku.manager.legacy.ShellRequestHandlerActivity` | legacy REQUEST_BINDER handler (exported) |
| `moe.shizuku.manager.legacy.LegacyIsNotSupportedActivity` | `REQUEST_AUTHORIZATION` legacy |

Services / receivers / provider:

| Component | Role |
|---|---|
| `moe.shizuku.manager.adb.AdbPairingService` | FGS `shortService` — wireless pairing |
| `moe.shizuku.manager.starter.SelfStarterService` | FGS `shortService` — restarts/enables wireless, sends the "tap to start" notification-crash target |
| `moe.shizuku.manager.receiver.BootCompleteReceiver` | `LOCKED_BOOT_COMPLETED` + `BOOT_COMPLETED` auto-start |
| `moe.shizuku.manager.receiver.ShizukuReceiver` | `rikka.shizuku.intent.action.REQUEST_BINDER` |
| `moe.shizuku.manager.ShizukuManagerProvider` | authority `moe.shizuku.privileged.api.shizuku`, exported, `directBootAware`, meta-data `moe.shizuku.client.V3_SUPPORT=true` |

APK assets/libs:

- `assets/rish` — the installer script content shown above.
- `assets/rish_shizuku.dex` — the `ShizukuShellLoader`.
- `lib/<abi>/libadb.so` — bundled ADB client (wireless self-start).
- `lib/<abi>/librish.so` — native shell/server support.
- `lib/<abi>/libshizuku.so` — server-shim support lib.
- `META-INF/services/rikka.shizuku.l4` → `rikka.shizuku.l4`, `rikka.shizuku.Uh` → `rikka.shizuku.q4` (client provider service loader; client lib is R8-minified in this APK).

## 5. Receiver behavior (smali-level facts)

`ShizukuReceiver.onReceive` in exact order:

1. If `action == "rikka.shizuku.intent.action.REQUEST_BINDER"` → `LA.l(ctx, intent)`
   (the binder hand-off described above).
2. **Unconditionally** (the following tail is shared and sits *outside* the action
   check, so it runs on every broadcast): `SharedPreferences` (`rikka.shizuku.jB.l`)
   key `start_on_boot_wireless` (default `false`). If **not** true → return.
3. `rikka.shizuku.Ht.r(contentResolver, ctx, false)` — returns **true only when the
   active network transport is Wi‑Fi** (it then flips `adb_wifi_enabled`); off Wi‑Fi
   it logs *"Wireless ADB auto-start condition not met: Not on Wi-Fi."* and returns
   false → no crash.
4. Then builds `SelfStarterService` intent with:
   - `moe.shizuku.manager.extra.AUTO_ENABLE_WIRELESS_DEBUGGING = true`
   - `moe.shizuku.manager.extra.FORCE_RESTART = false`
   - `moe.shizuku.manager.extra.DISABLE_WIRELESS_DEBUGGING_WHEN_FINISHED = true`
5. `rikka.shizuku.f7.j(ctx, intent)` → a 2-instruction bridge to
   `Context.startForegroundService(...)` with **no try/catch** → the Android 15
   background-FGS crash. Disable the pref (`scripts/shizuku-disable-selfstart.sh`)
   to make step 2 return early and eliminate the crash.

`BootCompleteReceiver` (parallel structure) additionally gates on:
- `rikka.shizuku.qZ.a` (server version stored) — skip if already set to a current value.
- `start_on_boot` (root/adb path) vs `start_on_boot_wireless` (sdk>=33 +
  `WRITE_SECURE_SETTINGS` granted branch, logged as:
  `ShizukuManager: WRITE_SECURE_SETTINGS is enabled and user has Start on boot is
  enabled for wireless ADB`) — and its FGS start is wrapped in
  `catch (SecurityException)`; the `ShizukuReceiver` path is not.

## 6. APK static-analysis workflow (MCP)

Reusable when you need to re-derive behavior from the binary:

```
mt_apk_open({ path: "shizuku.apk", temporary: true })            # workspace 5ye3m0af
mt_apk_read_text({ locator: "axml:AndroidManifest.xml", ... })   # decoded manifest
mt_apk_read_text({ locator: "dex_class:Lmoe/shizuku/manager/receiver/ShizukuReceiver;", ... })
mt_apk_read_text({ locator: "zip_entry:assets/rish", ... })
mt_apk_search({ target: "dex_names" | "dex_strings", ... })
```

The APK copy used for analysis lives under this session's scratch dir (e.g.
`/tmp/shizuku-skill/shizuku.apk`); its dex is **not** obfuscated in a way that
blocked component discovery (components keep real names; the bundled client lib is
minified).