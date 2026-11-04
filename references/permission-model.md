# Permission model & first-time authorization

## 1. Two layers

1. **Android permissions** declared by the manager app:
   - `moe.shizuku.manager.permission.MANAGER` — protection `signature`.
   - `moe.shizuku.manager.permission.API_V23` — protection `dangerous`, group
     `moe.shizuku.manager.permission-group.API`. The legacy grant path; the
     server also grants/revokes it on the client when the user answers the
     Shizuku dialog.
   - The manager may request `WRITE_SECURE_SETTINGS`, `RECEIVE_BOOT_COMPLETED`,
     `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`, `ACCESS_WIFI_STATE`,
     `ACCESS_NETWORK_STATE`, `INTERNET`. Whether any of these is actually
     granted is device/user specific — probe it, don't assume:

     ```sh
     rish -c 'dumpsys package moe.shizuku.privileged.api | grep -A2 WRITE_SECURE_SETTINGS'
     ```

2. **Shizuku authorization** — which apps may use the server. This is recorded
   **server-side**, by `shizuku_server`, in the shell user's device-encrypted
   data:

   ```
   /data/user_de/0/com.android.shell/shizuku.json
   ```

   The path is derived from the server identity (`com.android.shell`); it is the
   same on every device when Shizuku was started via adb. A root-started server
   records its config under its own identity. Read the live path with:

   ```sh
   rish -c 'ls -l /data/user_de/0/com.android.shell/shizuku.json 2>&1; cat /data/user_de/0/com.android.shell/shizuku.json'
   ```

## 2. `shizuku.json` schema

`version: 2`:

```json
{
  "version": 2,
  "packages": [
    {"uid": 10000, "flags": 2, "packages": ["com.example.client"]}
  ]
}
```

- One entry per **uid**; `packages` lists the package names that map to that uid
  (multi-package uids such as shared-user apps have more than one).
- `flags` bitmask (`ConfigManager`):
  - `1 << 1` = `2` → `FLAG_ALLOWED`
  - `1 << 2` = `4` → `FLAG_DENIED`
  - `MASK_PERMISSION = 6` — a value of `0` means **no decision**, not "allowed".
- `version` is the schema version; the current server writes `2`.

Never infer authorization from "the app is listed". Require
`flags & 2 != 0`.

Audit which authorized packages are still installed (device-agnostic):

```sh
rish -c 'for p in $(grep -oE "[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+" \
  /data/user_de/0/com.android.shell/shizuku.json | sort -u); do
    case "$p" in *.*.*|*.*) pm path "$p" >/dev/null 2>&1 && echo "OK   $p" || echo "GONE $p" ;; esac
  done'
```

## 3. First-time permission flow

1. The client library calls `Shizuku.requestPermission(requestCode)`.
2. If the app is not authorized, the manager opens
   `RequestPermissionActivity` (exported, action
   `moe.shizuku.privileged.api.intent.action.REQUEST_PERMISSION`).
3. That activity waits up to ~5 s for the server binder. If the server is not
   running it logs `ShizukuManager: Binder not received in 5s` and finishes —
   this is why permission requests fail fast when Shizuku is stopped.
4. It shows a dialog naming the requesting app. On **Allow**, the result is
   dispatched to the **server**, which records the grant in `shizuku.json`.
5. The dialog may offer **one-time** allow. A one-time grant is not persisted to
   `shizuku.json`; it is valid only for the current client session. Design for
   re-requesting.

## 4. Client-side API (public library)

The manager implements the same public API that consumer apps compile against
(`dev.rikka.shizuku:api`). The essentials:

```kotlin
// 1) Is the server reachable?
Shizuku.pingBinder()
Shizuku.getVersion()          // > 0 when the server is present
Shizuku.isPreV11()

// 2) Is this app authorized?
Shizuku.checkSelfPermission() // PackageManager.PERMISSION_GRANTED / _DENIED

// 3) Ask (first time, revoked, or one-time grant ended)
if (missing) {
    Shizuku.addRequestPermissionResultListener { code, result -> /* handle */ }
    Shizuku.requestPermission(REQUEST_CODE)
    Shizuku.shouldShowRequestPermissionRationale()
}

// 4) Use the server identity for system services / your own service
val pm = IPackageManager.Stub.asInterface(
    ShizukuBinderWrapper(SystemServiceHelper.getSystemService("package"))
)
Shizuku.bindUserService(Shizuku.UserServiceArgs(component), connection)
```

Binder delivery uses the `ShizukuProvider` content provider (authority
`<applicationId>.shizuku`) on modern builds, or the legacy broadcast path when
`Shizuku.isPreV11()` is true. Full method reference: `api-usage.md`.

`rikka.shizuku.shell.ShizukuShellLoader` is the terminal-side equivalent: it
takes the app id from `RISH_APPLICATION_ID` or from the uid's single package.
That is exactly what this skill's `scripts/rish` automates.

## 5. Notes

- Authorization is **per uid**. A multi-process app with several uids needs
  every uid authorized.
- Reinstalling or updating an app can change its uid; old entries become stale
  and the app must re-request.
- `shizuku.json` is typically world-readable/writable by the server identity, so
  `shell` *could* edit it. **Don't.** `shizuku_server` keeps the authoritative
  copy in memory and rewrites the file. Use the manager UI or the app's
  `requestPermission()` flow; treat the file as read-only evidence.
- The terminal app itself must appear in `shizuku.json` with `FLAG_ALLOWED` for
  `rish` to work. If it is missing or `flags: 0`, approve it in the manager.
