# T15 — FluidAudio / PocketTTS v2.1 upgrade

Status: **PARTIAL** — implementation committed and isolated verification passes.
Full OsaurusCore/app compilation, real synthesis/recognition, Release UI proof,
and latency comparison remain blocked/unverified. **No speedup is claimed.**

Implementation/tested source: `92d8694b58e610604919843197d4ec582c0a3e09`.
Base: `902d48f7e` on `task/T15-fluidaudio-upgrade`.
FluidAudio: **0.15.4**, `b9d43724cbdb5a980e441fd54180964e94d470f7`;
previously 0.14.1, `d302273d49ef4d8914b27f20d342be482e8810f1`.
vMLX remains `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
This RESULT is a subsequent documentation-only commit.

## Implemented and traced

Paths below are relative to `Packages/OsaurusCore/` unless stated otherwise.

| Location | Adaptation / trace |
| --- | --- |
| `Package.swift:341` and all three tracked `Package.resolved` files | Exact 0.15.4 pin, matching the owner's requested project version. Newer 0.15.x tags exist; this deliberately uses the specified matching 0.15.4. Only the FluidAudio lock rows changed. The full application dependency graph was not re-resolved; the isolated graph resolved and compiled this exact upstream commit. |
| `Services/Voice/PocketTTSResources.swift:6` | Single English / fp16 / GPU-placement contract, matching FluidAudio defaults. Derives language subdirectory and required artifacts from upstream APIs. Chooses complete shared cache first, then Osaurus-owned cache. |
| `Managers/TTSService.swift:605` | Passes explicit `language`, `precision`, `placement`, and the same cache **base** to downloader and manager. Retains existing progress states and load sentinel; late progress cannot overwrite a finished load. The downloader-returned **language root** feeds residency accounting. |
| `Managers/TTSService.swift:700` | All disk-readiness consumers (startup, speaker button, speak tool) now use the same v2.1 cache selection. |
| `Managers/TTSService.swift:375`, `:454`, `:788` | API `/v1/audio/speech`, incremental Talk, and ordinary playback all use the initialized manager's `synthesizeStreaming`. This manager overload has **no language argument**: it captures the manager's explicit English language internally. No call-site argument invented. |
| `Services/Voice/TTSStream.swift:287` | Remains provider-independent; its synthesis closure is supplied at TTSService:454. No direct FluidAudio API to change. Existing chunking, cancellation, backpressure, playback and voice/temperature choices retained. |
| `Services/Voice/SpeechModelMemory.swift:7`, `:17` | Parakeet v3 `requiredModelsV3` changed from a property to a function. TTS roots now use the loader's v2.1 required set, including constants, excluding optional ANE/state variants. |
| `Managers/SpeechService.swift:774`, `Managers/Model/SpeechModelManager.swift:186` | Existing ASR download/load, per-call decoder state, transcribe and VAD APIs remain compatible. No ASR/VAD settings or placement/precision overrides added. |
| `Managers/CoreMLLoadSentinel.swift:28` and TTSService:611/613 | Existing slot/model/OS crash marker remains around download/initialization; prior crash suppression is preserved. Six sentinel tests, including extracted production automatic speech-load suppression, pass. |
| `Views/Voice/TTSModeSettingsTab.swift:157`, `:179`; `Views/Chat/MakeItYoursCard.swift:71` | Explain v2.1 reuse and one-time migration, preserve Download/Preparing/progress/error flows. T05 already consumes the same TTS readiness/progress state. Removed the old download-size estimate. |
| `fork/metrics/talk_bench.py:23`, `:164` | Same shared/owned selection and v2.1 files, directory checks, no flat/v2 fallback. Result records checkout FluidAudio pin alongside vMLX. |

Guide updates: `Resources/Guide/guide-voice.md` and `guide-settings.md`.
No setting/control was added, moved, renamed, or given a new control title;
only descriptive/status text changed, so existing catalog IDs/anchors remain.
Tests/helper: new `Tests/Voice/PocketTTSResourcesTests.swift`,
`fork/tasks/T15-fluidaudio-upgrade.verify.py`, updated launcher tests and T12's
explicitly inert compatibility stubs.

## Upstream review and migration

Inspected the main checkout's actual 0.14.1 source read-only, and the upstream
`v0.14.1..v0.15.4` diff/log in this worktree. Sources:
[version comparison](https://github.com/FluidInference/FluidAudio/compare/v0.14.1...v0.15.4),
[0.15.4 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.4).
Relevant changes include multilingual PocketTTS (#549), slim language packs
(#624), v2.1 loading (#665), and precision-aware Parakeet filename APIs.
`build/T15/upstream-changes.log` retains the upstream commit list.

The v2.1 English pack requires these **directories**:

- `cond_prefill.mlmodelc`
- `flowlm_step.mlmodelc`
- `flow_decoder_fused.mlmodelc`
- `mimi_decoder.mlmodelc`
- `constants_bin`

A complete `~/.cache/fluidaudio/Models/pocket-tts/v2.1/english/` is reused.
If incomplete or absent, a complete
`~/.cache/osaurus/fluidaudio/Models/pocket-tts/v2.1/english/` is reused;
otherwise Download / Talk to it downloads there once with existing progress UI.
The exact chosen base is also passed to the manager's initialization, avoiding
an accidental second download into a different cache.

**Old flat and v2 packs are not compatible with this loader.** They stay intact;
users explicitly prepare v2.1 through Download or Talk to it. No copying,
renaming, or deletion of another project's model folders occurs in our migration.
The private download destination matters: upstream's downloader deletes an unused
FlowLM precision variant after downloading an incomplete pack. Complete shared
packs take its early-return path. Upstream may still best-effort backfill the
optional `bos_before_voice.bin`, or fetch a missing selected voice into that
shared pack; this is reuse, not a promise of a read-only runtime cache.

Presence checks are not corruption/integrity checks. Empty/corrupt compiled model
contents still fail through the real loader. New download contents and their
size depend on upstream's language-pack repository; no download size guarantee.

Parakeet v2/v3 keep the Application Support FluidAudio directories, split
Preprocessor/Encoder/Decoder/Joint artifacts and vocabulary. V3's default
`.int8` encoder still resolves to `Encoder.mlmodelc`. Silero retains
`silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc`; its VAD sources have no diff
between these releases. ASR internals have upstream bug fixes/additions, so
unchanged call sites/defaults are **not** a measured claim of identical output.

## Verification

Final source checks, all with exit 0 unless noted:

| Command | Result and scope |
| --- | --- |
| `python3 fork/tasks/T15-fluidaudio-upgrade.verify.py` | **13/13 tests, 2 suites**. Real FluidAudio 0.15.4 compiles; production resource/memory adapters and extracted TTS load methods compile against it. Compile-only probes cover unchanged ASR/VAD/transcribe/stream signatures. Seven resource tests plus six sentinel tests. App/residency singleton dependencies are inert; tests do not initialize CoreML or synthesize. |
| `scripts/test-talk-memory-isolated.sh > build/T15/memory-tests.log 2>&1` | **13/13 tests, 4 suites; 22/22 RAM fixtures**. Production policy/residency logic with documented app/provider stubs, not actual RAM measurements or integrated OsaurusEvals. |
| `python3 fork/tasks/T06-talk-latency-harness.verify.py > build/T15/talk-tests.log 2>&1` | **71/71 tests, 14 suites**. Existing Talk/stream/route/benchmark/settings regressions with inert providers; log at `build/t06-proof/isolated.log`. |
| `python3 -B -m unittest discover -s fork/metrics -p test_talk_bench.py -v > build/T15/python-tests.log 2>&1` | **8/8 tests**; mocked launcher and temporary cache fixtures. |
| `swiftc -frontend -parse` on the six changed/new Swift source/test files | PASS; `build/T15/parse.log`. |
| Python `compile` on both changed metrics files and both changed verification helpers; `bash -n fork/metrics/talk_bench.sh`; `git diff --check` | PASS. Three lock rows checked against the resolved 0.15.4 revision. |

The T15 helper's exact Swift command (environment is set in the helper):

```sh
swift test --disable-keychain --disable-sandbox --package-path "$PWD/build/T15/isolated" \
  --cache-path "$PWD/build/swiftpm-cache" --config-path "$PWD/build/swiftpm-config" \
  --security-path "$PWD/build/swiftpm-security" --jobs 4
```

The initial full-history SwiftPM fetch was interrupted (exit 130, no tests).
A mirror of the filtered inspection clone failed because missing historical blobs
could not be served. A shallow, unfiltered tag clone fixed this; SwiftPM resolved
0.15.4 into the worktree and compiled it. To reproduce that cache setup before
running the helper (only needed if the normal public fetch is slow):

```sh
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
mkdir -p build/T15/isolated
git clone --depth 1 --branch v0.15.4 https://github.com/FluidInference/FluidAudio.git build/T15/FluidAudioResolved
swift package --disable-keychain --disable-sandbox --package-path build/T15/isolated \
  config set-mirror --original https://github.com/FluidInference/FluidAudio.git \
  --mirror "file://$PWD/build/T15/FluidAudioResolved"
python3 fork/tasks/T15-fluidaudio-upgrade.verify.py
```

An initial test-target compile exposed missing app members in the **proof stub**;
the helper now extracts the real automatic-load suppression method and refuses
unexpected model loads. Final 13/13 above passed after this correction.

Read-only `require_models(Path.home())` successfully found the owner's existing
Parakeet v3, Silero and shared v2.1 English pack. The owner's manifest reports
version 2.1. This was only a disk-presence check: no models downloaded or loaded.

Required integrated attempts:

```sh
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$PWD/build/T15/test-root" OSU_MODELS_DIR="$PWD/build/T15/test-models"
swift test --disable-keychain --package-path Packages/OsaurusCore \
  --filter 'PocketTTSResourcesTests|CoreMLLoadSentinelTests|TTSStreamTests|TalkMemoryBudgetTests' \
  > build/T15/integrated.log 2>&1
xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Release \
  -derivedDataPath build/T15/ReleaseDerivedData -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build -quiet > build/T15/release-build.log 2>&1
```

Integrated tests: **BLOCKED, exit 1, zero tests** (`sandbox_apply: Operation not permitted`).
Release build: **BLOCKED, exit 66**, workspace rejected before app compilation.
No prolonged full-graph workaround, per CODEX_PREAMBLE.

## Host handoff: before/after and live proof

The specified `fork/metrics/results/talk-fork-qwen35-4b.json` was absent in both
this worktree and the main checkout. `fork/LOG.md` records the old cache-layout
blocker, not usable talk latency samples. The host's
`upstream-24e5121-qwen35-4b.json` is a **chat-only** benchmark, not a talk baseline.

Claude must build fresh isolated Release apps for base `902d48f7e` and implementation
`92d8694b58e610604919843197d4ec582c0a3e09`, preserve both, and run each version's
matching launcher from its source checkout. Substitute the two actual app paths
below; do not label an arbitrary existing app with these SHAs. Use this same
already-present model snapshot for both:

```sh
MODEL_ID=mlx-community/Qwen3.5-4B-4bit
MODEL_DIR=~/.cache/huggingface/hub/models--mlx-community--Qwen3.5-4B-4bit/snapshots/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c

# In the preserved BEFORE source checkout, with its original flat-cache preflight:
LABEL=t15-before APP_SOURCE_SHA=902d48f7e \
  fork/metrics/talk_bench.sh /absolute/path/to/before/osaurus.app "$MODEL_ID" "$MODEL_DIR"

# In this T15 source checkout, with the v2.1 shared/owned-cache preflight:
LABEL=t15-after APP_SOURCE_SHA=92d8694b58e610604919843197d4ec582c0a3e09 \
  fork/metrics/talk_bench.sh /absolute/path/to/after/osaurus.app "$MODEL_ID" "$MODEL_DIR"
```

If the old flat pack is missing, prepare it through the **before** app's normal
Download UI; do not move/delete the owner's v2.1 pack to make the old loader work.
If that baseline cannot be prepared, record it as BLOCKED. Retain both JSONs,
raw baseline and barge-in rows, sidecars/logs, app hashes and source pins. Compare
all rows, measured/missing denominators and first-audio p50/p90; inspect errors
and interruption observation. Check WAV hashes, model snapshot/defaults and
voice (`alba`), temperature (0.7), silence (700 ms) are matched. Repeat matched
runs before inferring performance. The harness uses real synthesis with a paced
null sink; its latency is software timing, not acoustic proof.

Also run integrated Core tests and fresh Release UI proof: cached startup and
relaunch; old-cache migration and progress/error/retry; Voice Preview; ordinary
speaker and auto-speak; per-agent voices; speak tool; T05 Talk to it; multi-turn
Talk and interruption/follow-up; phone `/v1/audio/speech` PCM/WAV and disconnect
cancellation. Exercise related settings through save/navigate/relaunch, inspect
complete turns and residency telemetry, and verify shared optional variants are
preserved. Use an isolated test profile for migration rather than deleting real
caches. Run applicable OsaurusEvals/AgentLoop/AgentLoopFrontier lanes with raw
scores and failed-row attribution outside this sandbox.

**Not verified:** full app graph/build, model download/initialization, audio quality,
ASR output parity, actual UI or persistence, real endpoint synthesis/cancellation,
latency, physical footprint, token/s, or model/cache/eval qualification. No live
model bundle or generation defaults were exercised. No system install, login,
Keychain prompt, push, other-worktree mutation, or delegated agent. Referenced
`~/AGENTS.md` is absent; required repository instructions and prior RESULT files
were read.

## Local evidence hashes

| Artifact | SHA-256 |
| --- | --- |
| `build/T15/isolated.log` | `194c61be4d26ec0de95e833c87a7ab7868bdda77038ab0e401f0c2136e2a2dd5` |
| `build/T15/memory-tests.log` | `13df08676f18fa2fc365a2c1f3e8602df299137bd3b01d6f3c6856b27f594850` |
| `build/t06-proof/isolated.log` | `6961e222c326593fca3d7b9be461614b81d54d45e1aa555e0ef8021a65a41327` |
| `build/T15/python-tests.log` | `01177d17224f471b2c3a556f13fc5f743729a2d3569661f789897aa5575c6b4c` |
| `build/T15/integrated.log` | `722d8904398f1fb73d0ec73a38bb24b12ec35c0416593843df33b2c18bec4d47` |
| `build/T15/release-build.log` | `488f103321be58246f716016b0a484605fd7bfba5c769be1eaf19a95e1cad0dc` |
