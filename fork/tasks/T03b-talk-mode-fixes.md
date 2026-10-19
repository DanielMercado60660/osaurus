# T03b — Talk mode live-run fixes

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, the T03 and T06 RESULT files.
A code review of T03 (paths under `Packages/OsaurusCore/`) found the issues
below. Fix them in priority order; add reducer/unit tests for every logic
change. Keep the T06 headless harness working (its input/output seams must
survive the engine rebuild changes).

1. **Route/config changes kill talk mode** (`Services/Voice/TalkAudioEngine.swift`
   ~98-101, handler `Managers/SpeechService.swift` ~1140-1145). Any
   `AVAudioEngineConfigurationChange` (AirPods connect, VPIO sample-rate
   renegotiation at start, another app's VP) calls `routeChanged` → `fail()`.
   Fix: coalesce notifications ~300 ms on the engine queue, rebuild in place
   (re-run configure with the same callbacks, keep player/generation valid),
   only fail if rebuild throws. Ignore notifications that arrive while the
   engine is still running with an unchanged input format.
2. **Device selection order** (`TalkAudioEngine.swift` ~56-64): enable voice
   processing **first**, then set `kAudioOutputUnitProperty_CurrentDevice`, then
   re-read formats. On macOS input/output share one IO unit: if a non-default
   input is selected, keep output on the default output device (aggregate device
   or separate handling); if that can't be done with AEC, disable AEC for that
   session and surface a one-line notice instead of failing.
3. **Per-turn errors end the session** (`TalkModeController.swift` ~235-236,
   ~250; `SpeechService.swift` ~1803-1806): TTS `.failed`, a turn's
   `lastStreamError` (including non-fatal fallbacks like
   `incompleteReasoningFallback`), and a single ASR throw must show a toast,
   cancel that reply and return to listening. Only capture/engine failures stop
   talk mode.
4. **External `TTSService.stop()` cancels the talk stream fatally**: while talk
   mode is active, route the `speak` tool's text into the talk stream (or no-op
   it, since the reply is already spoken) and make speaker buttons/tab switches
   not stop talk playback; treat an external `.cancelled` as end of reply, not a
   failure.
5. **Dropped utterance during ASR latency** (`TalkModeReducer.swift` ~64-69):
   a new-segment `speechStarted` in `.endOfTurn` with a pending/ready transcript
   must carry the text forward (concatenate with the next final) instead of
   discarding it. Cancel a stale preview ASR when the final is queued.
6. **Latency**: start the final ASR speculatively at ~250–300 ms of silence and
   reuse it if speech does not resume before `endOfTurnSilenceMs`; timestamp
   speech end at the true last-voiced frame (not the first sub-threshold chunk)
   so telemetry isn't optimistic.
7. **First-sentence release** (`Services/Voice/TTSStream.swift` ~43, ~66):
   require whitespace/end after `.!?`, skip digit-adjacent periods ("3.5",
   "1.") and common abbreviations ("Dr.", "e.g.", "i.e.", "Mr.", "vs."). The
   markdown-closed gate (~94-103) must not withhold speech for stray `)`, `<`,
   `:)` or `x < 5`: only gate on unclosed code fences/inline code and
   emphasis markers that actually pair within the current sentence.
8. Smaller: a toggle while `isStopping` should queue a restart; an utterance
   over 120 s closes the segment instead of failing; the avatar shows
   talk-mode speaking only for the owning agent's surfaces
   (`AvatarStateModel.swift` ~13); re-read the input format after
   `engine.start()` and convert in the tap using `buffer.format.sampleRate`;
   avoid `queue.sync` from the main actor in `cancelPlayback()` (async with a
   generation bump is fine).

Commit on your branch; write `fork/tasks/T03b-talk-mode-fixes.RESULT.md`
(finding → change → test).
