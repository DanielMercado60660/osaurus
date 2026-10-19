# T18 — Layered talk echo defense — RESULT

Status: **PARTIAL**. Implementation is committed and isolated validation passes.
Full app compilation, Release UI, real ASR/TTS echo scenarios, and Studio Display
acoustic behavior are **UNVERIFIED**. This is not release proof.

Tested implementation source: `ca80285587ae8439e3cae30110815e8edf56062f`.
Base: `5d871fc088d503c3d2e642fc225b563be4891cdf`.
Branch: `task/T18-echo-robustness`.
vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
No model bundle or generation defaults were exercised or changed. No live model
scores, token/s, physical footprint, acoustic latency, or AEC efficacy measured.

## Built

1. **Thresholds with and without AEC.** `TalkEchoPolicy` centralizes listening
   VAD 0.5, playback VAD 0.65 with AEC / 0.75 without, 250 ms elevated-threshold
   cooldown, and 250 / 300 ms sustained interruption qualification. Larger saved
   `bargeInMinSpeechMs` values still win. Cooldown raises the threshold rather
   than ignoring all speech. No new setting or changed setting label/path.
2. **Echo floor and concurrent output.** The speech worker computes linear RMS
   from the captured mono PCM used by VAD. Low-VAD playback frames update the
   EMA floor; accepted speech needs VAD >= threshold and RMS >= 2.5 × floor.
   The duplex mixer supplies raw output RMS separately from the compressed UI
   meter. Low-VAD microphone/output coupling predicts a louder echo floor when
   concurrent output increases. Stale output references are ignored. Floor and
   coupling reset per reply; the floor decays after playback stops. This adaptive
   double-talk estimate is unit-tested, not acoustically calibrated on the owner's
   hardware.
3. **Self-transcript rejection and reversible interruption.** Released chunks
   and actual played-chunk notifications feed a timestamped sentence history.
   Final ASR rejects normalized token substrings or >=0.6 overlap (intersection
   of unique tokens divided by the transcript's unique token count) with any
   sentence in the last 10 seconds. Foundation sentence enumeration preserves
   decimal/abbreviation boundaries. Arrival time is explicit in the reducer.
   `echoRejectedSegments` is visible in the popover and benchmark sidecar.
   Rejected segments lose their speech-duration contribution and cannot send;
   late echo finals preserve newer genuine text.

   Qualifying speech tentatively pauses the player while keeping buffers,
   backpressure, reply epoch, and stream subscriptions alive. Echo, empty/filler
   final ASR, or recognition failure restores the prior reply state and resumes
   playback if appropriate. A genuine final transcript confirms cancellation;
   its replacement send waits for the actual prior chat lifecycle to settle.
   Disable-barge-in, stop, reply failure, first-audio/finish races, old callbacks,
   and duplicate finals are covered. Generation can continue during the tentative
   pause; it is cancelled only after transcript confirmation.
4. **AEC visibility.** The existing gauge popover is available in Release as well
   as Debug and shows `Echo cancellation: On (Apple voice processing)` or
   `Echo cancellation: Off — <reason>`. VPIO failure text survives fallback and
   appears in that reason and the startup notice. `talk.audio` logs AEC decisions,
   selected/default device IDs, input rate/channels, and VPIO errors at `.notice`.
   Route rebuilds retain the user's AEC request, allowing a later eligible route
   to retry voice processing instead of permanently retaining an earlier fallback.
5. **Residual-echo harness.** `OSAURUS_TALK_ECHO_DB=-20` enables mixing the actual
   null sink's rendered 24 kHz TTS PCM into paced 16 kHz input, with an optional
   `OSAURUS_TALK_ECHO_DELAY_MS=30`. Gain accepts finite -60...0 dB; delay accepts
   integer 0...1000 ms and requires ECHO_DB. The bounded delay ring drains already
   emitted echo after pause/cancel; paused queued output is retained, cancelled
   queued output is discarded. Injection continues between user WAVs.

   The launcher runs baseline, real-user barge-in, echo, and echo-plus-barge-in.
   Sidecars report `echoMixedSamples`, `echoRejectedSegments`, `selfBargeIns`
   (confirmed cancellations), `tentativeSelfPauses`, and `echoSegmentsSent`.
   Echo runs require actual injection, zero self-cancellations, zero temporary
   self-pauses, zero echo sends, the expected turn count, and complete existing
   latency telemetry. Both interruption runs require a real observed barge-in.
   A two-second trailing observation period precedes final settlement/reporting.

## Files

Under `Packages/OsaurusCore/`:

- New `Services/Voice/TalkEchoPolicy.swift` and `Tests/Voice/TalkEchoTests.swift`.
- `Services/Voice/TalkModeReducer.swift`: gating, reversible interruption,
  sentence history, rejection telemetry, recovery and duration accounting.
- `Services/Voice/TalkModeController.swift`: released/played text, pause/resume,
  cancellation settlement, status and benchmark reporting.
- `Services/Voice/TalkAudioEngine.swift`: raw render meter, pause/resume, retained
  fallback error, notice logs and requested-AEC route recovery.
- `Managers/SpeechService.swift`: raw render reference registration and mic RMS.
- `Services/Voice/TalkBenchmark{Audio,Configuration}.swift`: PCM mixer, paced
  rendering, pause/resume and options.
- `Tests/Voice/Talk{Mode,Benchmark}Tests.swift`: revised contract and audio checks.
- `Views/Voice/TalkModeSettingsTab.swift`: Release-visible status popover.
- `Resources/Guide/guide-settings.md`: updated behavior descriptions.

Also `docs/VOICE_INPUT.md`, `fork/metrics/{talk_bench,test_talk_bench}.py`, and
`fork/tasks/T03-talk-mode.verify.py`. The proof generator includes the new pure
sources/tests and supplies the existing Smart Turn warm-up API on its inert stub.
Settings catalog IDs, control titles and anchors are unchanged; the catalog's
self-find tests still run in the isolated lane.

## Verification

**108/108 Swift tests, 17 suites, zero failures, exit 0:**

```sh
python3 fork/tasks/T06-talk-latency-harness.verify.py
```

This regenerates the existing isolated package and executes:

```sh
swift test --disable-keychain --disable-sandbox --build-system native \
  --package-path "$PWD/build/t06-harness" \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

The helper disables credential prompting and Keychain access, isolates models
and compiler caches, and clears inherited benchmark options. Production reducer,
controller, duplex engine, extracted speech worker, settings view, config and
stream code compile against explicitly inert app/ASR/provider/MLX stubs. Actual
AVFoundation converters and the paced null sink run against synthetic PCM.
**This is not a full OsaurusCore/app build or real speech-model execution.**

Coverage includes AEC and fallback thresholds/cooldowns, longer saved durations,
EMA gating/decay/reset and concurrent-output behavior, exact/partial/overlap/
unrelated/expired transcripts, sentence boundaries, tentative reversion and
confirmation, failure/stop/config-change races, late joined segments, option
validation, delay/gain/resampling, and null-sink pause/resume/cancel. The delayed
PCM fixture delivers exactly 1,600 nonzero echo samples from 2,400 rendered
24 kHz samples at -20 dB; it does not exercise VAD/ASR inference.

Initial development runs caught Swift Testing mutating-call macro errors and a
Foundation escaping-closure capture error; both were corrected before the final
108-test run. Existing tests asserting immediate 160 ms cancellation and the
old AEC/fallback behavior were updated to assert the requested new contract.
Existing Accelerate and SwiftPM-native-build deprecation warnings remain.

**14/14 Python tests, zero failures, exit 0:**

```sh
python3 -B -m unittest discover -s fork/metrics -p test_talk_bench.py -v
```

Mocked app launch and synthetic telemetry only. Checks require injection evidence
and reject missing counters, false pauses, self-cancellations or echo sends.

**11 Swift files parsed; diff check passed:**

```sh
swiftc -frontend -parse $(git diff --name-only -- '*.swift') \
  Packages/OsaurusCore/Services/Voice/TalkEchoPolicy.swift \
  Packages/OsaurusCore/Tests/Voice/TalkEchoTests.swift
git diff --check
```

This command ran before staging. For the committed source, obtain the same file
list with `git diff-tree --no-commit-id --name-only -r ca80285587ae8439e3cae30110815e8edf56062f`.

## How to try / outstanding host proof

1. Build a fresh isolated Release development app from the tested source. Per
   CODEX_PREAMBLE, known full-app/SwiftPM sandbox restrictions were not retried.
2. On the Mac mini + Studio Display, use the default display microphone/speakers.
   Open Talk Mode's gauge popover, verify actual AEC status and notice logs, and
   speak through several replies without interrupting. Then deliberately barge
   in. Record temporary pauses, rejected segments, echoed sends, visible output,
   complete lifecycle settlement, follow-up turns and acoustic stop latency.
3. Toggle **Echo Cancellation** and **Allow Barge-In**, save/navigate/relaunch,
   and test effective behavior. Test AEC failure, non-default microphone,
   route recovery, cancellation during a tentative pause, slow/failed ASR,
   silence/Smart Turn combinations, and follow-up turns. Verify current provider
   defaults, tools/memory/cache settings and relevant runtime telemetry on the
   actual app; these shared-path integration rows remain unproven here.
4. With cached speech models and a real built app, run all four retained scenarios:

   ```sh
   LABEL=t18 APP_SOURCE_SHA=ca80285587ae8439e3cae30110815e8edf56062f \
     fork/metrics/talk_bench.sh /absolute/path/osaurus.app \
     owner/model-folder /absolute/path/chat-model-bundle
   ```

   Direct file-input runs can set `OSAURUS_TALK_ECHO_DB=-20` and
   `OSAURUS_TALK_ECHO_DELAY_MS=30`. Inspect every raw turn and sidecar. **Zero live
   self-barge-ins / echo sends and preserved real-user barge-in are not established
   by this sandbox run.** The simulated path reports AEC off and does not model
   VPIO itself or room acoustics.
5. Full Core tests, applicable OsaurusEvals/AgentLoop/AgentLoopFrontier, Release
   UI/persistence, physical-device/audio proof and model/cache/RAM/token-rate
   matrices were not run. No external judge was invoked.

Limits: the transcript heuristic can reject intentional repetition of the agent.
The adaptive RMS coupling needs real-room testing for both residual rejection
and quiet-user sensitivity. Harness self-event attribution tracks unmixed user
WAV samples since the preceding send; it cannot distinguish echoed words from
real words during overlapping user/agent speech. Inspect those transcripts and
model output rather than treating the counters alone as acoustic proof.

## Evidence and commit outcome

Local, gitignored evidence under `build/t18-proof/`:

| Artifact | SHA-256 |
| --- | --- |
| `isolated.log` | `5a0dadea26984b400b8ddf068d3c19215676a1c82518e9e4b470ffbe56f328e5` |
| `python.log` | `df91b8768568da289eb4a6693e3d5f33123aff2b9a66f6e0575dd5cbad73dc52` |
| `parse.log` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `source-manifest.txt` | `ff4f1cb5e0f017c461e7383524902daaa63617cbf2c6a8e7e1377cd88916362f` |
| `implementation.patch` | `d8bd53e8e4ab9c5aaae74434eb1e7d7b49051811b174aac4e62dd3da5909ab25` |

The manifest/patch cover all 16 implementation/test/doc files, before this RESULT.
An initial multi-command staging invocation was denied access to the worktree
index lock; ordinary standalone `git add -A` and `git commit` then succeeded.
Implementation commit: `ca80285587ae8439e3cae30110815e8edf56062f`.
This RESULT is a subsequent documentation commit.

Read the preamble, worktree AGENTS, T18 spec and T03/T03b/T16/T17 RESULT files.
The referenced `~/AGENTS.md` was absent. No push, remote/other-worktree change,
installation, login, Keychain prompt, live permission grant or delegated agent.
