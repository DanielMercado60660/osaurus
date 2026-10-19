# T03 talk mode — RESULT

Status: **PARTIAL**. Implementation is committed; isolated checks pass. The full
app has **not** been compiled or run in this sandbox. Live audio, settings/UI
persistence, and the requested latency targets remain **UNPROVEN**. This is not
release proof.

Tested implementation source: `682eb79f3cdb21822f9b2c3c1b73fafb159f1b4d`.
Base: `d81269c9c2318885820e22f86fd4669aa9aba0f0`.
vMLX pin: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6` (unchanged).
No model bundle or generation defaults were exercised. Model scores, token/s,
physical footprint, and acoustic p50/p90: **not measured**.

## Built

- Pure `TalkModeReducer` with caller-supplied monotonic times, listening / user
  speaking / end-of-turn / thinking / speaking states, 300 ms minimum speech,
  configurable silence, empty/filler rejection, sustained barge-in, and monotonic
  reply epochs. Segment IDs additionally reject delayed ASR from an older turn.
- `@MainActor TalkModeController.shared` binds the active agent's existing or newly
  created chat window, sends through `ChatSession.send`, cancels the chat and TTS
  together, and stops when the owned window/session/agent changes. Startup and
  teardown are cancellable. Failures surface through an error toast.
- A talk-only `TalkAudioEngine` renders microphone capture and incremental TTS in
  one AVAudioEngine, requests Apple voice processing, and retries without voice
  processing if setup fails. Non-talk engines remain separate. The fallback
  raises VAD probability from 0.5 to 0.75 during playback and applies a 300 ms
  post-playback cooldown. Device changes stop talk mode with an explicit error.
- SpeechService exposes segment-tagged talk events alongside the T01 multicast
  events, using the same VAD/ASR worker. Talk VAD continues while serialized ASR
  runs asynchronously, so slow preview transcription does not block interruption
  detection. Capture keeps onset samples through barge-in. Recorder generation
  checks prevent a late legacy microphone startup from replacing talk capture.
- `TTSStreamReleasePolicy.conversational` emits the first complete sentence
  immediately, or a >=40-character comma/semicolon clause after 500 ms without a
  sentence. Subsequent chunks use the existing grouping. Default `.grouped`
  behavior remains in place. Completed handles no longer stop a reused duplex
  player when deallocated. Talk streams honor the active agent's voice override.
- A content-only hook before display pacing feeds talk TTS; reasoning still uses
  the existing separate channel. The existing paced publisher is unchanged.
- Talk Mode settings: enabled agents, silence, barge-in, echo cancellation, and
  captions. All five controls have catalog rows, exact labels in the self-find
  probe, landing anchors, scroll/glow support, and guide entries. Settings save
  automatically; echo/silence changes stop capture and apply on next start.
- Composer toggle, state/captions, global **Control–Option–Command–T**, and T02
  avatar integration. The avatar reads actual TTS output level and recognizes
  talk listening/speaking. Wake Word is paused and resumed if previously active;
  continuous Chat Voice is suspended. Auto-speak is suppressed for the owned
  session to avoid repeating the streamed reply.
- `ai.osaurus` / `talk.mode` logs and a last-50-turn history with nearest-rank
  p50/p90. A Debug gauge popover shows metrics and copies JSON;
  `fork/metrics/talk_latency.py` summarizes that JSON with measured/missing counts.

Primary new files (under `Packages/OsaurusCore/`):

- `Models/Voice/TalkModeConfiguration.swift`, `TalkModeConfigurationStore.swift`
- `Services/Voice/TalkModeReducer.swift`, `TalkModeController.swift`,
  `TalkAudioEngine.swift`, `TalkModeHotKey.swift`
- `Views/Voice/TalkModeSettingsTab.swift`
- `Tests/Voice/TalkModeTests.swift`, `TalkModeRawDeltaTests.swift`

Integration changes are in SpeechService, TTSService, TTSStream,
StreamingDeltaProcessor, ChatView, FloatingInputCard, VoiceView, VADService,
AvatarStateModel, AppDelegate, the settings catalog/probe, and existing TTS tests.
Documentation: `docs/VOICE_INPUT.md` and `Resources/Guide/guide-settings.md`.
Reproduction helper: `fork/tasks/T03-talk-mode.verify.py`.

## How to try outside the sandbox

1. Build this branch with the normal app build lane. In Voice Setup select a real
   microphone and speech model. Configure Text To Speech; load PocketTTS before
   starting talk mode, or select the OpenAI-compatible engine.
2. In **Voice → Talk Mode**, enable the desired agent. Open its chat and click the
   waveform-circle control beside the microphone, or press **⌃⌥⌘T** globally.
3. Speak a complete question, pause, and check the caption, visible chat turn,
   first-sentence audio, and return to listening. Interrupt both thinking and
   playback. Speak a follow-up, then toggle off during another turn.
4. Exercise each setting, navigate away/back, and relaunch for persistence proof.
   Test AEC on/off, actual AEC fallback, device changes, wake-word pause/resume,
   continuous-voice handoff, window close/session switch, and ordinary voice paths
   after talk mode stops. Inspect complete tool turns and follow-up turns too.
5. In a Debug build, open the gauge popover, copy latency JSON, save it, then run
   `python3 fork/metrics/talk_latency.py /path/to/turns.json`.

Current boundaries: microphone input only; no system-audio talk capture. A single
uninterrupted capture turn longer than two minutes stops with an explicit error
rather than retaining an unbounded utterance. Continuous Chat Voice is not
restarted automatically. Audio route changes require restarting talk mode.

## Verification

Local evidence directory: `build/t03-proof/` (gitignored).

**Isolated proof: 45/45 tests in 9 suites, 0 failures, exit 0.**

```bash
python3 fork/tasks/T03-talk-mode.verify.py --run
```

The helper sets keychain-disabled/test-model/cache isolation and runs exactly:

```bash
swift test --disable-keychain --disable-sandbox --build-system native \
  --package-path "$PWD/build/t03-harness" \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

This copies production reducer, configuration, stream/chunker, AVFoundation duplex
engine, raw-delta processor, settings catalog/search, controller, settings view,
configuration store, and hotkey code. It extracts the production speech worker
and chunker at declaration boundaries. **App/provider dependencies are inert
stubs**, clearly contained in `ProofStubs.swift`; this compiles those components
but does not prove real app integration, capture, ASR, synthesis, or playback.
Tests cover the requested reducer paths plus completion races, policy changes,
clause timeout without another delta, shared-player lifetime, arbitrary chunk
boundaries, legacy TTS cancellation/backpressure, configuration coding, telemetry
retention, and the full settings self-find probe. An initial test exposed
unmatched bold markup in conversational release; it was fixed before the final
45/45 run. Actor-isolation errors found by the worker compilation were also fixed.

**Pacer observation: 1/1 focused test, exit 0.** Using the same cache arguments and
credential environment as above:

```bash
swift test --skip-build --disable-keychain --disable-sandbox --build-system native \
  --package-path build/t03-harness \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --filter TalkModeRawDeltaTests
```

The focused run observed raw content at **0.006 ms**, first paced reveal at
**24.156 ms**, with reasoning excluded. These are one synthetic processor run's
measurements, not live-model latency statistics. The mixed-suite run had much
larger scheduling delay; no production performance claim is inferred from either.

**Syntax and diff checks: pass.**

```bash
swiftc -frontend -parse $(git diff-tree --no-commit-id --name-only \
  -r 682eb79f3cdb21822f9b2c3c1b73fafb159f1b4d | rg '\.swift$')
git diff --check
```

22 Swift files parsed. The metrics helper also passed **5 assertions** checking
50-row retention, p50/p90, missing samples, invalid measurements, and empty input
(`build/t03-proof/metrics-check.log`). It was imported with `importlib.util` in a
`python3 -B` process and checked against 60 synthetic rows numbered 1...60:
last-50 p50=35, p90=55, no first-audio samples; NaN/negative rows were excluded.

**Required integrated lane: BLOCKED, exit 1; 0 tests executed.**

```bash
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
swift test --disable-keychain --package-path Packages/OsaurusCore \
  --filter 'TalkMode|SettingsSearch'
```

SwiftPM manifest sandbox failed: `sandbox-exec: sandbox_apply: Operation not
permitted`. Log: `focused-integrated.log`.

**App Debug and Release: BLOCKED, exit 66 each; no app compilation.**

```bash
xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= build -quiet
xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Release \
  -derivedDataPath build/ReleaseDerivedData -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= build -quiet
```

Both report `'osaurus.xcworkspace' is not a workspace file` in this sandbox.
Logs: `app-debug.log`, `app-release.log`. Per CODEX_PREAMBLE, no prolonged build
workaround or system/toolchain installation was attempted.

## Outstanding proof

- Full OsaurusCore/app compilation and integrated focused tests outside the sandbox.
- Actual microphone/VAD/ASR behavior, same-engine AEC effectiveness and fallback,
  selected-device behavior, PocketTTS/remote synthesis, voice overrides, captions,
  shortcut registration, avatar motion, and all UI settings save/relaunch rows.
- End-to-end multi-turn/tool behavior, cancellation during model loading and every
  talk lifecycle phase, wake-word restoration, and coexistence with ordinary
  dictation, speaker buttons, auto-speak, and the speak tool.
- Real acoustic end-of-speech → first audio p50 <1.2 s and barge-in → silence
  <150 ms. First-audio telemetry uses the first **completed** playback buffer;
  barge-in telemetry measures **confirmed interruption → player-stop return**,
  excluding VAD qualification and output-device buffering. Neither proves an
  acoustic target. No live latency samples were collected.
- Full OsaurusEvals lanes / AgentLoop / AgentLoopFrontier were **not run**; no model
  or judge rows are claimed. No hardware/model family, cache, or RAM qualification.

No push, remote change, other-worktree edit, dependency addition, software install,
login, or live permission grant. The referenced `~/AGENTS.md` was absent. The
working-tree AGENTS.md and task preamble/spec/T01 result were read. Plain
`git commit` succeeded after `git -c ... commit` hit an index-lock sandbox denial.

## Evidence SHA-256

- `isolated.log`: `0f1d14f6a720469f087fc01f9c5faffba1e3ecd38b8c03cf4bdd21ce480560c7`
- `pacer.log`: `5571d428c6e678fd626c0199795f4be28f2c508af330aa723b2458df721456b9`
- `parse.log`: `2093f837afb581309c9668c1d5b2c3cb5d7f12732e75048d9edcff5c6b79b775`
- `metrics-check.log`: `be9e00ffbdb72029a16f6fffb95f81e7725f0dd6e74a6b07c8a865cf8f345c07`
- `focused-integrated.log`: `fb8f3e901a3475f588b30297ab3b3d510b48b1f684d64c12d9b0ad2750b7eae6`
- `app-debug.log`: `c1078b79f37f632d53b3595effe3f1e91baa82c88dad66c812494f46113fd7a8`
- `app-release.log`: `62e4c01ec5e0d290f0713ebdd5359a38a0d4b3a22be82b67cc22df5ab47968c1`
