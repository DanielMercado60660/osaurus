# T11 — Companion everywhere — RESULT

Status: **PARTIAL — implementation committed; isolated checks and Safari visual
fixture verified. Full Release app, real wake word/audio and iPhone proof remain
UNVERIFIED.** This is not release-readiness evidence.

Branch: `task/T11-companion-everywhere`.
Base SHA: `b9c45070c3a8ba35adc2057d1b1c182343c04a78`.
Tested implementation SHA: `ec6c58bd99e9996e2775dca876ab4f550b9bad4f`.
This RESULT is committed separately; runtime/test sources are unchanged.
vMLX pin remains `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6` in both resolved files.
No model bundle or generation defaults were exercised. No model scores, token/s,
RAM footprint, acoustic latency, or live permission grants are claimed.

## Built

- Plain CSP-safe `phone-avatar.js`, loaded through an explicit `PhoneWebAssets`
  route, with no libraries or inline scripts. Uses the Mac renderer's 160-point
  dinosaur geometry, exact mascot palette, muzzle, belly, tail, plates, blinks,
  breathing, listening ring, thinking dots, speaking mouth and expressions.
  Accessories match T09: blue/red scarf, purple/orange glasses, green/yellow leaf,
  unknown/unset no accessory and blue fallback color.
- A small header companion starts Talk mode. During talk it becomes a large
  centered button with a caption bubble; tapping ends/interrupts the existing talk
  loop. Completion triggers `happy`, errors `oops`, interruption `surprised`.
  Activity/reaction precedence and expiry follow the native policy.
- `/agents` supplies mascot identity and `custom_avatar`; custom images load only
  from the existing same-origin `/agents/{id}/avatar` endpoint and render with a
  level-reactive ring. Stale image loads cannot replace a newly selected agent.
  An unavailable image retains the procedural fallback.
- TTS sources now connect through an output AnalyserNode. RMS drives a clamped,
  attack/release-smoothed mouth. Sentence captions use the scheduled buffer's
  actual AudioContext playback clock, not token arrival or synthesis completion.
  Observations sample every 33 ms; this is not acoustic timing measurement.
  The existing sentence/clause splitter and PCM scheduling remain in use.
  Microphone levels drive the listening ring. Finish/error/interrupt disconnects
  the output meter, clears scheduled captions and cancels its timer.
- Reduced motion freezes breathing, blink, orbit and body deformation, retaining
  a simple level-driven mouth and fixed expressions. Reduced-motion idle has no
  animation loop; hiding the page cancels requestAnimationFrame and the existing
  page lifecycle stops talk/capture. Normal drawing targets 30 fps speaking and
  10 fps otherwise; measured device cadence/CPU is not claimed.
- Pure `WakeWordRoute.resolve` selects companion only when the animated-avatar
  setting and detected agent's talk enablement are both on. AppDelegate takes
  that branch before creating/focusing chat; otherwise existing behavior remains.
- Wake detection already pauses VAD before notification. `startFromWakeWord`
  explicitly transfers wake-listening responsibility to the existing T09
  `withoutWindow` talk path. Duplicate detections do not toggle talk off. Busy or
  unavailable startup returns wake listening through the existing VAD service.
- Fixed stop ordering: VAD previously refused resume while `isStopping` still
  made talk active. Teardown now completes before resume, queued restart retains
  ownership, and a new talk during VAD's settle delay retains the pending resume.
  VAD's existing configuration check still decides whether listening is enabled.
- Updated the bundled guide for both flows. No native setting or label was
  added, removed or renamed; existing catalog entries remain authoritative.

Phone talk retains its T07 half-duplex/tap-interrupt contract. It does not add
voice barge-in or wake-word listening on the phone.

## Files

Under `Packages/OsaurusCore/`:

- `Resources/Phone/phone-avatar.js` — pure presentation state, Canvas renderer,
  image selection, visibility/reduced-motion scheduling.
- `Resources/Phone/phone-app.js`, `phone-voice.js`, `phone-index.html`,
  `phone-style.css` — talk presentation, playback meter/captions, controls/layout.
- `Networking/PhoneWebAssets.swift` — authenticated asset registration.
- `AppDelegate.swift`, `Services/Voice/WakeWordRoute.swift`,
  `Services/Voice/TalkModeController.swift` — routing and resume ownership.
- `Tests/Voice/WakeWordRouteTests.swift`, `Tests/PhoneAccess/PhoneAccessTests.swift`
  — pure policy and asset coverage.
- `Resources/Guide/guide-settings.md` — user instructions.

Repo-relative:

- `scripts/test-phone-web.mjs` — actual JS with mock DOM, canvas, Web Audio/fetch.
- `fork/tasks/T11-companion-everywhere.verify.py` and
  `T11-companion-everywhere.binding-tests.swift` — reproducible isolated Swift
  proof, extending the existing T03/T09 harness with inert VAD/window/capture spies.
- This RESULT.

## Verification

All final commands below exited 0. Local evidence is ignored under `build/T11/`.

| Exact command | Result / scope |
| --- | --- |
| `node --test scripts/test-phone-web.mjs` | **36/36 tests**, 0 failures; `web.log`. Includes the 26 existing regressions plus mood precedence, reaction priority/expiry, level sanitization/smoothing, all mascot/mood/reaction drawing combinations, reduced-motion static rendering, hidden cancellation, stale custom images/ring, audible-clock captions/meter cleanup, companion tap lifecycle, completion/error expressions and output graph failure cleanup. |
| `python3 fork/tasks/T11-companion-everywhere.verify.py` | **76/76 Swift tests in 15 suites**, 0 failures; `isolated.log`. Includes pure route tests, 10 serialized real-controller tests with inert services, plus existing talk/stream/decoder/settings tests. Wake cases cover already-paused VAD, duplicate detection, busy refusal, startup failure, immediate stop, queued restart, normal talk behavior and new talk during resume delay. |
| `scripts/test-phone-access-isolated.sh` | **16/16 Swift tests in 2 suites**, 0 failures; `phone-access.log`. Includes loading the new asset from Bundle.module and existing phone state/settings/catalog checks. Settings tests overlap the T11 lane; counts must not be added as unique coverage. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-avatar.js` | Syntax passes. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-app.js` | Syntax passes. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-voice.js` | Syntax passes. |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-sw.js` | Syntax passes. |
| `git diff --check` | No whitespace errors. |

Syntax-only Swift command (7 files; `parse.log`):

```sh
swiftc -frontend -parse \
  Packages/OsaurusCore/AppDelegate.swift \
  Packages/OsaurusCore/Networking/PhoneWebAssets.swift \
  Packages/OsaurusCore/Services/Voice/TalkModeController.swift \
  Packages/OsaurusCore/Services/Voice/WakeWordRoute.swift \
  Packages/OsaurusCore/Tests/Voice/WakeWordRouteTests.swift \
  Packages/OsaurusCore/Tests/PhoneAccess/PhoneAccessTests.swift \
  fork/tasks/T11-companion-everywhere.binding-tests.swift
```

The T11 helper copies production controller/routing sources unchanged and uses
explicitly inert app seams. Its actual Swift command is:

```sh
swift test --disable-keychain --disable-sandbox --build-system native \
  --package-path "$PWD/build/T11/Proof" \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

The helper sets the preamble's noninteractive Git/empty credential-helper
variables, keychain-disabled mode, isolated test/model roots and compiler caches.
AppDelegate is syntax-checked, not full-app typechecked. No MLX dependency graph
or app linkage is implied by the isolated package.

### Visual check

Ran `python3 build/T11/preview-server.py` on loopback port 8765 and inspected its
local Safari page through computer-use screenshots. The fixture served the real
phone assets with same-origin CSP, mock agent metadata, two 390px frames (header
and talk), and a seven-pose renderer sheet. Visually checked dinosaur proportions,
six colors/three accessories, five moods, three reactions and caption readability.
Clicked the large companion: stage/caption disappeared, header returned and
status became `Stopped.`. A fixture charset issue was corrected; final happy
heart rendered correctly. The source also uses a Unicode escape for that glyph.

This fixture injected a speaking state/level/caption; **it did not exercise live
speech, a microphone, actual TTS synchronization or a native app**. Custom image
rendering, reduced motion and visibility cancellation have mock tests but no
physical iPhone visual proof. Screenshots were viewed in-session, not committed.
The preview tab was closed and server stopped after review.

## How to try / remaining host validation

1. Outside the sandbox, build a fresh isolated Release app at the tested SHA,
   following the existing preamble/keychain precautions. Run full Core focused
   talk/avatar/phone tests and applicable regression/eval lanes.
2. Configure transcription/TTS and an agent. Enable **Conversation → Appearance
   → Show animated avatar**, enable that agent in **Voice → Talk Mode**, and
   enable/configure its wake word. With chat closed, say the wake word; confirm
   companion talk starts without a raised chat window, replies, accepts a
   follow-up, stops cleanly, then detects another wake word.
3. Test all four animated-avatar/talk-enable combinations, readiness/busy errors,
   stop during startup/playback, rapid restart and VAD configuration changes.
   Save/navigate/relaunch to check the effective existing settings and persistence.
4. Open the trusted HTTPS phone URL on iPhone/iPad. Tap its companion, speak,
   confirm listening/thinking/speaking, audible mouth levels and sentence captions,
   then complete a follow-up and tap-interrupt. Select each mascot and a custom
   image; verify Reduce Motion, hidden/background behavior and return-to-page.
5. Exercise the complete real chat/tool lifecycle, settled cards/reasoning/Stop/
   input and follow-up. Record app/pin/model/defaults, token/s, cache telemetry and
   all failures as required by AGENTS.md before making runtime/release claims.

Per CODEX_PREAMBLE, full Core/Release builds were not retried against the known
sandbox/Metal/Xcode limitations. No Release app was produced or launched. Real
wake recognition, mic permissions/audio, phone tailnet/auth transport, actual
settings save/relaunch, measured output latency/CPU, full integrated model/tool
turns, OsaurusEvals/AgentLoop/AgentLoopFrontier remain unverified. No scores are
invented for those missing lanes.

Read preamble, worktree AGENTS, spec and T02/T09/T04/T04b/T07 RESULT files.
Referenced `~/AGENTS.md` is absent. No subagents, push, branch switch, other
worktree source edits, system installs, logins or keychain prompts.

## Local evidence SHA-256

- `build/T11/web.log`: `991b2b7bd468c14ea6faab16ed30511dafddb99b8ee320a8a73f14e02de6509e`
- `build/T11/isolated.log`: `2cabda1b7b1a651e6eb58acf97cf577602d8d12d1453fb44d5b18cffad41c129`
- `build/T11/phone-access.log`: `55b5fd38fecab7b68b3605a73375af1def9f01e53fd0d53021d2a32f87647514`
- `build/T11/parse.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `build/T11/preview-server.py`: `ae7bb087653d077c2f9817f10962cd666cc7964222fe0119e81d8a0ef1e7bba0`
