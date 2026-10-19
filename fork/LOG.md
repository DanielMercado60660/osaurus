# Fork progress log

Newest entries at the bottom. Each entry: date, what changed, evidence, next.

## 2026-10-18 (day 0)

- Cloned osaurus @ `24e5121b1` to `~/osaurus-fork`, branch `fork/main`,
  remote `upstream`. Dev machine: M4 Pro, 64 GB, macOS 27.0.1, Xcode 27.1.
  Target machine profile: 16 GB Apple silicon.
- Codebase: ~2,670 Swift files, ~1.04M lines. FluidAudio pinned 0.14.0..<0.14.2.
- Local models available without downloading (HF cache / LM Studio):
  Qwen3.5-4B-4bit, Qwen3.5-0.8B-4bit, gemma-4-E2B-it 5bit, LFM2.5-1.2B,
  gemma-4-26B-A4B QAT 4bit, Qwen3.5/3.6-35B-A3B 4bit; voice: Kokoro-82M,
  Silero VAD v5, smart-turn-v3, Parakeet/Qwen3-ASR, whisper-large-v3-turbo.
- Voice source survey (mama-mei-v2): port the **cascade** path (Silero gate
  with echo-raised thresholds, barge-in epoch/cancel, sentence chunker,
  Parakeet EOU streaming ASR, Kokoro TTS ~110 ms to first audio). **Venus
  realtime is out of scope**: ~14 GB, Python-only, choppy in live tests; does
  not fit a 16 GB target. Improvement over mama-mei: real AEC via
  AVAudioEngine voice processing (mama-mei never had AEC).
  Reference latency: end-of-turn → first audio p50 929 ms / p90 1572 ms.

## 2026-10-18 (day 0, evening)

- Build: `make app` needs `XCODEBUILD_FLAGS="-skipPackagePluginValidation
  -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM="` (plugin trust + upstream's signing team). Clean Release
  build: 18 min on M4 Pro.
- Baseline (upstream 24e5121, Qwen3.5-4B-4bit, measured while 2 Codex builds
  were running — rerun in a quiet window before comparing):
  bundle 508 MB (exe 451 MB: __LINKEDIT 282 MB unstripped symbols, __TEXT
  140 MB, __LLVM_COV 20 MB coverage segment in a Release build), server ready
  2.9 s after launch, idle footprint 50 MB, 4.0 GB with model loaded, cold TTFT
  5.9 s (includes load), warm TTFT 0.18 s, decode 83 tok/s.
  → Upstream is already lean at runtime; the "small" wins are bundle-level
  (strip, drop coverage) rather than runtime rewrites.
- Codex running: T01 voice plumbing, T02 animated avatar, T04 Tailscale phone
  access (each in `~/osaurus-wt/<task>`, logs in `~/osaurus-wt/_logs`).
