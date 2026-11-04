# Architecture

How Shizuku is built and how it runs. Everything below is either a stable
component name from the public AIDL/API (`rikka.shizuku.*`, `moe.shizuku.*`) or
behaviour that can be re-verified at runtime with `dumpsys`, `/proc`, and
`logcat` on the device you are working on.

Obfuscated helper names in the manager (`rikka.shizuku.<short>`, the manager's
own `p1`/`Jj`/`AK` classes, etc.) change between builds. Match on **structure**
and on the stable strings (`REQUEST_BINDER`, `start_on_boot_wireless`,
`ShizukuReceiver`, `SelfStarterService`), never on a single letter.

## 1. Two processes, one "server"

| Process | What it is | Identity |
|---|---|---|
| `shizuku_server` | The privileged worker. Executes system-facing operations on behalf of authorized clients. | The identity used to start it: `shell` (uid 2000) when started via adb/wireless debugging, `root` (uid 0) when started via root. Launched through `/system/bin/app_process*`; its parent is normally `init`. |
| `moe.shizuku.privileged.api` | The manager app: UI, authorization store, boot receiver, binder relay. | A normal app uid (`u0_aNNN`), assigned at install time. |

Key consequences:

- The server is **not an app component**. It is a plain `app_process` process
  owned by `shell` or `root`. It has exactly that identity's privileges and no
  more (an adb-started server has `CapEff 0`).
- `am force-stop moe.shizuku.privileged.api` kills **only the manager app**. The
  server survives; `rish` keeps working.
- Server lifetime ends on reboot, on an explicit server stop/restart, or if the
  process is killed by the system. Re-resolve its pid at runtime:
  `pidof shizuku_server`.
- The server loads its native libs and dex from the manager APK's on-disk
  install directory (`pm path moe.shizuku.privileged.api` →
  `/data/app/.../base.apk`, with `lib/<abi>/` beside it). Never hard-code that
  path; it changes on every install/update.

## 2. The server has no servicemanager binder

```sh
rish -c 'service check shizuku'      # Service shizuku: not found
rish -c 'service list | grep -i shizuku'   # usually empty
```

`shizuku_server` is **not registered by name** with the native servicemanager.
Clients never call `ServiceManager.getService("shizuku")`. They receive the
server binder from the manager app through one of two channels:

- the `ShizukuProvider` content provider (modern path, `V3_SUPPORT`), or
- the `rikka.shizuku.intent.action.REQUEST_BINDER` ordered broadcast (the path
  `rish` and pre-v11 clients use).

So "is Shizuku running?" means **check the process** (`pidof shizuku_server`),
not `service check`.

## 3. `rish` and the REQUEST_BINDER dance

`rish` is a small `/system/bin/sh` script shipped in the manager APK at
`assets/rish`. Its shape is stable:

```sh
#!/system/bin/sh
BASEDIR=$(dirname "$0")
DEX="$BASEDIR"/rish_shizuku.dex
[ -z "$RISH_APPLICATION_ID" ] && export RISH_APPLICATION_ID="PKG"
/system/bin/app_process -Djava.class.path="$DEX" /system/bin \
    --nice-name=rish rikka.shizuku.shell.ShizukuShellLoader "$@"
```

- The script carries the literal `PKG` placeholder; the *caller* must export
  `RISH_APPLICATION_ID` (this skill's `scripts/rish` does that).
- On Android 14+ (`sdk >= 34`) `app_process` refuses to load a **writable**
  dex. The files must therefore live somewhere the owner can `chmod 400` them —
  an app-private directory. This is why the skill stages them under
  `/data/data/<terminal-app>/files/home/.rish-skill/`.

`ShizukuShellLoader` (in `assets/rish_shizuku.dex`) then:

1. Resolves the application id:
   - if the current uid maps to exactly one installed package, use it;
   - otherwise read `RISH_APPLICATION_ID`; abort if it is empty or still `PKG`.
2. Sends `Intent("rikka.shizuku.intent.action.REQUEST_BINDER")` with
   `setPackage("moe.shizuku.privileged.api")` and the caller's **reply binder**
   in the extras, as an **ordered broadcast** through `IActivityManager`
   (a pre-8.0 fallback goes through `startActivityAsUser`).
3. The manager's `ShizukuReceiver` handles that action and returns the server
   binder over the reply binder.
4. The loader loads the manager APK's dex (`BaseDexClassLoader`, native lib path
   `<apk>/lib/<abi>`) and calls the shell implementation
   (`moe.shizuku.manager.shell.Shell`) with the args, app id, server binder and
   handler.
5. A ~5 s watchdog aborts with a `Request timeout …` message if the binder never
   arrives. That is the fixed per-invocation cost you see.

Consequence: **every `rish` invocation sends a broadcast to the manager.** If the
manager's receiver has a bug that starts a foreground service from the
background, that broadcast is the trigger (see `logs-and-crashes.md`). The
server itself is unaffected; `rish` continues to work because the server already
holds the binder.

## 4. APK layout & components

Stable component names in the manager package:

Activities:

| Activity | Role |
|---|---|
| `moe.shizuku.manager.MainActivity` | launcher / start UI |
| `moe.shizuku.manager.management.AppsManagementActivity` | authorized-app management |
| `moe.shizuku.manager.adb.AdbPairingTutorialActivity` | wireless pairing tutorial |
| `moe.shizuku.manager.shell.ShellTutorialActivity` | rish install tutorial |
| `moe.shizuku.manager.settings.SettingsActivity` | preferences |
| `moe.shizuku.manager.starter.StarterActivity` | server start UI |
| `moe.shizuku.manager.authorization.RequestPermissionActivity` | per-app permission dialog; exported; handles `moe.shizuku.privileged.api.intent.action.REQUEST_PERMISSION` |
| `moe.shizuku.manager.legacy.ShellRequestHandlerActivity` | legacy REQUEST_BINDER handler |
| `moe.shizuku.manager.legacy.LegacyIsNotSupportedActivity` | legacy REQUEST_AUTHORIZATION path |

Services / receivers / provider:

| Component | Role |
|---|---|
| `moe.shizuku.manager.adb.AdbPairingService` | foreground `shortService` for wireless pairing |
| `moe.shizuku.manager.starter.SelfStarterService` | foreground `shortService` that re-enables wireless debugging / restarts the server |
| `moe.shizuku.manager.receiver.BootCompleteReceiver` | `LOCKED_BOOT_COMPLETED` / `BOOT_COMPLETED` auto-start |
| `moe.shizuku.manager.receiver.ShizukuReceiver` | `rikka.shizuku.intent.action.REQUEST_BINDER` relay |
| `moe.shizuku.manager.ShizukuManagerProvider` | authority `<manager-package>.shizuku`, exported, `directBootAware`, meta-data `moe.shizuku.client.V3_SUPPORT` |

Permissions declared by the manager:

- `moe.shizuku.manager.permission.MANAGER` — `signature` (same signer only).
- `moe.shizuku.manager.permission.API_V23` — `dangerous`, group
  `moe.shizuku.manager.permission-group.API` (legacy grant path; the server also
  grants/revokes it on the client).

APK assets / native libs (names vary by ABI):

- `assets/rish` — the loader script above.
- `assets/rish_shizuku.dex` — `ShizukuShellLoader`.
- `lib/<abi>/libadb.so` — bundled ADB client used for wireless self-start.
- `lib/<abi>/librish.so` — native shell/server support (not needed by the dex
  loader; never substitute it for the dex).
- `lib/<abi>/libshizuku.so` — server shim support.

## 5. Receiver behaviour (structural, build-independent)

`ShizukuReceiver.onReceive` does two things:

1. On `REQUEST_BINDER`, it hands the server binder back to the caller.
2. Then it falls through to a shared tail that reads the manager preference
   **`start_on_boot_wireless`** (default `false`). If it is `true`, and the
   device's active network transport is Wi-Fi, it builds an intent for
   `SelfStarterService` and calls `Context.startForegroundService(...)`.

That FGS call is the origin of the `ForegroundServiceStartNotAllowedException`
crash class documented in `logs-and-crashes.md`. Turning the preference off
makes the tail return before the call, which removes the crash. The setting is
reversible and does not touch `shizuku.json`, the server, or signatures.

`BootCompleteReceiver` has a parallel structure, gated on
`start_on_boot` (root/adb) or `start_on_boot_wireless` (SDK >= 33 +
`WRITE_SECURE_SETTINGS`). Some builds wrap that FGS start in
`catch (SecurityException)`, which does **not** cover
`ForegroundServiceStartNotAllowedException` (it extends `IllegalStateException`).

## 6. Re-deriving behaviour from the APK

When you must confirm a behaviour on a specific build, treat the APK as the
source of truth:

```sh
rish -c 'pm path moe.shizuku.privileged.api'   # find base.apk
# then decode the manifest and the relevant dex classes with your APK tool of
# choice (MT Manager MCP, apktool, jadx, …) and grep for the stable strings:
#   REQUEST_BINDER, start_on_boot_wireless, ShizukuReceiver, SelfStarterService
```

Component names, the provider authority and the permission names are stable;
only the minified helper classes move.
