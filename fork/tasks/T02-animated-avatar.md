# T02 — Animated agent avatar (2D, no new dependencies)

Repo: osaurus fork (native Swift macOS app). Paths are relative to
`Packages/OsaurusCore/` unless noted. Read `AGENTS.md` at the repo root first
and follow its conventions (especially the settings-catalog rule).

## Goal

An optional, delightful animated character for the agent that visibly
**idles, listens, thinks and speaks (with lip sync)**. It should feel alive,
cost almost nothing when idle, and work on a 16 GB Mac. A 3D (RealityKit/USDZ)
renderer will come later, so put the state logic behind a renderer seam.

## Context (verified by survey)

- Static avatars today: `Views/Agent/AgentAvatarView.swift` — `enum AgentMascot`
  (:16, colors blue/green/orange/purple/red/yellow with `tint`), `AgentAvatarView`
  (:69) draws gradient circle + custom image / mascot bitmap / monogram.
  Assets: `Resources/Assets.xcassets/osaurus-avatar-{color}.imageset`.
- Agent model: `Models/Agent/Agent.swift` — `avatar: String?` (:278),
  `customAvatarFilename` (:282), `themeId` (:218).
- Floating-panel template: `Services/Voice/TranscriptionOverlayWindowService.swift`
  (:91-120) — borderless non-activating `.floating` NSPanel hosting SwiftUI,
  `canJoinAllSpaces`, movable.
- State sources:
  - Listening: `VADService.shared` (`Services/Voice/VADService.swift:48-49`,
    `state`, `audioLevel`) and `SpeechService.shared` (`isSpeechDetected`,
    `audioLevel`).
  - Thinking: the active `ChatSession.isStreaming` (`Views/Chat/ChatView.swift:197`)
    before the first visible text arrives.
  - Speaking: `TTSService.shared.playingMessageId != nil`. **Another task (T01)
    is adding `TTSService.shared.outputLevel: Float` (0…1)** for lip sync. Do
    not edit `TTSService.swift`; instead read speaking level through a small
    protocol (e.g. `AvatarAudioLevelSource`) with a default adapter that
    returns 0 / uses `playingMessageId` today, and a clearly marked one-line
    TODO where `outputLevel` gets wired once T01 merges.
- In-chat surface: `Views/Chat/ChatEmptyState.swift` (:32 and :370 already
  render `AgentAvatarView`).

## Deliverables

1. `AvatarStateModel` (`@MainActor`, ObservableObject or @Observable): reduces
   the sources above into `enum AvatarMood { idle, listening(level), thinking,
   speaking(level), error }` with smoothing and sensible precedence
   (speaking > listening > thinking > idle). Pure reducer function separated
   from the singletons so it can be unit tested.
2. `Views/Agent/AnimatedAgentAvatarView.swift`: a procedural 2D character drawn
   with SwiftUI `Canvas` + `TimelineView`, tinted by the agent's
   `AgentMascot.tint`. Behaviors: breathing, random natural blinks, eyes that
   track toward the mouse loosely (optional), listening = attentive pose + a
   subtle level-reactive ring, thinking = eyes up / orbiting dots, speaking =
   mouth opening driven by level with a little jaw/squash. Respect
   `accessibilityReduceMotion` (static pose + simple mouth). Throttle to ~30 fps
   while speaking, ~10 fps idle, and stop the timeline when not visible.
   Make it genuinely charming — this is a showcase feature; avoid a generic
   emoji-face look. A renderer protocol (`AvatarRenderer`) lets a future 3D view
   plug in using the same `AvatarMood`.
3. `Services/Avatar/AvatarOverlayWindowService.swift`: floating panel modeled
   on `TranscriptionOverlayWindowService`; draggable, remembers position, can
   be shown/hidden from the app menu or a setting; click opens/focuses the
   agent's chat.
4. Setting: a global "Show animated avatar" toggle (and in-chat use in
   `ChatEmptyState` when enabled, falling back to `AgentAvatarView` when off).
   Follow AGENTS.md's settings-catalog checklist exactly (SettingsSearchIndex
   row, anchor id, `Resources/Guide/guide-settings.md`, self-find probe).
5. A SwiftUI `#Preview` that cycles through every mood so it can be screenshot.

## Tests

Unit tests for the reducer (precedence, smoothing, transitions) under
`Tests/` near similar view-model tests. Run:
`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test
OSU_MODELS_DIR=/tmp/osaurus-test-models swift test --package-path
Packages/OsaurusCore --filter Avatar` plus the settings self-find probe tests.
Make sure the app still compiles (`xcodebuild -workspace osaurus.xcworkspace
-scheme osaurus -configuration Debug -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation build -quiet`).

## Constraints

- No new package dependencies. Do not edit `TTSService.swift`,
  `SpeechService.swift` or `ChatView.swift` beyond read-only use (T01 owns
  them).
- Idle CPU with the panel visible should be negligible; note how you
  measured it.
- Commit on your branch when done. Write `fork/tasks/T02-animated-avatar.RESULT.md`
  with: files added/changed, how to enable it, test commands and results
  (counts), CPU measurement, and anything not done.
