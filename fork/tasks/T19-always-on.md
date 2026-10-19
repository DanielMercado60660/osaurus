# T19 — Always on, always reachable from the phone

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, and RESULT files for T04,
T04b, T13b. Paths under `Packages/OsaurusCore/`.

## Goal

The owner wants their personal AI **always running and reachable from the
phone** (over Tailscale) without babysitting the Mac. Today: the app must be
open, the Mac may sleep (tailnet unreachable), and nothing tells the owner why
the phone can't connect.

## Deliverables

1. **"Keep my AI reachable" (Phone access card)**, one toggle that turns on:
   - Start at login (use the existing `LoginItemService`; it currently logs
     `SMAppServiceErrorDomain Code=1 Operation not permitted` for unsigned/dev
     builds — surface that clearly instead of silently failing);
   - start the server + phone helper on launch when Phone access is on, with the
     app running in the background (menu bar only, no window) — reuse existing
     silent-launch paths (`isSilentLaunch` in `AppDelegate`);
   - **prevent idle system sleep** while Phone access is on and the Mac is on
     AC power, via an `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)`
     assertion (display may sleep). On battery: no assertion, and say so. Release
     the assertion when Phone access turns off or the app quits.
   - show a status line: "Reachable at https://… · Mac stays awake on power" /
     "Not reachable: Mac will sleep on battery" etc.
2. **Recover after sleep/wake and network changes**: on `NSWorkspace.didWakeNotification`
   and network path changes, health-check the tsnet helper (status stream) and
   restart it if it doesn't report `running` within ~10 s.
3. **Phone page offline state**: when the Mac is unreachable the PWA shows
   "Your Mac is asleep or offline" with the last-seen time instead of a generic
   fetch error, and retries with backoff.
4. Settings-catalog rules for the new toggle; docs in `guide-settings.md`.

## Tests

Pure logic: assertion policy (phone on/off × AC/battery), helper health
state machine (wake → check → restart), status-line text, JS offline/backoff.
Commit on your branch; write `fork/tasks/T19-always-on.RESULT.md` with a live
checklist (sleep the Mac on AC, open phone page; unplug; reboot → reachable).
