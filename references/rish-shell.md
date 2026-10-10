# rish — shelling out as uid 2000 (shell)

The agent lives inside a PRoot-Ubuntu environment whose host is Termux. Shizuku
installed a `rish` script into `/data/data/com.termux/files/home/rish`. Executing it
starts an `app_process` that connects through the Shizuku protocol and drops into a
shell owned by **uid 2000 (shell)** — the same uid `adb shell` uses, without adb.

## The wrapper (this skill's `scripts/rish`)

```sh
#!/system/bin/sh
# Shizuku authorization is per-application-id. Termux owns this invocation.
export RISH_APPLICATION_ID=com.termux
exec /data/data/com.termux/files/home/rish "$@"
```

Usage from the PRoot shell:

```sh
RISH=<SKILL_DIR>/scripts/rish
"$RISH" -c 'id'
```

Output (captured on this device):

```
uid=2000(shell) gid=2000(shell) groups=2000(shell),1004(input),1007(log),1011(adb),
1015(sdcard_rw),1028(sdcard_r),1078(ext_data_rw),1079(ext_obb_rw),3001(net_bt_admin),
3002(net_bt),3003(inet),3006(net_bw_stats),3009(readproc),3011(uhid),3012(readtracefs)
context=u:r:shell:s0
```

Group highlights that make this useful: `input` (inject keys/taps), `log`, `adb`,
`sdcard_rw`, `readproc`, `inet`.

## Command forms

```sh
"$RISH" -c 'single command'                    # run one command
"$RISH" -c 'a; b | c > /data/local/tmp/x'      # full shell line
"$RISH" -c 'cat /data/user_de/0/com.android.shell/shizuku.json'   # host filesystem is visible
"$RISH"                                          # interactive shell (avoid in non-interactive sessions)
"$RISH" <<'EOF'                                  # SCRIPTED SESSION (cheapest form)
...
EOF
```

**Session cost is per invocation, not per command.** A `-c '…'` call costs ~3.5–4 s
regardless of how many commands it contains; a **multi-line script piped via
stdin** costs the same ~4 s for ALL its commands. Example:
`printf 'echo a\nid\npidof shizuku_server\n' | rish` ≈ 4.4 s total versus ~3×4 s
for three separate calls. Note the commands run under the server-side `shell`
environment: **environment variables do NOT propagate** from the calling PRoot
shell into the rish session (verified), so inject values literally into the script
text. `scripts/ui-fast.sh` (see `references/ui-automation.md`) uses exactly this
trick to run dump→resolve→tap→verify in one session.

## Verified usable (read-only)

- `pm path/list/dump`, `dumpsys package ...`
- `dumpsys activity exit-info <pkg>`, `dumpsys activity services|activities|broadcasts`
- `dumpsys window`, `dumpsys dropbox --print`
- `logcat` (main / crash / events buffers; `--pid`, `-s`)
- `settings get global|secure|system`, `getprop`
- `service list`, `service check <name>`, `cmd -l`
- `ps -A`, `pidof`, `/proc/<pid>/maps`, `/proc/<pid>/status`
- `cat /data/anr/*`, `head /data/tombstones/*`, `cat /data/local/tmp/*`
- `appops get <pkg>`

## Verified blocked / limited

- `cat /data/data/<other-app>/...` → `Permission denied` (as expected)
- `su` → not found (no root)
- `service check shizuku` → `Service shizuku: not found` (server has no servicemanager binder)
- Some settings writes → `Failed to find setting` / `Permission denied` without the right holder

## Pitfalls

1. **Batch commands into one `-c '...'`.** Every rish invocation sends a
   `REQUEST_BINDER` broadcast to the manager. If the `start_on_boot_wireless`
   preference is enabled and the phone is on Wi‑Fi, that broadcast can trigger the
   manager FGS crash (§logs-and-crashes). Run
   `scripts/shizuku-disable-selfstart.sh` once to remove it; otherwise batching
   still reduces noise and crash churn.
2. **`RISH_APPLICATION_ID` must match the owner package.** Wrong value → rish exits
   with a printed error. Our wrapper pins it to `com.termux`.
3. **You are NOT root.** Commands that work are exactly those granted to the
   `shell` user; don't assume more.
4. **5 s connect timeout.** If the connection can't complete:
   `Request timeout. ... disable battery optimization for both apps`.
5. Prefer writing scratch/output under `/data/local/tmp` (owned by shell) and
   reading it back into the PRoot side.