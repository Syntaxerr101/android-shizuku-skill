# UI automation — verify → act → confirm (device control, no root)

The accessibility tree **is** the screen: a text-only agent can fully drive the
device by reading `uiautomator` XML, resolving targets, and acting. This is the
default workflow whenever UI automation or device interaction is requested.

## 1. The FAST + SAFE default — `ui-fast.sh` (one session per step)

Cost model: every `rish` invocation pays a fixed handshake (several seconds,
device dependent) and every `uiautomator dump` adds a few more. A naive
read → act → confirm loop burns one rish session per action plus one dump per
read. `ui-fast.sh` runs the **whole** step — dump → resolve → act → verify —
inside ONE rish session, and makes wrong taps much harder.

Doctrine for every step, in order:

1. **Dump a FRESH tree** and trust it only if `uiautomator dump` prints
   `dumped to:`. On failure it can exit leaving the OLD XML on disk; an
   `RC=0 && file exists` check then acts on a **stale screen** = wrong taps.
   The scripts retry the dump up to 5× and check the message.
2. **Gate on the foreground package** (`pkg:<SUB>`, a substring match). If you
   are on the wrong screen the step fails loudly instead of mis-tapping.
3. **Resolve the target on-device against that same fresh dump**, immediately
   before tapping — no stale coordinates, no host round-trip.
4. **Act, then re-dump and verify.** `set` re-resolves and confirms the switch's
   `checked` actually flipped (with one retry tap).

```sh
UI=/path/to/android-shizuku-skill/scripts

bash "$UI/ui-fast.sh" launch -a android.settings.SETTINGS
bash "$UI/ui-fast.sh" check  pkg:settings          # substring; discover the real pkg
bash "$UI/ui-fast.sh" read   text:Bluetooth
bash "$UI/ui-fast.sh" set    text:Bluetooth on
bash "$UI/ui-fast.sh" set    text:Bluetooth off
```

The post-`launch` output reports the actual foreground package, so you never have
to guess an OEM settings package name.

| Command | What it does (one session each) |
|---|---|
| `launch <am args…>` | `am start …`, wait, re-dump, report the resulting package |
| `check pkg:<SUB>` | fresh dump; exit 0 iff the current package contains `<SUB>` |
| `read <target> [pkg:<SUB>]` | resolve and print `coords | label | checked | via` |
| `tap <target> [pkg:<SUB>]` | resolve and tap the **actionable** element |
| `set <target> on\|off [pkg:<SUB>]` | flip a checkable switch; verify `checked` flipped (retry once) |
| `type <text>` | `input text` into the focused field (spaces auto-`%s`) |
| `replace <text>` | `MOVE_END` + repeated `DEL`, then type — clear+overwrite a field |
| `key <NAME>` | `input keyevent` (`ENTER BACK DEL DPAD_CENTER …`) |

Targets:

- `text:<SUB>` — matches node `text` **or** `content-desc` (exact first, then
  substring). The **actionable** element wins: the matched node if it is
  clickable/checkable, otherwise its nearest clickable ancestor. That is why
  `text:Bluetooth` hits the switch row, not an ActionBar title.
- `id:<SUB>` — resource-id substring (e.g. `id:switch_widget`).
- `xy:<x>,<y>` — raw coordinates, no resolution. Multi-word text needs no quotes:
  `text:More Settings` is joined automatically.

Output: human-readable lines plus a final `RESULT:ok|err`; exit code is 0/1.

## 1b. High-cadence loops — the persistent session (`ui-shell.sh`)

For `launch → read → tap → check …` loops where every step targets a different
screen, `ui-fast.sh` still pays a fresh rish handshake per call. `ui-shell.sh`
keeps ONE rish session open, reading commands from a FIFO, with the helpers
defined once at `start`:

```sh
UI=/path/to/android-shizuku-skill/scripts
bash "$UI/ui-shell.sh" start
bash "$UI/ui-shell.sh" run "step 'settings' 'text:Bluetooth'"   # pkg substring + target
bash "$UI/ui-shell.sh" run "curpkg"
bash "$UI/ui-shell.sh" run "repl NewName"
bash "$UI/ui-shell.sh" ping
bash "$UI/ui-shell.sh" status
bash "$UI/ui-shell.sh" stop
```

- `run '<command>'` round-trips quickly (push to the FIFO + wait for the marker);
  the remaining cost per step is the unavoidable `uiautomator dump`.
- `step '<pkg-sub>' '<target>'` = fresh dump → pkg gate → on-device resolve →
  tap → sleep → **fresh dump for the next decision**. The decision gap is
  sub-second.
- Dumps are written on-device under `/data/local/tmp`, then parsed inside the
  session; the host never needs direct access to that path, so this works in
  Termux and PRoot alike.
- **The fresh-dump gate stays mandatory.** Reusing a previous dump to skip the
  first dump has caused wrong taps when the OS dropped a task between runs.
  Every `step` re-dumps and re-gates first; `ERR: gate pkg=…` means "relaunch and
  retry", and the post-tap dump makes the loop self-heal.
- Keep ONE such session per device at a time; `stop` kills it cleanly.

## 2. The classic trio — raw read and control

| Tool | Role | Output |
|---|---|---|
| `scripts/ui-dump.sh [OUTDIR]` | **Read** the screen | `ui.xml`, `screen.txt`, `screen.json`, `focus.txt` |
| `scripts/ui-act.sh <action> …` | **Act** (raw driver) | rish output |
| `scripts/ui-wait.sh <pred> [timeout_s]` | **Poll** a predicate | exit 0 = holds, 1 = timeout (last snapshot kept) |

`OUTDIR` defaults to `${TMPDIR:-/tmp}/shizuku-skill/ui` (override with
`$SHIZUKU_WORK` or `$UI_OUT`).

```sh
bash "$UI/ui-dump.sh"                         # READ → screen.txt
bash "$UI/ui-act.sh"  tap 37                  # ACT by index from that dump
bash "$UI/ui-act.sh"  tap 'text:Submit'       # resolve from OUTDIR/ui.xml
bash "$UI/ui-act.sh"  type "Hello World"      # then: key ENTER
bash "$UI/ui-wait.sh" text:'Saved' 15         # poll (each round = 1 session!)
```

> **Stale-tree warning:** `ui-act.sh tap text/idx` resolves against whichever
> `ui.xml` exists. If the screen may have changed since the last `ui-dump.sh`,
> re-dump first (or use `ui-fast.sh`, which never has this problem).
> `ui-wait.sh` rounds are full sessions. Use it to poll predictable transitions,
> not for cheap verification — `ui-fast.sh set/read` verifies in-session.

## 3. Read — what `screen.txt` gives you

Every enabled textual/clickable node, one per line:

```
  37 | TAP,CHECK:false | LinearLayout | 'Wi-Fi'       | [0,600][720,760] -> 360,680
  38 |                 | TextView     | 'Connected'   | [117,710][484,749] -> 300,729  #title
```

`idx | marks(TAP,FIELD,CHECK,SCROLL,FOCUS) | class | label | bounds -> center`.
`screen.json` keeps the full attribute set (text, content-desc, resource-id,
scrollable, checked, selected, password, package, …) for programmatic use.

### Picking a tap target

- `tap 37` — by index.
- `tap text:<unique-substring>` — resolver prefers clickable, enabled,
  non-scrollable nodes and prints a warning if several match.
- **Prefer `ui-fast.sh`** — it resolves against a *fresh* tree and prefers the
  actionable element/ancestor.

### Actions cheat-sheet (`ui-act.sh`)

| Action | Form |
|---|---|
| tap | `tap <idx>` / `tap text:<sub>` / `tap xy:X,Y` |
| long press | `longtap <idx\|text:…>` (800 ms) |
| type | `type "text with spaces"` (spaces auto-mapped to `%s`) |
| key | `key BACK` `key HOME` `key ENTER` `key TAB` `key DEL` `key ESC` … |
| swipe | `swipe X1 Y1 X2 Y2 [MS]` |
| scroll | `scroll up\|down\|left\|right [N]` (uses live `wm size`) |
| launch | `launch <component>` or `launch -a <intent action>` |
| navigate | `back` `home` |
| wake | `wake` (screen off → dump fails) |
| state | `focus` (current focused window) |

## 4. Confirm — predicates (`ui-wait.sh`) and in-session verify

| Predicate | True when |
|---|---|
| `text:<sub>` | any node text/content-desc contains `<sub>` (case-insensitive) |
| `gone:<sub>` | no node contains `<sub>` |
| `pkg:<pkg>` | the current screen's package equals `<pkg>` or is a sub-package |

```sh
bash "$UI/ui-act.sh" tap "text:Save"
if bash "$UI/ui-wait.sh" text:"saved" 15; then echo confirmed; else echo retry; fi
```

For switches, `ui-fast.sh set … on|off` already verifies the state flipped and
retries once. `pkg:` gates are the cheap way to guarantee "I am on the right
screen before I tap."

## 5. Reliability rules

1. **Fix the manager crash once.** Run
   `bash scripts/shizuku-disable-selfstart.sh` first: it turns the manager's
   **Start on boot (wireless ADB)** setting OFF (the precondition for the
   Android 14/15 `ForegroundServiceStartNotAllowedException`). After that, no
   `REQUEST_BINDER` broadcast can kill the manager and exit codes become
   meaningful. If the pref stays ON, the backgrounded manager (on Wi-Fi) can die
   with `reason=4` on any broadcast — harmless to `shizuku_server` but raw exit
   codes become unreliable.
2. **Trust only a fresh dump.** `uiautomator dump` prints `dumped to:` on success;
   on failure it can leave the previous file behind. Never gate on
   `$?`/file-exists alone. The skill's dump helpers all check the message.
3. **Check the current UI, then go next.** Before every tap: confirm the package
   and resolve on the just-made dump. Judge actions by the re-read state, not the
   exit code.
4. **One rish session per logical step; never run rish calls in parallel.**
   Concurrency → `Request timeout … disable battery optimization`.
   `ui-fast.sh` is one session per step; batch raw on-device work into one
   `rish <<'EOF' … EOF` session.
5. **Reads are idempotent, mutators are not.** Retry reads; never blindly re-issue
   a `tap`/`back` — confirm first, then decide.
6. **First call after idle may cold-start the manager** → if the first dump
   errors, wait ~3–5 s and retry once; it is not a device fault.
7. **Cleanup is free**: dumps overwrite fixed on-device paths; host copies land in
   `OUTDIR`.

## 6. Gotchas

- **OEM settings packages.** Some ROMs use `com.android.settings`, others a
  vendor package. Never hard-code one: run `ui-fast.sh launch -a
  android.settings.SETTINGS`, read the reported package, then gate with that
  substring.
- **Animations** can make `uiautomator dump` report "could not get idle state" →
  the scripts retry. Give taps a moment before verifying.
- **Secure windows** (PIN entry, banking, keyguard) refuse the dump; `focus`
  still reports the window. `wake` first if the screen is off.
- **Hidden/obfuscated rows** (ad rows injected by some OEM skins) have no stable
  label — ignore them, never tap blind.
- **Tasks can be dropped by the OS** (system setting pages are notorious). That
  is why every step re-dumps and re-gates; a gate failure means "relaunch and
  continue". Prefer intent navigation over deep row-walks where possible.
- **`type`**: Android `input text` wants `%s` for spaces (handled). Single quotes
  are stripped; avoid newlines.
- **Dialogs whose positive button is disabled until the text changes**: the
  initial dump may show only `Cancel`; the `OK`/`Save` node appears after you
  edit. Flow: `tap` the row → `replace <new>` → `read` to verify → re-dump →
  `tap text:OK`.
- **The user is probably in the terminal app on the same device** — start from
  wherever the screen is, `launch` your target, **confirm the package**, drive
  it, then restore the terminal.

## 7. Device-courtesy rules

- When done with an app, restore the user's terminal. The terminal package is
  whatever hosts your shell — get it from `ui-fast.sh check`/the last launch or
  your detected app id; do not hard-code a package.
- Mutating UI actions belong to the app under analysis only. Do not alter other
  apps' state; restore switches to their original state.
- Scripts: `ui-fast.sh` (default), `ui-dump.sh`, `ui-act.sh`, `ui-wait.sh`,
  `ui_resolve.py`, `ui_parse.py`, `ui_wait_check.py`, `ui_toggle.py`, and
  `shizuku-disable-selfstart.sh` (the crash fix).
