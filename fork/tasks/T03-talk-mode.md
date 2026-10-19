# T03 — Realtime talk mode (controller, echo cancellation, UI)

Repo: osaurus fork (native Swift macOS app). Paths are relative to
`Packages/OsaurusCore/` unless noted. Read `AGENTS.md` first.
**Depends on T01** (already merged into this branch): read
`fork/tasks/T01-voice-plumbing.RESULT.md` for the incremental TTS stream,
`TTSService.outputLevel`, `SpeechService` events and chat delta APIs.

## Goal

Hands-free, full-duplex conversation with the current agent: the user just
talks, the agent answers out loud as soon as it has a sentence, and the user
can interrupt it mid-sentence (barge-in). Target: end of user speech → first
agent audio **p50 under 1.2 s** with a small local model on the PocketTTS
engine; barge-in silences playback in **under 150 ms**.

Design reference (owner's prior project, measured p50 929 ms / p90 1572 ms):
Silero VAD gate, echo-raised thresholds during playback, speech-epoch
cancellation across LLM stream + TTS queue + playback, sentence-by-sentence
release of the reply into TTS.

## Behavior

State machine (`TalkModeState`): `off → listening → userSpeaking →
endOfTurn → thinking → speaking → listening …`, with:

- **End of turn**: VAD silence ≥ `endOfTurnSilenceMs` (default 700) after
  ≥ 300 ms of speech, using the T01 final transcript. Empty/whitespace or
  filler-only transcripts ("uh", "um") go back to `listening` without sending.
- **Send**: `ChatSession.send` on the active agent's chat session (create or
  focus a chat window for the current agent like `.vadAgentDetected` does in
  `AppDelegate.handleVADAgentDetected`). Stream assistant deltas into a T01 TTS
  stream so audio starts after the first sentence.
- **Barge-in**: while `thinking` or `speaking`, a T01 `.speechStarted` that
  stays above threshold for ≥ `bargeInMinSpeechMs` (default 160) cancels the TTS
  stream and calls `ChatSession.stop(...)`, then moves to `userSpeaking` and
  keeps the onset audio for the new turn. Use a monotonically increasing speech
  epoch so late callbacks from a cancelled turn are ignored.
- **Echo handling**:
  1. Preferred: real AEC. Mic capture and TTS playback currently run on two
     separate `AVAudioEngine`s (`SpeechService.swift` ~1193, `TTSService.swift`
     ~46); Apple voice processing (`inputNode.setVoiceProcessingEnabled(true)`)
     only cancels output rendered through the same engine. Add a
     `Services/Voice/TalkAudioEngine.swift` duplex engine used only in talk mode
     that both capture and TTS playback attach to (add the injection seam to
     SpeechService/TTS pipeline if T01 didn't). Leave non-talk paths on their
     current engines.
  2. Fallback (setting off, or voice processing fails to start): during playback
     raise the VAD start threshold (e.g. 0.5 → 0.75), require sustained speech
     for barge-in, and ignore speech for 300 ms after playback ends.
- **Coexistence**: pause `VADService` wake-word listening while talk mode is
  on and resume after; do not fight `FloatingInputCard`'s continuous voice
  mode (talk mode supersedes it while active).
- **Latency telemetry**: per turn, log end-of-speech → first token, → first
  audio, and barge-in → silence, via `os.Logger` (subsystem `ai.osaurus`,
  category `talk.mode`), and keep the last 50 turns in memory with a p50/p90
  accessor (used by the debug overlay and by `fork/metrics`).

## Known latency gaps in T01 to fix here

- T01's incremental chunker keeps the last chunk open to preserve
  `TTSTextChunker.split`'s 240-character grouping, so the **first sentence is
  not released until ~240 chars or `finish()`**. Add a low-latency release
  policy for talk mode (option on `beginStream`): release the first complete
  sentence immediately (or first clause ≥ ~40 chars at a comma/semicolon when
  no sentence end arrives within ~500 ms), then group subsequent sentences
  normally. Default (non-talk) behavior unchanged.
- `ChatSession.assistantDeltas` fires at the UI smooth-streaming **reveal
  cadence** (`StreamingDeltaProcessor.onVisibleDelta`). Measure whether the
  pacer adds delay vs raw engine deltas; if it does, add a raw visible-content
  hook before the pacer for talk mode.

## Deliverables

1. `Services/Voice/TalkModeController.swift` (`@MainActor` singleton) with the
   state machine implemented as a **pure reducer** (`(state, event) ->
   (state, [effect])`) plus a thin effect runner, so the logic is unit-testable
   with scripted events and fake clocks.
2. `Services/Voice/TalkAudioEngine.swift` (duplex + voice processing).
3. `Models/Voice/TalkModeConfiguration.swift` + store, following
   `VADConfigurationStore`. Settings: enabled-for-agent, end-of-turn silence,
   barge-in on/off, echo cancellation on/off, show captions. New `VoiceTab`
   case in `Views/Voice/VoiceView.swift`. Follow the AGENTS.md settings-catalog
   checklist exactly.
4. UI: a talk-mode toggle button in the chat composer (near the existing mic
   control in `Views/Chat/FloatingInputCard.swift`) and a global keyboard
   shortcut; a compact state indicator (listening / thinking / speaking) with
   live captions of the user's partial transcript. Expose `TalkModeController.shared.state`
   so the animated avatar (`AvatarStateModel`, task T02) can follow it —
   wire it if T02 is merged, otherwise leave a clearly marked hook. (T02 **is** merged: also replace the `TODO(T01)` in `Services/Avatar/AvatarStateModel.swift` so `DefaultAvatarAudioLevelSource.outputLevel` reads `TTSService.shared.outputLevel`, and make the avatar show `listening` while talk mode is listening.)
5. Docs: a "Talk mode" section in `docs/VOICE_INPUT.md`.

## Tests

- Reducer tests: happy path, empty transcript, barge-in during thinking,
  barge-in during speaking, stale events from a cancelled epoch, echo fallback
  thresholds, toggling off mid-turn.
- Run focused tests + settings self-find probe:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test
  OSU_MODELS_DIR=/tmp/osaurus-test-models swift test --package-path
  Packages/OsaurusCore --filter 'TalkMode|SettingsSearch'`.
- The app must compile: `xcodebuild -workspace osaurus.xcworkspace -scheme
  osaurus -configuration Debug -derivedDataPath build/DerivedData
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build -quiet`.

## Constraints

- No new package dependencies.
- Don't change behavior of dictation, wake word, speaker button, `speak` tool,
  or auto-speak when talk mode is off.
- Commit on your branch. Write `fork/tasks/T03-talk-mode.RESULT.md`: design
  summary, files, how to try it, test commands + counts, what's unverified
  (live audio needs a human or a live run), anything not done.
