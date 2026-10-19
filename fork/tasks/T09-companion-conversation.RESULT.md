# T09 — Companion conversation — RESULT

Status: **PARTIAL**. Headless talk entry, presence UI, reactions, idle actions,
accessories, and isolated validation are implemented and committed. **Assistant
playback-synced captions are blocked by the task's audio-code constraint.** Full
Release/UI/audio/performance proof remains unverified. This is not release proof.

Tested implementation SHA: `8fbfad8043ba2fd87391b8f1dcfb88aea19c6b6c`.
Base: `004f71c0d3574b9ca4170dd7f416eff21be2a110`.
Branch: `task/T09-companion-conversation`.
vMLX pin remains `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6` in both resolved files.
No model bundle, generation defaults, token/s, RAM footprint, or acoustic timing
was exercised or measured. No inference/eval scores are claimed.

## Implemented

- Clicking the companion toggles `TalkModeController` for its agent without
  raising chat. Existing focused/agent sessions are reused; otherwise the existing
  `createWindow(showImmediately: false)` path creates and retains a hidden window
  and session. This is hidden-window binding, not a new independent session store.
  The existing shortcut uses this same path while the companion is visible.
- Native dragging stays separate from clicking. Right-click/Control-click offers
  **Open chat**, **Hide companion**, and agent selection. Open chat reveals the
  owned session. Agent selection stops current talk. Hiding stops companion-started
  talk and cancels pending headless restarts. Ordinary chat-started talk retains
  its previous reveal behavior.
- Presence grows from 180×190 to 280×390 points, keeps the lower center anchored,
  clamps to the current screen, and shrinks on stop. Reduce Motion disables resize
  animation. Listening status and user partial transcripts use the existing
  **Show Captions** setting; no setting was added, renamed, or moved.
- Talk-controller presentation events drive timed `happy`, `oops`, and `surprised`
  overlays. Expressions preserve the underlying mouth level and listening state;
  celebration is suppressed over speaking/thinking/error. Barge-in has priority.
- An injected-clock/RNG scheduler starts idle look-around, stretch, and tail-wag
  actions at 20–60 second intervals. Activity cancels the action and resets the
  idle deadline. Idle pupils loosely follow the mouse sampled at the idle rate.
- Mascot colors are retained. Blue/red wear a scarf, purple/orange wear glasses,
  green/yellow have a leaf, and unknown/unset mascots have no accessory. All are
  Canvas drawing commands; no asset or dependency was added.
- Guide instructions now match click-to-talk and the menu. Removed the stale T01
  meter-pending description: the current adapter already reads TTS output level.

## Caption blocker — not delivered as a live feature

The spec requires playback sentence synchronization while saying **“no changes to
 talk-mode audio code beyond a window-less session binding if required.”**
`TTSStreamEvent` currently exposes only first audio, finished, cancelled, and
failed. It supplies no spoken text, sentence index, chunk boundary, or timestamp.
Subsequent synthesis chunks can contain multiple sentences. Raw model deltas can
run ahead of playback and cannot truthfully identify the sentence being heard.

Implemented/tested the pure caption sequencer (stream accumulation, authoritative
playback text, epochs, interruption clearing, expiry) and the fading bubble view.
**The production `.playback` presentation event has no producer, so the assistant
bubble is not populated.** User partial transcripts work through the existing
controller caption. Tests that feed sentence events establish the pure sequencer
contract only; they do not establish real playback synchronization.

Asked whether a read-only playback text event was permitted; no affirmative reply
arrived. `TTSStream.swift`, `TalkAudioEngine.swift`, `TTSService.swift`, and
`SpeechService.swift` were left unchanged. A concrete, **unapplied and untested**
observation patch is at `build/T09/proposed-caption-observation.patch`.
`git apply --check` succeeds against the implementation. It would publish each
chunk's text only after its first existing buffer-completion callback, without
changing synthesis or scheduling, and forward it to the caption sequencer.
Even that supplies **chunk-level** alignment, with first-buffer/callback delay;
exact sentence timing within grouped chunks needs a separately authorized design.
No token-count timing estimate or simulated playback event was introduced.

## Files

Relative to `Packages/OsaurusCore/`:

- `Services/Avatar/AvatarPresentation.swift`: pure reaction/idle/caption policies,
  accessory mapping, frame intervals, presentation event types.
- `Services/Avatar/AvatarStateModel.swift`: scoped talk-event projection, current
  talk-session mood, idle scheduling, gaze and caption state.
- `Services/Avatar/AvatarOverlayWindowService.swift`: click/menu/agent actions,
  presence resizing, headless entry, hide/restart handling.
- `Services/Voice/TalkModeController.swift`: hidden-session binding, shortcut
  routing and presentation observation; capture/synthesis scheduling unchanged.
- `Views/Agent/AnimatedAgentAvatarView.swift`: procedural expressions/accessories.
- `Views/Agent/LiveAgentAvatarView.swift`: presence/transcript/caption presentation.
- `Tests/Avatar/AvatarPresentationTests.swift`: six parameterized/nonparameterized
  test functions covering the pure policies.
- `Resources/Guide/guide-settings.md`: updated companion behavior.

Repo-relative proof support:

- `fork/tasks/T09-companion-conversation.verify.py`: reproducible isolated tests
  and ImageRenderer contact sheet; production files copied without rewriting.
- `fork/tasks/T09-companion-conversation.binding-tests.swift`: four harness-only
  tests of the real controller with inert service/window spies. This file is
  deliberately outside the normal app test target.
- `fork/tasks/T03-talk-mode.verify.py`: copy the new pure presentation types and
  add an inert overlay boundary so the existing T03/T06 lanes keep compiling.

## Verification

Final-source commands, all exit 0:

```sh
python3 fork/tasks/T09-companion-conversation.verify.py
python3 fork/tasks/T06-talk-latency-harness.verify.py
git diff --check
```

- **T09: 88/88 Swift tests in 17 suites, 0 failures.** Includes the existing
  T03/T03b/T06 tests, seven existing avatar tests, six new pure-policy test
  functions, and four headless binding tests. Parameterized invocations are
  reported by Swift Testing inside those function counts.
- **Existing T06 lane: 71/71 tests in 14 suites, 0 failures.** Overlaps the T09
  suite; these counts must not be added as distinct coverage.
- Headless spy tests cover create/reuse, focused session binding, normal explicit
  reveal, busy-session refusal, rapid restart, and dismissal of a queued restart.
  No real window or hardware is opened by those spies.
- Both helpers set `GIT_TERMINAL_PROMPT=0`, an empty credential helper,
  keychain-disabled test mode, isolated test/model roots and compiler caches.
  Actual Swift command for T09 (T06 substitutes `build/t06-harness`):

```sh
swift test --disable-keychain --disable-sandbox --build-system native \
  --package-path "$PWD/build/T09/Proof" \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

- `swiftc -frontend -parse` passed for all **8 changed/new Swift files**, including
  the harness-only binding tests. File names were collected using `git diff
  --name-only` and `git ls-files --others --exclude-standard`, filtered to Swift,
  and passed as subprocess arguments. Log: `build/T09/parse.log`.
- Rendered the production Canvas via `ImageRenderer` and visually inspected
  `build/T09/contact-sheet.png`: five moods, three reactions, four accessory
  choices, three idle poses. Labels are readable and figures fit the sheet.
  This is offscreen rendering, not live panel/accessibility/motion proof.
- Actual avatar/controller/SwiftUI/AppKit sources compile in the isolated package
  against explicitly inert app/provider services. This is not full-app typecheck
  or linkage. The compiler logged preview sandbox diagnostics but returned success;
  the offscreen renderer also exited 0.

## Performance and outstanding proof

The shared interval policy is 0.1 seconds idle/listening/thinking/error and 1/30
second speaking; both the sampler and TimelineView consume it. Tests verify those
intervals. Existing window-visibility observation pauses the timeline and cancels
sampling on occlusion/removal; hiding destroys the hosting view. Reduce Motion
pauses the timeline, suppresses micro-action/gaze rendering, and disables resize
animation. **Actual visible frame cadence and CPU were not measured.** Nominal
interval tests and source inspection are not measured desktop performance proof.

Per CODEX_PREAMBLE, full SwiftPM/app builds were left for host validation rather
than repeating the known sandbox/Metal/Xcode failures. No fresh Release build,
real UI interaction, persistence/relaunch, mic/ASR/TTS, or live follow-up/tool turn
was run. OsaurusEvals/AgentLoop/AgentLoopFrontier were not run. No model/cache/RAM
qualification, live permission grant, or latency claim is made.

Host checklist:

1. Build a fresh isolated Release app at the tested SHA; configure speech input
   and TTS, enable the agent in Voice → Talk Mode, and enable Show animated avatar.
2. With chat closed, click the companion, speak, hear a reply, interrupt, and
   complete a follow-up. Confirm no chat window raises; input/reasoning/tool cards
   fully settle when inspecting the owned session through **Open chat**.
3. Exercise shortcut, drag, right-click/Control-click menu, agent selection, busy
   sessions, hide during startup/thinking/playback, and rapid stop/restart.
4. Toggle Show Captions and Reduce Motion, navigate away/back, relaunch; verify
   preference persistence, transcript visibility, screen-edge position recovery,
   real mouth meter, reaction timing and idle-only micro-actions.
5. Measure visible idle/speaking cadence and CPU, then hidden/occluded behavior.
6. Resolve the caption authorization/design blocker before claiming T09 complete.

Read the preamble, worktree AGENTS, T09 spec and T02/T03/T03b results.
`~/AGENTS.md` was absent. No subagent, push, remote change, other-worktree edit,
software installation, login, or keychain prompt. Implementation commit succeeded;
this report is committed separately so it can name the exact tested source SHA.

## Local evidence SHA-256

- `build/T09/isolated.log`: `cefbd9ba3808cf33ac99abb8ade5d1585b327bec7ffd2cf2391ee263318e3583`
- `build/t06-proof/isolated.log`: `df0af1f70eb31910a30636e05adcaa78d572f5fb6ae7057aab18bca2af1c2b9a`
- `build/T09/contact-sheet.png`: `418f89974cab9335a148d0dfe50261403416d6988004e0306367840173793012`
- `build/T09/render.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `build/T09/parse.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `build/T09/source-sha256.txt`: `a71666d6b206d88ee1d696c27b8449d08188118be99bf005f9c87b9400220668`
- `build/T09/proposed-caption-observation.patch`: `96fcbf649452d313483846db92da305541b7a8ebed7f8d349fef3d1a97eaf2b9`
