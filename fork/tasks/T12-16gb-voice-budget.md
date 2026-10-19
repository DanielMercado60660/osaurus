# T12 — 16 GB memory budget that counts voice models

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, `docs/RAM_ADMISSION_EVALS_2026_09_14.md`,
`docs/RESIDENT_RAM_INCREMENTAL_ADMISSION_2026_09_16.md`,
`docs/CORE_UTILITY_RESIDENCY_2026_09_15.md`, and the T03/T05 RESULT files.
Paths under `Packages/OsaurusCore/`.

## Problem

The fork's headline setup on a **16 GB** Mac runs, at the same time: the chat
model (Raptor 0.6 4B ≈ 4.3 GiB estimated), Parakeet STT (~0.6 GB CoreML),
PocketTTS (~0.7 GB CoreML), Silero VAD, plus optionally the privacy-filter model
(~2.8 GB), an embedder, and the sandbox VM. Upstream's RAM admission
(`Models/Configuration/GPUMemoryBudget.swift`, RAMAdmission, core utility
residency) may not count the speech models, so talk mode could push a 16 GB
machine into swap or trigger refusals that make no sense to the user.

## Deliverables

1. **Audit** (write it up in the RESULT): which resident components are
   counted by admission today (chat model, embedder, privacy filter, image
   models, sandbox VM, speech STT/TTS/VAD) and how (estimate vs measured).
2. **Count speech models**: register STT/TTS/VAD residency with the same
   admission/residency mechanism used for other core utility models, using
   on-disk size × a documented factor (or the measured footprint if the
   mechanism supports it), loaded/unloaded at the right times (talk mode
   start/stop, voice input, TTS use). No hardcoded per-model allowlists.
3. **16 GB talk preset**: when physical RAM ≤ 16 GB and talk mode starts,
   if the admission projection doesn't fit comfortably, show one clear
   message offering the concrete fix (e.g. "Unload the privacy filter while
   talking" or "Use a smaller model while talking"), instead of a generic
   refusal or silent swap. Do not change behavior on larger machines.
4. Extend the deterministic `Packages/OsaurusEvals/Suites/RAMAdmission` with
   scripted cases for a 16 GB machine: chat 4B + speech fits; chat 4B + speech
   + privacy filter → the specific message; 32 GB machine unaffected. These must
   pass under `OSAURUS_EVALS_SCRIPTED_ONLY=1`.

Commit on your branch; write `fork/tasks/T12-16gb-voice-budget.RESULT.md`.
