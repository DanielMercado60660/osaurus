# T16 — Talk-mode latency: per-stage telemetry + reasoning setting

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md` (especially **Model Runtime
Non-Negotiables**: no forced thinking tags, no template coercion, no hidden
defaults — reasoning behavior comes from the bundle unless the **user
explicitly** overrides it through a documented setting), and the RESULT files
for T03, T03b, T06.

## Measured (fork/metrics/results/talk-fork-qwen35-4b.json)

Headless harness, Qwen3.5-4B-4bit, PocketTTS, warm turns: end-of-speech →
first visible token p50 ≈ 2.0–2.8 s, → first audio ≈ 2.8–3.6 s (target 1.2 s).
App log shows the model **reasons before answering** (e.g. "capital of France":
40 reasoning deltas, 3 content deltas; stream 1.14 s), and ≈0.9 s passes
between speech end and stream start (700 ms end-of-turn silence + ASR final).

## Deliverables

1. **Per-stage telemetry** in the talk-mode turn record and the T06 harness
   JSON summary (p50/p90 each): speechEnd → endOfTurnDecided, → asrFinal,
   → sendIssued, → firstStreamDelta (any, incl. reasoning), → firstReasoning,
   → firstVisibleToken, → firstSentenceReleased, → firstAudio; plus reasoning
   duration and reasoning delta count. Update `fork/metrics/talk_bench.py`
   output and `fork/metrics/talk_latency.py`.
2. **"Think before speaking" talk-mode setting** (Voice → Talk Mode), default
   **Off**: when Off and the active model's bundle/template declares a thinking
   toggle, talk-mode sends set the explicit thinking choice **through the same
   mechanism the chat composer's Thinking control uses** (find it: e.g.
   `ChatExecutionContext.currentEnableThinking` / the composer's reasoning
   toggle and how it reaches the template kwargs). When the model has no such
   toggle, do nothing and show "This model always reasons" / "This model doesn't
   reason" in the setting's caption. When On, defer to the bundle default as
   today. Never edit templates, inject tags, or strip output. This is a visible,
   persisted, user-controlled setting — follow the AGENTS.md settings-catalog
   checklist. Talk-mode only; the chat composer's own control is unaffected.
3. **Speculative ASR check**: T03b claims a speculative final ASR at ~250–300 ms
   silence. Verify it actually fires in the talk loop path and that
   `asrFinal` lands before `endOfTurnDecided` in the new telemetry when speech
   doesn't resume; fix if not.

## Tests

Pure tests for the thinking-choice resolution (setting × model capability →
explicit choice or no override), telemetry stage ordering/percentiles, and the
harness summary fields. Commit on your branch; write
`fork/tasks/T16-talk-latency.RESULT.md`. Claude will rebuild and rerun the
benchmark to measure.
