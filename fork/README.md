# Osaurus fork — a personal AI you can talk to, see, and reach from your phone

A fork of [osaurus](https://github.com/osaurus-ai/osaurus) (MIT, native Swift
on Apple silicon) tuned for one goal: **set up a personal AI on a 16 GB Mac in
a few clicks**, run a local model or a cloud one, let it control the Mac, talk
with it hands-free, and reach it from your phone.

Upstream already provides the hard parts (local MLX inference, cloud
providers, agents, memory, sandbox VM, WebKit browser use, computer use,
channels). This fork adds:

| Feature | What it does | Where |
| --- | --- | --- |
| **Talk mode** | Hands-free, full-duplex conversation: VAD + end-of-turn detection, barge-in, first sentence spoken as soon as it's generated, Apple voice-processing echo cancellation (with a fallback), latency telemetry. ⌃⌥⌘T. | `Services/Voice/TalkMode*`, `TalkAudioEngine` |
| **Companion** | Animated procedural dinosaur on your desktop: idles, listens, thinks, speaks with lip sync, reacts (happy / oops / surprised), follows your mouse, per-agent accessories. Click it to talk without opening a chat. Wake word starts companion talk. | `Services/Avatar`, `Views/Agent/AnimatedAgentAvatarView` |
| **Phone access over Tailscale** | Your Mac joins your tailnet via an embedded `tsnet` helper. Open the phone page from any of your devices: chat, talk mode with spoken replies, the companion, model picker. No port forwarding, no third-party relay. | `helpers/osaurus-ts`, `Services/PhoneAccess`, `Resources/Phone` |
| **See & steer the Mac from the phone** | Optional (off by default): view the Mac's screen on the phone and ask a computer-use agent to act. Owner-login only, audited, visible on-Mac indicator. | `PhoneScreen*` |
| **Speech API** | `POST /v1/audio/speech` (OpenAI-compatible, streaming) backed by the on-device TTS. | `Networking/AudioSpeech*` |
| **Make it yours** | After onboarding, one card with three one-click rows: Talk to it, Show your companion, Reach it from your phone. | `Views/Chat/ChatEmptyState` |
| **16 GB memory budget** | Speech models count toward RAM admission; on ≤16 GB Macs talk mode explains tight memory with a concrete fix. | `AuxiliaryModelResidency` |
| **Mac control fixes** | Localized/case/diacritic-insensitive app names; precise validation errors the model can recover from. | `ComputerUse/Driver/AppCatalog` |
| **Packaging** | `make fork-dmg` → stripped, signed (ad-hoc or Developer ID) DMG. | `scripts/build/build-fork-dmg.sh` |

## Build

```bash
make app XCODEBUILD_FLAGS="-skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="
make fork-dmg XCODEBUILD_FLAGS="-skipPackagePluginValidation -skipMacroValidation"
```

Needs Xcode, Go (for the Tailscale helper). See `fork/PACKAGING.md`.

## Status and evidence

See `fork/LOG.md` for the day-by-day log with measurements, and
`fork/tasks/*.RESULT.md` for each feature's tests and what is and isn't
verified. Short version:

- Builds green; all 12 deterministic eval suites meet their floors.
- **Talk mode latency** (headless harness `fork/metrics/talk_bench.sh`: real
  VAD → ASR → Qwen3.5-4B → PocketTTS, paced WAV input, null audio sink):
  end of speech → first audio **1.14 s p50** (started at 3.58 s). Steps:
  FluidAudio 0.15.4 (PocketTTS v2.1, ANE) → "Think before speaking" off by
  default in talk mode → Smart Turn v3 semantic end-of-turn (MLX Swift).
- Verified live: the phone page against the real server and a local model
  (model picker + streamed chat), endpoint auth rejections, the DMG builds and
  codesign verifies.
- Not yet verified live: talk mode through real speakers/mic with a person
  (echo cancellation, acoustic latency), Tailscale login on a real tailnet,
  iPhone Safari, the Mac UI by a human.

## How it was built

Planned and integrated by Claude; most features implemented by Codex from
specs in `fork/tasks/` (each in its own git worktree), with Claude subagent
code and security reviews feeding fix-up tasks.
