# Fork plan: 4-day build on osaurus

Branch: `fork/main` (upstream remote: `upstream` → osaurus-ai/osaurus).
Window: 2026-10-19 → 2026-10-22. Owner is hands-off; Claude drives, Codex and
Claude subagents do most of the implementation.

## Product goal

A personal AI for a Mac that someone can set up in a few clicks, runs well on a
**16 GB Apple silicon Mac** with a local model (or connects to a cloud one), can
**control the Mac**, can be **talked to in real time**, can be **reached from a
phone**, and has an optional **interactive avatar**.

Osaurus already ships agents, memory, sandbox (Containerization), WebKit
browser use, computer use, voice input (FluidAudio) and TTS (PocketTTS), cloud
providers, channels and a mobile protocol. The fork adds what is missing and
tunes what exists, instead of rebuilding it.

## Tracks (priority order)

1. **Baseline + 16 GB profile** — reproducible metrics (bundle size, idle RSS,
   launch time, time-to-first-token, tok/s, clicks to first chat) measured
   against upstream; a 16 GB default model and memory budget.
2. **Realtime voice conversation** — full-duplex talk mode (VAD/turn
   detection, barge-in, streaming STT → LLM → streaming TTS), ported from the
   owner's mama-mei-v2 voice stack (Venus realtime). Builds on osaurus'
   existing FluidAudio STT and PocketTTS.
3. **Interactive avatar** — on-screen character that listens/talks with lip
   sync driven by TTS audio, idle/listening/thinking states. Asset pipeline via
   Tripo 3D (owner has the Codex plugin).
4. **Mac control quality** — measure computer-use / AppleScript / Apple apps
   with the existing evals, fix the worst failures.
5. **Phone access without the relay** — reach the Mac's agents over the
   owner's tailnet (Tailscale) in addition to upstream's relay.
6. **Few-click setup** — onboarding tuned for the 16 GB profile; local-or-cloud
   in one step.

## Ground rules

- Every change keeps `make app` green and runs the focused tests for the area.
- Measure before and after anything claimed as "faster" or "smaller";
  results go in `fork/metrics/`.
- No pushes to any remote, releases, sign-ups or paid services without the
  owner saying yes.
- Codex works in its own git worktree per task, from a written spec in
  `fork/tasks/`; Claude reviews and merges into `fork/main`.
- Progress is logged in `fork/LOG.md` so work survives context resets.

## Build notes

- `make app XCODEBUILD_FLAGS="-skipPackagePluginValidation -skipMacroValidation"`
  (without the flags the build fails validating the swift-secp256k1 plugin,
  same flags upstream CI uses).
