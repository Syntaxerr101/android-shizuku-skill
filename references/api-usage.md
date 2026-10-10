# Public Shizuku API (for app developers / client integration)

Consumer apps use `dev.rikka.shizuku:api` (and `:provider` for pre-11 automatic
start). The manager APK bundles a R8-minified copy of this library — the public
class/package names are the stable reference below.

## 1. Dependencies

```gradle
repositories { mavenCentral() }        // or jitpack for PR builds
dependencies {
    implementation 'dev.rikka.shizuku:api:13.1.5'
    implementation 'dev.rikka.shizuku:provider:13.1.5'
}
```

## 2. Connect & detect the server

```kotlin
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuProvider

// On app start:
Shizuku.addBinderReceivedListenerSticky {
    // server binder available
    if (!Shizuku.isPreV11()) {
        // content-provider path (this build: V3_SUPPORT=true)
        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            // ready
        }
    }
}

if (!Shizuku.pingBinder()) {
    // server not running — offer to start Shizuku
}
```

## 3. Permission request (first time)

```kotlin
private val REQ_CODE = 1001

if (Shizuku.isPreV11()) {
    // legacy broadcast/RequestPermissionActivity path
} else if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
    grantListener.onRequestPermissionResult(REQ_CODE, true)
} else if (!Shizuku.shouldShowRequestPermissionRationale()) {
    Shizuku.requestPermission(REQ_CODE)
    Shizuku.addRequestPermissionResultListener { requestCode -> ... }
} else {
    // explain then requestPermission again
}
```

The result dialog is `RequestPermissionActivity` (see permission-model.md); the
*server* records the grant in `shizuku.json`.

## 4. Using system services through Shizuku

```kotlin
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper

// Wrap a system service with Shizuku's binder as the calling identity
val pm = IPackageManager.Stub.asInterface(
    ShizukuBinderWrapper(SystemServiceHelper.getSystemService("package"))
)

val am = IActivityManager.Stub.asInterface(
    ShizukuBinderWrapper(SystemServiceHelper.getSystemService("activity"))
)
```

This is how Shizuku apps call privileged `IPackageManager` / `IActivityManager`
methods that their own uid couldn't call — the server (uid 2000 / root) is the
actual caller.

## 5. UserServices (run your code under Shizuku)

```kotlin
val args = Shizuku.UserServiceArgs(ComponentName(ctx, MyService::class.java))
    .daemon(true)              // keep it alive
    .debugable(false)
    .processNameSuffix(":shizuku")

Shizuku.bindUserService(args, object : Shizuku.ShizukuBinderHandler {
    override fun onServiceConnected(binder: IBinder) { /* talk to it */ }
    override fun onServiceDisconnected() {}
})
val conn = Shizuku.bindUserService(args, handler)
Shizuku.unbindUserService(conn, handler)
```

Supported from API 28+ on some versions; always feature-check with
`Shizuku.getMajorVersion()` / `getMinorVersion()`.

## 6. `rish`/shell for your own app

- Install the `rish` script into the terminal app's home (Shizuku app → Shell
  tutorial). For **Termux** the standard location is
  `/data/data/com.termux/files/home/rish`.
- The termux script launches `app_process` with `rikka.shizuku.shell.ShizukuShellLoader`.
- The loader picks the app id from `RISH_APPLICATION_ID` (or the single package
  mapped to the shell uid). On Android 14+ the `rish_shizuku.dex` must not be
  writable (the launcher forces `chmod 400` or instructs you to move files into the
  terminal app's private dir) — that's why Termux keeps it under `/data/data/com.termux/`.

## 7. Version gates

```kotlin
Shizuku.getVersion()          // 0 if server missing
val major = Shizuku.getMajorVersion()
val minor = Shizuku.getMinorVersion()
Shizuku.setSystemContext(applicationContext)   // for provider-less access
ScanResult / multi-process: ShizukuProvider must be declared in manifest via
META-INF/services (this build: `rikka.shizuku.Uh` -> `rikka.shizuku.q4`,
`rikka.shizuku.l4` -> `rikka.shizuku.l4`).
```

## 8. Practical debugging hooks for an agent

- `Shizuku.pingBinder()` + `Shizuku.getVersion()` is everything "is Shizuku up?" needs.
- For an app that uses Shizuku, check its `shizuku.json` entry to confirm the
  expected uid/package pair before assuming permission failures.
- Correlate app-side "Shizuku not granted"/"binder not received" with
  `ShizukuManager: Binder not received in 5s` in logcat (server down).