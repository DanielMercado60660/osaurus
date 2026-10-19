# T05 — "Make it yours": one-click setup for voice, companion and phone

Repo: osaurus fork (native Swift macOS app). Paths relative to
`Packages/OsaurusCore/` unless noted. Read `fork/tasks/CODEX_PREAMBLE.md`,
then `AGENTS.md`. Builds on T02 (avatar), T03 (talk mode), T04 (phone
access) — all merged in this branch; read their `fork/tasks/T0*.RESULT.md`.

## Goal

Upstream onboarding already gets to a working chat in 2–4 clicks (welcome →
create agent → configure AI; Raptor 0.6 4B recommended on 16 GB). Keep that
untouched. Add one **post-onboarding** card that turns on this fork's three
headline features, each with **one click**, so a new user gets "a personal AI
you can talk to, that lives on your desktop and answers your phone" in under a
minute of clicking (downloads can continue in the background).

## Deliverables

1. **Make-it-yours card** shown in the chat empty state (`Views/Chat/ChatEmptyState.swift`)
   after onboarding completes, until dismissed or all three are done. Three
   rows, each with a single primary button and live status/progress:
   - **Talk to it** — downloads the speech-to-text model (Parakeet, ~600 MB,
     via `SpeechModelManager`) and the on-device TTS model (PocketTTS via the
     existing TTS model download path) if missing, requests microphone
     permission at the moment of the click, enables talk mode for the current
     agent (T03 configuration), and shows the talk-mode shortcut. Shows combined
     download progress; failures show a retry with the real error.
   - **Show your companion** — turns on the animated avatar (T02 setting).
   - **Reach it from your phone** — opens Settings at the Phone access card
     (T04) using the settings-search anchor (`server.phoneAccess`) rather than
     enabling it silently (it needs the Tailscale login).
   Rows already satisfied show as done. Dismiss ("Not now") persists.
2. **Defer the notification permission prompt** so it never appears on top of
   onboarding: today `AppDelegate.swift` ~341 →
   `Services/NotificationService.swift` ~50-52 asks on every launch. Ask only
   after onboarding has completed (and keep current behavior for existing users
   who already completed onboarding).
3. Settings-catalog compliance for any new user-facing control (AGENTS.md).
4. Update `Resources/Guide/` with a short "Make it yours" section.

## Tests

- Pure state logic for the card (which rows are done/pending/in-progress,
  dismissal persistence) in a testable type with unit tests.
- Notification deferral decision as a pure function with tests.

## Constraints

- Do not change the three onboarding steps or the model recommendation.
- No new dependencies. Downloads only through the app's existing managers.
- Commit on your branch; write `fork/tasks/T05-make-it-yours.RESULT.md`.
