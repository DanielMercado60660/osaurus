# T01 — Voice plumbing for talk mode (no UI)

Repo: osaurus fork (native Swift macOS app). Paths are relative to
`Packages/OsaurusCore/` unless noted. Read `AGENTS.md` at the repo root first
and follow its conventions.

## Goal

Add the low-level hooks a realtime, barge-in-capable "talk mode" needs. This
task adds **APIs only**; a later task (T03) builds the controller and UI on
top. Existing behavior (speaker button, `speak` tool, auto-speak, VAD wake
word, dictation) must be unchanged.

## Context (verified by survey)

- `Managers/TTSService.swift`: `TTSAudioPipeline` (lines ~40-167) owns an
  `AVAudioEngine` + `AVAudioPlayerNode`; `toggleSpeak` / `startToolPlayback`
  take whole messages and call `stop()` first; `TTSTextChunker.split` (~795)
  splits into sentences; `stop()` (~301) cancels; the only "finished" signal is
  `playingMessageId` returning to nil. Engines: PocketTTS (FluidAudio, 24 kHz)
  and OpenAI-compatible (`OpenAICompatibleTTSClient.synthesizeStreaming`).
- `Managers/SpeechService.swift`: `TranscriptionWorker.runLoop` (~1495-1589)
  polls every 100 ms with Silero `VadManager`; publishes `currentTranscription`,
  `confirmedTranscription`, `isSpeechDetected`, `audioLevel`. A private
  `TranscriptionUpdate` type exists (~1427).
- `Views/Chat/ChatView.swift`: `ChatSession` (~141). `send(_:attachments:directUserSend:)`
  (~6200), `stop(preservesCancelledMarker:)` (~2629), `isStreaming` (~197).
  Text deltas flow through `StreamingDeltaProcessor`
  (`Utils/StreamingDeltaProcessor.swift`, ~131, ~341-348), created at
  `ChatView.swift` ~5177. There is no public delta stream today.

## Deliverables

1. **Incremental TTS stream** on `TTSService`:
   - `beginStream(id: String) -> TTSStreamHandle` (or equivalent), `enqueue(text:)`
     on the handle, `finish()`, `cancel()`. Text may arrive as arbitrary
     deltas; buffer it and release complete sentences to synthesis using the
     existing `TTSTextChunker` rules (and `MarkdownStripper`). Synthesis of
     sentence N+1 should overlap playback of sentence N. Works with both
     engines.
   - Playback lifecycle callbacks/publisher: `firstAudio`, `finished`,
     `cancelled` per stream id, emitted from the actual player-node buffer
     completions, not from synthesis.
   - `cancel()` must silence output within one audio buffer and must be safe
     to call at any phase (before first audio, mid-sentence, after finish).
2. **Output level**: `@Published var outputLevel: Float` (0…1, smoothed RMS,
   ~30 Hz) on `TTSService`, computed from audio actually being played (a tap on
   the pipeline's mixer or per-buffer at schedule time aligned to playback).
   This drives lip sync for an avatar; zero when silent.
3. **STT events**: a public `AsyncStream<SpeechEvent>` (or Combine publisher)
   on `SpeechService` with at least `.speechStarted`, `.speechEnded`,
   `.partial(String)`, `.final(String)`. `.speechStarted` must fire as soon as
   VAD crosses threshold (this is the barge-in trigger), not after
   transcription.
4. **Chat deltas**: a way to observe assistant text deltas for a `ChatSession`
   turn as they stream (e.g. `ChatSession.assistantDeltas: AsyncStream<String>`
   or a subscriber hook on `StreamingDeltaProcessor`), plus a completion signal.
   Visible text only (no reasoning/thinking content, no tool-call JSON).

## Tests

Add focused tests under `Tests/Voice/` (Swift Testing or XCTest, matching
neighbors):
- incremental chunker: deltas split mid-word/mid-sentence release the same
  sentences as `TTSTextChunker.split` on the whole text;
- stream lifecycle ordering (firstAudio → finished; cancel before/after first
  audio → cancelled, no finished) using a fake synthesizer/player seam;
- output level is 0 when idle and > 0 for a non-silent buffer.

Run: `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test
OSU_MODELS_DIR=/tmp/osaurus-test-models make test` (filter to your tests while
iterating with `swift test --package-path Packages/OsaurusCore --filter ...`).
Also make sure `make app` still compiles at the end (or at least
`xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration
Debug -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation build -quiet`).

## Constraints

- Do not add settings or UI in this task.
- Do not change public behavior of existing TTS/STT entry points.
- Keep changes minimal and in the style of surrounding code. No new package
  dependencies.
- Commit on your branch with a clear message when done. Write a short summary
  of the API you added (names + one-line semantics) to
  `fork/tasks/T01-voice-plumbing.RESULT.md`, including test commands run and
  their results (paste pass/fail counts). If something could not be done,
  say so plainly there.
