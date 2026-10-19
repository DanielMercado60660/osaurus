# T13b — Phone screen view hardening

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, `fork/tasks/T13-phone-remote-screen.RESULT.md`.
A security review of T13 found no non-owner access path but these issues.
Paths: `Packages/OsaurusCore/` = `PC/`.

1. **Unauthenticated audit flooding (medium).** `/phone/api/screen` hops to the
   main actor and writes an Insights row for every request, including 403s from
   callers with no marker/secret, and the rate limiter only runs after the trust
   check (`PC/Networking/HTTPHandler.swift` ~635-638, ~4730-4765;
   `PC/Services/PhoneAccess/PhoneScreenService.swift` ~56-76). Fix: evaluate
   the `verifiedDevice` predicate on the NIO event loop before any MainActor
   hop; unverified callers get 403 with no per-request row (coalesce to at most
   one "rejected N unverified screen requests" row per minute). Per-device
   limiter also caps 429 rows.
2. **Audit fails open (medium).** If `InsightsService.storeAvailable` is false
   or the append throws, frames are still served
   (`PC/Managers/InsightsService.swift` ~165-183). Fix: require a durable store
   before capture (503 `audit_unavailable` otherwise); write a durable "screen
   view started (device …)" row **before** the first frame of a viewing session
   and coalesce subsequent frames into periodic rows; surface append failures by
   stopping the session.
3. **Screen access tied to any allowed login (low).** Forward the WhoIs login in
   a helper-set header (stripped from client input like the others) and require
   it to equal the tailnet node owner's login for the screen route; other
   allowed logins can chat but not view the screen. Update the toggle caption.
4. **Indicator can be hidden (low).** In addition to the status item, show a
   small floating non-activating overlay ("Phone is viewing your screen") on the
   active display while viewing, and post a user notification on the first frame
   of each session (and after > 60 s idle gaps).
5. **Setting persists forever (low).** Reset "Allow phone to view this Mac's
   screen" to off whenever Phone access is turned off, and auto-disable it after
   7 days unused; show when it will expire in the card.

Tests for each (predicate on loop, coalescing, 503 path, login check in Go and
Swift, overlay timeout, reset/expiry). Commit on your branch; write
`fork/tasks/T13b-screen-hardening.RESULT.md` (finding → fix → test).
