# T09 — Talk to the companion (interactive avatar)

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, then the RESULT files for
T02 (avatar), T03 + T03b (talk mode). Paths under `Packages/OsaurusCore/`.

## Goal

Make the floating dinosaur a companion you can **talk with directly**,
without opening the chat window: click (or a hotkey) → it perks up and listens
→ you speak → it thinks → it answers out loud with lip sync and a caption
bubble → it listens again. It should feel like a little character on your
desktop, not a chat UI in disguise.

## Deliverables

1. **Click to talk**: clicking the companion toggles talk mode for the
   companion's agent (the last active agent, as today) via
   `TalkModeController` — **without** bringing the chat window forward. A
   secondary click target or right-click menu keeps "Open chat", "Hide
   companion", and agent switching. The existing talk-mode hotkey also drives
   the companion when it is visible.
   If talk mode requires a chat session, create/bind it headlessly (no window
   focus) — check how `TalkModeController` binds sessions and add a
   window-less path if needed.
2. **Presence mode**: while talk mode is active from the companion, the panel
   smoothly grows (e.g. 180→280 pt) and shows:
   - a speech-bubble caption of the assistant's current sentence (from the
     talk stream text, synced to playback sentence boundaries, fading out), and
   - a small caption of the user's partial transcript while listening.
   Shrinks back when talk mode ends. Respect Reduce Motion.
3. **Expressions**: extend `AvatarMood`/renderer with short one-shot
   reactions driven by events: `happy` (turn completed successfully), `oops`
   (turn failed / error toast), `surprised` (barge-in). Plus idle micro-actions
   every ~20–60 s while idle (look around, stretch, tail wag), never while
   speaking/listening. Eyes follow the mouse loosely when idle (cheap: sample
   `NSEvent.mouseLocation` at the idle frame rate).
4. **Per-agent look**: use the agent's mascot color (already) and an optional
   accessory per mascot (e.g. scarf, glasses, leaf) so different agents read as
   different characters. Keep everything procedural (Canvas), no new assets.
5. Performance: idle panel still throttled (≤10 fps idle, 30 fps speaking),
   timeline paused when hidden/occluded. Note how you measured.

## Tests

Pure logic tests: reaction scheduling (one-shot expiry, priority vs moods),
idle micro-action scheduler (never during speaking/listening, randomized
within bounds with injected RNG/clock), caption sentence sync (given stream
text + playback sentence events → visible caption). Render an `ImageRenderer`
contact sheet of all moods + reactions + accessories into `build/T09/` for
review (gitignored).

## Constraints

No new dependencies; no changes to talk-mode audio code beyond a window-less
session binding if required. Commit on your branch; write
`fork/tasks/T09-companion-conversation.RESULT.md`.
