# T18 — Talk mode hears itself: layered echo defense

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, and the RESULT files for
T03, T03b, T16, T17. Paths under `Packages/OsaurusCore/`.

## Field report

Owner ran the DMG on a Mac mini with a **Studio Display** (default input =
Studio Display Microphone, default output = Studio Display Speakers, no input
selected in Osaurus, `echoCancellationEnabled: true`, no "unavailable" toast →
Apple voice processing was very likely active). Talk mode **picks up its own
voice** (self-barge-in and/or transcribing its own speech).

Current behavior (`Services/Voice/TalkModeReducer.swift` ~169, ~194-195,
~329-331): when `aecActive` is true, every secondary guard is off — VAD
threshold stays 0.5 during playback, no post-playback cooldown, barge-in needs
only 160 ms. VPIO residual echo from loud speakers next to the mic easily
crosses 0.5.

## Deliverables (all with pure, tested logic)

1. **Playback-time thresholds even with AEC**: while the agent is speaking (and
   for 250 ms after), VAD threshold 0.65 with AEC / 0.75 without; barge-in needs
   ≥ 250 ms sustained speech with AEC (≥ 300 ms without). Configurable
   constants in one place.
2. **Echo floor gate**: while the agent plays audio and VAD is below threshold,
   track the mic RMS (EMA) as `echoFloor`; during playback a speech frame only
   counts toward barge-in if mic RMS ≥ `echoFloor × 2.5` (≈ +8 dB) **and**
   VAD ≥ threshold. Reset the floor per reply; decays when playback stops.
   Use the existing capture RMS (`TalkAudioEngine` tap) and the TTS output level
   (`TTSService.outputLevel` / duplex meter) — consider a double-talk check that
   compares mic RMS against the concurrent output level.
3. **Self-transcript rejection**: keep the text of what the agent spoke in the
   current/last reply (the talk stream's released sentences). When a user
   segment's final transcript, normalized (lowercase, strip punctuation), has
   token-overlap ≥ 0.6 with any agent sentence spoken in the last 10 s, or is a
   substring of it, discard it as echo: don't send, don't barge in, return to
   the prior state (resume speaking if a barge-in was only tentative), and count
   it in telemetry (`echoRejectedSegments`).
4. **Visibility**: the talk-mode indicator popover shows "Echo cancellation:
   On (Apple voice processing)" / "Off — <reason>"; log the AEC decision,
   device IDs, input format (rate/channels) and any VPIO error at `.notice`
   level (persisted in the unified log), not `.info`. If `configure(aec: true)`
   throws, keep the error text and surface it (today it's discarded at
   `TalkAudioEngine.swift` ~88).
5. **Harness echo scenario**: extend the T06 headless harness with an option
   that mixes the agent's own TTS output back into the paced input (attenuated,
   e.g. −20 dB, with ~30 ms delay) to simulate residual echo, and report
   self-barge-ins and `echoRejectedSegments`. Expected: zero self-barge-ins and
   zero echo segments sent, while real user barge-in (the existing barge-in
   scenario) still works.

## Tests

Reducer/gate tests for each threshold path, echo-floor tracking and gating,
transcript rejection (exact, partial, unrelated, old > 10 s), tentative
barge-in revert, and harness option parsing. Commit on your branch; write
`fork/tasks/T18-echo-robustness.RESULT.md`.
