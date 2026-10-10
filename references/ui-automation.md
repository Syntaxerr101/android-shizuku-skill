# UI automation — verify current UI → act → confirm (full device control, no root)

Everything below is verified on this device (<device model>, Android 15) via `rish`
(uid 2000). This is the **default workflow whenever UI automation or device
interaction is requested** during testing. An agent that can read text but not
images can still fully drive the screen: the accessibility XML **is** the exact
screen UI.

## 1. The FAST+SAFE default path — `ui-fast.sh` (one session per step)

Cost model on this device: **every `rish` invocation is ~3.5–4 s** (app_process
startup + REQUEST_BINDER ordered broadcast handshake) and **every
`uiautomator dump` adds ~3 s**. The naive read→act→confirm loop burns one
4-second session per action plus one 7-second dump per read (~30–40 s a step).
`ui-fast.sh` runs the WHOLE step — dump → resolve → act → verify — inside ONE rish
session (~7–12 s) and, more importantly, makes wrong taps impossible.

Doctrine — every step, in order:
1. **Dump a FRESH tree** and only trust it if `uiautomator dump` prints
   `dumped to:`. On failure it can exit leaving the OLD xml on disk; an
   `RC=0 && file exists` check then acts on a **stale screen** = wrong taps.
   `ui-fast.sh` retries the dump up to 5× and checks the message.
2. **Gate on the foreground package** (`pkg:<SUB>`, a substring/prefix match).
   If you're on the wrong screen the step fails loudly instead of mis-tapping.
3. **Resolve the target ON-DEVICE against that same fresh dump**, immediately
   before tapping — no stale coordinates, no host round-trip.
4. **Act, then re-dump and verify.** `set` re-resolves and confirms the switch's
   `checked` actually flipped (with one retry tap).

```sh
UI=<SKILL_DIR>/scripts

# Turn Bluetooth on (need the Transsion settings pkg — see §6), wait, turn off:
bash "$UI/ui-fast.sh" launch -a android.settings.BLUETOOTH_SETTINGS
bash "$UI/ui-fast.sh" set  text:Bluetooth on  pkg:com.transsion.settings
sleep 3
bash "$UI/ui-fast.sh" set  text:Bluetooth off pkg:com.transsion.settings
bash "$UI/ui-fast.sh" check pkg:com.termux   # back home
```

| Command | What it does (1 session each) |
|---|---|
| `launch <am args…>` | `am start …`, wait, re-dump, report resulting pkg |
| `check pkg:<SUB>` | fresh dump; exit 0 iff current pkg contains `<SUB>` |
| `read <target> [pkg:<SUB>]` | resolve + print `coords | label | checked | via` |
| `tap <target> [pkg:<SUB>]` | resolve and tap the **actionable** element |
| `set <target> on\|off [pkg:<SUB>]` | flip a checkable switch; verify `checked` flipped (retry once) |
| `type <text>` | `input text` into the focused field (spaces auto-`%s`) |
| `replace <text>` | `MOVE_END` + ~60 `DEL`, then type — clear+overwrite rename fields |
| `key <NAME>` | `input keyevent` (`ENTER OK BACK DEL DPAD_CENTER …`) |

Targets:
- `text:<SUB>` — matches node `text` **or** `content-desc` (exact first, then
  substring). The ACTIONABLE element wins: the matched node if it is
  clickable/checkable, otherwise its **nearest clickable ancestor**. That is why
  `text:Bluetooth` taps the switch bar (row), **never** the ActionBar *title*, and
  `text:More Settings` opens the row instead of hitting a dead label.
- `id:<SUB>` — resource-id substring (e.g. `id:switch_widget` → the checkable
  switch node itself).
- `xy:<x>,<y>` — raw coordinates, no resolution. Multi-word text needs no quotes:
  `text:More Settings` is joined automatically.

Output: human lines + a final `RESULT:ok|err`; exit code is 0/1 on those.

## 1b. High-cadence loops — the persistent session (`ui-shell.sh`)

For `launch → read ui → tap → check …` loops where every step targets a DIFFERENT
screen, `ui-fast.sh` still pays a new ~4 s rish handshake per call. The fast fix is a
**persistent** driver: `scripts/ui-shell.sh` opens ONE rish session that reads
commands from a FIFO; shell state persists across commands, so the dump/resolve/
step/repl helpers are defined once at `start` and reused for every step.

```sh
UI=<SKILL_DIR>/scripts
bash "$UI/ui-shell.sh" start          # one-time ~5 s (binder handshake + boot helpers)
bash "$UI/ui-shell.sh" run "step 'com.android.settings' 'text:My Phone'"   # ~6-8 s
bash "$UI/ui-shell.sh" run "repl <NAME>"                                      # clear+type (~5-8 s)
bash "$UI/ui-shell.sh" run "step 'com.android.settings' 'text:OK'"
bash "$UI/ui-shell.sh" stop | status | ping
```

- **`run '<command>'` round-trips in ~0.3 s** (push to FIFO + wait for the marker),
  versus the ~4 s fixed + dump time of a fresh ui-fast call. The remaining cost per
  step is the unavoidable `uiautomator dump` (~3.2 s each).
- **`step '<pkg-sub>' '<target>'`** = fresh dump → pkg gate → on-device resolve →
  tap → sleep → **fresh dump for the NEXT decision**. Together with `repl`/`do_dump`/
  `resolve` it gives a "verify current UI, then go next" loop whose decision gap is
  sub-second.
- Dumps go to `/sdcard/.us.xml` + `.us.lines` (PRoot mirrors under `/mnt/sdcard/…`)
  — parse those host-side for the next decision (grep / `ui_parse.py`).
- **Fresh-dump gate stays MANDATORY here.** A tempting "reuse the last dump to skip
  the first dump" shortcut caused a wrong-tap on this device: XOS dropped the
  Settings task between runs (see §6) and the tap coordinate was computed from stale
  lines. Every `step` re-dumps and re-gates first; a gate failure (`ERR: gate
  pkg=…`) means "relaunch and retry", and the in-run post-tap dump makes the loop
  self-heal. Cheaper state checks that do NOT need coordinates (e.g. `dumpsys window
  | grep -m1 mCurrentFocus`) are fine as a quick decision aid.
- Keep ONE such session per device at a time; `stop` kills it cleanly.

## 2. The classic trio — raw reads and control

| Tool | Role | Output |
|---|---|---|
| `scripts/ui-dump.sh [OUTDIR]` | **Read** the screen | `ui.xml` (raw tree), `screen.txt` (condensed), `screen.json` (full model), `focus.txt` |
| `scripts/ui-act.sh <action> …` | **Act** (raw driver) | rish output printed |
| `scripts/ui-wait.sh <pred> [timeout_s]` | **Poll** a predicate | exit 0 = holds, 1 = timeout (last snapshot saved) |

`OUTDIR` defaults to `/tmp/shizuku-skill/ui`.

```sh
bash "$UI/ui-dump.sh"                                   # READ  → screen.txt
bash "$UI/ui-act.sh"  tap 37                           # ACT by index from that dump
bash "$UI/ui-act.sh"  tap 'text:Submit'                # resolves from OUT/ui.xml
bash "$UI/ui-act.sh"  type "Hello World"; key ENTER
bash "$UI/ui-wait.sh" text:'Saved' 15                  # poll (each round = 1 session!)
```

> **Stale-tree warning:** `ui-act.sh tap text/idx` resolves against whichever
> `ui.xml` exists. If the screen may have changed since the last `ui-dump.sh`,
> re-dump first (or use `ui-fast.sh`, which never has this problem).
> `ui-wait.sh` rounds are full sessions (~7 s each): `timeout 12` is only ~1–2
> rounds. Use it to poll (predictable transitions), not for cheap verification —
> `ui-fast.sh set`/`read` verifies in-session for free.

## 3. Read — what `screen.txt` gives you

Every enabled textual/clickable node, one per line:

```
  37 | TAP        | LinearLayout | '<network-ssid>,Connected,…' | [0,633][720,758] -> 360,695
  38 |            | TextView     | 'Wi‑Fi'                   | [117,710][484,749] -> 300,729  #title
```

`idx | marks(TAP,FIELD,CHECK,SCROLL) | class | label | bounds -> center`. `screen.json`
keeps the full attribute set (text, content-desc, resource-id, scrollable, checked,
selected, password, package…) for programmatic decisions.

### Picking a tap target from an old-style dump
- `tap 37` — by index (the TAP container for a row is usually above the label node).
- `tap text:<network-ssid>` — by unique substring (resolver prefers clickable,
  enabled, non-scrollable; prints a WARNING if several match).
- **Prefer `ui-fast.sh` for taps** — it resolves against a *fresh* tree and prefers
  the actionable element/ancestor, which `ui-act.sh` cannot.

### Actions cheat-sheet (`ui-act.sh`)
| Action | Form |
|---|---|
| tap | `tap <idx>` / `tap text:<sub>` |
| long press | `longtap <idx|text:…>` (800 ms) |
| type | `type "text with spaces"` (spaces auto-mapped to `%s`) |
| key | `key BACK` `key HOME` `key ENTER` `key TAB` `key DEL` `key ESC` … |
| swipe | `swipe X1 Y1 X2 Y2 [MS]` |
| scroll | `scroll up\|down\|left\|right [N]` |
| launch | `launch <component>` or `launch -a <intent action>` |
| navigate | `back` `home` |
| wake | `wake` (screen off → `uiautomator dump` fails) |
| state | `focus` (current focused window) |

## 4. Confirm — predicates (`ui-wait.sh`) and in-session verify

| Predicate | True when |
|---|---|
| `text:<sub>` | any node text/content-desc contains `<sub>` (case-insensitive) |
| `gone:<sub>` | no node contains `<sub>` |
| `pkg:<pkg>` | current screen's package contains `<pkg>` (prefix match) |

```sh
bash "$UI/ui-act.sh" tap "text:Save"
if bash "$UI/ui-wait.sh" text:"saved" 15; then echo confirmed; else echo retry; fi
```

For switches, `ui-fast.sh set … on|off` **already verifies** the state flipped and
retries once — no separate confirm round needed. `pkg:` gates in `ui-fast.sh` are
the cheap way to guarantee "I am on the right screen before I tap."

## 5. Reliability rules (learned the hard way — READ THIS)

1. **The Shizuku manager crash — FIX IT ONCE, then it's gone.**
   Run `bash scripts/shizuku-disable-selfstart.sh` first: it turns the manager's
   **Start on boot (wireless ADB)** setting OFF (the smali-verified precondition
   for the Android 15 `ForegroundServiceStartNotAllowedException` crash). After
   that no `REQUEST_BINDER` broadcast can kill the manager and exit codes become
   meaningful. If the pref is left ON, the manager (backgrounded while your target
   app is foreground, on Wi‑Fi) can die with `reason=4` on any broadcast — harmless
   (`shizuku_server` survives) but raw exit codes become unreliable.
2. **Trust only a fresh dump.** `uiautomator dump` prints `dumped to:` on success;
   on failure it can leave the previous file behind. Never gate on
   `$?`/file-exists alone. `ui-fast.sh`, `ui-dump.sh`, `ui-wait.sh` all check the
   message now. If you hand-roll a dump, check it too.
3. **Check the current UI, then go next.** Before every tap: confirm the screen
   (pkg gate) and resolve on the just-made dump. Judge actions by the re-read
   state, not the exit code (`input tap` may print `Request timeout …` yet land).
4. **One rish session per logical step; never run rish calls in parallel.**
   Each call = a serialized ~4 s ordered broadcast; concurrency → `Request timeout
   … disable battery optimization`. `ui-fast.sh` is one session per step; batch
   raw on-device work into one stdin `rish <<'EOF' … EOF` session (all commands
   share the session cost).
5. **Reads are idempotent, mutators are not.** Auto-retry reads
   (`ui-dump.sh`/`ui-wait.sh` retry internally). Re-issuing a `tap`/`back` blindly
   can double-fire — confirm first, then decide.
6. **First call after idle may cold-start the manager** → if the first dump of a
   session errors, wait ~3–5 s and re-run once; it is not a device fault.
7. **Cleanup is free**: dumps overwrite fixed `/sdcard` paths (`.uic.xml`,
   `.uiw.xml`, `.uif.xml`); PRoot copies land in `OUTDIR`.

## 6. Gotchas specific to this device

- **Transsion/XOS settings packages.** System-settings pages live in
  `com.transsion.settings*`, NOT `com.android.settings` — e.g. the Bluetooth page
  is `com.transsion.settings.bluetooth` (activity
  `…bluetooth.ui.BluetoothSettingsActivity`). Always gate with a Transsion prefix:
  `pkg:com.transsion.settings`. A `pkg:com.android.settings` wait will time out
  forever even though the page IS open.
- **Animations** make `uiautomator dump` return "could not get idle state" → dumps
  retry automatically; give taps ~1.5 s before verifying (ui-fast does this).
- **Secure windows** (PIN entry, banking, keyguard) refuse the dump → `focus.txt`
  still tells the window; `wake` first if the screen is off.
- **Hidden/obfuscated nodes**: Transsion/XOS injects hidden rows (e.g. a
  `syntafbhli5t` "Use more services" ad row) — ignore them, never tap them blind.
- **XOS Settings task-removal quirk**: tapping inside Settings (observed on the
  *home* `SettingsHomeActivity` AND on the "My Phone" sub-page) has removed the
  Settings task entirely (exit-info `reason=10 subreason=22 REMOVE TASK`) and
  dropped back to Termux — sometimes with a delay, so a *later* step's tap can land
  on Termux. That is why every step re-dumps and re-gates the pkg: a `gate
  pkg=com.termux` failure means "relaunch and continue", and re-`launch` the target
  (`am start -a android.settings.*`). Prefer intent navigation over deep row-walks
  where possible.
- **`type`**: Android `input text` wants `%s` for spaces (handled); quote the
  whole string; single quotes are stripped.
- **Rename dialogs (XOS/Transsion):** the positive button is **disabled until the
  text changes** — the initial dump shows only `Cancel`, and `OK`/`Save` pops into
  the tree only after you edit. Flow: `tap` the row → `replace <new>` → verify the
  field (`read text:new`) → re-dump to see the now-enabled positive button → `tap
  text:OK`. Renaming Device Name on the "My Phone" page updates
  `settings get global device_name`; the Bluetooth name is a **separate** setting
  (`secure bluetooth_name`) renamed on the Bluetooth settings page (only visible
  while Bluetooth is ON) — don't assume they are the same value.
  `replace` clears via `MOVE_END` + repeated `DEL`, which is one cheap session.
- **The user is probably in Termux on the same device** — start from wherever the
  screen is, `launch` your target, **confirm the pkg**, drive it, and restore
  Termux (`launch com.termux/.app.TermuxActivity` + `check pkg:com.termux`).

## 7. Device-courtesy rules

- When done with any app, restore the user's terminal:
  `bash "$UI/ui-fast.sh" launch com.termux/.app.TermuxActivity` and
  `check pkg:com.termux`.
- Mutating UI actions belong to the app under analysis only — never alter another
  app's state (e.g. don't disconnect the user's Wi-Fi while demonstrating taps;
  restoring switches to their original state is polite).
- Scripts: `ui-fast.sh` (default), `ui-dump.sh`, `ui-act.sh`, `ui-wait.sh`,
  `ui_resolve.py`, `ui_parse.py`, `ui_wait_check.py`, `ui_toggle.py` (find a
  settings switch by its label), and `shizuku-disable-selfstart.sh` (the crash
  fix) in `scripts/`.