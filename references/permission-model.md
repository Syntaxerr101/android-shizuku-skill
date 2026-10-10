# Permission model & first-time authorization

## 1. Two layers

1. **Android permissions** declared by the manager (from decoded manifest):
   - `moe.shizuku.manager.permission.MANAGER` — protection `signature` (only the same signer).
   - `moe.shizuku.manager.permission.API_V23` — protection `dangerous`, group
     `moe.shizuku.manager.permission-group.API` (the legacy pre-v26 grant path).
   - Used perms: `WRITE_SECURE_SETTINGS` (**granted=true** on this device),
     `RECEIVE_BOOT_COMPLETED`, `FOREGROUND_SERVICE`, `INTERNET`, `POST_NOTIFICATIONS`,
     `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE`, `ACCESS_LOCAL_NETWORK`.
2. **Shizuku authorization** — which apps may use the server. This is **server-side**,
   recorded by `shizuku_server` (uid 2000) in the shell user's data, NOT in the app's
   `/data/data` (unreadable anyway):

```
/data/user_de/0/com.android.shell/shizuku.json
```

## 2. `shizuku.json` format (live truth on this device)

```json
{"version":2,"packages":[
  {"uid":<uid>,"flags":2,"packages":["com.example.logviewer"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.debloater"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.filemanager.canary"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.appdumper"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.filemanager"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.hibernator"]},
  {"uid":<uid>,"flags":2,"packages":["com.termux"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.patcher"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.themer"]},
  {"uid":<uid>,"flags":2,"packages":["com.example.themer"]}
]}
```

- One entry per **uid**; `packages` = package names that map to that uid.
- `flags: 2` = the current authorized state observed for every granted app.
- `version: 2` — schema version.

Read it any time with:

```sh
"$RISH" -c 'cat /data/user_de/0/com.android.shell/shizuku.json'
```

Audit quickie — which authorized apps are still installed:

```sh
"$RISH" -c 'for p in $(cat /data/user_de/0/com.android.shell/shizuku.json | grep -oE "com\.[a-zA-Z0-9._]+" | sort -u); do pm path $p >/dev/null 2>&1 && echo "OK  $p" || echo "GONE $p"; done'
```

## 3. First-time permission flow (who shows the dialog, who records)

1. The app's client library calls `Shizuku.requestPermission(requestCode)`.
   The client binds to the manager provider
   `content://moe.shizuku.privileged.api.shizuku` and asks the server (via the
   manager) whether that app is authorized.
2. If not authorized, the manager opens
   `moe.shizuku.manager.authorization.RequestPermissionActivity` (exported,
   action `moe.shizuku.privileged.api.intent.action.REQUEST_PERMISSION`).
3. `RequestPermissionActivity.onCreate` behavior (decompiled):
   - Waits up to **5 s** for the server binder
     (`rQ.b(...)` + `CountDownLatch.await(5, SECONDS)`); on timeout logs
     `ShizukuManager: Binder not received in 5s` and finishes — i.e., if the
     server isn't running, permission requests fail fast. (This is also why
     "Shizuku not started" produces permission failures.)
   - Reads `uid`, `pid`, `requestCode`, `applicationInfo` extras; finishes if missing.
   - Shows a system dialog naming the requesting app.
4. On "Allow" it dispatches
   `z(uid, pid, requestCode, allowed=true, isOnetime=false)` →
   `dispatchPermissionConfirmationResult(...)` → the **server** records the grant
   in `shizuku.json`.

## 4. Client-side API (public library)

The developer API the manager's minified `rikka.shizuku.*` classes implement
(the manager bundles `dev.rikka.shizuku:api`; consumer apps add the Maven deps):

```kotlin
// 1) Is the server even reachable?
Shizuku.pingBinder()
Shizuku.getVersion()            // > 0 when server present
Shizuku.isPreV11()
ScanResult -> check binder on app start via ShizukuProvider

// 2) Check this app's own grant state
Shizuku.checkSelfPermission()

// 3) Ask (first time or revoked)
if (missing) {
    Shizuku.requestPermission(REQUEST_CODE)          // triggers RequestPermissionActivity
    Shizuku.shouldShowRequestPermissionRationale()
    Shizuku.addRequestPermissionResultListener { requestCode -> ... }
}

// 4) Use the server binder on system services
val pm = ShizukuBinderWrapper(SystemServiceHelper.getSystemService("package")) … as IPackageManager
Shizuku.bindUserService(Shizuku.UserServiceArgs(...), conn)   // run your own service under shizuku
```

Startup detection (from `ShizukuProvider`):

```kotlin
// content://authority/moe.shizuku.privileged.api.shizuku (V3_SUPPORT=true on this build)
// or `Shizuku.isPreV11()` for the old broadcast path
```

`rikka.shizuku.shell.ShizukuShellLoader` gives shell execution (`rish`) where the
app id comes from `RISH_APPLICATION_ID` or the single package of the uid — this is
exactly how this skill's `rish` works under `com.termux`.

Full API reference: `api-usage.md`.

## 5. Notes

- Authorization is **per uid**, so a multi-process app with several uids needs each
  uid authorized (see themer having two entries above).
- Reinstalling apps can change uids → grant may be stale → app must re-request.
- `shizuku.json` is `-rw-rw-rw-` owned by `shell` (confirmed via `ls -la`), so shell
  *could* technically edit it. **Don't** — `shizuku_server` keeps the authoritative
  in-memory copy and rewrites/clobbers manual edits. Use the app UI or the API to
  grant/revoke; treat the file as read-only.