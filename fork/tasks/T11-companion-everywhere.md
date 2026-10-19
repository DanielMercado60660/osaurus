# T11 — Companion everywhere: phone + wake word

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, and the RESULT files for
T02, T09 (companion), T04/T04b/T07 (phone). Paths under
`Packages/OsaurusCore/` unless noted.

## 1. Companion on the phone

Port the procedural dinosaur renderer (`Views/Agent/AnimatedAgentAvatarView.swift`
and the T09 additions: moods, reactions, accessories) to a plain JS `<canvas>`
module in `Resources/Phone/` (no libraries, CSP-safe, no inline script). Show it
on the phone page:
- large and centered while phone talk mode is active (listening / thinking /
  speaking with lip sync from the Web Audio output level of the TTS playback,
  `happy` on turn complete, `oops` on error, `surprised` on interrupt), with the
  current sentence as a caption bubble;
- small in the header otherwise; tap it to start/stop talk mode.
- Use the agent's mascot color and accessory from `GET /agents` (`avatar`
  field; derive the accessory the same way T09 does). If the agent has a custom
  image, show that image with a level-reactive ring instead.
- `prefers-reduced-motion`: static pose + simple mouth.
- Pause the animation loop when the page is hidden.
Keep the visual identical in spirit to the Mac renderer (same proportions,
colors, expressions). Add the new asset to `PhoneWebAssets` route table.

## 2. Wake word → companion talk

Today `VADService` wake-word detection posts `.vadAgentDetected` and
`AppDelegate.handleVADAgentDetected` opens/focuses a chat window and starts
voice input. When the animated companion is enabled (T02 setting) **and** the
detected agent has talk mode enabled (T03 config), start companion talk mode
(T09 window-less path) for that agent instead of opening the chat window. Keep
the existing behavior otherwise. After the talk session ends, resume wake-word
listening exactly as today.

## Tests

- JS: renderer state machine (mood/reaction precedence, reaction expiry,
  reduced-motion path) and level→mouth mapping with a mocked canvas context;
  extend `scripts/test-phone-web.mjs`.
- Swift: the routing decision (companion vs chat) as a pure function with
  tests.

Commit on your branch; write `fork/tasks/T11-companion-everywhere.RESULT.md`.
