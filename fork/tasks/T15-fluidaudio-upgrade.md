# T15 — Upgrade FluidAudio (faster on-device voice, reuse the owner's models)

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, and the RESULT files for
T01, T03, T03b, T06, T12. Baseline latency numbers are in
`fork/metrics/results/talk-fork-qwen35-4b.json` and `fork/LOG.md`.

## Why

Osaurus pins `FluidAudio "0.14.0" ..< "0.14.2"` (`Packages/OsaurusCore/Package.swift`
~339-343; the comment says 0.14.3 added a breaking `language:` parameter to
TTS). The owner's other project uses **FluidAudio 0.15.4** with PocketTTS
**v2.1** (`~/.cache/fluidaudio/Models/pocket-tts/v2.1/english/`, manifest:
"re-converted for speed: fused flow decoder (100% ANE), one-shot cond prefill,
fp16 flowlm"; same weights as v2). Moving to 0.15.x should cut TTS
time-to-first-audio and let the fork reuse models already on the owner's disk.

## Deliverables

1. Bump FluidAudio to the latest 0.15.x that matches the owner's project
   (0.15.4 if API-compatible with everything else here). Read the FluidAudio
   changelog/diff between 0.14.1 and the target (the checkout lives under
   `build/DerivedData/SourcePackages/checkouts/FluidAudio` in the main
   checkout; the new version resolves into your worktree) and adapt **every**
   call site: PocketTTS (`Managers/TTSService.swift`, `Services/Voice/TTSStream.swift`,
   `/v1/audio/speech` synthesis path), ASR/VAD (`Managers/SpeechService.swift`,
   `Managers/Model/SpeechModelManager.swift`), `CoreMLLoadSentinel`, speech
   residency estimates (T12 `SpeechModelMemory` uses FluidAudio path/name APIs),
   and the T06 harness model checks (`fork/metrics/talk_bench.py` required
   paths). Pass `language` explicitly where the new API requires it, defaulting
   to English exactly as today.
2. Use the v2.1 PocketTTS layout the new version expects, and make the
   download/"is it downloaded" UI and the T05 "Talk to it" row understand it.
   Existing users with the old flat layout must keep working (either the new
   version still loads it, or migrate by downloading the new layout once with a
   clear progress UI — never delete the user's other projects' folders).
3. Keep Parakeet/Silero behavior identical unless the new version requires a
   change; document any model-layout change for ASR/VAD too.
4. Update the PocketTTS-related tests and the T06 harness checks.

## Done

Commit on your branch; write `fork/tasks/T15-fluidaudio-upgrade.RESULT.md`
with the API changes you adapted (file:line), migration behavior, and exactly
what Claude must run to compare before/after (`fork/metrics/talk_bench.sh` with
the same model). Do not claim a speedup — Claude will measure it.
