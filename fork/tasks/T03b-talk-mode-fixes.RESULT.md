# T03b — Talk mode live-run fixes — RESULT

Status: **PARTIAL**. Implementation and isolated regression checks are complete
and committed. Full app compilation, Release/UI proof, real ASR/TTS, and live
hardware behavior are **UNVERIFIED**. This is not release proof.

Implementation/tested source: `863b47381aa3bbc4bfa7d334b176d4e57afa2cb5`.
Base: `511578a8677a697d8cb12e8746827988a54e313f`.
Branch: `task/T03b-talk-mode-fixes`.
vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
No model bundle or generation defaults were exercised or changed. Model scores,
token/s, physical footprint, acoustic latency, and live p50/p90 were not measured.

## Finding → change → test

| Finding | Change | Verification / boundary |
| --- | --- | --- |
| Route notifications stopped talk mode | Queue-confined 300 ms debounce; ignore running/unchanged-input notifications; rebuild capture/render graphs with the same callbacks, retain reply generation and pending PCM, reject old graph callbacks, reschedule outstanding buffers. Only rebuild failure emits capture failure. | Route decision tests and actual GCD debounce/cancel test pass. Engine compiles against AVFoundation in the isolated harness. Actual device switching and pending-audio replay remain unverified. |
| Device selection preceded VPIO activation and could redirect output | Enable voice processing before selecting the device. A non-default input uses separate capture/output engines with AEC disabled; output remains on its default device. AEC fallback is reported at startup and on rebuild, and updates the VAD gate. | Default/non-default/unknown-device and AEC preference decision tests pass. CoreAudio selection, AirPods, actual default-speaker routing, and AEC effectiveness need hardware proof. |
| TTS, chat-turn, and ASR errors killed the session | Turn failure cancels the reply and returns to listening, preserving an already-starting barge-in. ASR failures are segment-scoped recoverable events, including preview errors; stale final callbacks cannot revive a failed turn. Toasts report errors. Capture/VAD/engine errors still stop capture. | Reducer tests cover thinking/speaking failures, stale epochs, concurrent onset, preview/final recognition failures, accumulated-segment failure, and a successful next turn. Real providers/toasts remain unverified. |
| External TTS stop/speak competed with talk playback | Speaker toggles, the speak tool, and public TTS stop are inert while talk mode owns audio. Stream replacement has a separate internal stop path. Existing standalone playback is stopped before talk startup. External stream/chat cancellation recovers the turn instead of stopping capture. | Source-traced TTS entrypoints and controller subscriptions; recovery and existing stream cancellation/lifetime tests pass. Real speaker-button, tab-switch, and speak-tool flows remain unverified. |
| A new capture segment discarded pending text | Retain ordered segment IDs and final text until every carried segment resolves. Late finals can complete an earlier segment without replacing the newer one. Cancel stale previews when speculative/final recognition is queued. | Tests cover ready versus pending earlier text, reversed final-delivery order, stale preview suppression, and old-segment failure while newer text is retained. |
| Final ASR waited for the full silence threshold | Start speculative final recognition at 275 ms silence, hold delivery until the configured endpoint, reuse completed or in-flight results, and cancel speculation on renewed speech. ASR calls remain serialized. Speech-end events use the last VAD-positive capture timestamp, rather than the first silent chunk or VAD completion time. | Endpoint and recognition-ledger tests cover both completion orders, resumed speech, duplicate/stale results and failures. Worker source compiles. Capture timestamp wiring was source-reviewed; real VAD timing/latency is unmeasured. |
| First-sentence release split decimals/abbreviations and stalled on ordinary punctuation | Require whitespace/current end after sentence punctuation; skip digit-adjacent periods and common abbreviations. Recognize emphasis delimiters rather than counting arbitrary punctuation. Only inspect the first candidate sentence for its Markdown closure, so a later unfinished construct cannot hold it. Closed code blocks cannot supply a spoken sentence boundary. Preserve legacy grouped-stream policy. | Conversational boundary tests cover Dr./Mr./vs./e.g./i.e., decimals/list periods, punctuation without whitespace, stray parentheses, emoticons, comparisons, multiplication, later open code, and fenced code closure. Existing incremental/Markdown tests pass. |
| Teardown toggles, long utterances, avatar scope, format renegotiation, blocking stop | Queue restart targets through teardown; finalize a 120-second segment and keep capture alive; scope speaking to the owning agent; re-read input format after engine start and convert actual tap-buffer formats to stable mono 16 kHz; enqueue hardware cancellation on the audio queue. | Restart, long-segment, avatar-ownership and real AVAudioConverter tests pass, including 48/44.1/16/24 kHz format changes. Actual lifecycle/UI/audio-thread behavior remains unverified. |

T06 file-input and null-output seams remain intact. The null sink still stops
synchronously and records its existing interruption metric. Hardware cancellation
is asynchronous, so `bargeInToStopMs` remains nil there rather than reporting queue
submission as a completed stop. Recoverable benchmark errors are retained in the
completion status instead of being silently reported as success.

## Files

Under `Packages/OsaurusCore/`:

- `Services/Voice/TalkAudioEngine.swift`: routing, graph rebuild, PCM retention,
  actual-buffer resampling and asynchronous cancellation.
- `Services/Voice/TalkModeReducer.swift`: recoverable events, ordered transcripts,
  endpoint/recognition/restart/route policies and route debounce.
- `Services/Voice/TalkModeController.swift`: recovery, fallback notices, restart,
  benchmark error/telemetry handling.
- `Managers/SpeechService.swift`: speculative ASR, cancellation/delivery tracking,
  segment rollover, capture timestamps and recoverable ASR events.
- `Managers/TTSService.swift`: talk ownership at standalone playback entrypoints.
- `Services/Voice/TTSStream.swift`: conversational sentence/Markdown boundaries.
- `Services/Avatar/AvatarStateModel.swift`: speaking ownership.
- `Tests/Voice/TalkModeTests.swift`: new regression coverage.

Also updated `docs/VOICE_INPUT.md` and the inert T03 proof stubs in
`fork/tasks/T03-talk-mode.verify.py`. No user-facing setting was added, removed,
renamed, or moved; settings catalog entries and labels are unchanged.

## Verification

Evidence is local and gitignored under `build/t03b-proof/`.

**71/71 Swift tests in 14 suites passed, 0 failures, exit 0:**

```bash
python3 fork/tasks/T06-talk-latency-harness.verify.py
```

This regenerates the T03 isolated package and runs it with T06 tests, using:

```bash
swift test --disable-keychain --disable-sandbox --build-system native \
  --package-path "$PWD/build/t06-harness" \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

The helper sets credential prompting off, an empty Git credential helper,
keychain-disabled/test-model isolation and worktree compiler caches. Inherited
benchmark environment variables are cleared. Production components, including
the engine, controller and extracted speech worker, compile against explicitly
inert app/ASR/provider stubs. AVAudioConverter tests use actual AVFoundation;
WAV/null-sink tests use synthetic PCM. No microphone, speakers or real model ran.
The full TTSService and avatar integrations receive syntax/source checks here,
not full-app typechecking or behavioral UI proof.

**6/6 Python launcher tests passed, exit 0:**

```bash
python3 -B -m unittest discover -s fork/metrics -p test_talk_bench.py -v
```

These mock app launch/cache resources and do not run the real app.

**8 changed Swift files parsed; diff check passed, exit 0:**

```bash
swiftc -frontend -parse \
  Packages/OsaurusCore/Managers/SpeechService.swift \
  Packages/OsaurusCore/Managers/TTSService.swift \
  Packages/OsaurusCore/Services/Avatar/AvatarStateModel.swift \
  Packages/OsaurusCore/Services/Voice/TTSStream.swift \
  Packages/OsaurusCore/Services/Voice/TalkAudioEngine.swift \
  Packages/OsaurusCore/Services/Voice/TalkModeController.swift \
  Packages/OsaurusCore/Services/Voice/TalkModeReducer.swift \
  Packages/OsaurusCore/Tests/Voice/TalkModeTests.swift
git diff --check
```

Initial development runs found and corrected a sentence-candidate bug involving
closed code fences. Test-only corrections addressed a Swift Testing key-path
macro compile error, existing final-chunk punctuation normalization, the deliberate
numeric-period exception, and AVAudioConverter's initial filter priming. The
reported 71/71 is the final full isolated run on the committed implementation.

Per `CODEX_PREAMBLE.md`, full SwiftPM/app builds were left for the host instead of
retrying the known sandbox/Metal/Xcode limitations. No full OsaurusCore tests,
Release build, UI/persistence/relaunch matrix, OsaurusEvals, AgentLoop or
AgentLoopFrontier were run. Required integrated release proof remains **PARTIAL**.

## How to try on the host

1. Build a fresh Release development app from the tested source. Configure the
   real ASR and TTS providers, enable an agent in Voice → Talk Mode, and start its
   chat. Complete a spoken turn, a tool turn and a follow-up.
2. Connect/disconnect AirPods during capture and playback; change sample rates;
   select a non-default microphone with a different default speaker. Verify
   continued capture/playback, the fallback notice and effective AEC/VAD policy.
   A rebuild can replay the outstanding portion of a buffer; seamless acoustic
   continuity has not been demonstrated.
3. Trigger a TTS/provider or chat-turn error, then speak again. Exercise ASR
   failures, speech resuming during delayed recognition, and speech resuming
   during the speculative silence interval. Check ordered text and no stale send.
4. Exercise speak-tool calls, speaker buttons and tab changes during a reply;
   rapid off/on during teardown; a >120 s utterance; and two different agents'
   avatar surfaces. Check complete cancellation/finalization and follow-up turns.
5. Run the existing T06 launcher against that actual app and cached models:

   ```bash
   LABEL=t03b APP_SOURCE_SHA=863b47381aa3bbc4bfa7d334b176d4e57afa2cb5 \
     fork/metrics/talk_bench.sh /absolute/path/osaurus.app \
     owner/model-folder /absolute/path/to/model-bundle
   ```

   Both baseline and interruption artifacts are required. This run was not
   performed here; isolated tests do not establish the latency targets.

Read the requested preamble, worktree AGENTS, spec and T03/T06 results.
`~/AGENTS.md` was absent. No push, remote/other-worktree change, system install,
login, keychain prompt, live permission grant, or delegated agent was used.

## Evidence SHA-256

- `isolated.log`: `7abf265c7c0868bb4a18db594dd84dab08d1c8119d160ebe832a72c867ca7ec5`
- `launcher-tests.log`: `8e54226ade53996a9d9140729ad57fe0968550fb7f8aee38bb6b81eccbf2f116`
- `parse.log` (empty successful output): `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
