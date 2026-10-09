# Script-free build — verification before you trust it

The wake logoff in this folder is **two scheduled tasks and nothing else**. Both run as
**LOCAL SYSTEM** and execute `rwinsta.exe console` — a reset of the console session,
targeted by name, so there's no session-ID resolution and no dependence on which user
is signed in or on an interactive token existing. A reset is deliberately *not* a
graceful logoff: apps get no save prompts and can't stall it, which is why it's faster
than `logoff.exe`. On a thin client that holds no local data that's the right trade —
the Cloud PC session simply drops to disconnected server-side and waits for the next
authenticated sign-in, which is the outcome the whole design wants.
No PowerShell, no files on the endpoint besides the tasks themselves.

| Task | Trigger | Filter |
|---|---|---|
| `W365-LogoffOnSxWake` | Power-Troubleshooter **1** + Kernel-Power **107** | None — an Sx (S3/hibernate) resume is always a genuine return |
| `W365-LogoffOnStandbyWake` | Kernel-Power **507** (exiting Modern Standby) | In the trigger query itself: Reason is **Lid or Power Button** AND standby lasted **> 120 s** |

## Why the 507 filter can live in the query

Two facts from the pilot device's own logs (Oct 9, 2026):

1. **The event XML stores Reason as a number**, and renders the friendly text
   ("Lid", "Power Button", "Input Touchpad", …) only at display time. Trigger
   queries match the number, so the allowlist is a query clause, not a script.
2. **Event 507 carries `DurationInUs`** in its EventData — the standby duration in
   microseconds, measured by the OS and stamped on the exit event. So the
   "standby floor" is also a query clause: `DurationInUs > 120000000`.

## The 507 subscription query (as shipped)

```xml
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=507)] and EventData[(Data[@Name='Reason']=15 or Data[@Name='Reason']=1) and Data[@Name='DurationInUs']&gt;120000000]]</Select>
  </Query>
</QueryList>
```

**Floor conversions** (DurationInUs is microseconds): 60 s = `60000000` ·
120 s = `120000000` · 300 s = `300000000`. Edit the number in the task XML to retune.

## Verify on the pilot — 10 minutes, do these in order

1. **Reason codes.** Run `Verify-PilotEvents.ps1` (one-time diagnostic; not deployed).
   Confirm the rows whose ReasonText is `Lid` carry code **15** and `Power Button`
   rows carry code **1**. These are the community-decoded values; Microsoft publishes
   no table. If your build differs, edit the two numbers in the Subscription of
   `W365-LogoffOnStandbyWake.xml` (and the NOFLOOR variant) before importing.
2. **DurationInUs sanity.** In the same output, check `StandbySec` is populated and
   plausible. Then do one timed test: lid closed ~3 minutes, reopen — the newest 507
   should show ~180 s. If the field is missing or nonsense on this build, the floor
   clause can't be trusted; use the NOFLOOR variant and accept flap logoffs, or fall
   back to the v1 script build.
3. **Query dry-run against history.** Event Viewer → Create Custom View → XML tab →
   paste the query above. Against the pilot's existing log it should return only
   Lid / Power Button exits longer than the floor — on the Oct 2026 pilot history
   that's a *small* set, because most long absences on that machine ended in
   hibernate (handled by the Sx task) and most lid cycles were 11–36 s relocations
   (correctly excluded). Small is expected; *wrong reasons in the result* is not.
4. **Import test.** `schtasks /create /tn "W365-LogoffOnStandbyWake" /xml W365-LogoffOnStandbyWake.xml /f`
   — if Task Scheduler rejects the query (the numeric `>` comparison on EventData is
   the one untested assumption), import `W365-LogoffOnStandbyWake-NOFLOOR.xml`
   instead and tell Gemma; the floor then needs the v1 script or a different trick.

## Import / remove (deployment is two commands; nothing else lands on the box)

```bat
schtasks /create /tn "W365-LogoffOnSxWake"        /xml W365-LogoffOnSxWake.xml        /f
schtasks /create /tn "W365-LogoffOnStandbyWake"   /xml W365-LogoffOnStandbyWake.xml   /f

schtasks /delete /tn "W365-LogoffOnSxWake"      /f
schtasks /delete /tn "W365-LogoffOnStandbyWake" /f
```

## Expected behaviour (pilot test matrix)

| Test | Expected |
|---|---|
| Lid closed 10 s, reopen | **No logoff** — under the floor |
| Lid closed 5 min, reopen | Logoff → Windows logon → auth → SSO to Cloud PC |
| Power-button sleep 5 min, wake | Logoff |
| Idle timeout, then touchpad/keyboard wake | No logoff — reason not in allowlist |
| Long standby → machine hibernates → lid open | Logoff via the Sx task (107 / PT1) |
| Plug/unplug AC flapping (AC/DC burst 507s) | No logoff |
| Cold boot | Untouched — single sign-in, SSO flows as before |

**Double-coverage note:** a hibernate resume can also emit a 507 (on the pilot it
did — reason Lid, alongside 107). If that 507's DurationInUs clears the floor, both
tasks fire `rwinsta.exe console`; the second reset is a harmless no-op on an
already-ending session. Same story if a qualifying 507 fires while the device sits
at the logon screen with nobody signed in — the console session just resets to a
fresh logon screen.

**What this build deliberately does not cover:** the disconnect-while-awake path
(v1 Path 2). Arm/cancel state can't be expressed in trigger queries, and on the
pilot it's still unproven whether LocalSessionManager 24/25 even fire for Cloud PC
disconnects. If they do and you want that path, it's the v1 scripts — everything
else stays script-free.
