# T06 — headless talk latency harness — RESULT

Status: **PARTIAL**. Implementation and isolated checks are complete. The real
app/model end-to-end run and Release/UI proof are **UNVERIFIED**; this is not a
release-readiness or latency-target claim.

Implementation/tested source: `be9f686e277218bfd13d665f01f55517ca160bb1`.
Base: `9b324883f4198e3c3b653f1f4096b6f1834cca73`.
Branch: `task/T06-talk-latency-harness`.
vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
FluidAudio unchanged: 0.14.1, `d302273d49ef4d8914b27f20d342be482e8810f1`.
No actual chat/STT/TTS model bundle was exercised. No model score, token/s,
physical footprint, acoustic latency, or live p50/p90 was measured.

## Built

- `TalkBenchmarkConfiguration.swift`: validated environment parsing and pure
  integer WAV frame/padding arithmetic. All configurations compile the harness;
  `OSAURUS_TALK_INPUT_WAV` is the opt-in boundary. Absent INPUT_WAV leaves the
  ordinary audio path unchanged, including when other benchmark variables exist.
- `TalkBenchmarkAudio.swift`: reads nonempty 16 kHz mono WAV files, at most
  120 seconds each, and supplies 320-sample frames every 20 ms. Leading/trailing
  silence and final-frame padding preserve every input sample. Idle capture
  continues supplying silence while ASR/chat/TTS settle. Decoding is off-main.
- The null sink consumes the **real synthesized 24 kHz PCM** on a serial clock,
  preserving ordered buffer completions, cancellation invalidation, backpressure,
  and smoothed RMS output level. It creates no AVAudioEngine and accesses neither
  microphone nor speakers. Pending callbacks fail on cancellation, output level
  resets to zero, and capture remains alive for the interruption/follow-up.
- `TalkAudioEngine.swift` selects the seam only with INPUT_WAV present.
  `SpeechService.swift` bypasses microphone source/device/permission handling in
  that mode, but uses the existing VAD, ASR, worker, and capture events.
  `AppDelegate.swift` suppresses wake-word startup and competing ASR autoload
  for file-input runs; talk startup loads ASR through the normal service.
- `TalkModeController.swift` waits for TTS readiness, autostarts the selected
  agent in a hidden chat window, feeds the WAV list, waits for real reply and
  chat settlement, and records the existing last-50-turn latency history.
  Explicit file-input mode permits starting an agent without persisting a
  change to its enabled-agent setting. No user-facing settings were added.
- Barge-in targets the second input after the first reply's first completed
  buffer plus the requested delay. The second input has no leading silence.
  If the preceding WAV/trailing padding has not finished, it starts later;
  it never overlaps two input files. A completed/short reply is reported as a
  missed scenario. The report requires actual pending null-sink audio both
  at attempted interruption and at the controller's cancellation, rather than
  inferring playback solely from the `.speaking` state.
- Exhaustion waits for the final reply, writes raw latency JSON and a completion
  sidecar, stops capture/chat/TTS, then terminates the app. Recognition/startup/
  reply timeouts and errors preserve partial history. The launcher also has an
  outer watchdog for a hung app, terminating/killing only its own subprocess.
- `fork/metrics/talk_bench.sh` / `talk_bench.py`: preflight cached speech models,
  create separate isolated roots for baseline and interruption runs, symlink
  the supplied local chat model, generate four fixed questions with `say -o`
  and `afconvert`, launch the actual app binary, and summarize p50/p90 with
  measured/missing counts. No downloads, synthetic chat replies, sampler
  overrides, prompt repairs, or model-family allowlists were added.
- `TalkBenchmarkTests.swift`, `test_talk_bench.py`, and the T06 verify helper
  cover the new seams. T03's existing verify helper was updated to copy the new
  dependencies and keep its inert app stubs compatible.

## Run outside the sandbox

Build a fresh app from this branch using the normal app build lane. Use an
actual macOS login session: the harness hides its chat window and needs no
person/audio hardware, but it is still the native AppKit app.

Before running, download/select **Parakeet TDT v3**, **Silero VAD**, and
**PocketTTS** through the normal Voice setup. The launcher refuses to run when
required cached resources are missing and prints the specific repository,
setting destination, and missing paths. It checks the pinned loader paths:

- `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`
- `~/Library/Application Support/FluidAudio/Models/silero-vad/`
- `~/.cache/fluidaudio/Models/pocket-tts/`

The script checks required model directories and ASR vocabulary presence; it
cannot establish integrity of a partially corrupted cached model. Such failures
remain runtime errors. The ordinary app loaders are retained.

```bash
LABEL=t06-my-build APP_SOURCE_SHA=<actual-app-build-source-sha> \
  fork/metrics/talk_bench.sh \
  /absolute/path/osaurus.app \
  owner/model-folder \
  /absolute/path/to/model-with-config-and-safetensors
```

The script runs a four-question baseline, then a separate two-question barge-in
scenario at 800 ms. App config, logs, WAVs, raw turns, and status sidecars remain
under the unique `osaurus-talk-<label>-*` temporary directory printed to stderr.
The result is printed and saved to `fork/metrics/results/talk-<label>.json`.
The app executable hash, declared app build SHA, checkout SHA/pin, model config,
generation defaults, speech settings, input hashes, and raw rows accompany the
summary. Checkout SHA is explicitly distinct from the supplied app's build SHA.

Exit 0 / `COMPLETE` means all requested software latency samples and the
interruption observation were collected. It does **not** grade ASR/chat answers,
prove acoustic latency, or qualify a model/runtime for release. Missing audio,
failed recognition, an unobserved barge-in, startup errors, or watchdog expiry
produce `PARTIAL` and exit 1. Baseline and interruption results are both retained.
No unsuccessful rows are silently discarded from the raw evidence.

For a custom input run, launch `APP/Contents/MacOS/osaurus` directly with:

| Variable | Meaning/default |
| --- | --- |
| `OSAURUS_TALK_INPUT_WAV` | Required opt-in; 1–50 comma-separated absolute WAV paths; commas in filenames unsupported |
| `OSAURUS_TALK_AUTOSTART` | `default` or an existing agent UUID; omit for manual talk start |
| `OSAURUS_TALK_METRICS_OUT` | Absolute output path; parent directory must exist |
| `OSAURUS_TALK_LEADING_SILENCE_MS` | 500; integer 0–30000 |
| `OSAURUS_TALK_TRAILING_SILENCE_MS` | 1200; integer 0–30000 |
| `OSAURUS_TALK_BARGE_IN_AFTER_MS` | Optional; integer 0–30000; first-to-second input only |
| `OSAURUS_TALK_TIMEOUT_MS` | 180000 per wait; integer 1000–3600000 |

The raw file is the existing latency array, compatible with `talk_latency.py`.
`<metrics-path>.status.json` contains errors and interruption observations.
First audio means **first completed playback buffer**. Barge-in means
**confirmed interruption → synchronous sink-stop return**, excluding the VAD
qualification delay. AEC/device/acoustic buffering is absent in this harness;
no latency target is inferred from the isolated synthetic tests.

## Verification

Local evidence: `build/t06-proof/` (gitignored).

1. **52/52 Swift tests in 10 suites passed**, 0 failures, exit 0:

   ```bash
   python3 fork/tasks/T06-talk-latency-harness.verify.py
   ```

   This creates `build/t06-harness`, copies the actual production components and
   the existing T03 regression tests, and runs:

   ```bash
   swift test --disable-keychain --disable-sandbox --build-system native \
     --package-path "$PWD/build/t06-harness" \
     --cache-path "$PWD/build/swiftpm-cache" \
     --config-path "$PWD/build/swiftpm-config" \
     --security-path "$PWD/build/swiftpm-security" --jobs 4
   ```

   The helper sets keychain-disabled/test-model isolation, worktree compiler
   caches, and `GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
   GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=`. It clears inherited
   benchmark variables. Seven new tests cover inert/valid/invalid env parsing,
   exact frame samples/padding/timing math, paced real WAV decoding and rejection
   of wrong sample rates, ordered null completions, actual RMS, and cancellation.
   The controller/duplex/worker compile against explicitly inert app/provider
   stubs. This is **not full OsaurusCore or live-model proof**.

2. **6/6 Python launcher tests passed**, exit 0:

   ```bash
   python3 -B -m unittest discover -s fork/metrics -p test_talk_bench.py -v
   ```

   Tests use temporary fake cache entries and a mocked subprocess. They verify
   missing-model diagnostics, pinned paths, isolated configuration, missing/error
   artifacts, percentile counts, and rejection of missed barge-in. No model or
   app was run. An initial symlink assertion needed macOS `/var` versus
   `/private/var` normalization; the final run passes. Initial Swift test syntax
   errors were likewise corrected before the reported final run.

3. **Syntax/diff checks passed**, exit 0:

   ```bash
   swiftc -frontend -parse Packages/OsaurusCore/AppDelegate.swift \
     Packages/OsaurusCore/Managers/SpeechService.swift \
     Packages/OsaurusCore/Services/Voice/TalkAudioEngine.swift \
     Packages/OsaurusCore/Services/Voice/TalkModeController.swift \
     Packages/OsaurusCore/Services/Voice/TalkBenchmarkAudio.swift \
     Packages/OsaurusCore/Services/Voice/TalkBenchmarkConfiguration.swift \
     Packages/OsaurusCore/Tests/Voice/TalkBenchmarkTests.swift
   bash -n fork/metrics/talk_bench.sh
   git diff --check
   ```

   Also compiled the source text of both Python metrics files and both verify
   helpers with Python `compile(..., 'exec')`: 4 files, no syntax errors.

4. **Integrated lane BLOCKED**, exit 1, **0 tests executed**:

   ```bash
   export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
   export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
   OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
   OSAURUS_TEST_ROOT="$PWD/build/t06-test" \
   OSU_MODELS_DIR="$PWD/build/t06-test-models" \
   swift test --disable-keychain --package-path Packages/OsaurusCore \
     --filter 'TalkBenchmarkTests|TalkModeTests'
   ```

   SwiftPM manifest failed with `sandbox-exec: sandbox_apply: Operation not
   permitted`. No prolonged workaround was attempted, per CODEX_PREAMBLE.

Full app Debug/Release builds, UI/save/relaunch proof, real synthesis/VAD/ASR,
actual app autostart/termination, real-model baseline/interruption runs, all
OsaurusEvals/AgentLoop lanes, model coherency, token/s, and RAM/cache matrices
were **not run**. Those remain the outside-sandbox handoff. No microphone,
speakers, keychain permissions, or live tool grants were exercised.

Read the requested preamble, AGENTS, T06 spec, T01 result, and T03 result.
The referenced `~/AGENTS.md` is absent. No push, other-worktree edits, remote
changes, system installs, logins, or delegated agents. Implementation commit
succeeded on the requested branch; this RESULT is committed separately.

## Evidence hashes (SHA-256)

- `isolated.log`: `17a6f5605df414aeaac0939dd6673f4bd36d7e3b91da3d22943914416e312709`
- `launcher-tests.log`: `e164671d4e868335dda2ad9b048eb3315791d915fc285d6aceba9ea5d4e1088f`
- `integrated.log`: `d1d9e5917ee3bf2a791f2fbea03e5c40c44237912327ddc1b88c4d11814231c9`
- `parse.log` (empty successful output): `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
