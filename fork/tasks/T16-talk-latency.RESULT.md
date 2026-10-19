# T16 — Talk latency stages and thinking preference

Status: **PARTIAL**. Implementation and isolated validation are complete. Full
app compilation, Release UI/persistence proof, and live benchmark measurements
remain **UNVERIFIED**. **Commit BLOCKED by filesystem sandbox**; changes remain
in this worktree on `task/T16-talk-latency`.

Base/source HEAD: `4fe31c59e370c98bc24593c8944c6c64f2b6cdcb`, plus the uncommitted
implementation described below. There is no new implementation SHA to report.
vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
No model bundle or generation defaults were exercised. No live latency, token/s,
model scores, physical footprint, or acoustic results were measured.

## Built

- Turn records expose speech-end-relative `endOfTurnDecidedMs`, `asrFinalMs`,
  `sendIssuedMs`, `firstStreamDeltaMs`, `firstReasoningMs`,
  `firstVisibleTokenMs`, `firstSentenceReleasedMs`, and `firstAudioMs`, plus
  `reasoningDurationMs` and `reasoningDeltaCount`. Existing `firstTokenMs` remains
  a compatibility alias. All stream observation is separate from output routing.
- The Python exporter and T06 summary report p50/p90 and measured/missing counts
  for every field. Invalid/negative/nonfinite samples are excluded; old exports
  retain missing stages. Ordering errors and ASR-before-endpoint counts are
  reported. The benchmark requires all unconditional stages and requires
  reasoning onset only when reasoning deltas occurred. Incomplete rows remain
  PARTIAL. Benchmark config explicitly records the new Off preference.
- **Voice → Talk Mode → Think before speaking**, default Off, persists in
  `talk.json`. Missing keys migrate to Off. Off resolves the active local bundle
  off-main and sets the same `disableThinking` / `enable_thinking` choice as the
  chat composer, only when `isToggleableThinking` is true. On omits reasoning
  overrides and defers to the bundle. Unknown/remote capabilities also omit the
  override. Captions distinguish toggleable, always-reasoning, non-reasoning,
  and unavailable capability; they follow the active talk or last-focused chat.
- The preference travels through both immediate and handshake-delayed sends,
  into `ChatTurnGenerationControls`, its repeated request application, and the
  existing `ChatExecutionContext.currentEnableThinking` binding. Ordinary chat
  and its stored choices are unchanged. Talk snapshots explicitly retain an
  empty options dictionary when necessary, preventing ChatEngine's UI-agent
  fallback from restoring composer reasoning choices. Existing ChatEngine and
  MLXBatchAdapter mapping to template kwargs is reused without edits.
- Setting catalog, landing anchor, exact-label self-find probe, settings guide,
  and voice documentation are updated.

## Speculative ASR finding

Source trace: `SpeechService.startTalkTranscription` creates the worker with a
`TalkSpeechGate`; the worker selects `runTalkLoop`. The loop calls
`TalkFinalizationPolicy.update` on captured silence, starts `.speculative` ASR at
275 ms on the next VAD/capture iteration, and reuses it at the configured endpoint.
ASR remains serialized behind any earlier recognition call. Renewed speech
cancels speculation and invalidates its result.

The path already fired speculation; the missing piece was its completion time.
The recognition ledger now retains the original completion timestamp through
withheld delivery, and capture separately emits the endpoint-decision timestamp.
A completed speculative result can therefore show `asrFinalMs` before
`endOfTurnDecidedMs`. Tests prove the deterministic early, late, cancelled, and
joined-segment cases. **Actual ASR completion before the live endpoint is not
verified** and is not guaranteed for a slow recognizer or queued preview.

Timing semantics: visible token means raw content before display pacing; first
sentence release includes clause timeout and final fragments; first audio means
first completed playback buffer. Reasoning duration sums first-reasoning to
next-visible-content/termination phases, including intervening waits, across
continuations. It is not isolated decoder compute time or acoustic latency.

## Files

Under `Packages/OsaurusCore/`:

- `Managers/SpeechService.swift`
- `Services/Voice/{TalkModeReducer,TalkModeController,TTSStream}.swift`
- `Services/Chat/ChatTurnGenerationControls.swift`, `Views/Chat/ChatView.swift`
- `Models/Voice/TalkModeConfiguration.swift`, `Views/Voice/TalkModeSettingsTab.swift`
- `Models/Configuration/SettingsSearchIndex.swift`
- `Tests/Configuration/SettingsSearchSelfFindProbe.swift`
- New `Tests/Voice/TalkLatencyTests.swift`
- `Resources/Guide/guide-settings.md`

Also `docs/VOICE_INPUT.md`, `fork/metrics/{talk_latency,talk_bench,test_talk_bench}.py`,
and the existing `fork/tasks/T03-talk-mode.verify.py` isolated package generator.

## Verification

**79/79 Swift tests in 15 suites, zero failures, exit 0:**

```bash
python3 fork/tasks/T06-talk-latency-harness.verify.py
```

Includes eight new test functions for thinking resolution/captions, old-config
migration and coding, composer isolation and repeated request application,
speculative completion ordering/cancellation, joined segments, reasoning phases,
legacy telemetry decoding, percentiles, and TTS release observation. Existing
T03/T03b/T06, chunker/TTS, raw-delta and settings-search tests also pass.

The helper uses production sources with inert app/provider stubs, including the
controller, extracted speech worker, settings view and generation-control helper.
It does **not** compile the real ChatSession/ChatEngine or run providers. Exact
underlying command (with keychain/test/cache isolation and disabled credential
prompting supplied by the helper):

```bash
swift test --disable-keychain --disable-sandbox --build-system native \
  --package-path "$PWD/build/t06-harness" \
  --cache-path "$PWD/build/swiftpm-cache" \
  --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

**9/9 Python tests, zero failures, exit 0:**

```bash
python3 -B -m unittest discover -s fork/metrics -p test_talk_bench.py -v
```

Uses synthetic records, fake cached-resource files and a mocked app subprocess.
Checks every summary field, required/missing/conditional stages, retention,
percentiles, invalid samples, valid early/late ASR ordering, legacy records,
interruption requirements, and launcher preflight. No actual app was launched.

**Syntax/diff checks: pass, exit 0; 11 Swift files parsed:**

```bash
swiftc -frontend -parse $(git diff --name-only -- '*.swift') \
  Packages/OsaurusCore/Tests/Voice/TalkLatencyTests.swift
git diff --check
```

Five Python source files also passed `compile(source, filename, 'exec')`:
all three changed metrics files and the T03/T06 verify helpers. An initial new
Swift test failed because `#require` wrapped a mutating ledger call; splitting
that expression corrected it before the final passing runs.

Evidence (gitignored): `build/t16-proof/`.

- `isolated.log`: SHA-256 `1eaa61483c5f0cb3a34e7cfbca165f890559232ca3391925d4c02088802a3715`
- `python.log`: SHA-256 `5e99cc1958c8a6f1c47abb97c439b0e4bc2aa2976a43265bad1095f7a8a98c58`
- `parse.log`: SHA-256 `90dc54bf9554de8d142e9b874bbfea1b249c05a163140188b7d8e0aac04e391f`
- `implementation.patch`: SHA-256 `585c86dd6aac72a9dfa71b694cd2fe56397f4a81490461419c17efe86bd95833`;
  tracked implementation diff before this RESULT file.
- New `TalkLatencyTests.swift`: SHA-256 `f1e171ec274eaa27665ba54a145f831b7a4dddb18368259c233061669d7ff982`;
  separate from the patch because staging failed.

## Host handoff / outstanding proof

1. Stage/commit these changes on this branch, then build a fresh isolated Release
   app. Per CODEX_PREAMBLE, full SwiftPM/app builds were not retried in this sandbox.
2. In Voice → Talk Mode, test Off/On, search landing, save/navigate/relaunch,
   capability captions, model switching, and unchanged composer choices. Confirm
   effective request/template kwargs on toggleable models, always-reasoning and
   non-reasoning models, and bundle-default On behavior. Test delayed startup,
   tool continuations, cancellation, full settlement and a follow-up turn.
3. Run the T06 harness on that actual app and cached models:

   ```bash
   LABEL=t16 APP_SOURCE_SHA=<actual-build-source-sha> \
     fork/metrics/talk_bench.sh /absolute/path/osaurus.app \
     owner/model-folder /absolute/path/to/model-bundle
   ```

   Inspect both baseline and barge-in raw rows, every stage denominator, reasoning
   count/duration, and `asr_before_endpoint`. Compare with the prior benchmark;
   no improvement or <1.2 s target is claimed here.
4. Full OsaurusCore integration, Release UI/persistence, real VAD/ASR/TTS,
   OsaurusEvals/AgentLoop/AgentLoopFrontier, and model/cache/RAM/token-rate matrices
   remain unrun and unproven. No external judge was invoked.

## Commit outcome

Both `git add -A` and `git commit -m "Add talk latency stages and bundle-aware
thinking preference"` failed with:

```
fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T16-talk-latency/index.lock': Operation not permitted
```

The worktree's backing Git metadata lies outside the sandbox's writable roots.
No bypass, other-worktree edit, push, remote change, install, login, keychain
prompt, permission grant, or delegated agent was attempted. The implementation
and this RESULT are left in place as CODEX_PREAMBLE directs on commit failure.
The referenced `~/AGENTS.md` was absent; the worktree instructions, preamble,
T16 spec and T03/T03b/T06 results were read.
