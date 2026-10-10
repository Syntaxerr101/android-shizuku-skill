# Advanced capabilities — beyond basic logging (all verified on this device)

Everything below was executed via `rish` (uid 2000 shell) on the <device model>.
These are the "pro" levers that make this shell context a real device-control plane.

## 1. UI automation channel (eyes + hands without root)

| Step | Command (via rish) | Result captured |
|---|---|---|
| See the screen | `screencap -p /sdcard/.sz_screen.png` | 720×1600 PNG, ~200 KB, md5 cleaned |
| Read the UI tree | `uiautomator dump /sdcard/.sz_ui.xml` | Full hiearchy: class, text, bounds per node |
| Act on it | `input tap CX CY` / `input swipe` / `input keyevent` | needs `input` group (shell has it) |
| Current focus | `dumpsys window \| grep mCurrentFocus` | `com.termux/...TermuxActivity` |
| Top activity | `dumpsys activity top \| grep "ACTIVITY "` | task stack incl. **other apps** (e.g. `com.example.filemanager.canary`, `<launcher>`) |

- The UI XML gives exact `bounds="[x1,y1][x2,y2]"` per node → compute center and
  `input tap`. Verified nodes (Termux keyboard): `ESC [4,1414][105,1474]`, `HOME`,
  `END`, `↑/↓/←/→`, `CTRL`, `ALT` etc.
- **Prefer the one-broadcast wrappers for automation**: `scripts/ui-dump.sh` (read),
  `scripts/ui-act.sh` (act), `scripts/ui-wait.sh` (confirm). The full
  read→act→confirm playbook lives in `references/ui-automation.md` — use it
  whenever UI automation is requested.
- `uiautomator dump` worked while the screen was locked? No — works when a window
  is focused; treat it as needing an alive UI.

### Pulling the artifacts into PRoot (IMPORTANT)
- Android `/sdcard` **is** PRoot `/mnt/sdcard` (bind confirmed via `ps -A -o ARGS`
  and md5 match `d42bee2a…` both sides).
- `cat` over the rish exec pipe **truncates/mangles >~100 KB binary** — do not use
  it for PNGs/XML. Use the `/sdcard` ↔ `/mnt/sdcard` channel instead.
- **PRoot `/data` is a DIFFERENT filesystem** from Android `/data` (PRoot binds only
  `/data/app`, `/data/dalvik-cache`, `/data/data/com.termux/files/home`,
  `/data/data/com.termux/files/usr`, apex/system/vendor — NOT `/data/local/tmp`).
  So `/data/local/tmp` written by rish is invisible to PRoot, and vice versa.
- The full PRoot bind map is discoverable from rish:
  `ps -A -o PID,PPID,USER,ARGS | grep -m1 " --rootfs="` (verified: rootfs under
  termux's `usr/var/lib/proot-distro/`, `/tmp` = termux `usr/tmp`, `/sdcard` =
  `/storage/self/primary`).

## 2. `run-as` into debuggable apps

```sh
"$RISH" -c 'run-as com.termux id'
```
Verified output: `uid=<uid> … context=u:r:runas_app:s0:c34,c257,c512,c768`
— i.e. shell can **enter a debuggable app's private identity**. Termux ships
`debuggable=true`, so you can read/fix files under Termux's private home
(including a broken `rish` deployment). Most third-party apps are not debuggable;
expect `run-as: not debuggable` elsewhere.

## 3. AppOps — read any app, mutate cautiously

- **Read any app:** `appops get <pkg>` (verified for com.termux: `Uid mode:
  COARSE_LOCATION: ignore …`).
- **Write any app:** `appops set <pkg> <OP> allow|ignore|deny` **WORKS from shell**
  (verified: termux `POST_NOTIFICATION` → allow). 
- **⚠️ Writing ops KILLS the target app's processes** (Android kills so new ops
  apply). Mutating `com.termux` kills Termux → kills the PRoot host → kills this
  session (exactly what happened once; see troubleshooting §10). **Never mutate
  ops/permissions of the app hosting your shell.**
- **Quirk:** `appops set <pkg> <OP> default` prints rc=0 but does **not** clear an
  explicit op (verified twice). Only `appops reset <pkg>` clears — and that kills
  the app (and hence the host if target is termux).
- `pm grant` / `pm revoke` observed **no state change** on termux (no root; only
  debuggable or privileged paths affect runtime permissions here).

## 4. Process & /proc visibility

- `ps -A -o PID,PPID,USER,ARGS` works (toybox) and leaks full command lines —
  including the **entire PRoot invocation** (bind map, see §1).
- <N> processes visible; `ps -A` total; `pidof` for any package.
- `/proc/<pid>/maps` readable **only for same-uid processes** (verified readable for
  `shizuku_server` uid 2000, `Permission denied` for `system_server`/`messaging`).
- `readtracefs`/`readproc` groups do NOT grant cross-uid maps on this build.

## 5. Device-wide runtime stats for ANY app (read-only)

| Source | What | Verified sample |
|---|---|---|
| `dumpsys meminfo` | per-process RSS table | `<rss-a>: <app-a>`, `<rss-b>: <app-b>`, `211,236K: com.example.messaging` |
| `dumpsys gfxinfo <pkg>` | frame stats | termux: <frames> frames, <jank>% janky, p50 <ms> ms p90 <ms> ms |
| `dumpsys battery` | level/status/temp | `level: 51`, `status: 3`, `temperature: 317` |
| `dumpsys netstats` | per-interface usage | `iface=wlan0 … wifiNetworkKey="<network-ssid>"` |
| `dumpsys activity top` | task stack of ALL apps | other apps' activities + pid/uid |
| `dumpsys drobox/exit-info` | crashes (see logs-and-crashes.md) | — |

## 6. Network visibility

- `ip addr` — all interfaces (lo/dummy0/ifb/tun/gre… + wlan0).
- `dumpsys connectivity` — rich L3 info: SSID `<network-ssid>`, BSSID, IP
  `<local-ip>/24`, gateway, **private DNS <private-dns>**, RSSI <rssi>,
  11ac, <link-rate> Mbps.
- `ping` works (inet group): `1.1.1.1 → <rtt> ms`.
- This is live network/posture recon from a non-rooted shell.

## 7. Package inventory for ANY app

- `<N>` packages total · `<M>` third-party · `<K>` disabled (verified counts).
- `dumpsys package <pkg>` → versionName/Code, codePath, minSdk/targetSdk (e.g.
  themer v3.0.1 targetSdk 36), full requested+granted permission blocks (Termux
  requests WRITE_SECURE_SETTINGS, MANAGE_EXTERNAL_STORAGE, PACKAGE_USAGE_STATS…).
- `cmd package list features`, `pm list libraries`, `pm path`, `pm path android`.

## 8. Concurrency behavior (important)

Parallel rish invocations intermittently fail with:
`Request timeout. The connection between the current app (com.termux) and Shizuku
app … disable all battery optimization for both apps.`
- Each rish run sends an ordered `REQUEST_BINDER` broadcast with a 5 s wait; pile-up
  → timeouts. **Batch many commands into ONE `-c '...'`** (the doctor does this).
- The manager app can die on ANY background broadcast **while the
  `start_on_boot_wireless` preference is ON and the phone is on Wi‑Fi** — measured:
  a manager warm for minutes (pid <pid>) was killed by one tap; its cold-start
  replacement (pid <pid>) died on the next launch broadcast; `reason=4` throughout
  (logs-and-crashes.md §4).
- **Eliminate it (recommended once)**: `bash scripts/shizuku-disable-selfstart.sh`
  turns that preference OFF (reversible with `--enable`), after which no broadcast
  can crash the manager. Or, for terminal-only bursts, foreground the manager first:
  `am start -n moe.shizuku.privileged.api/moe.shizuku.manager.MainActivity`
  (foreground app is exempt from the background-FGS ban).
- For UI automation (where the target app must stay foreground) run the fix script
  first; otherwise accept the crash, keep each script to one broadcast, and confirm
  every action with `ui-wait.sh` (never trust a mutating action's exit code). See
  `references/ui-automation.md` §4.

## Safety recap for this section
- Read-only by default. The only *mutating* powers that worked: `input`, `am`,
  `appops set` (kills target!), sdcard/file writes, `settings put` in some cases.
- Never target `com.termux` (or any process your shell depends on) with appop or
  permission mutations.