# Shizuku Java API — client integration reference

This is the API a normal Android app (a "Shizuku client") uses. It is the same
API Shizuku-aware modules compile against. The manager APK bundles a minified
copy; the public names below are stable across 13.x.

- Artifact: `dev.rikka.shizuku:api` (latest published: **13.1.5**)
- Optional provider artifact: `dev.rikka.shizuku:provider:13.1.5`
- Requires Android 6.0+ (API 23)
- Server API version in 13.1.5: `SERVER_VERSION = 13`, `SERVER_PATCH_VERSION = 6`
- Package: `rikka.shizuku`; Sui bridge: `rikka.sui`

## 1. Gradle

```kotlin
repositories { mavenCentral() }

dependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5") // provider path / pre-11
}
```

`ShizukuBinderWrapper` needs the hidden system-service interfaces
(`IPackageManager`, `IActivityManager`, …). Compile against hidden-API stubs or
your own AIDL copies; the wrapper itself only depends on `IBinder`/`Parcel`.

## 2. Manifest — binder delivery provider

The server pushes its binder to clients through a content provider. Without the
provider you must obtain the binder yourself (`Sui.init`, or a custom channel).

```xml
<provider
    android:name="rikka.shizuku.ShizukuProvider"
    android:authorities="${applicationId}.shizuku"
    android:exported="true"
    android:multiprocess="false"
    android:permission="android.permission.INTERACT_ACROSS_USERS_FULL" />
```

Why these attributes:

- `exported=true` — the server (shell uid) must be able to call it;
- `permission=INTERACT_ACROSS_USERS_FULL` — granted to shell, not to ordinary
  apps, so only the app itself and the server can call it;
- `multiprocess=false` — the server addresses the binder to the app's main uid;
  multi-process sharing is opt-in (below).

The provider also initializes Sui automatically (unless disabled):

```java
ShizukuProvider.disableAutomaticSuiInitialization(); // call before provider creation
```

Multi-process apps:

```java
// In Application.onCreate / static init, in every process:
ShizukuProvider.enableMultiProcessSupport(/* isProviderProcess= */ isMainProcess);
// In a non-provider process, after enabling:
ShizukuProvider.requestBinderForNonProviderProcess(context);
```

`ShizukuProvider` constants:

| Constant | Value / use |
|---|---|
| `METHOD_SEND_BINDER` | `"sendBinder"` — server → provider |
| `METHOD_GET_BINDER` | `"getBinder"` — provider → sibling process |
| `ACTION_BINDER_RECEIVED` | `"moe.shizuku.api.action.BINDER_RECEIVED"` |
| `PERMISSION` | `"moe.shizuku.manager.permission.API_V23"` |
| `MANAGER_APPLICATION_ID` | `"moe.shizuku.privileged.api"` |

## 3. Binder lifecycle

```java
import rikka.shizuku.Shizuku;

Shizuku.addBinderReceivedListenerSticky(() -> {
    // Called on the main thread; sticky = fires immediately if already bound.
    // The binder can be re-delivered after a server restart, so this may run
    // more than once.
});

Shizuku.addBinderDeadListener(() -> {
    // Server died/restarted. Drop cached wrappers and re-bind.
});

boolean alive = Shizuku.pingBinder();
IBinder raw = Shizuku.getBinder(); // advanced; normally not needed
```

Listener API:

```java
void addBinderReceivedListener(OnBinderReceivedListener l);
void addBinderReceivedListener(OnBinderReceivedListener l, Handler h);
void addBinderReceivedListenerSticky(OnBinderReceivedListener l);
void addBinderReceivedListenerSticky(OnBinderReceivedListener l, Handler h);
boolean removeBinderReceivedListener(OnBinderReceivedListener l);

void addBinderDeadListener(OnBinderDeadListener l);
void addBinderDeadListener(OnBinderDeadListener l, Handler h);
boolean removeBinderDeadListener(OnBinderDeadListener l);
```

Most `Shizuku.*` calls throw `IllegalStateException` until a binder is received.
Do not call them from a cold start without the sticky listener.

## 4. Permission flow

`Shizuku` uses its own authorization, separate from normal runtime permissions.
The server also grants/revokes the runtime permission
`moe.shizuku.manager.permission.API_V23` on the client when the user answers.

```java
int REQ = 1001;

if (Shizuku.isPreV11()) {
    // Legacy path: the manager's RequestPermissionActivity / broadcast flow.
} else if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
    onReady();
} else if (!Shizuku.shouldShowRequestPermissionRationale()) {
    Shizuku.addRequestPermissionResultListener((requestCode, grantResult) -> {
        if (requestCode == REQ && grantResult == PackageManager.PERMISSION_GRANTED) onReady();
    });
    Shizuku.requestPermission(REQ);
} else {
    // Explain why the app needs Shizuku, then request again.
}
```

Methods:

```java
int  checkSelfPermission();                         // GRANTED / DENIED
int  checkRemotePermission(String permission);      // asks the server identity
void requestPermission(int requestCode);            // result via listener
boolean shouldShowRequestPermissionRationale();
boolean isPreV11();
```

Result listener:

```java
void addRequestPermissionResultListener(OnRequestPermissionResultListener l);
void addRequestPermissionResultListener(OnRequestPermissionResultListener l, Handler h);
boolean removeRequestPermissionResultListener(OnRequestPermissionResultListener l);
```

The result can be **one-time** (`REQUEST_PERMISSION_REPLY_IS_ONETIME` in the
manager dialog). A one-time grant is not written to `shizuku.json`; the client is
authorized only for the current process/session. Design for re-requesting.

Manager-only APIs (annotated `@RestrictTo(LIBRARY_GROUP_PREFIX)` in 13.1.5):

```java
int  getFlagsForUid(int uid, int mask);                 // manager only
void updateFlagsForUid(int uid, int mask, int value);   // manager only
int  getServerPatchVersion();                           // manager only
```

`ConfigManager` flags: `FLAG_ALLOWED = 1 << 1` (2), `FLAG_DENIED = 1 << 2` (4),
`MASK_PERMISSION = 6`. See `permission-model.md`.

## 5. Calling system services as the server identity

`SystemServiceHelper` returns the raw system-service binder (from
`android.os.ServiceManager`). `ShizukuBinderWrapper` forwards each transaction
through the Shizuku server, so the server's uid/SELinux context is the caller.

```java
import rikka.shizuku.ShizukuBinderWrapper;
import rikka.shizuku.SystemServiceHelper;

IPackageManager pm = IPackageManager.Stub.asInterface(
        new ShizukuBinderWrapper(SystemServiceHelper.getSystemService("package")));

IActivityManager am = IActivityManager.Stub.asInterface(
        new ShizukuBinderWrapper(SystemServiceHelper.getSystemService("activity")));

// These now execute with the server identity.
pm.getInstalledPackages(0, 0);
am.forceStopPackage("com.example.app", UserHandle.USER_SYSTEM);
```

`ShizukuBinderWrapper` implements `IBinder` and, on server version >= 13, sends
the flags separately from the payload. It works with the AIDL stubs you compile
against; method availability still depends on the platform version.

Lower-level (usually unnecessary):

```java
void transactRemote(Parcel data, Parcel reply, int flags);
```

`SystemServiceHelper.getTransactionCode(...)` and `obtainParcel(...)` are
deprecated — use `ShizukuBinderWrapper`.

## 6. User services — run your code as shell/root

A UserService is a bound service started by the Shizuku server in a separate
`app_process` with the server identity. It is the supported replacement for the
old `newProcess` approach (now private/deprecated and planned for removal).

```java
Shizuku.UserServiceArgs args = new Shizuku.UserServiceArgs(
        new ComponentName(context, MyService.class))
    .processNameSuffix(":shizuku")  // REQUIRED (forAdd() rejects null)
    .daemon(true)                   // default true; false = die with client
    .version(1)                     // bump to force recreation after code changes
    .tag("my-service")              // stable id; required if class names are obfuscated
    .debuggable(false);             // show process when "show all processes" is on

ServiceConnection conn = new ServiceConnection() {
    @Override public void onServiceConnected(ComponentName name, IBinder binder) {
        IMyService svc = IMyService.Stub.asInterface(binder);
    }
    @Override public void onServiceDisconnected(ComponentName name) { }
};

Shizuku.bindUserService(args, conn);

// Check without creating:
int version = Shizuku.peekUserService(args, conn); // -1 if not running

// Detach; remove=true kills the process.
Shizuku.unbindUserService(args, conn, /* remove= */ true);
```

`UserServiceArgs` methods:

| Method | Meaning |
|---|---|
| `daemon(boolean)` | default `true`; non-daemon dies with the client process |
| `tag(String)` | stable identity for the service, useful with obfuscation |
| `version(int)` | version code; bump when service code changes |
| `debuggable(boolean)` | expose the process for debugging |
| `processNameSuffix(String)` | **required**; final name like `com.example:suffix` |

Service side: declare the service normally, return a binder from `onBind`, and
implement a destroy transaction so `unbind(..., remove=true)` can clean up.

```java
public class MyService extends Service {
    private final IMyService.Stub binder = new IMyService.Stub() {
        @Override public void destroy() {
            // cleanup, then:
            System.exit(0);
        }
        // ... your methods
    };

    @Override public IBinder onBind(Intent intent) { return binder; }
}
```

Destroy transaction ids:

- binder `transact` code: **16777115** (`USER_SERVICE_TRANSACTION_destroy`)
- AIDL declaration: **16777114** (AIDL adds 1 to the transaction code)

If you use AIDL, the generated stub uses 16777114; the framework-side constant is
16777115. Match the convention of your AIDL file, not the other number.

Limitations:

- The process is not a normal Android app process. You may obtain a `Context`,
  but `registerReceiver`, `getContentResolver`, some `PackageManager` calls and
  other app-framework features can fail.
- The service is killed when Shizuku restarts (daemon or not). Re-bind from the
  binder-received listener.
- The service runs with the server's identity; treat every input as untrusted.

## 7. Identity, versions and process control

```java
int uid = Shizuku.getUid();                    // server uid (2000 or 0)
int ver = Shizuku.getVersion();                // -1 if unavailable/denied
int latest = Shizuku.getLatestServiceVersion();// library's SERVER_VERSION
String ctx = Shizuku.getSELinuxContext();      // e.g. u:r:shell:s0
boolean pre11 = Shizuku.isPreV11();
```

`getVersion()`/`getUid()` can return `-1` on pre-v11 servers when permission is
not granted; do not treat `-1` as a valid uid.

`Shizuku.exit()` asks the server to exit. It is manager-only in practice (the
server enforces manager permission); clients should never call it.

Removed/deprecated:

- `newProcess(String[] cmd, String[] env, String dir)` — private in 13.1.5 and
  deprecated in the API lineage. Use `ShizukuBinderWrapper` for binder calls and
  `UserServiceArgs` for arbitrary code.

## 8. Sui (Magisk/KernelSU backend)

Sui exposes the same binder contract without the Shizuku app. The provider
initializes it automatically on first use:

```java
if (Sui.isSui()) { /* Sui is the backend */ }
boolean ok = Sui.init(context.getPackageName()); // call once; false if absent
```

`Sui.init` requests the binder from the `activity` system service through a
private transaction (`('_'<<24)|('S'<<16)|('U'<<8)|'I'`, action 2). Do not call
it repeatedly; `ShizukuProvider` already does it in `onCreate()` unless
`disableAutomaticSuiInitialization()` was called.

## 9. `ShizukuApiConstants` (13.1.5)

| Constant | Value |
|---|---|
| `SERVER_VERSION` | `13` |
| `SERVER_PATCH_VERSION` | `6` |
| `BINDER_DESCRIPTOR` | `"moe.shizuku.server.IShizukuService"` |
| `BINDER_TRANSACTION_transact` | `1` |
| `USER_SERVICE_TRANSACTION_destroy` | `16777115` |
| `USER_SERVICE_ARG_TAG` | `"shizuku:user-service-arg-tag"` |
| `USER_SERVICE_ARG_COMPONENT` | `"shizuku:user-service-arg-component"` |
| `USER_SERVICE_ARG_DEBUGGABLE` | `"shizuku:user-service-arg-debuggable"` |
| `USER_SERVICE_ARG_VERSION_CODE` | `"shizuku:user-service-arg-version-code"` |
| `USER_SERVICE_ARG_PROCESS_NAME` | `"shizuku:user-service-arg-process-name"` |
| `USER_SERVICE_ARG_NO_CREATE` | `"shizuku:user-service-arg-no-create"` |
| `USER_SERVICE_ARG_DAEMON` | `"shizuku:user-service-arg-daemon"` |
| `USER_SERVICE_ARG_USE_32_BIT_APP_PROCESS` | `"shizuku:user-service-arg-use-32-bit-app-process"` |
| `USER_SERVICE_ARG_REMOVE` | `"shizuku:user-service-remove"` |
| `BIND_APPLICATION_SERVER_VERSION` | `"shizuku:attach-reply-version"` |
| `BIND_APPLICATION_SERVER_PATCH_VERSION` | `"shizuku:attach-reply-patch-version"` |
| `BIND_APPLICATION_SERVER_UID` | `"shizuku:attach-reply-uid"` |
| `BIND_APPLICATION_SERVER_SECONTEXT` | `"shizuku:attach-reply-secontext"` |
| `BIND_APPLICATION_PERMISSION_GRANTED` | `"shizuku:attach-reply-permission-granted"` |
| `BIND_APPLICATION_SHOULD_SHOW_REQUEST_PERMISSION_RATIONALE` | `"shizuku:attach-reply-should-show-request-permission-rationale"` |
| `REQUEST_PERMISSION_REPLY_ALLOWED` | `"shizuku:request-permission-reply-allowed"` |
| `REQUEST_PERMISSION_REPLY_IS_ONETIME` | `"shizuku:request-permission-reply-is-onetime"` |
| `ATTACH_APPLICATION_PACKAGE_NAME` | `"shizuku:attach-package-name"` |
| `ATTACH_APPLICATION_API_VERSION` | `"shizuku:attach-api-version"` |

## 10. Debugging a client integration

| Symptom | Check |
|---|---|
| `IllegalStateException: binder haven't been received` | provider missing/wrong authority; server down; Sui init skipped |
| Permission always denied | `checkSelfPermission()`, `shizuku.json` entry, runtime permission in `dumpsys package` |
| `SecurityException` from a wrapped call | client not authorized, wrong package/uid, or the service rejects the calling identity |
| Wrapped call hangs | transaction is blocking; run it off the main thread; check server alive |
| User service never connects | `processNameSuffix` missing, service not exported/declared, version/tag mismatch |
| Works after server restart only | re-bind in `OnBinderReceivedListener`; cached binder is dead |
| Sui installed but not used | provider did not run, or `disableAutomaticSuiInitialization()` was called and `Sui.init` was not |

Correlate with the device side:

```sh
scripts/rish -c 'cat /data/user_de/0/com.android.shell/shizuku.json'
scripts/rish -c 'logcat -d -v brief | grep -E "ShizukuManager|ShizukuProvider|rikka.shizuku" | tail -100'
```
