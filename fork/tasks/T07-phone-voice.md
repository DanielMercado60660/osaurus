# T07 — Speech out + talk mode on the phone

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, then the T04, T04b and T03
RESULT files in `fork/tasks/`.

## Goal

From the phone web app (`Packages/OsaurusCore/Resources/Phone/`), talk to the
Mac's agent and hear it answer, using the Mac's on-device models. Today the
phone can transcribe (hold to talk → `/audio/transcriptions`) but there is no
speech synthesis endpoint, so replies are text-only.

## Deliverables

1. **`POST /v1/audio/speech`** (OpenAI-compatible: `model`, `input`, `voice`,
   `response_format` = `wav` | `pcm`, optional `speed`) on the local server,
   backed by the app's configured TTS engine (PocketTTS on device, or the
   configured OpenAI-compatible TTS server). Stream audio as it is synthesized
   (chunked WAV with a streaming header, or raw PCM 24 kHz s16le) so the first
   sentence plays early. Same auth gate as other APIs; owner/phone-trusted
   callers allowed. Bounded input length; clear JSON errors (TTS not configured
   / model not downloaded). Add to `docs/OpenAI_API_GUIDE.md`.
   Do **not** route through `TTSService` playback — synthesize only; reuse the
   synthesis code paths without touching the speaker.
2. **Phone UI**:
   - A speaker toggle: when on, assistant replies are spoken. Split the
     streamed reply into sentences client-side (port the conversational release
     policy: first sentence immediately) and request `/v1/audio/speech` per
     sentence, queueing playback with Web Audio so sentences play back-to-back.
   - **Talk mode** on the phone: tap once to start a hands-free loop — browser
     VAD (simple energy-based with hangover; no external libs) detects end of
     speech, uploads the clip to `/audio/transcriptions`, sends, speaks the
     reply, then listens again. Tapping while it speaks interrupts (stop
     playback + abort the fetch + `stop` the run). Visual states: listening /
     thinking / speaking.
   - iOS Safari constraints: audio must be unlocked by a user gesture; keep a
     single AudioContext; handle `getUserMedia` only over HTTPS (show a clear
     message on the HTTP fallback).
3. Keep the CSP intact (no inline scripts, no CDNs).

## Tests

- Swift: request validation/parsing for `/v1/audio/speech` as pure functions
  with tests; WAV streaming header writer tests.
- JS: extend `scripts/test-phone-web.mjs` for sentence splitting/release,
  playback queue ordering, interrupt, and VAD state transitions (mocked audio).

## Constraints

No new dependencies. Commit on your branch; write
`fork/tasks/T07-phone-voice.RESULT.md` including a live checklist (phone on
tailnet, HTTPS, mic permission, speaker toggle, talk mode, interrupt).
