> **Repo note:** the task XMLs in this repo are UTF-8 copies for readability. `schtasks /create /xml` wants the UTF-16LE originals — re-encode before import (the local package folder holds the deployable copies).

# W365 Thin Client — Log off the local IoT session when the Cloud PC session can't be trusted

**Problem (Bruce, Oct 8 2026):** On the Windows 11 IoT thin clients, lock-on-physical
and disconnect-on-MA-identity are disabled because of the credential-provider config.
So when a Cloud PC session locks, only the Cloud PC locks. If the user then closes the
lid / sleeps the device, on wake it SSOs straight back into the Cloud PC with **no auth**.

**Goal:** Log the user off the *local IoT session* whenever the device transitions to a
disconnected state — but not so aggressively that a Wi-Fi blip or quick dock/undock
logs people out mid-work.

## ⭐ Recommended build (v2, Oct 9 2026): script-free — folder `script-free/`

Pilot testing on Bruce's actual thin client changed the design. The fleet is
**Modern Standby (S0ix)**, and two months of its Kernel-Power logs showed:

- 506/507 fire constantly, mostly noise (Input Touchpad/Keyboard idle cycles,
  AC/DC display bursts). Only **Lid** and **Power Button** 507 exits mean
  "a person deliberately left and returned."
- The machine also drops from standby into **S4 hibernate** when the standby
  battery budget is exceeded — those resumes fire Kernel-Power **107** and
  Power-Troubleshooter **1**, exactly what v1 Path 1 already triggers on.
- Genuine short lid cycles are common (11–36 s while relocating the device),
  so a **standby-duration floor** is required — and Event 507 carries
  `DurationInUs` in its own payload, so the floor can be evaluated **inside the
  trigger query**. No script ever has to run.

The script-free build is two tasks running as **LOCAL SYSTEM** whose only action is
`rwinsta.exe console` (session reset by name — Bruce's choice over `logoff.exe`,
Oct 9 2026: faster, unstallable, and indifferent to which user is signed in):

- `W365-LogoffOnSxWake` — PT1 + 107, no filter (an Sx resume is always a real return).
- `W365-LogoffOnStandbyWake` — 507 with the query doing all the work:
  Reason ∈ {Lid (15), Power Button (1)} **and** `DurationInUs > 120000000` (120 s).

Full rationale, the raw query, a 10-minute verification protocol (reason codes and
`DurationInUs` are build-specific and must be confirmed on the pilot), and a fallback
no-floor variant live in **`script-free/VERIFY.md`**. The v1 scripted build below is
retained for one thing only: Path 2 (disconnect grace), which cannot be expressed in
trigger queries — and which is still unproven on this hardware (see the Path 2
verification warning). If LocalSessionManager 24 never fires on these clients, the
script-free build is the whole solution.

## Design — two paths, deliberately different

### Path 1 — Power transitions: log off immediately on wake (no grace period)
Sleep / lid-close are deliberate. There is no "blip" version of waking from sleep,
so no debounce here.

- Task `W365-LogoffOnWake` fires on **wake**, not on sleep entry
  (a task starting while the machine is suspending may never finish; wake is reliable):
  - `System` log, source `Microsoft-Windows-Power-Troubleshooter`, **Event ID 1** (resumed from sleep)
  - `System` log, provider `Microsoft-Windows-Kernel-Power`, **Event ID 107** (resumed from suspend)
  - Optional, disabled by default in the XML: Kernel-Power **Event ID 507** (exiting
    Modern Standby / S0ix) — enable only if your pilot devices use Modern Standby
    and 1/107 don't fire (see Verification). 507 can also fire on ordinary idle
    standby entry/exit, so test before enabling fleet-wide.
- Action: `Invoke-W365Logoff.ps1 -Mode Wake` — cancels any pending logoff, writes a
  log line, then `logoff.exe <own session id>`.
- Race note: the Windows App may start auto-reconnecting on wake. Logoff of the
  local session wins — the client dies with the session — and the user lands on the
  Windows logon screen, authenticates, *then* SSOs into the Cloud PC. That's the point.

### Path 2 — Disconnect while awake: 5-minute grace, cancelled by reconnect
This is where the Wi-Fi-blip worry lives, so a disconnect never logs off directly.

- Task `W365-ArmLogoffOnDisconnect` fires on
  `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` **Event ID 24**
  (session disconnected) and runs `Arm-PendingLogoff.ps1`, which registers a one-time
  task `W365-PendingLogoff` for **now + GraceMinutes (default 5, in `config.json`)**
  that runs `Invoke-W365Logoff.ps1 -Mode Expired`.
  - If a pending logoff is already armed, it is **not** re-armed/reset — repeated
    disconnect flapping can't push the logoff out forever.
- Task `W365-CancelLogoffOnReconnect` fires on LocalSessionManager **Event ID 25**
  (session reconnected) and runs `Cancel-PendingLogoff.ps1`, which deletes
  `W365-PendingLogoff` if present.
  - Blip < 5 min → reconnect cancels → session untouched.
  - Real disconnect → timer expires → logged off.
  - Sleeps mid-window → `StartWhenAvailable` fires the pending task on wake,
    which is harmless: Path 1 has already logged the user off.

All tasks run **in the logged-on user's context** (`InteractiveToken`, least
privilege). Nothing runs as SYSTEM except the installer. The logoff script resolves
its *own* session ID from its own process, avoiding the classic SYSTEM-context
`logoff.exe` footgun of logging off the wrong session.

## ⚠️ The one verification that decides whether Path 2 works as-is

Event 24/25 describe the **local** Terminal Services session. Confirm on a pilot
device that a Cloud PC disconnect actually produces a local session disconnect.
On some Windows App / RDP configurations the local IoT session stays "Active" the
whole time and only the *client's* connection drops — in that case Event 24 never
fires and Path 2 needs its trigger swapped to the client event source (check
`Microsoft-Windows-TerminalServices-ClientActiveXCore` / the Windows App logs while
doing the lid-close and Wi-Fi tests below). **Path 1 is unaffected** — it keys off
power events, which fire regardless — and Path 1 covers the lid/sleep hole Bruce
described, which is the actual security issue.

## Files

```
script-free/                ⭐ v2 (recommended): zero scripts at runtime
  W365-LogoffOnSxWake.xml          PT1 + 107 -> rwinsta.exe console (as SYSTEM)
  W365-LogoffOnStandbyWake.xml     507, query-filtered (reason + DurationInUs floor) -> rwinsta.exe console
  W365-LogoffOnStandbyWake-NOFLOOR.xml  fallback if the build rejects the floor comparison
  Verify-PilotEvents.ps1           one-time diagnostic (NOT deployed)
  VERIFY.md                        rationale, raw query, verification protocol
scripts/
  Invoke-W365Logoff.ps1     logoff own session (-Mode Wake|Expired), with logging
  Arm-PendingLogoff.ps1     registers W365-PendingLogoff at +GraceMinutes
  Cancel-PendingLogoff.ps1  deletes W365-PendingLogoff if present
  config.json               { "GraceMinutes": 5, "WakeDelaySeconds": 3 }
  Install-W365Logoff.ps1    elevated: copies scripts, sets log ACL, imports tasks
  Uninstall-W365Logoff.ps1  elevated: removes all four tasks + install folder
tasks/
  W365-LogoffOnWake.xml
  W365-ArmLogoffOnDisconnect.xml
  W365-CancelLogoffOnReconnect.xml
```

Scripts + log live in `C:\ProgramData\W365Logoff\` (`scripts\`, `w365-logoff.log`).
Users get Modify on the log file only; scripts are read/execute for Users,
write for SYSTEM/Admins (a user-writable logoff script would be a privesc toy).

## Deploy (Intune)

1. Pilot first — one device, one friendly user, one day. Do not fleet-push this
   untested; a logoff bug is a very visible bug.
2. Package the folder as a Win32 app (or push via Platform scripts / Proactive
   Remediation with the install script as the remediation):
   `powershell.exe -ExecutionPolicy Bypass -File Install-W365Logoff.ps1`
   run as **SYSTEM**, 64-bit.
3. Uninstall command: same line with `Uninstall-W365Logoff.ps1`.
4. Detection: task `W365-LogoffOnWake` exists
   (`Get-ScheduledTask -TaskName 'W365-LogoffOnWake'`).

## Test matrix (pilot device)

| # | Test | Expected |
|---|------|----------|
| 1 | Close lid 10 s, reopen | Windows logon screen; auth required before Cloud PC |
| 2 | Close lid 10 min, reopen | Same as 1 |
| 3 | Sleep button, then wake | Same as 1 |
| 4 | Wi-Fi off 2 min, back on | Session intact; log shows ARM then CANCEL |
| 5 | Wi-Fi off 10 min | Logged off at ~5 min |
| 6 | Disconnect, then sleep mid-window, wake | Logon screen (Path 1; pending task no-ops) |
| 7 | Normal lock/unlock, no sleep/disconnect | Nothing happens — no logoff |
| 8 | Check Event Viewer first: do 1 / 107 fire on wake? Do 24 / 25 fire on Cloud PC disconnect/reconnect? | If not, see verification note above; run `powercfg /a` — if the device is S0ix/Modern Standby, enable the 507 trigger in the Wake XML and retest 1–3 |

Log check: `Get-Content C:\ProgramData\W365Logoff\w365-logoff.log -Tail 20`
Every action (WAKE logoff, ARM, CANCEL, EXPIRED logoff) writes one timestamped line —
enough to prove behaviour in the pilot and to feed Nexthink later if you want a
remote action / custom metric on logoff counts.

## Trade-offs & notes

- **Unsaved local work is lost on logoff.** Acceptable on a thin client with no local
  data by design — say it out loud in the pilot comms anyway.
- **Grace period is a config value, not a code change.** 5 min is a starting point;
  if your Wi-Fi roaming is rough, 7–10 min costs little security on Path 2 because
  Path 1 (the real hole) has no grace at all.
- **Cloud PC-side "Always prompt for password upon connection" — evaluated and
  rejected (Bruce, Oct 8 2026).** The policy is unconditional: it prompts on every
  connection including cold boot, which breaks SSO and forces a double login in the
  one flow that currently works. The local-logoff approach exists precisely to
  avoid that; don't pair them.
- Tasks use `IgnoreNew` for multiple instances and a 2-minute execution limit, so a
  wedged run can't stack up or wedge the next wake.

*Prepared Oct 8, 2026; v2 script-free build added Oct 9, 2026 from pilot-device
event-log evidence. Untested on Bruce's hardware — the test matrices are the test.
Event IDs, reason codes, and the DurationInUs floor should be confirmed on one
pilot IoT device before any wider rollout.*
