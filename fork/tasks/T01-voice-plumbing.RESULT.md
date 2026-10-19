# T01 voice plumbing — RESULT

Status: **PARTIAL** — APIs implemented and the full core/test target compiles.
Focused integrated tests pass (26/26); the full suite stalls in an existing
Computer Use test, and app/live proof remains blocked. No release-readiness claim.

## APIs

- `TTSService.beginStream(id:) -> TTSStreamHandle`: supersedes current playback,
  snapshots the configured PocketTTS/OpenAI-compatible provider, and accepts
  arbitrary text deltas through `enqueue(text:)`. `finish()` closes input and
  drains playback; `cancel()` invalidates callbacks and stops the player.
- `TTSStreamHandle.events`: main-actor Combine publisher of `firstAudio(id:)`,
  `finished(id:)`, `cancelled(id:)`, and `failed(id:message:)`. Playback events use
  `.dataPlayedBack` completions. Empty input finishes without `firstAudio`;
  terminal handles ignore subsequent calls. Subscribe before enqueueing.
- `TTSService.outputLevel`: published, smoothed mixer RMS in 0...1, targeting
  30 Hz, reset to zero on silence/termination. This reads rendered audio.
- `SpeechService.events`: multicast `SpeechEvent` publisher with `speechStarted`,
  `speechEnded`, `partial(String)`, and segment-level `final(String)`. Activity
  edges use the existing VAD update emitted before transcription; stopping an
  active detection also produces the falling edge.
- `ChatSession.assistantDeltas`: internal session publisher of visible
  `delta(turnId:text:)`, `finished`, and `cancelled`. Completion covers the whole
  send including tool continuations; `finished` means settled, not a success
  verdict. `StreamingDeltaProcessor.onVisibleDelta` observes only the content
  path, after existing reasoning/tool routing and at the UI reveal cadence.

The incremental chunker retains the extendable last chunk to preserve
`TTSTextChunker.split`'s existing 240-character sentence grouping. Short tails
therefore wait for `finish()`. Unclosed Markdown delays emission; the existing
`MarkdownStripper` determines spoken text. Synthesis overlaps playback with at
most eight 800-sample (33 ms at 24 kHz) buffers queued. Output-route changes
cancel the new stream rather than claiming discarded audio finished. No UI,
settings, package dependencies, or existing entry-point contracts were added or
replaced.

## Verification

Evidence is local under `build/t01-proof/` (not committed).

- Required command:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test OSU_MODELS_DIR=/tmp/osaurus-test-models make test`
  **BLOCKED**, exit 2: `sandbox-exec: sandbox_apply: Operation not permitted`.
  **0 tests executed**, no pass/fail assertion counts. Log: `make-test.log`.
- Focused `swift test --package-path Packages/OsaurusCore --filter TTSTextChunkerTests`
  hit the same sandbox failure. `--disable-sandbox` then exposed an unwritable
  compiler module cache. Redirecting module/cache/config/security paths into
  this worktree resolved that issue. Logs: `initial-test.log`,
  `focused-test.log`, `focused-test-local-cache.log`.
- SwiftPM's binary-artifact downloads stalled; two attempts were interrupted
  before compilation. Existing Sentry artifacts were copied read-only from the
  user cache into the worktree cache. Sparkle 2.9.2 was fetched solely for
  SwiftPM resolution; SwiftPM subsequently accepted all cached artifacts.
- Full `swift test --disable-sandbox ... --jobs 4`: **BLOCKED** before tests by
  vMLX `CompileMetalFile ... steel_attention.metal` failure under the default
  Swift Build engine. **0 tests executed**. Log: `full-test-cached.log`.
- Full `swift test --disable-sandbox --build-system native ... --jobs 4`:
  **BUILD PASS** in 510.72 seconds, including all production and test sources.
  Execution stalled; stopped with Ctrl-C (exit 130) after over two minutes
  without log progress. A `--skip-build` repeat with `NSUnbufferedIO=YES`
  identified the stalled row as
  `BackgroundDriverRouteTests.testChromiumClickEscalatesDecoyAndRealClickToHid`,
  immediately after macOS logged `NSCocoaErrorDomain Code=134020` (incompatible
  Core Data store configuration). This repeat was also stopped (exit 130).
  **88 passed, 0 reported failed, 1 skipped, remaining tests incomplete**;
  these are observed cases, not an aggregate full-suite verdict. Logs:
  `full-test-native.log`, `full-test-unbuffered.log`.
- Focused integrated command: `swift test --skip-build --disable-sandbox --build-system native ... --filter 'TTSStreamTests|TTSTextChunkerTests|AssistantDeltaObservationTests|StreamingDeltaProcessorTests|TTSEngineRebuildTests'`
  with the fallback environment below and `NSUnbufferedIO=YES`: **26 tests in
  5 suites passed, 0 failed**, exit 0. This runs the actual built OsaurusCore
  package, including the visible-content observer test and adjacent regressions.
  Log: `focused-integrated.log`.
- Isolated dependency-free package using exact copies of `TTSStream.swift`,
  `MarkdownStripper.swift`, the production chunker and AVFoundation pipeline,
  plus `TTSStreamTests` and existing `TTSTextChunkerTests`: **18 tests passed,
  0 failed** (two suites). Covers arbitrary delta boundaries, Markdown, playback
  ordering, synthesis overlap, cancellation before input/during synthesis/while
  draining/under backpressure, late completions, failure, empty input, and RMS.
  Reproduce with `python3 build/t01-proof/prepare-isolated.py`, then
  `swift test --disable-sandbox --package-path build/t01-harness` with the cache
  overrides below. Log: `isolated-tests.log`. This is not full-app proof.
- `swiftc -frontend -parse` on all changed Swift files: **PASS**.
  `git diff --check`: **PASS**.
- Release and Debug `xcodebuild -workspace ... -scheme osaurus ... build -quiet`
  attempts both returned exit 66: workspace reported as not a workspace file,
  despite valid on-disk XML. Absolute paths and worktree-local `TMPDIR` did not
  help. Direct `-project App/osaurus.xcodeproj` reached package resolution but
  failed with the sandbox denial. Every invocation included
  `-skipPackagePluginValidation -skipMacroValidation`. Logs: `app-release.log`,
  `app-debug.log`, `app-local-tmp.log`, `app-project-fallback.log`.

Fallback environment: `CLANG_MODULE_CACHE_PATH=$PWD/build/ModuleCache`,
`SWIFTPM_MODULECACHE_OVERRIDE=$PWD/build/ModuleCache`,
`TMPDIR=$PWD/build/tmp`, `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
`OSAURUS_TEST_ROOT=$PWD/build/t01-test`, `OSU_MODELS_DIR=$PWD/build/t01-test-models`.
SwiftPM flags: `--cache-path "$PWD/build/swiftpm-cache" --config-path "$PWD/build/swiftpm-config" --security-path "$PWD/build/swiftpm-security" --package-path Packages/OsaurusCore`.

Real PocketTTS/remote synthesis, audible one-buffer cancellation latency, mixer
cadence, microphone VAD, and complete Chat/Settings UI/relaunch proof are
**UNPROVEN**: no app bundle could be built. No manual live provider/model proof
or OsaurusEvals model lanes were run. `AssistantDeltaObservationTests` is included
and passed in the integrated focused lane. No system software installed,
no push, no remote changes, and no other worktrees modified. Root `AGENTS.md`
was read; the referenced `~/AGENTS.md` does not exist.

A chained `git add` was denied access to the worktree index; the standalone
`git add` invocation succeeded. No permission escalation was requested.

Base source: `d901d09e4078b4aec81a714be81b7b67e8d86d68`.
vMLX pin: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6` (unchanged).

Implementation patch SHA-256 (excluding this report):
`37de98ea77976aa21233443222cabd9096b465a72f5a7bc2a2017429c7de8beb`.
