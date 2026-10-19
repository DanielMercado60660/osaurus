# T14 — Phone: pick a model when the agent has none

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, `docs/MOBILE_PROTOCOL.md`
§12 (`GET /models/picker`, `PUT /agents/{id}/model`), and the phone web app in
`Packages/OsaurusCore/Resources/Phone/` plus `scripts/test-phone-web.mjs`.

Found in a live test of the phone page against a fresh profile: sending a
message to an agent with no default model shows "This agent has no model
configured. Set the agent's default model on the host and try again." and a
dead "No completed reply" bubble. The owner is on their phone; make it fixable
there.

1. Show the agent's current model under the agent picker (tap to change).
   The change sheet lists `GET /models/picker` models grouped by `tab_title`,
   favourites first, unavailable ones disabled with a reason, and applies via
   `PUT /agents/{id}/model`. Built-in agents that answer 404 hide the control.
2. When a run fails with the no-model error, replace the dead bubble with an
   inline "Choose a model" action that opens the same sheet, then lets the user
   resend the last message with one tap. Don't leave "No completed reply"
   bubbles for runs that never started.
3. Accessible, works at 320 px width, dark/light, CSP-safe, no libraries.

JS tests for grouping/ordering, unavailable handling, the error→picker→resend
flow, and 404 hiding (mocked fetch). Commit on your branch; write
`fork/tasks/T14-phone-model-picker.RESULT.md`.
