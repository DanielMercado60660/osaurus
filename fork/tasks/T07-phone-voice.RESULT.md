# T07 — Phone speech and Talk mode

Status: **PARTIAL — implementation committed and isolated checks passed; full app build, live synthesis, and phone proof remain UNVERIFIED.**

## Source and environment

- Branch: `task/T07-phone-voice`.
- Base: `9b324883f4198e3c3b653f1f4096b6f1834cca73`.
- Tested implementation commit: `5917140d6385838d064b4fc7553bae58cc15d253`.
  The following documentation commit adds this RESULT and removes the stale
  “no speech endpoint” statement from the bundled settings guide. Runtime and
  test sources are unchanged from the tested implementation commit.
- vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
  FluidAudio lockfile pin unchanged: `d302273d49ef4d8914b27f20d342be482e8810f1`
  (`0.14.1`). The isolated writer lane uses existing app dependency NIO `2.99.0`.
- No model bundle or generation defaults were exercised. Model/eval scores,
  token/s, physical footprint, first-audio latency and acoustic results are
  **not measured**. There are no live passing model rows.
- Read preamble, AGENTS, task spec, T04/T04b/T03 RESULT files. The referenced
  `~/AGENTS.md` does not exist. No subagents, push, other
  worktree edits, software installs, logins or live permission grants.

## Built

- `Networking/AudioSpeechRequest.swift`: pure JSON validation and typed JSON
  errors; required model/input/voice, WAV/PCM formats, speed range, 4096-character
  input and 32 KiB body limits. PCM conversion and 44-byte streaming WAV header.
- `Networking/AudioSpeechWriter.swift`: NIO streaming writer, flush backpressure,
  first-frame headers, JSON failures before audio, and truncated transport on
  midstream failure. WAV lengths use `0xffffffff`; raw PCM is mono 24 kHz s16le.
- `Networking/HTTPHandler.swift`: normalized `/v1/audio/speech` and `/audio/speech`
  route behind the existing API auth gate plus owner trust; trusted helper phones,
  trusted loopback and master keys allowed, agent-scoped keys denied. Applies the
  body limit before allocation. Request registry cancels synthesis on disconnect.
- `Managers/TTSService.swift`: synthesis-only API method reusing the loaded
  PocketTTS manager/utterance chunker or existing compatible TTS client. Snapshots
  saved enabled/provider/model/voice/temperature/speed configuration; never calls
  playback, stop, or download. Explicit API model/voice/speed are validated against
  the active provider. One API synthesis at a time, with a clear 429 while busy.
- `Resources/Phone/phone-voice.js`: first-sentence release, 500 ms/40-character
  first-clause fallback, bounded sentence requests, incremental PCM decoding
  across arbitrary byte boundaries, ordered Web Audio scheduling, bounded
  playback lead, and cancellation epochs. Pure energy VAD plus browser capture:
  300 ms speech, 700 ms hangover, 30-second clip cap, device/context cleanup.
- `Resources/Phone/phone-app.js`, HTML/CSS, and `Networking/PhoneWebAssets.swift`:
  Speaker and Talk controls, a single gesture-unlocked AudioContext, streaming
  speech, half-duplex listen/transcribe/send/speak/listen loop, visible states,
  tap/Stop interruption, HTTPS guidance and hidden-page shutdown. Existing
  hold-to-talk transcript review remains. Capability advertises speech endpoint
  availability (not model readiness). New JS is an explicit authenticated asset;
  CSP and network-only worker are unchanged.
- Tests: `Tests/Networking/AudioSpeechTests.swift`, `AudioSpeechWriterTests.swift`,
  updated `Tests/PhoneAccess/PhoneAccessTests.swift`, extended
  `scripts/test-phone-web.mjs`, and `scripts/test-phone-voice-isolated.sh`.
- `docs/OpenAI_API_GUIDE.md` documents requests, auth, streaming format, errors,
  configuration precedence and phone use. Bundled `guide-settings.md` describes
  the new phone actions. No native settings/catalog labels or persistence were
  added; the phone buttons are session-only controls and reset on reload.

Paths above without a repository prefix are under `Packages/OsaurusCore`.

## Verification

Evidence is local and gitignored under `build/t07/`.

| Command | Result | Evidence / scope |
| --- | --- | --- |
| `scripts/test-phone-voice-isolated.sh` | **12/12 named Swift tests**, 2 suites; the invalid-request test has **11/11 parameter cases** | `swift-http-final.log`. Production request/PCM/writer files copied unchanged; real NIO async test channels. Covers defaults, validation, limits, escaping, WAV fields, PCM saturation, early chunks, one header, JSON errors, truncation, closed-channel writes and empty output. No model, app singleton or real socket. |
| `node --test scripts/test-phone-web.mjs` | **26/26**, 0 failures | `web.log`. Mock DOM/fetch/audio plus actual browser JS source. Includes existing chat/history/Markdown/hold-to-talk regressions, sentence/clause release, long-input bounds, PCM byte splits/order, early playback, interruption/stale work, errors, VAD, talk loop and mic cleanup/late permission/context failure. No real Safari or acoustic evidence. |
| `scripts/test-phone-access-isolated.sh` | **16/16 Swift tests**, 2 suites | `phone-access.log`. Existing phone asset/trust/settings regression lane; now requires the voice asset and speech capability. Existing unrelated app shims remain. |
| `node --check Packages/OsaurusCore/Resources/Phone/{phone-app,phone-voice,phone-sw}.js` (each file separately) | PASS, 3 files | Syntax only; exit 0. |
| `swiftc -frontend -parse` on the 8 changed Swift files | PASS | `parse.log`, empty. Includes full HTTPHandler and TTSService; these integration files were **not typechecked against the full app**. |
| `bash -n scripts/test-phone-voice-isolated.sh` | PASS | Exit 0. |
| `git diff --check` | PASS | Exit 0. |

Exact final syntax command:

```bash
swiftc -frontend -parse \
  Packages/OsaurusCore/Networking/AudioSpeechRequest.swift \
  Packages/OsaurusCore/Networking/AudioSpeechWriter.swift \
  Packages/OsaurusCore/Networking/HTTPHandler.swift \
  Packages/OsaurusCore/Managers/TTSService.swift \
  Packages/OsaurusCore/Networking/PhoneWebAssets.swift \
  Packages/OsaurusCore/Tests/Networking/AudioSpeechTests.swift \
  Packages/OsaurusCore/Tests/Networking/AudioSpeechWriterTests.swift \
  Packages/OsaurusCore/Tests/PhoneAccess/PhoneAccessTests.swift
```

The speech helper sets keychain-disabled/test-root/empty-model and module-cache
isolation, and runs `swift test --disable-keychain --disable-sandbox --package-path
"$PWD/build/t07/isolated"`. Both scripts set the preamble's noninteractive Git
credential environment. No keychain-backed services were run.

The first NIO compilation caught a throwing closure mismatch in `flatSubmit`;
returning a typed failed future fixed it. The final writer compilation/tests pass.
Initial diagnostic remains in `build/t07/swift-http.log`.

Per CODEX_PREAMBLE, full Core/Release app builds were not retried in this sandbox;
the outside-sandbox build lane must run them. **No fresh Release app was produced
or launched.** Full integration tests, auth over real transport, actual synthesis,
Mac speaker isolation, Settings interactions, persistence, Safari playback,
tailnet/HTTPS, acoustic latency, and AgentLoop/AgentLoopFrontier/full eval lanes
were not run. No release-readiness or regression-free claim is made.

## How to try and live checklist — all pending

1. Build a fresh isolated Release app from this branch outside the sandbox.
   Follow the preamble's credential/keychain precautions. Run the focused full
   Core lanes for AudioSpeech, PhoneAccess, TTSStream, TTSTextChunker and
   OpenAICompatibleTTS, then the applicable full regression/eval lanes.
2. On the Mac configure an agent/chat model and transcription model. In
   **Voice → Text To Speech**, enable TTS and load PocketTTS, or configure the
   compatible endpoint/model/voice. In **Server → Overview → Phone access over
   Tailscale**, enable the existing trusted-phone setup.
3. Use the allowed phone's HTTPS tailnet URL. Grant mic permission when prompted;
   toggle Speaker on, then try Talk mode. Tap the Talk button again to interrupt.

- [ ] Phone connected to allowed tailnet; login/device policy admits it; non-owner,
  forged helper capability, revoked device and agent-scoped API key are rejected.
- [ ] HTTPS certificate/phone URL works. HTTP fallback explains HTTPS mic
  requirement; no microphone request occurs there. CSP remains intact.
- [ ] Speaker tap unlocks iOS Safari audio; one context is reused. First sentence
  starts before the full answer finishes, remaining sentences play in order,
  and the Mac speaker remains silent/unaffected.
- [ ] PocketTTS load/not-downloaded/disabled cases; valid/invalid voice/model;
  remote provider with saved defaults and explicit overrides; 400/413/429/503/502
  failures; WAV and PCM streaming. Verify actual remote PCM/WAV and compressed
  fallback behavior, concurrent callers and desktop/phone coexistence.
- [ ] Talk mode requests microphone permission, captures actual speech, transcribes,
  sends to selected agent, speaks, returns to listening and completes a follow-up.
  Verify denial, device loss, short noise, long utterance and empty transcription.
- [ ] Tap/Stop during permission startup, capture, transcription, model loading,
  generation and playback. Confirm immediate silence, aborted speech request,
  stopped connection-bound agent run, no late audio/mic restart and unlocked input.
- [ ] Hidden/backgrounded Safari stops Talk mode; foreground requires another tap.
  Test suspended audio and screen lock. Reload starts both phone controls off.
- [ ] Exercise relevant Mac TTS/transcription/model controls, save/navigate/relaunch,
  and verify effective provider/voice/speed/temperature and model/default state.
- [ ] Full multi-turn/tool lifecycle: exact tool args and grounded results, no parser
  leaks, settled cards/Stop/input, follow-up completion. Record tested SHA, pins,
  model bundle/defaults, token/s, cache telemetry and failures per AGENTS.md.
- [ ] Record actual first-sentence/audio/interrupt timing and acoustic quality on
  iPhone/iPad Safari over the tailnet; repeat the affected matrix on final source.

## Explicit limitations

- Talk mode is half-duplex and tap-interrupted; it does not listen for voice
  barge-in while speaking. Capture begins at detected onset, so onset loss and
  energy threshold/noisy-room behavior need real microphone evaluation.
- PocketTTS has no native speed override in the reused synthesis path; only
  omitted/1 is supported locally. Other valid-range speeds return a clear 400.
- Compressed-only upstream TTS uses the existing client's whole-body decode
  fallback. Early streaming is available with PocketTTS and upstream PCM/WAV.
- Multiple phone clients receive 429 while an API synthesis is active. Desktop
  playback coexistence still needs real model proof; the API never stops it.
- Isolated writer success is not proof of the full HTTP route, auth pipeline,
  provider cancellation, or helper proxy transport. Those remain pending.

## Evidence SHA-256

- `web.log`: `5cc538248df074ed41f3589bb1869a92532ca1955049b50f796e9e1541d1632f`
- `swift-http-final.log`: `9968c16a35325942b6306b3ac3cfa610550bd0bfd265d77521ccb3e542680d5a`
- `phone-access.log`: `b00b36bfa8bcf21beb72e78ccb5801ce3a3ea48f9d6c0ec0b0e8fc09c7139a34`
- `parse.log`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
