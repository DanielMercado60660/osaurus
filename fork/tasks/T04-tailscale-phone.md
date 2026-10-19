# T04 — Phone access over Tailscale (no third-party relay)

Repo: osaurus fork (native Swift macOS app). Read `AGENTS.md` first.

## Goal

From a phone that is on the owner's tailnet, open a URL and chat with (and
talk to) the Mac's agents — with no port forwarding and without upstream's
`agent.osaurus.ai` relay. Setup on the Mac should be: toggle "Phone access",
sign in to Tailscale once (browser login link), scan a QR code with the phone.

## Context

- The app already runs an HTTP server (default `127.0.0.1:1337`) with
  OpenAI/Anthropic-compatible APIs and `POST /agents/{id}/run`
  (`Packages/OsaurusCore/Networking/`), a mobile protocol
  (`docs/MOBILE_PROTOCOL.md`), pairing (`Services/Pairing`,
  `Views/Pairing`) and a Go helper precedent: `helpers/osaurus-wa`
  (WhatsApp bridge built with `make wa-helper`, embedded/pinned by digest).
  Study how osaurus-wa is built, launched, supervised and pinned, and mirror it.
- Plugins can register HTTP routes and serve web apps (v3 host API) — check
  whether the core server can serve a static web UI directly.

## Design

1. `helpers/osaurus-ts`: a small Go helper embedding `tailscale.com/tsnet`.
   - Joins the tailnet as `osaurus-<short-hostname>` with state in the app's
     support dir; prints the interactive login URL on first run (the app shows
     it as a button/QR); supports ephemeral = false so the node persists.
   - Serves HTTPS on the tailnet (`ListenTLS` with tailnet certs, or plain
     HTTP on the tailnet if certs are unavailable) and reverse-proxies to the
     app's local server.
   - **Auth**: every request is checked with tsnet `LocalClient.WhoIs`; only
     the tailnet login(s) allowlisted by the owner (default: the login that
     authenticated the node) are allowed; others get 403. Inject a header the
     local server can trust only from this helper (shared secret passed via
     env/stdin at launch) so the local server can treat these requests as the
     owner.
   - Line-delimited JSON status on stdout (`login_url`, `running`, `dns_name`,
     `error`) for the app to display.
2. App side: `Services/PhoneAccess/TailscalePhoneAccessService.swift` that
   launches/supervises the helper (like osaurus-wa), surfaces status, and a
   Settings card: toggle, login button, status, the phone URL as text + QR
   (CoreImage `CIQRCodeGenerator`), allowlisted logins. Follow the AGENTS.md
   settings-catalog checklist.
3. Phone UI: a lightweight mobile web chat served at `/phone` by the local
   server (static HTML/JS/CSS bundled as resources, no build step, no CDN):
   agent picker, chat with streaming replies, markdown rendering, a
   push-to-talk mic button that records in the browser and posts audio for
   transcription if a transcription endpoint exists (otherwise text only), and
   playback of TTS audio if a speech endpoint exists. Mobile-first, works in
   iOS Safari, installable as a PWA (manifest + icons), dark/light.
4. Build integration: `make ts-helper` target; embed the binary in
   `Contents/Helpers` in `make app` (skip gracefully with a clear message if Go
   is missing).

## Tests

- Go: unit tests for the WhoIs allowlist middleware and header injection
  (`go test ./...` in the helper).
- Swift: status-line parsing and the service state machine; settings
  self-find probe.
- Manual/live steps that need a real tailnet and phone go in the RESULT file
  as a checklist — do not attempt to log in to Tailscale yourself.

## Constraints

- Never call Tailscale login, never create accounts, never contact external
  services beyond Go module download.
- Default off. Nothing listens on a non-loopback interface unless the user
  enables it.
- Commit on your branch. Write `fork/tasks/T04-tailscale-phone.RESULT.md` with
  files, how to try it, tests run + counts, and the live checklist.
