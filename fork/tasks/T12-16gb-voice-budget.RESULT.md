# T12 — 16 GB voice memory budget

Status: **PARTIAL — implemented and committed; isolated deterministic checks pass. Full-app build, integrated eval execution, live UI/audio, and physical 16 GB qualification are BLOCKED/unverified in this sandbox.**

Implementation/tested source: `6713de9f5aac79e06d98ddee5035a30f45d497b1` on `task/T12-16gb-voice-budget`.
Base: `b9c45070c3a8ba35adc2057d1b1c182343c04a78`.
This RESULT is a subsequent documentation-only commit.
vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
FluidAudio pin inspected locally: `d302273d49ef4d8914b27f20d342be482e8810f1` (0.14.1).
No live model bundle or generation defaults exercised; no token/s, physical-footprint, swap, cache, or acoustic measurements claimed.

## Audit of the starting implementation

“Counted by host sampling” below means inclusion in the OS-wide wired/compressed/non-purgeable anonymous page accounting used by `ChatResidencyHandoff.sampledAvailableMemoryBytes`. It is not a per-component physical-footprint measurement. Reclaimable file-backed pages remain reclaimable; disk size is not unload credit.

| Component | Starting accounting and ownership |
| --- | --- |
| Chat model and chat-backed core utilities | Explicit `ModelRuntime.modelCache` / in-flight load weight accounting. Bundle sizes/effective load footprint, architecture-dependent KV estimates, selected runtime memory limits, and host headroom feed the existing projections/admission. `GPUMemoryBudget` uses on-disk size × 1.25 for ordinary chat estimates. These are estimates, not measured per-model RSS/physical footprint. Titles/suggestions reuse that model and preserve its residency owner; the core-utility document describes ownership, not a universal auxiliary-model registry. |
| Embedder | `EmbeddingService.sharedEmbedder` owns `VMLXModel2VecEmbedder`, whose `pipeline()` lazily retains a separate Model2Vec pipeline. Metal work is coordinated, but the pipeline is not a `ModelRuntime` chat resident and has no individual entry in its load projection. Its physical effects enter host sampling (and MLX allocator telemetry where applicable). |
| OpenAI privacy filter (~2.8 GB in task example) | `PrivacyFilterEngine` retains a separate `PrivacyFilterKit`; not in `ModelRuntime.modelCache`. Starting implementation had only host/allocator effects, no explicit auxiliary estimate. Disabling a setting is not necessarily an unload. |
| Rampart privacy alternative | Separate `RampartPrivacyDetector` MLX model, MetalGate-protected. Not an explicit chat resident or per-component RAM projection. This task leaves it represented through host sampling; it does not assume the large OpenAI filter is loaded just because privacy is enabled. |
| Image/video models | Native media jobs use their service's `estimatedPeakBytes` and `ChatResidencyHandoff.memoryPreflight`, including workspace when supplied, the existing 3 GiB reserve, and fresh host sampling after handoff/reclaim. Not ordinary chat-cache resident entries. Peak estimates/admission are not physical measurements. |
| Sandbox VM | `SandboxManager` sets `VZVirtualMachineConfiguration.memoryInBytes` from configured `memoryGB`; no corresponding chat-residency reservation. Host sampling observes its actual pressure, not a precharge of the VM's configured ceiling. |
| Parakeet STT and Silero VAD | `SpeechService` retains ASR and VAD managers, shared by dictation, wake-word/continuous input, and Talk. No individual model projection before T12. Stopping capture does not release these cached managers. Actual host memory effects were already sampled. |
| PocketTTS | `TTSService` retains its own manager for streaming and ordinary speech. No individual model projection before T12. `stop()` stops playback, not the model; switching to remote TTS also retains a previously loaded local manager. Remote requests have no new local TTS weights. |

There was no existing general auxiliary residency ledger to register with. T12 adds one and connects it to the **existing shared `ModelRuntime.buildRAMFeasibility` projection**, rather than pretending CoreML engines are evictable chat containers or subtracting resident speech a second time from measured host headroom. Existing subagent host-sampling/reservation arithmetic remains intact.

## Built

- `AuxiliaryModelResidency` tracks STT, TTS, VAD, and the OpenAI privacy kit by weak reference to their actual owners. Repeated registration of an owner replaces its entry. No service-stop flag invents an unload: an active worker or cached service retains its charge until the engine really becomes unreferenced. Snapshots prune released owners.
- `AuxiliaryModelEstimate` measures logical regular-file bytes recursively, deduplicates resolved file paths, and uses the existing ordinary-chat **1.25×** inflation for runtime state/activations. It returns unknown for missing/unreadable/empty artifacts. This factor is a documented heuristic, not calibrated physical-footprint evidence.
- `SpeechModelMemory` gets STT/VAD artifact paths from the pinned FluidAudio path/name APIs and selected existing loader version. TTS uses the actual directory returned by its downloader and the library's required artifacts, including constants. There is no model-name size table or admission allowlist. Disk scans run on utility tasks.
- Real speech/TTS initialization registers successful engine owners. OpenAI privacy initialization registers its kit. Explicit unload, failed partial loads, worker retention, and replacement use actual object lifetimes. Speech initialization now keeps partial ASR local until VAD succeeds and rejects a cancelled or explicitly unloaded load before publishing it. Cancellation is rechecked between load phases; FluidAudio's currently executing detached load itself is not made forcibly interruptible.
- Existing normal-load and candidate-load projections add known auxiliary estimates. They preserve the meaning of `residentWeightsBytes` as chat weights and do not increase incremental `requiredAvailableBytes` by already-resident speech. They do not change configured admission thresholds or turn diagnostics into a refusal.
- At Talk startup on **physical RAM <=16 GiB**, the selected local chat model, other actual resident/in-flight chat models, planned cold STT/VAD, and actual auxiliary residents are projected. A draining old ASR worker cannot satisfy a new capture's cold-load requirement. The comfort ceiling reuses `GPUMemoryBudget.budgetGB × comfortableBudgetRatio` (0.85); host checking reuses the existing 3 GiB reserve and charges only cold additions against available memory.
- A tight projection shows one **Talk mode memory** toast. With a loaded OpenAI privacy kit, its exact remedy is: **“Use a smaller chat model while talking to leave room for the privacy filter and speech models. Privacy protection is not changed automatically.”** Other tight cases recommend a smaller chat model or stopping other local workloads. Missing estimates produce an explicit unknown-estimate message.
- This “preset” is an **advisory**, not automatic settings mutation or a hard RAM block. Talk continues under existing runtime limits. It does not promise to prevent swap. It neither unloads/disables privacy nor overrides model defaults. Machines above 16 GiB skip the Talk advisory entirely; auxiliary accounting still improves shared diagnostics.
- Added the deterministic `talk_memory` eval lane and four JSON rows to the existing RAMAdmission suite. Existing 18 admission rows are retained. The new rows cover 16 GiB fit, 16 GiB with privacy and exact message, 32 GiB unaffected, and resident speech without a duplicate host charge.
- Guide updated. No new or renamed user setting/control was added, so there is no new settings-catalog entry. T03's isolated harness has additional inert seams for the new controller dependency.

The scripted example uses 4.3 GiB estimated chat plus 0.6/0.7/0.01 GiB on-disk STT/TTS/VAD inflated 1.25×: approximately **5.9375 GiB**. Adding 2.8 GiB on-disk privacy inflated 1.25× yields **9.4375 GiB**, above the supplied 16 GiB comfortable ceiling of approximately **9.0667 GiB**. These are injected inputs, not measurements of installed models.

## Files

Under `Packages/OsaurusCore/`:

- New: `Services/ModelRuntime/AuxiliaryModelResidency.swift`, `Services/Voice/TalkMemoryBudget.swift`, `Services/Voice/SpeechModelMemory.swift`, `Tests/Voice/TalkMemoryBudgetTests.swift`.
- Updated: `Managers/SpeechService.swift`, `Managers/TTSService.swift`, `PrivacyFilter/Core/PrivacyFilterEngine.swift`, `Services/ModelRuntime.swift`, `Services/Voice/TalkModeController.swift`, `Tests/Service/ModelRuntimeRAMFeasibilityTests.swift`, `Resources/Guide/guide-settings.md`.

Under `Packages/OsaurusEvals/`: `EvalCase.swift`, `EvalRunnerSubagent.swift`, `RAMAdmissionEvalTests.swift`, and four `Suites/RAMAdmission/talk-*.json` fixtures.

Proof helpers: `scripts/test-talk-memory-isolated.sh`, `fork/tasks/T12-16gb-voice-budget.verify.py`, and the compatible T03 helper update.

## Verification

1. **PASS: 13 reported tests in 4 suites, zero failures; RAM fixtures 22/22.** One lifecycle test also runs two argument cases (unload and cancellation).

   ```sh
   scripts/test-talk-memory-isolated.sh > build/T12/isolated.log 2>&1
   ```

   The script sets `OSAURUS_EVALS_SCRIPTED_ONLY=1`, credential suppression, keychain-disabled mode, empty model/test roots, and isolated SwiftPM/module caches. Its exact Swift command is:

   ```sh
   swift test --disable-keychain --disable-sandbox --package-path "$PWD/build/T12/isolated" \
     --cache-path "$PWD/build/T12/swiftpm-cache" --config-path "$PWD/build/T12/swiftpm-config" \
     --security-path "$PWD/build/T12/swiftpm-security" --jobs 4
   ```

   Production Talk policy, registry, sizing, planner, reservation actor, and eval bridge are copied unchanged. The shared RAM projection and actual speech load/unload methods are extracted at declaration boundaries. `SpeechModelMemory` is copied with only the FluidAudio import removed. Explicit inert settings/FluidAudio/app seams exercise manager retention, VAD failure, cancellation and unload while loading, no stale publish, and no duplicate host charge. The artifact sizing test writes tiny temporary files. No actual CoreML engine or model runs.

   All **18 existing plus 4 new fixtures** execute the production policy methods with a minimal JSON envelope. This does **not** constitute execution of the full `OsaurusEvals` CLI/runner; integrated runner execution is blocked below. New fixture outcomes: comfortable, smaller_model_with_privacy with exact message, unaffected, comfortable. No failing row was excluded.

2. **PASS: 64/64 tests in 13 suites**, with Talk controller, settings, stream/reducer, chunker, audio-route logic, and catalog sources type-checked against the existing T03 inert seams:

   ```sh
   python3 fork/tasks/T03-talk-mode.verify.py --run > build/T12/talk-regression.log 2>&1
   ```

   Raw log: `build/t03-proof/isolated.log`. Compiler-plugin sandbox warnings occurred, but compilation and all tests completed with exit 0. A default-build-system rerun also passed 64/64 (`build/T12/talk-regression-swiftbuild.log`), not 64 additional distinct tests:

   ```sh
   swift test --disable-keychain --disable-sandbox --package-path build/t03-harness \
     --cache-path "$PWD/build/swiftpm-cache" --config-path "$PWD/build/swiftpm-config" \
     --security-path "$PWD/build/swiftpm-security" --jobs 4
   ```

3. **PASS:** `swiftc -frontend -parse` on all **13 changed/new Swift files**, `bash -n scripts/test-talk-memory-isolated.sh`, Python helper compilation, `git diff --check`. Reproduce parsing from the implementation commit:

   ```sh
   swiftc -frontend -parse $(git diff-tree --no-commit-id --name-only -r \
     6713de9f5aac79e06d98ddee5035a30f45d497b1 | rg '\.swift$')
   ```

4. **BLOCKED, exit 1, zero integrated tests executed**, for each of:

   ```sh
   export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
   export OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$PWD/build/T12/test-root"
   export OSU_MODELS_DIR="$PWD/build/T12/test-models" OSAURUS_EVALS_SCRIPTED_ONLY=1
   swift test --disable-keychain --package-path Packages/OsaurusCore \
     --filter TalkMemoryBudgetTests > build/T12/integrated.log 2>&1
   swift test --disable-keychain --package-path Packages/OsaurusEvals \
     --filter RAMAdmissionEvalTests > build/T12/integrated-evals.log 2>&1
   ```

   Both fail evaluating their package manifest: `sandbox-exec: sandbox_apply: Operation not permitted`. No prolonged full-graph workaround.

5. **BLOCKED, exit 66, no Release app built/launched**, with credential suppression:

   ```sh
   xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Release \
     -derivedDataPath build/T12/ReleaseDerivedData -skipPackagePluginValidation \
     -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
     build -quiet > build/T12/release-build.log 2>&1
   ```

   Xcode reports `'osaurus.xcworkspace' is not a workspace file` before app compilation.

## How to try / required outstanding proof

Build the implementation outside the sandbox using the normal isolated Release lane. On actual <=16 GiB hardware, configure Voice input, load local TTS, enable Talk for an agent, and select the intended 4B chat bundle. Start using the waveform-circle control or Control–Option–Command–T. Check multi-turn input, audible output, Stop, input unlock, and a complete follow-up/tool turn. Repeat with the large privacy kit actually **loaded**, not just enabled: inspect the concrete Talk memory message. Keep privacy protection unchanged, select a smaller chat model, and repeat. With remote TTS, check both a fresh process and one retaining PocketTTS from earlier use.

Exercise ordinary voice input, wake word, TTS playback, Talk stop/start, explicit speech unload, model replacement, failed loading, cancellation during each load phase, and workers still draining after unload. Verify counts remain while cached and disappear on actual engine release. Test the 32 GiB path (no new Talk message), both unknown-artifact and unknown-host-sample cases, cold and resident chat, model aliases, concurrent local loads, background core utilities, embedder, image jobs, VM, and privacy backend switching. Inspect relevant memory, cache, concurrency, model-default and override settings through the real UI, save/navigate/relaunch, then confirm runtime telemetry and finalization.

Record Activity Monitor **physical footprint**, swap behavior, token/s, exact model bundle/defaults, runtime/cache telemetry, and the complete chat lifecycle. Run the integrated 22-case RAMAdmission suite under `OSAURUS_EVALS_SCRIPTED_ONLY=1`, applicable Core suites, and the required full AgentLoop/AgentLoopFrontier lanes with scores and failed-case attribution. No inference or live lane was run here; none is reported as passing.

Limitations: the 1.25× estimate is not validated against CoreML peak memory. Registration follows successful engine initialization; this is not a prospective reservation for FluidAudio download/compile/load transients. The embedder, alternate Rampart model, media and VM remain represented by existing host sampling/admission rather than individual entries in the new auxiliary ledger. Other chat residents are conservatively included at Talk startup even if a subsequent strict-single-model load will evict them. The advisory is not an allocation guarantee and does not replace explicit runtime limits.

## Evidence / commit notes

Local ignored artifacts (no screenshots, models, or generated harness packages committed):

| Artifact | SHA-256 |
| --- | --- |
| `build/T12/isolated.log` | `21ab7b48dab2c0299335f32fd1e4ba3254ef7947a803c06f52255199af58df4f` |
| `build/t03-proof/isolated.log` | `c6b452fb54250b1950ae028fbff0945c39ce673145375f4afa1c35cdb797aafb` |
| `build/T12/talk-regression-swiftbuild.log` | `e672d495b80a5988d7c7d43a130ee0d9910989845dadc19c7d76edda8a6f20fb` |
| `build/T12/parse.log` | `89dfc916daa90aefbbeac52e1284c6b2039b9f81bfe218401aa5ef34c95e79f8` |
| `build/T12/integrated.log` | `b71335fa724e590910a65f5401a9cd2fbeca838ba28b9c70f4218531f3cb5d58` |
| `build/T12/integrated-evals.log` | `0b1c2b50086c6e687d75ab7dabbb36bf0c93704ec85a0d2aa74d7ecd4ea2142b` |
| `build/T12/release-build.log` | `f987f909b30576709d9bd81e8a68a1fc66d870c6874d84cc4d5c168115207557` |

Initial combined staging/commit command hit an index-lock sandbox denial. Separate ordinary `git add -A` and `git commit` commands succeeded. No push, branch switch, remote edit, dependency addition, system installation, login, helper agent, or Keychain prompt. `~/AGENTS.md` was absent; the repository instructions, required documents, and T03/T05 results were inspected.
