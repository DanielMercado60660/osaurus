# T13 — See and steer the Mac from the phone

Status: **PARTIAL — implementation and isolated checks complete; commit blocked by sandbox; full app and real phone/runtime proof unverified.**

## Source and commit blocker

- Branch: `task/T13-phone-remote-screen`.
- Base/current HEAD: `4f5f4be8587384e3195480618d2c2d785fcf7f52`.
- The implementation is **uncommitted**, not a tested release SHA. The exact
  22-file source snapshot (excluding this RESULT) is recorded in
  `build/T13/source-manifest.sha256`; manifest SHA-256:
  `325bbe79d148322c1a1df6114afedc9a7ae4ae7531768a627ac3a1dcb1606ce5`.
- Attempted normal `git add -A -- <implementation files>` followed by
  `git -c commit.gpgsign=false commit -m "Add owner-only phone screen preview and Computer Use panel"`.
  Staging failed, so the chained commit did not execute:

  ```text
  fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T13-phone-remote-screen/index.lock': Operation not permitted
  ```

  All changes remain in this worktree, unstaged. There is no approval escalation
  available. No alternate Git metadata/index or permission workaround was used.
  Diagnostic is recorded in `build/T13/commit-failure.txt`. Once normal metadata
  writes are available, stage the implementation and this RESULT, then commit on
  this branch; do not push.
- vMLX pin unchanged in both resolved files:
  `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`. Helper remains Tailscale `v1.94.2`.
- No model bundle, generation defaults, token/s, cache telemetry, RAM footprint,
  or model/eval score was exercised. There are no live passing runtime rows.

## Built

- A separate persisted **Allow phone to view this Mac's screen** switch, off by
  default, in Server → Overview → Phone access. The card reports Screen
  Recording permission and provides **Open Screen Recording Settings**. Both
  controls have exact-title catalog rows, matching landing anchors, self-find
  probes and guide documentation. Permission status refreshes on appearance and
  when the app becomes active. The switch saves immediately.
- `GET /phone/api/screen?display=main&max=1280`: in-memory JPEG at quality 0.6,
  aspect-preserving longest-edge limit (positive `max`, capped at 1280), using
  the existing ScreenshotCaptureService permission/capture path. No artifact or
  screenshot file is created. Responses have no-store/nosniff and no CORS;
  structured JSON explains disabled, permission, trust, invalid query, method,
  rate, cancellation and capture failures. OPTIONS also goes through the screen
  gate instead of generic preflight. Only GET can capture.
- An explicit screen caller predicate requires marker `1`, current launch
  secret, physical loopback and bounded device StableID. Relay, Secure Channel,
  Authorization/API-key callers, ordinary loopback and invalid/missing helper
  credentials fail closed. The helper replaces client device-header values with
  WhoIs StableID, after its existing login/device policy. A stale helper without
  this header cannot fetch screenshots. The app and helper must be rebuilt
  together using the existing embedding/integrity workflow.
- Main-actor per-device rate limiting: at least 500 ms between capture starts,
  one outstanding capture per device, idle table pruning. Captures recheck
  setting revision, helper trust, cancellation and permission before returning
  bytes. An off/on cycle or helper restart during capture cannot revive it.
- Each handled screen request emits metadata through InsightsService into its
  existing tamper-evident activity-log path: verified device StableID (otherwise
  `unverified`), method, path, status, duration, error and byte count. No claimed
  unverified identity, secret or pixels are logged. Existing Insights store
  health/retention semantics remain; live disk-chain persistence is unverified.
- A menu-bar item **Phone is viewing your screen** appears before capture and
  refreshes on a successful frame. It expires about five seconds after the last
  frame and clears immediately when viewing is disabled or Phone access stops.
- Phone **Screen** panel: single-flight polling while active/visible, abort and
  late-frame discard on hidden/pagehide/Chat, blob cleanup, error backoff, tap
  enlargement with scrolling, and browser pinch zoom enabled. API responses are
  not cached by the network-only service worker.
- Agent metadata exposes `computer_use_enabled` from canonical effective Tools
  plus Computer Use capabilities, excluding built-ins. Screen mode filters the
  existing agent picker, explains an empty list and disables send/voice when
  there is no eligible agent. Reload after changing agent settings on the Mac.
- **Ask about this screen** sends unchanged text through the existing
  `/agents/{id}/run` path, displays its streamed answer, and refreshes on
  `osaurus_agent_tool.phase == "completed"` and turn completion. Polling shows
  changes during longer/nested tools. History survives a panel switch when the
  selected agent is unchanged; an agent change still starts a new chat.
- No input injection or approval bypass. The preview is not attached to the
  model: Computer Use retains its existing perception/cloud-consent behavior.
  Keep a Mac chat presenter open for approval cards. This browser flow does not
  add the paired native client's remote approval UI; an unpresentable approval
  retains the existing explicit failure.

## Files

Under `Packages/OsaurusCore/`:

- `Services/PhoneAccess/PhoneScreenPolicy.swift`, `PhoneScreenService.swift` —
  trust/options/rate/timeout/audit logic, service and menu-bar indicator.
- `Services/PhoneAccess/PhoneAccessState.swift`,
  `TailscalePhoneAccessService.swift` — device-header contract and stop cleanup.
- `Services/ScreenshotCaptureService.swift` — ephemeral JPEG preview/encoding.
- `Networking/HTTPHandler.swift`, `PhoneWebAssets.swift` — strict endpoint,
  effective agent metadata, asset registration and blob-image CSP support.
- `Resources/Phone/phone-screen.js`, `phone-app.js`, `phone-index.html`,
  `phone-style.css` — panel, lifecycle and existing chat integration.
- `Views/Settings/PhoneAccessSettingsCard.swift`,
  `Models/Configuration/SettingsSearchIndex.swift`,
  `Tests/Configuration/SettingsSearchSelfFindProbe.swift` — settings/catalog.
- `Tests/PhoneAccess/PhoneScreenTests.swift`, `PhoneAccessTests.swift` — regression
  tests and bundled asset coverage.
- `Resources/Guide/guide-settings.md` — setup and limitations.

Repo-relative: `helpers/osaurus-ts/main.go`, `main_test.go`,
`scripts/test-phone-access-isolated.sh`, `scripts/test-phone-web.mjs`,
`docs/MOBILE_PROTOCOL.md`, and this RESULT.

## Verification

All final checks below passed. Evidence is gitignored under `build/T13/`.

| Exact command | Result and scope |
| --- | --- |
| `scripts/test-phone-access-isolated.sh` | **28/28 named Swift tests, 3 suites**: 12 screen, 9 phone access, 7 settings/search. Revocation has two parameter cases. Production phone services, settings card, policy, capture/encoding and catalog are compiled unchanged. Unrelated app/store/permission types are shimmed; no real capture or status item is invoked. `swift.log`. |
| `node --test scripts/test-phone-web.mjs` | **45/45**, zero failures. Actual JS with mocked DOM/fetch/audio/timers, including existing chat/voice/avatar cases and new screen lifecycle/filter/stream/rate/error/Safari receiver/history cases. `web.log`. |
| `go test -race -v ./...` (cwd `helpers/osaurus-ts`) | **8/8 top-level tests, 41/41 named subtests**, no race reports. Existing trust cases additionally verify replacement of forged/duplicate device headers and hop-by-hop nominations. `go.log`. |
| `go vet ./...` (same cwd) | Exit 0, no diagnostics. `go-vet.log`. |
| `swiftc -frontend -parse` command below | Exit 0; syntax only for HTTPHandler integration, not full-app typechecking. `parse.log`. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-screen.js` | Exit 0. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-app.js` | Exit 0. |
| `bash -n scripts/test-phone-access-isolated.sh` | Exit 0. |
| `git diff --check` | Exit 0. |

Exact Swift syntax command:

```bash
swiftc -frontend -parse \
  Packages/OsaurusCore/Networking/HTTPHandler.swift \
  Packages/OsaurusCore/Networking/PhoneWebAssets.swift \
  Packages/OsaurusCore/Services/PhoneAccess/*.swift \
  Packages/OsaurusCore/Services/ScreenshotCaptureService.swift \
  Packages/OsaurusCore/Views/Settings/PhoneAccessSettingsCard.swift \
  Packages/OsaurusCore/Models/Configuration/SettingsSearchIndex.swift \
  Packages/OsaurusCore/Tests/PhoneAccess/*.swift \
  Packages/OsaurusCore/Tests/Configuration/SettingsSearchSelfFindProbe.swift
```

The isolated script uses `swift test --disable-keychain --disable-sandbox
--package-path "$PWD/build/t04/isolated"`, isolated compiler caches/test roots,
empty model directory and keychain-disabled wrappers. Before package-capable
commands the preamble's environment was set:

```bash
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
```

The first Swift run found Swift Testing's mutating-receiver macro limitation in
limiter assertions. Tests now call a local admission function; the final run
passes. Initial diagnostics are retained in `swift-initial.log`.

### Safari fixture check

Ran `python3 build/T13/preview-server.py` on `127.0.0.1:8765`, serving the real
phone assets/CSP with mock agents, an explicitly labeled SVG desktop fixture and
mock SSE replies. Inspected through native Safari UI: selected Screen, observed
filtering to Mac helper and live preview, tapped enlargement, sent “Close that
dialog”, saw the completed fixture reply/Ready/unlocked input, returned to Chat
and confirmed the preview disappeared. Closed the fixture tab and stopped the
server; port 8765 has no remaining listener. No screenshots were committed.

This caught a real Safari browser-function receiver issue: storing native
`setTimeout`/`clearTimeout`/`fetch` directly as instance methods prevented polling.
Default wrapper functions fixed it; actual Safari then loaded the image. A
regression covers that receiver contract. Final history-preservation/empty-agent
voice refinements were subsequently mock-tested, not re-auditioned in Safari.
This is desktop browser fixture evidence, **not** real capture, JPEG transport,
iPhone pinch/touch, native settings, tailnet authentication or agent execution.

### Unverified lanes

Per CODEX_PREAMBLE, the known sandbox/Metal/Xcode full-build limitations were not
retried. No fresh Release app was produced or launched. Full Core/HTTP pipeline
integration and typechecking, actual ScreenCaptureKit/TCC, menu-bar visibility,
Insights disk-chain verification, helper embedding/signature/WhoIs transport,
settings clicks/save/relaunch, iPhone/iPad rendering/pinch, real approvals and
multi-turn model/tool execution remain **unverified**. No OsaurusEvals,
AgentLoop/AgentLoopFrontier or model scores are claimed. This is not release-ready
or regression-free proof.

## How to try / live checklist (all pending)

1. Resolve the Git metadata-write restriction and commit the current source plus
   this RESULT on this branch. Outside the sandbox, build a fresh isolated
   Release development app using the normal `make app` lane (including its
   rebuilt/hashes-before-compilation helper). Record its source SHA and app pin.
   Run full Core focused PhoneScreen/PhoneAccess/SettingsSearch suites with the
   preamble's credential/keychain protections and empty model root, then all
   applicable regression/eval lanes.
2. With the already-authorized tailnet setup, open Server → Overview → Phone
   access. Enable **Allow phone to view this Mac's screen** and use **Open Screen
   Recording Settings** if permission is missing. A human grants macOS
   permission. Configure a custom agent with Tools and Computer Use enabled.
3. Open the allowed phone URL, reload after agent configuration, select Screen,
   choose the eligible agent and ask it to act. Keep a Mac chat window open for
   approval cards and verify the actual tool/approval/result lifecycle.

- [ ] Fresh preferences are off; neither ordinary loopback (trust on/off), API
  keys (owner/agent), relay nor Secure Channel can fetch pixels. Missing/wrong/
  rotated secret, missing/wrong marker, nonloopback socket and missing/forged
  device identities fail closed. Rebuilt helper supplies genuine WhoIs StableID.
- [ ] Login/device removal, empty restrictions and helper restart revoke existing
  viewing. Off/on or restart during capture does not return stale pixels.
- [ ] Search both labels from another Server tab; scroll/glow, toggle, permission
  link/state, navigate away/back and relaunch. Verify persisted setting changes
  the effective endpoint result. Test missing/revoked TCC and required relaunch.
- [ ] Real JPEG has correct display, dimensions/aspect/quality, no-store/nosniff,
  no CORS and no on-disk artifact. Check typed errors and 500 ms/per-device/
  outstanding-capture rate behavior with two phones and concurrent requests.
- [ ] Mac indicator is visible with chat/settings closed, survives ongoing frames,
  expires around five seconds after viewing stops, and clears on disable/stop.
- [ ] Insights contains each handled fetch with the requesting StableID, status
  and bytes; no screen body/secret. Verify persisted chain/retention and behavior
  when Insights storage is unavailable.
- [ ] iPhone/iPad Safari narrow/landscape, pinch zoom, tap enlargement/scroll,
  keyboard, hidden/background/lock/pagehide/back-forward and Chat return work;
  no polling or stale preview while hidden, no retained blob URLs on teardown.
- [ ] Only effective Computer Use agents appear; empty list explains setup.
  No input endpoint exists. Requests run through the ordinary agent binding and
  approvals; deny/approve/Stop/error paths settle normally. When no presenter
  exists, a gated action fails clearly instead of hanging.
- [ ] Complete a real task and follow-up: tool args/results grounded, no parser
  leaks, reasoning/cards settled, Stop gone/input unlocked, visible screen changes
  during tools and after completion. Exercise cancellation at load/tool/approval.
  Record all model bundles/defaults, token/s, cache telemetry, scores/denominators
  and failed-case attribution required by AGENTS.md. Re-run on final source.

Read preamble, worktree AGENTS, spec, T04/T04b/T07/T11 RESULTs and COMPUTER_USE.
Referenced `~/AGENTS.md` is absent. No subagents, pushes, branch changes,
other-worktree source edits, installs, logins or live permission grants.

## Evidence SHA-256

- `swift.log`: `f00314c1127dcf1dfa9b23da3e151fe701c2753a9b9c71f0268174830d910a1a`
- `web.log`: `344c62e5ca9cb60641c5f12e37710144ae906b73d14094914b86f298e6dbf9ed`
- `go.log`: `92638376e9869614648a6b851a51ef3cf8f20c5c3149d15b2478434d8f12cf13`
- `go-vet.log` and `parse.log` (empty): `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `preview-server.py`: `6f8268c82a4a64e60fc5ec9b0660c2c4c57d42e3b121de0d759d6b8d7c65460c`
- `preview.log`: `e5257f10a2f12db1edb863d3f4a98f62dfc97a1e764d55aec2bac081b195416c`
