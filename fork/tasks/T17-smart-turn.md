# T17 — Smart Turn v3 end-of-turn detection (MLX Swift)

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, and the RESULT files for
T03, T03b, T06, T12, T16. Paths under `Packages/OsaurusCore/`.

## Measured

Latest talk benchmark (`fork/metrics/results/talk-t16-qwen35-4b.json`, p50
from end of speech): end-of-turn decided **708 ms** (the 700 ms silence
window), speculative ASR final 376 ms, first audio 1534 ms. The silence window
is now the largest single cost. Target: end-of-turn ≈ 300–400 ms for complete
utterances without cutting people off mid-thought.

## Model

`pipecat-ai` Smart Turn v3 (semantic end-of-turn classifier), already on the
owner's disk as MLX safetensors: `~/.cache/huggingface/hub/models--mlx-community--smart-turn-v3/`
(31 MB; config: 16 kHz, up to 8 s audio, input `[batch, 80, 800]` log-mel
features, output 1 logit, threshold 0.5; converted from
`smart-turn-v3.2-gpu.onnx`). Inspect the safetensors header (stdlib Python
reading the JSON header is fine) to get the exact architecture/weight names.
References:
- the owner's Rust port of the feature extraction:
  `~/mama-mei-v2/crates/operator-voice/src/smart_turn.rs`
  (read-only; it's another project);
- any MLX/Python reference implementation present on disk (e.g. an
  `mlx-audio` install or HF cache), otherwise the upstream model card.

## Deliverables

1. `Services/Voice/SmartTurn/` — feature extraction (Whisper-style 80-bin log
   mel, 8 s window, left-padded/truncated exactly like the reference) and the
   model forward pass in **MLX Swift** using the MLX package the app already
   links (vmlx-swift). No new dependencies. Load lazily; register its residency
   with the T12 auxiliary residency ledger. Inference off the main actor.
2. **Golden test**: compute logits for 3–4 fixed WAVs (generate with
   `say` + `afconvert` into `build/T17/`, or commit tiny fixtures if small) with
   a reference (Python MLX/ONNX if available on disk, or the Rust port for the
   features) and assert the Swift features and logits match within tolerance.
   If no reference runtime is available in your sandbox, write the comparison
   script so Claude can run it, and test the feature extractor against the Rust
   port's documented constants.
3. **Hybrid end-of-turn policy** in the talk reducer/finalization policy: after
   ≥ 300 ms of speech, at `smartTurnCheckSilenceMs` (default 250) run Smart
   Turn on the last ≤ 8 s of audio; if p(complete) ≥ threshold → end turn now
   (reuse the speculative ASR result); otherwise keep waiting and re-check
   every ~200 ms until `endOfTurnSilenceMs` (raise the default to 900 ms when
   Smart Turn is active, since complete turns now end early). Silence-only
   behavior remains when the model is missing or the setting is off.
4. Setting **Voice → Talk Mode → Smart end of turn** (default On when the model
   is present). Model download through the app's existing download path from
   `mlx-community/smart-turn-v3` (show size), never deleting other caches. If the
   owner's HF cache already has it, use it in place. Settings-catalog rules.
5. Telemetry: add `smartTurnChecks`, `smartTurnProbability` (last) and
   `endOfTurnReason` (`smartTurn` | `silence`) to the turn record and the T06
   harness summary.

Commit on your branch; write `fork/tasks/T17-smart-turn.RESULT.md`. Claude
will build, run the golden comparison and the talk benchmark.
