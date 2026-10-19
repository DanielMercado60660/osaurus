# T13b — Phone screen view hardening

Status: **PARTIAL — implementation and isolated verification complete; commit BLOCKED by sandbox; full Core/Release app and live UI proof unverified.**

## Source and commit blocker

- Branch: `task/T13b-screen-hardening`.
- Base/current HEAD: `04e3dd160f7856da886bd03f4310643e9fc8dff9`.
- Changes are **uncommitted and unstaged**. This HEAD is the base, not a tested
  implementation commit. The exact 19 changed implementation/test/documentation
  files (excluding this RESULT) are hashed in
  `build/T13b/source-manifest.sha256`; manifest SHA-256:
  `cf257a4154e7f003b8205932a32e8c5c5644f043663546e397420fce19cbcb22`.
- Attempted `git add -A` then
  `git -c commit.gpgsign=false commit -m "Harden phone screen trust, durable auditing, indicators and expiry"`
  in a `set -e` shell. Staging failed:

  ```text
  fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T13b-screen-hardening/index.lock': Operation not permitted
  ```

  The commit command did not run. No alternate index/metadata or sandbox bypass
  was used. Diagnostic: `build/T13b/commit-failure.txt`. Once normal Git metadata
  writes are available, stage the implementation and this RESULT and commit on
  this branch; do not push.
- vMLX pin unchanged in both resolved files:
  `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`. Tailscale helper dependency remains
  `v1.94.2`. No built app pin, model bundle, generation defaults, token/s, model
  scores, or live runtime results are claimed.

## Finding → fix → test

| Finding | Implemented fix | Evidence and limits |
| --- | --- | --- |
| Unauthenticated audit flooding | `HTTPHandler` evaluates `verifiedDevice` synchronously on the NIO event loop before creating the request task. Failure writes 403 directly, without MainActor service access or per-request audit. A process-wide locked counter and single 60-second timer emit one aggregate rejection row. Verified rejections, including 429s, are capped at one row/device/minute. | Passing concurrent 10,000-rejection test proves one scheduled aggregate and exact count; 1,000 in-flight 429s produce one rejection row, with the next allowed at 60 seconds. Repeated capture failures also cannot flood start rows. Added `HTTPAuthGateTests.unverifiedScreenRejectsOnEventLoopWithoutActorHop`, which synchronously expects the 403 while MainActor is occupied; this full-Core test is **not run**, only syntax-checked. Route ordering was source-inspected. |
| Audit fails open | Capture requires a healthy open Insights store. The service awaits a durable `screen view started (device …)` metadata row before capture. Subsequent frames produce periodic summaries instead of individual rows. Durable append temporarily selects SQLite `synchronous=FULL`, restores the prior mode, and updates the hot cache only after append succeeds. Any observed ordinary or durable append failure revokes durable admission until relaunch. Availability is rechecked after capture; errors return 503 `audit_unavailable`, discard pixels, invalidate sessions, and clear indicators. | Passing tests cover missing store, initial/periodic append exceptions, awaiting the start write, revocation while that write is pending, storage loss during capture, 120 frames coalesced into one start plus a periodic summary, real SQLite injected failures, hash-chain verification, FULL mode during insert and restoration afterward. The actual Insights/store files compile unchanged in the audit isolation; system plaintext SQLite substitutes for SQLCipher. Real encrypted/on-disk app persistence and power-loss durability are **unverified**. |
| Any allowed login can view | Helper replaces client `X-Osaurus-Phone-Login` values with WhoIs login, alongside existing secret/device headers; strips Connection nominations before injection. Screen admission in Go and Swift requires the actual node owner's login, case-insensitively, in addition to existing login/device policy. Helper `owner_login` now reports the actual owner rather than the configured chat allowlist. Unknown owner fails closed. Restart clears cached owner identity with the secret. | Go race-enabled tests verify owner screen access, allowed guest chat but denied screen, absent owner, owner excluded from allowlist, forged/duplicate login headers and hop-by-hop nominations. Swift trust matrix covers missing/wrong/combined login, case folding and unknown owner. Actual tsnet/WhoIs transport and rebuilt helper embedding remain **unverified**. |
| Hidden indicator | Keep the menu-bar item and add a small non-activating, mouse-transparent floating NSPanel on the display containing the pointer (fallback NSScreen.main), across Spaces/fullscreen auxiliary windows. Both share the five-second timeout and immediate stop/revoke cleanup. Successful first frames post a user notification per device/session, repeated after more than 60 seconds idle, including slow captures that create that gap. | Passing service/policy tests cover timeout boundaries, clearing on stop/failure, notification counts, idle-gap restart and slow-capture gaps. Actual AppKit implementation compiles in isolation; no real panel/status item or notification was displayed. Notification delivery follows existing macOS authorization and the app's existing NotificationService delegate; headless processes skip notification posting. Fullscreen/multidisplay placement and actual delivery remain **unverified**. |
| Indefinite persisted grant | Phone-access off clears the screen grant and timestamp. Enabling starts a seven-day interval; only successful frames renew it. Persisted expiry is checked at initialization, request admission/completion, settings appearance/activation and an expiry task. Expired or legacy undated grants reset to off. The card shows the expiry date, owner-only caption, and disables the screen control while Phone access is off. | Passing tests cover defaults/persistence, legacy/expired grants on reconstruction, exact expiry boundary, successful renewal, no renewal from denied requests, Phone-access-off reset and reconstructed state. Settings title/anchor remain canonical; catalog aliases/disambiguation, guide and search probes are updated. Actual settings clicks/save/relaunch and seven-day wall-clock operation remain **unverified**. |

Periodic audit rows describe the preceding interval's captured/returned frame
count and bytes, not exact network-delivery receipts. The final partial interval
is not flushed when viewing ends. The durable session-start row remains the
precondition for any capture. Audit details contain verified device IDs, status,
event/counts and sizes, never pixels or helper secrets. An audit append failure
requires restoring storage and relaunching Osaurus before retrying screen access;
ordinary Insights writes retain their existing best-effort behavior.

## Files

Under `Packages/OsaurusCore/`:

- `Services/PhoneAccess/PhoneScreenPolicy.swift`, `PhoneScreenService.swift` —
  trust, coalescing, session auditing, expiry, overlay/notification lifecycle.
- `Services/PhoneAccess/PhoneAccessState.swift`,
  `TailscalePhoneAccessService.swift` — login header/owner trust, off reset.
- `Networking/HTTPHandler.swift` — event-loop rejection and shared response writer.
- `Managers/InsightsService.swift`, `Storage/ActivityLogStore.swift` — awaited
  durable append and failure propagation.
- `Views/Settings/PhoneAccessSettingsCard.swift`,
  `Models/Configuration/SettingsSearchIndex.swift`,
  `Resources/Guide/guide-settings.md` — owner/expiry UI and canonical catalog/docs.
- `Tests/PhoneAccess/PhoneScreenTests.swift`,
  `Tests/Insights/ActivityLogSettingsTests.swift`,
  `Tests/Networking/HTTPAuthGateTests.swift`,
  `Tests/Configuration/SettingsSearchSelfFindProbe.swift` — regression coverage.

Also: `helpers/osaurus-ts/main.go`, `main_test.go`,
`scripts/test-phone-access-isolated.sh`, new
`scripts/test-phone-screen-audit-isolated.sh`, `docs/MOBILE_PROTOCOL.md`, and this
RESULT. No images, generated build outputs, or unrelated changes are committed.

## Verification

Final results below are passing; evidence is gitignored under `build/T13b/`.

| Exact command | Result |
| --- | --- |
| `scripts/test-phone-access-isolated.sh` | **39/39 named tests, 3 suites**; revocation additionally has two parameter cases. Production phone services, policy, capture/encoding, AppKit indicator, settings card and search catalog compile unchanged. Permission/capture/indicator/audit effects are injected in tests; unrelated integration types are shimmed. `swift.log`. |
| `scripts/test-phone-screen-audit-isolated.sh` | **35/35 tests, 2 suites** (`ActivityLogStore`, `Activity log settings`). Production Insights/store/models compile unchanged. Tests use real plaintext in-memory SQLite via a system-library shim, with app paths/lifecycle/provider types stubbed. Includes four new durable-audit tests. This is not SQLCipher or actual app disk proof. `audit.log`. |
| `node --test scripts/test-phone-web.mjs` | **45/45**, no failures. Existing browser asset regressions with mocked DOM/network/timers; no live browser run. `web.log`. |
| `go test -race -v ./...` from `helpers/osaurus-ts` | **9/9 top-level tests and 46/46 named subtests**, no race reports. `go.log`. |
| `go vet ./...` from `helpers/osaurus-ts` | Exit 0, no diagnostics. `go-vet.log`. |
| `swiftc -frontend -parse Packages/OsaurusCore/Networking/HTTPHandler.swift Packages/OsaurusCore/Tests/Networking/HTTPAuthGateTests.swift` | Exit 0; syntax only, **not** full HTTP integration typechecking/execution. `parse.log`. |
| `bash -n scripts/test-phone-access-isolated.sh scripts/test-phone-screen-audit-isolated.sh` | Exit 0. |
| `git diff --check` | Exit 0. |

Both isolation scripts invoke `swift test --disable-keychain --disable-sandbox`
with explicit package paths under `build/`, isolated compiler caches/test roots,
empty model roots and `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`. Package-capable and
Go commands used:

```bash
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
```

Initial audit isolation had an incorrect maintenance-handle shim signature;
corrected the shim, not production source (`audit-initial.log`). New search probes
initially found that separate words did not match `screen expiry` / `screen
overlay`; added those full aliases to the canonical catalog and reran successfully
(`swift-search-failure.log`). The intentional SQLite failure diagnostic in the
passing audit log belongs to the injected failure test.

Per CODEX_PREAMBLE, did not retry the known sandbox/Metal/Xcode full build
limitations. No fresh isolated Release app, full `make test` / `make ci-test`,
OsaurusEvals, live Chat/tool turns, real screen capture/TCC, notification grant,
helper embedding or phone network test was performed. No release-ready,
regression-free, model/runtime, or live-UI proof claim is made.

## How to try / pending outside-sandbox proof

1. Commit these changes on this branch once Git metadata writes are available.
   Build a fresh isolated Release app and matching helper through the normal
   `make app` embedding/integrity lane; record the tested SHA/app pin. Run focused
   PhoneScreen/PhoneAccess/SettingsSearch/ActivityLogSettings/ActivityLogStore and
   HTTPAuthGate tests in the real Core harness, then applicable full lanes.
2. Open Server → Overview → Phone access. Enable Phone access and **Allow phone
   to view this Mac's screen**. Check the owner-only caption, expiry date, search
   landing/glow, navigation and relaunch persistence. Verify legacy/expired grants
   are off, successful use extends expiry, and Phone-access-off clears the grant.
3. With existing authorized Tailscale and Screen Recording setup, view Screen
   from the node owner's phone. Verify real JPEGs, pre-frame durable start row,
   periodic metadata, visible overlay/menu bar with windows hidden, nonactivation,
   fullscreen and multiple displays, five-second timeout, first-frame notification
   and notification after >60 seconds idle. Do not grant unrelated OS permissions.
4. Configure an additional allowed login: verify chat still works and screen is
   denied. Exercise missing/forged headers, duplicate headers, rotated helper,
   relay/API-key/Secure Channel denials, and burst requests. Verify durable
   coalesced rejection counts and per-device bounded 429 rows in actual Insights.
5. In the isolated test environment, make Insights unavailable or inject an
   append failure. Verify 503 `audit_unavailable`, no returned pixels, immediate
   session/indicator cleanup, discarded in-flight frames, and recovery only after
   restoring storage/relaunch. Inspect the persisted chain on disk.
6. Complete the ordinary phone Chat/Computer Use workflow and a follow-up in the
   real app. Check tool args/history grounding, permission cards, reasoning and
   tool completion, Stop/input cleanup. Record any required model/default/speed
   and eval evidence separately; none was exercised here.

Read CODEX_PREAMBLE, worktree AGENTS, T13b spec and T13 RESULT in that order.
`~/AGENTS.md` is absent. No subagents, pushes, branch switches, other-worktree
source edits, software installs, logins or live permission grants.

## Evidence SHA-256

- `swift.log`: `3b5de955a411ca505f82c9c1ff007024a69ab1519f309bd99563a0a3eaa2b65a`
- `audit.log`: `30baa7f07c0e0681acac7d959413b5779b261cc590a85847f0f57e79ddb9e210`
- `go.log`: `bdddaeea85f91b27f7c0e9fe6af20cc56dee0e399f7f268a3e08dd7e2487c617`
- `web.log`: `97fe7f271f7885a278619428a2fff889aea0ee48bc8e5ceecbcccfb3f3f9546a`
- `go-vet.log`, `parse.log` (empty): `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
