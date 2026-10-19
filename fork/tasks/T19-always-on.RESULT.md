# T19 — Always on, always reachable from the phone

Status: **PARTIAL — implementation and isolated verification complete; commit BLOCKED by sandbox; full Release app and live phone/power/login proof unverified.**

## Source and scope

- Branch: `task/T19-always-on`; base SHA: `5d871fc088d503c3d2e642fc225b563be4891cdf`.
- Commit status: **blocked**; changes remain unstaged/uncommitted. The base SHA above is not a tested implementation commit. See the exact error below.
- Tested implementation snapshot: `build/T19/source-manifest.sha256` (excludes this RESULT and generated artifacts).
- Existing vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`; Tailscale dependency remains `v1.94.2`.
- No Release app/model was loaded. App/helper bundle pin, model bundle, generation defaults, token/s, model scores and live runtime evidence are **unverified**, not inferred from unit tests.
- Read CODEX_PREAMBLE, worktree AGENTS, T19 spec and T04/T04b/T13b RESULT files. Referenced `~/AGENTS.md` is absent. No subagents, other-worktree edits, logins, live permission grants, system installations, pushes or remote changes.

## Built

- Renamed the existing Phone access switch to **Keep my AI reachable**, retaining its persisted key, default-off behavior and `server.phoneAccess` search anchor. Existing enabled installations inherit the new always-on behavior. The card displays power/helper status and Start at Login registration errors, including error domain/code and unsigned-development-build guidance.
- `PhoneReachabilityService` observes power-source changes, wake notifications and network path changes. It acquires `kIOPMAssertPreventUserIdleSystemSleep` only with Phone access enabled on AC power; the display can sleep. It releases on battery, unknown power, toggle-off and app termination. Failed assertion creation is visible.
- Login registration uses the existing `LoginItemService`, with serialized off-main ServiceManagement operations and visible results. Effective registration is General Start at Login **OR** Phone access. Disabling Phone access preserves the independent General preference. General settings copy/catalog explain the composition.
- Phone-enabled launches reuse `isSilentLaunch`, suppress the initial window and use menu-bar/accessory activation policy. The existing app launch already starts the local server; its existing server-bound callback starts the helper. No second server startup path was added.
- Wake/network changes and a 30-second maintenance check request a fresh helper status over parent-owned stdin (`health\n`). Go checks tsnet LocalClient status with a five-second deadline and emits `running` only for a Running backend. Missing fresh running status for ten seconds triggers the existing serialized helper stop/restart path and capability rotation. Repeated network changes cannot postpone the deadline; disable/server-stop/restart cancel pending checks. Swift uses a continuous clock so time spent asleep cannot strand a probe. Login-in-progress is exempt to avoid repeatedly interrupting authentication.
- Phone UI has a dedicated **Your Mac is asleep or offline** banner and last-seen timestamp, five-second read/probe timeouts, 30-second idle connectivity checks, and retry delays of 1/2/4/8/16/30 seconds (30-second cap). Returning online/foreground probes immediately. Successful reconnection retries initial read-only setup if needed. It never automatically replays a chat, model edit, audio request or other mutation. HTTP denials/server errors remain distinct from network failure.
- The HTTPS service worker caches only an explicit static UI shell allowlist, allowing an already-installed page to reopen while the Mac is offline. No API response, agent data, chat, screen pixels or audio are cached. Only last-seen time goes into localStorage. Offline shell fallback does not replace HTTP 401/403 responses. First installation requires a successful online visit; HTTP fallback has no offline-worker support.
- Catalog, exact-label search probe, guide and affected Mobile protocol paths updated.

## Files

Under `Packages/OsaurusCore/`:

- `Services/PhoneAccess/PhoneReachabilityPolicy.swift` — pure power/login/status and health-deadline logic.
- `Services/PhoneAccess/PhoneReachabilityService.swift` — IOKit, wake/network and app-lifetime effects.
- `Services/PhoneAccess/TailscalePhoneAccessService.swift` — health probes, timeout/restart and fresh status handling.
- `Services/LoginItemService.swift`, `AppDelegate.swift` — login outcome visibility/composition, silent launch and shutdown.
- `Views/Settings/{PhoneAccessSettingsCard,ConfigurationView}.swift`, `Models/Configuration/SettingsSearchIndex.swift` — controls, descriptions, status and catalog.
- `Resources/Phone/{phone-connection.js,phone-app.js,phone-index.html,phone-sw.js}`, `Networking/PhoneWebAssets.swift` — connection policy/UI, offline shell and asset route.
- `Tests/PhoneAccess/{PhoneReachabilityTests,PhoneAccessTests}.swift`, `Tests/Configuration/SettingsSearchSelfFindProbe.swift` — deterministic coverage.
- `Resources/Guide/guide-settings.md` — behavior, limits and troubleshooting.

Also `helpers/osaurus-ts/{main.go,main_test.go}`, `scripts/test-phone-access-isolated.sh`, `scripts/test-phone-web.mjs`, `docs/MOBILE_PROTOCOL.md`, and this RESULT.

## Verification

Evidence is gitignored under `build/T19/`.

| Exact command | Result |
| --- | --- |
| `scripts/test-phone-access-isolated.sh > build/T19/swift.log 2>&1` | **44/44 named tests, 4 suites**, including 5 new reachability tests, existing Phone access/screen regressions and settings self-findability. Production power/network/login services and settings card compile unchanged; unrelated app integrations are shimmed. No real assertion, login registration, helper launch or power event is exercised. |
| `node --test scripts/test-phone-web.mjs > build/T19/web.log 2>&1` | **67/67 tests**. Includes 9 new connection/offline tests: capped backoff, last-seen data, no mutation replay, HTTP/abort distinctions, timeout/cancellation, idle loss/recovery, stale-probe rejection, UI error text and static-only worker cache. Mock DOM/network/timers; not Safari/PWA live proof. |
| `go test -race -v ./... > ../../build/T19/go.log 2>&1` in `helpers/osaurus-ts` | **10/10 top-level tests, 51/51 named subtests**, no race reports. Includes 5 parent-command cases (health, coalescing, unknown, oversized, EOF). No real tailnet startup/recovery. |
| `go vet ./... > ../../build/T19/go-vet.log 2>&1` in `helpers/osaurus-ts` | Exit 0, no diagnostics. |
| `swiftc -frontend -parse Packages/OsaurusCore/AppDelegate.swift Packages/OsaurusCore/Views/Settings/ConfigurationView.swift > build/T19/parse.log 2>&1` | Exit 0, syntax only for full-app integration files. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-app.js` (also `phone-connection.js`, `phone-sw.js`) | Exit 0 for all three. |
| `bash -n scripts/test-phone-access-isolated.sh` | Exit 0. |
| `git diff --check` | Exit 0. |

Swift isolation uses `swift test --disable-keychain --disable-sandbox`, an empty model directory, isolated test root/module cache, and `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`. Package-capable commands used:

```bash
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
```

Initial Swift compilation caught the SDK's async `SMAppService.unregister()` overload; fixed with `await`. Initial tests exposed Swift Testing's inability to expand mutating struct calls directly in `#expect`; evaluate those calls into named values first. Both failures are preserved in `swift-initial.log` and `swift-test-macro-failure.log`; final runs pass. One syntax-check command was initially launched from the Go directory and could not create its relative log; rerun successfully from the worktree. A read-only `go doc` lookup emitted denied module-cache metadata-write warnings; no package/source changes resulted.

Per CODEX_PREAMBLE, did not retry known full-Core/Metal/Xcode sandbox limitations. **No full `make test`, `make ci-test`, fresh Release app, OsaurusEvals or live UI proof was run.** No agent-loop or model settings implementation changed. Full app compilation, built helper embedding/integrity and all real platform effects remain unverified.

## How to try and required live checklist (all pending)

1. Build a fresh isolated Release app and matching helper outside this sandbox using the normal `make app` lane. Record exact source SHA, final app/helper pins and vMLX pin. Run the focused suites in the actual Core graph and the applicable full lanes.
2. Open **Server → Overview → Phone access over Tailscale → Keep my AI reachable**. Search both the new label and legacy “Phone access”; verify Overview landing/glow. Toggle on, navigate away/back and relaunch. Use the existing authorized Tailscale setup, or have the owner complete login.
3. **AC idle/display sleep:** with the toggle on, inspect `pmset -g assertions` for the Osaurus idle-system-sleep assertion. Let the display/idle timeout expire; open the phone page and complete chat. The display may sleep while the Mac remains reachable.
4. **Explicit sleep/wake on AC:** manually sleep the Mac and open the installed phone page. Expect offline + last seen; an idle-sleep assertion does not override manual sleep. Wake it and verify a fresh health response and automatic page recovery. Stall/kill the helper in the isolated test environment; verify a restart after a missed ten-second probe, fresh capability, no overlapping helper or orphan, and settled chat cancellation/follow-up.
5. **Unplug/replug:** on a MacBook, unplug and confirm assertion release and “Mac will sleep on battery.” Allow battery sleep, verify offline/backoff on the phone, then replug/wake and verify assertion restoration and reconnect. Also verify toggle-off and app quit release the assertion and stop helper exposure. A desktop-only test cannot prove the battery row.
6. **Reboot/login → reachable:** use a signed installed app. Confirm successful registration or the explicit approval/failure message, reboot and sign in (unlock FileVault if applicable). Verify menu-bar-only launch, no initial window, automatic server/helper start and phone chat without manually opening Osaurus. Test unsigned/dev registration failure separately; it must never be presented as successful registration.
7. Change General **Start at Login** on/off while phone access is on. Verify effective registration remains required; turn phone access off and verify the independent preference is restored. Exercise fast toggles, save/relaunch and macOS approval changes. Confirm Hide Dock Icon preference + phone-enabled menu-bar launch behavior.
8. Switch Wi-Fi/Ethernet, disconnect/reconnect network, and repeat wake events. Verify fresh helper status, ten-second timeout, restart serialization, preserved login/device restrictions and uninterrupted authentication when a login URL is pending.
9. In iOS Safari and installed HTTPS PWA, first visit online, then reopen offline. Verify readable banner/last-seen, static-only cache, five-second read timeouts, backoff, return-to-foreground recovery, and initial agent loading after recovery. Verify 401/403/500 messages, no cached private data, no automatic duplicate mutation/chat, and legacy service-worker upgrade. Check HTTP fallback limitations.
10. Complete a real phone Chat turn, Stop during a connection loss, and a follow-up after recovery. Record model bundle, actual generation defaults, token/s, reasoning/tool boundaries and full lifecycle settlement. Any newly exercised tool permission follows AGENTS.md's isolated-agent rule. No such model/tool proof is claimed here.

The “Reachable at …” line describes the helper's reported state and power assertion, not an end-to-end remote reachability guarantee. Login-item registration cannot bypass pre-login encryption, shutdown, lid/manual sleep or OS policy. These limits are documented in the UI/guide.

## Commit

Attempted:

```bash
git add -A
git -c commit.gpgsign=false commit -m "Keep phone access reachable across login, idle sleep and network changes"
```

The shell used `&&`, and staging failed, so the commit command did not execute:

```text
fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T19-always-on/index.lock': Operation not permitted
```

Evidence: `build/T19/commit.log`. This worktree's shared Git metadata is outside
permitted write roots, and escalation is unavailable. No alternate index,
metadata relocation, branch change or permission bypass was attempted. Changes
remain in this worktree. Once normal Git metadata writes are permitted, stage and
commit these files plus this RESULT on `task/T19-always-on`; do not push.


## Evidence SHA-256

- `build/T19/source-manifest.sha256`: `c3237e4154c37712ed69ef05252751cfcf028124d7beb57f28e4901cb8829fad`
- `build/T19/swift.log`: `3f4eff13010e878a4d042656538ffff97d82eed9a7cf51958659e82755222b62`
- `build/T19/web.log`: `407beff64f0d9984ebb4e9c1467a35051c72afeeba2a5c024011198d5de3d64b`
- `build/T19/go.log`: `6c8f507043d225831b46615114c98e8186db2224c21423ea6a53903ba1f4ddd2`
- `build/T19/go-vet.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `build/T19/parse.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `build/T19/commit.log`: `ffd72aeacf17758d8471c73a8947a54a8e6ff93e08f0ae6f59cc33b370d1e36c`
