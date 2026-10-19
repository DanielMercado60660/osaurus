# T17 — Smart Turn v3 end-of-turn detection

Status: **PARTIAL**. Implementation committed; isolated regression tests and
four-WAV feature parity pass. **MLX logits, full app compilation, Release UI,
real download/cancellation, and the talk latency target are UNVERIFIED.**

Implementation/tested source: `93ac28aabed209e9bb607ccc95560df1efb1a392`.
Base: `8356d174d40a50dd5d2a09a33172aa0912ba717f`.
Branch: `task/T17-smart-turn`. This RESULT is a subsequent documentation commit.
vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.

Inspected bundle: `mlx-community/smart-turn-v3` snapshot
`74af1538ebace37b0fcc667a6a8a3d902d73eee0`, converted from
`smart-turn-v3.2-gpu.onnx`, 32,010,016-byte safetensors, SHA-256
`12d072e170f17145340ffcc4318530249faca9704748d16130a325ddb7ac2cd6`.
Threshold comes from its config (0.5). No chat generation defaults were changed
or exercised. No live token/s, model score, physical footprint, acoustic timing,
or end-of-turn p50/p90 is claimed.

## Built

- `Services/Voice/SmartTurn/SmartTurnFeatures.swift`: mono 16 kHz PCM, last eight
  seconds, left zero padding, normalization over the padded window using
  variance + 1e-7, centered reflect STFT, periodic 400-point Hann, hop 160,
  Slaney-normalized 80-bin filters, log10 floor at max minus eight, `(x+4)/4`,
  and last frame dropped. Exact 400-point batched DFT uses Accelerate BLAS.
  Output is mel-major `[80,800]`. No app-singleton dependencies.
- `SmartTurnModel.swift`: MLX Swift float32 forward pass, four Whisper encoder
  layers (384 width, six heads, 1536 FFN), two convolutions, positional embeddings,
  attention pooling and classifier. Validates every consumed tensor's shape and
  dtype; handles the conversion's mixed `inner.` names and Conv1d axis order.
  Exact GELU, layer norm epsilon 1e-5, and final sigmoid match the local MLX Python
  forward implementation. This correspondence is source/typecheck evidence;
  **numerical logit parity has not run**.
- `SmartTurnService.swift`: lazy serial actor loading/inference, cancellable
  acquisition of the existing shared Metal gate, and T12 auxiliary residency
  registration under `smartTurn`. Registration follows the actual cached model
  owner's lifetime, using the existing artifact-byte ×1.25 estimate. This is
  not measured physical footprint. Stop does not pretend to unload the cache.
- `TalkSmartTurnPolicy.swift` and the speech worker: after >=300 ms detected
  speech, launch at 250 ms silence, at most one check in flight, retry at 200 ms
  intervals, commit early at the bundle threshold, reuse completed or in-flight
  speculative ASR. Smart-enabled speculation begins at 250 ms; legacy stays at
  275 ms. VAD and the silence deadline never await semantic inference. Resumed
  speech, stop, ASR failure and segment rollover cancel/invalidate stale checks.
  Inference failure shows a notice and uses silence for the rest of that capture.
- Automatic silence defaults are 900 ms when Smart Turn is available and 700 ms
  otherwise. Explicit saved values, including old 700 ms settings, always win.
  An explicit 700 ms selection from the automatic 900 ms state correctly restarts
  capture. The reducer accepts a committed early endpoint instead of waiting out
  its previous timer before sending.
- **Voice → Talk Mode → Smart end of turn**: effective default On when the model
  exists, Off/unavailable when absent, persisted user opt-out, exact catalog row,
  landing anchor, self-find label and guide. Settings changes restart capture.
  Availability is resolved again at the next Talk start.
- `SmartTurnResources.swift`: reuses HF snapshots in place (including HF_HOME /
  HF_HUB_CACHE), or uses the existing `DirectDownloader` path with progress,
  cancellation and errors. Downloads the pinned config/weights into Osaurus
  `aux-models`, shows **32 MB**, and never deletes or rewrites shared caches.
  Model files stay out of the chat picker. No new package dependencies.
- Turn JSON and T06 summaries include `smartTurnChecks`, last accepted
  `smartTurnProbability`, and `endOfTurnReason` (`smartTurn` / `silence`). Counts
  include cancelled/failed attempts. Joined segments sum checks and retain the
  last available probability; the last segment supplies the endpoint reason.
  Legacy data stays missing. T06 refuses COMPLETE when count/reason telemetry
  is missing, or a semantic endpoint lacks a probability. Its isolated config
  now enables Smart Turn and leaves silence automatic instead of forcing 700 ms.

Other changed files: SpeechService, TalkModeController/Reducer/Configuration,
AuxiliaryModelResidency, TalkModeSettingsTab, SettingsSearchIndex and its probe,
`guide-settings.md`, `docs/VOICE_INPUT.md`, metrics helpers/tests, and the T03
isolated-package generator. New tests: `Tests/Voice/SmartTurnTests.swift`.
Golden tools: `T17-smart-turn.{build-probe.py,golden.py,probe.swift}`.

## Verification

All commands ran inside this worktree. Builds that can fetch use the preamble's
credential suppression and `--disable-keychain`; no packages were fetched for
the standalone probe. Evidence is local/gitignored.

1. **87/87 tests, 16 suites, zero failures**, including eight new Smart Turn
   tests and the existing T03/T03b/T06/T16 regressions:

   ```sh
   python3 fork/tasks/T06-talk-latency-harness.verify.py
   ```

   Production reducer, worker, controller, settings view, config, features,
   resource discovery and download orchestration compile in this lane. App,
   ASR/TTS, MLX service and downloader transport are explicitly inert stubs.
   This is not a full OsaurusCore build. Underlying command:

   ```sh
   swift test --disable-keychain --disable-sandbox --build-system native \
     --package-path "$PWD/build/t06-harness" \
     --cache-path "$PWD/build/swiftpm-cache" --config-path "$PWD/build/swiftpm-config" \
     --security-path "$PWD/build/swiftpm-security" --jobs 4
   ```

2. **13/13 tests, four suites, all 22/22 RAM fixtures**, zero failures:

   ```sh
   scripts/test-talk-memory-isolated.sh > build/T17/memory-regression.log 2>&1
   bash build/T17/run-memory-native.sh > build/T17/memory-native.log 2>&1
   ```

   The first command prepared the existing T12 package. A native-build-system
   rerun supplied the explicit test counts (the default build-system log printed
   only build completion). Exact second command uses the exports in
   `scripts/test-talk-memory-isolated.sh`, then:

   ```sh
   swift test --disable-keychain --disable-sandbox --build-system native \
     --package-path "$PWD/build/T12/isolated" \
     --cache-path "$PWD/build/T12/swiftpm-cache" --config-path "$PWD/build/T12/swiftpm-config" \
     --security-path "$PWD/build/T12/swiftpm-security" --jobs 4
   ```

3. **13/13 Python tests**, zero failures; synthetic records/mocked launch only:

   ```sh
   python3 -B -m unittest discover -s fork/metrics -p test_talk_bench.py -v
   ```

4. **4/4 feature golden comparisons PASS** against actual Transformers
   `WhisperFeatureExtractor(chunk_length=8, do_normalize=True)`, tolerance 0.01:

   ```sh
   python3 fork/tasks/T17-smart-turn.build-probe.py --features-only
   ~/mama-mei-v2/sidecars/.venv/bin/python -I \
     fork/tasks/T17-smart-turn.golden.py --features-only \
     --probe build/T17/features-probe \
     --model ~/.cache/huggingface/hub/models--mlx-community--smart-turn-v3/snapshots/74af1538ebace37b0fcc667a6a8a3d902d73eee0 \
     --fixture-source ~/mama-mei-v2/crates/operator-voice/assets/speech_fixture.wav \
     --workdir build/T17/feature-final
   ```

   | WAV variant | Max absolute feature error | Single extraction time |
   | --- | ---: | ---: |
   | Full speech | 0.0000222921 | 1.547 ms |
   | Cut at 55% | 0.0000166893 | 0.796 ms |
   | Speech + 250 ms silence | 0.0000146627 | 0.727 ms |
   | Repeated speech >8 s (tail truncation) | 0.0000160933 | 0.713 ms |

   Times are single optimized CPU feature calls, **not** live/model latency.
   Generated WAV hashes, raw Swift/reference float arrays and complete results
   are in `build/T17/feature-final/`. Source WAV was read-only. `say`/`afconvert`
   initially returned empty audio under sandbox restrictions; the golden script
   now rejects empty WAVs and supports deterministic existing-WAV fixtures.

5. **Standalone real-MLX probe compile/link PASS**, without dependency stubs:

   ```sh
   python3 fork/tasks/T17-smart-turn.build-probe.py \
     --derived-data <repo>/build/DerivedData
   ```

   It compiles the actual feature/model sources and links existing Release
   MLX/MLXNN/Cmlx objects read-only. That checkout's SHA matches the pinned vMLX
   SHA above. It does not build the app. The actual service, model, feature
   extractor, MetalGate and auxiliary ledger also passed Swift 6 typechecking:

   ```sh
   swiftc -typecheck -swift-version 6 -module-cache-path build/ModuleCache \
     -I <repo>/build/DerivedData/Build/Products/Release \
     -I <repo>/build/DerivedData/SourcePackages/checkouts/vmlx-swift/Source/Cmlx/include \
     -I <repo>/build/DerivedData/SourcePackages/checkouts/swift-numerics/Sources/_NumericsShims/include \
     Packages/OsaurusCore/Services/Voice/SmartTurn/SmartTurnModel.swift \
     Packages/OsaurusCore/Services/Voice/SmartTurn/SmartTurnFeatures.swift \
     Packages/OsaurusCore/Services/Voice/SmartTurn/SmartTurnService.swift \
     Packages/OsaurusCore/Services/ModelRuntime/MetalGate.swift \
     Packages/OsaurusCore/Services/ModelRuntime/AuxiliaryModelResidency.swift \
     build/T17/service-stubs.swift
   ```

   The two stubs supply only existing budget sum/inflation helpers. MLX and actor
   APIs are real. Accelerate emitted CBLAS deprecation warnings; no compile error.

6. **Logit execution BLOCKED: zero logit comparisons.** The actual probe traps
   with `[metal::load_device] No Metal device available`. A CPU-device attempt
   also fails during runtime initialization. Full golden comparison is provided
   with assertions at feature error <0.01, end-to-end logit error <0.02, and
   identical-input forward error <0.002, but these logit bounds are **unverified**.

7. **15 Swift files parsed; six Python files syntax-checked; `git diff --check`
   passed.** Full app build, full SwiftPM graph, UI and Evals were not attempted,
   following CODEX_PREAMBLE's host-build handoff.

## Host completion / how to try

1. Build a fresh isolated Release development app at the implementation SHA.
   Run the full golden comparison using that build's MLX artifacts:

   ```sh
   python3 fork/tasks/T17-smart-turn.build-probe.py --derived-data /path/to/DerivedData
   /path/to/existing/python fork/tasks/T17-smart-turn.golden.py \
     --probe build/T17/smart-turn-probe --model /path/to/smart-turn-snapshot \
     --workdir build/T17/host-golden
   ```

   Default fixtures use four fixed `say` utterances. Alternatively pass
   `--fixture-source /path/to/mono-PCM16.wav` or four `--wav` arguments. The
   existing Python environment needs numpy, transformers, mlx and mlx_audio.
   Script writes JSON, input hashes and feature arrays and exits nonzero on
   mismatch. It never installs packages/downloads models.

2. In Voice → Talk Mode, test Smart end of turn Off/On, search landing,
   save/navigate/relaunch, automatic/custom silence and echo settings. Confirm
   cached-HF reuse and missing-model fallback. On an isolated root/cache, test
   download/progress/cancel/retry without touching shared caches. Exercise failed
   inference, resumed mid-thought speech, short noise, repeated pauses, barge-in,
   rapid stop/start, long utterances, late ASR, tool turns and follow-up settlement.
   Confirm Stop disappears and input unlocks. No live permissions were granted here.
3. Run the actual T06 app benchmark and retain every baseline/interruption row:

   ```sh
   LABEL=t17 APP_SOURCE_SHA=93ac28aabed209e9bb607ccc95560df1efb1a392 \
     fork/metrics/talk_bench.sh /absolute/path/osaurus.app \
     owner/model-folder /absolute/path/to/chat-model-bundle
   ```

   Inspect checks/probability/reason and end-of-turn p50/p90 against T16. **The
   300–400 ms target and avoidance of mid-thought cutoffs are not demonstrated.**
   Include cold load and GPU contention: MetalGate waits can make a check miss
   the deadline; capture still falls back to silence. Explicit older silence
   values remain unchanged, so use the isolated automatic default for comparison.
4. Required full Core/Evals/AgentLoop/AgentLoopFrontier, live settings matrices,
   real ASR/TTS, model coherency, token/s, cache telemetry and physical RAM proof
   remain unrun. No release-ready or regression-free claim is made.

## Evidence SHA-256

| Local artifact | SHA-256 |
| --- | --- |
| `build/t06-proof/isolated.log` | `b2f9dc7be1714c7de05c50343196ca4d2130008eac8395c3d70fcfca978b4dae` |
| `build/T17/memory-native.log` | `386b812304287af9d36a2f1d820273c50cd631c363b9fe76dd833fa6f12cbaac` |
| `build/T17/python.log` | `e0d69fcf383e34119a7a73915f922dbb19df3f48a310f56a172d6ddccc6b9cfb` |
| `build/T17/feature-final/comparison.json` | `b31d4ad1171e755b09fcc720199e746c610869cc8ccc875ce2678f3972fe68a7` |
| `build/T17/probe-build.log` | `f8a75cadac6ba0be343917d50971d5f0cd54235a264b22d8a8a4379e210c7241` |
| `build/T17/service-typecheck.log` | `ebc91cb3bd56561ab59fdde15e5ea178d66f578e840f754503be407d6d4ea8ba` |
| `build/T17/probe-runtime.log` | `a46527c28774595a15727d83e6534fbaa804c5301ab12d6fa1a760b2250da52a` |
| `build/T17/parse.log` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Ordinary `git add -A` and `git commit` succeeded. No push, branch switch,
other-worktree/cache modification, dependency addition, installation, login,
Keychain prompt or delegated agent. Read the requested preamble, AGENTS, spec,
T03/T03b/T06/T12/T16 results and local Rust/MLX references. `~/AGENTS.md` was absent.

## Host verification (Claude, outside the sandbox)

- Full golden on GPU (`build/T17/host-golden/comparison.json`): **PASS**, 4/4
  clips, Swift vs reference logit |diff| ≤ 7.3e-06, features ≤ 2.2e-05.
  Warm inference 4–11 ms; **first call 2155 ms** (Metal pipeline compile).
- Semantics sanity (`say`-generated, Swift probe): "What is the capital of
  France?" p=0.979, "Can you set a timer for ten minutes please." p=0.987,
  "I was thinking that maybe we could" p=0.291, "So the thing about the meeting
  is that um" p=0.345. (The mama-mei `speech_fixture.wav` full clip scores
  0.010 in both Swift and the reference — a property of that fixture.)
- Added `SmartTurnService.warmUp(directory:)`, called detached at talk start
  when Smart Turn is active, so the first end-of-turn check isn't the 2 s cold
  compile.
