# T06 — Headless talk-mode latency harness

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, then
`fork/tasks/T01-voice-plumbing.RESULT.md` and `fork/tasks/T03-talk-mode.RESULT.md`.

## Goal

Measure talk mode end to end **without a person, microphone or speakers**, so
latency can be tracked per commit: recorded user speech in → real VAD/ASR →
real chat model → real TTS synthesis → time to first audio buffer, plus
barge-in → silence.

## Design

1. A debug-only audio source seam for talk mode: when the app is launched with
   `OSAURUS_TALK_INPUT_WAV=/path/a.wav[,b.wav...]` (and only then), talk mode's
   capture reads 16 kHz mono frames from those files in real time (10–20 ms
   pacing, with configurable leading/trailing silence) instead of the mic, and
   playback renders to a null/offline sink that still produces the same
   buffer-completion events and output level. Compile it in all configs but make
   it inert unless the env var is set; never touch the mic in that mode.
2. `OSAURUS_TALK_AUTOSTART=<agent id or "default">` starts talk mode on launch
   for the default agent, and `OSAURUS_TALK_METRICS_OUT=/path/out.json` writes
   the controller's per-turn latency history (the existing last-50-turn record:
   end-of-speech → first token, → first audio, barge-in → silence) when the
   input list is exhausted, then the app quits.
3. A barge-in scenario: an option to start the next WAV while the reply is
   still playing (`OSAURUS_TALK_BARGE_IN_AFTER_MS=800`).
4. `fork/metrics/talk_bench.sh APP MODEL_ID MODEL_DIR` that prepares an isolated
   test root like `fork/metrics/measure.sh` does (keychain-free env,
   `OSU_MODELS_DIR` with a symlinked model), generates the input WAVs with
   macOS `say -o x.aiff` + `afconvert` to 16 kHz mono WAV (3–4 short
   questions, e.g. "What's the capital of France?"), runs the app headless, and
   prints p50/p90 for each metric plus the barge-in result as JSON into
   `fork/metrics/results/talk-<label>.json`.
   The STT model and TTS model must be present; the script checks and prints a
   clear message naming what to download if missing (it must not download).

## Tests

Pure tests for the WAV frame pacer (frame counts/timing math) and the
autostart/env parsing. The end-to-end script can't run in your sandbox; make it
correct by construction and document exactly how to run it.

## Constraints

Default behavior unchanged when the env vars are absent. Commit on your branch;
write `fork/tasks/T06-talk-latency-harness.RESULT.md`.
