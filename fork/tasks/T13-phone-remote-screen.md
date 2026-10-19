# T13 — See and steer the Mac from the phone

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, the RESULT files for T04,
T04b, T07, T11 (phone), and `docs/COMPUTER_USE.md`. Paths under
`Packages/OsaurusCore/` unless noted.

## Goal

From the phone page, the owner can glance at the Mac's screen and ask an agent
with computer use to act on it ("close that dialog", "open my notes and add
milk"), watching the result update. This is the "control your Mac from your
phone" story, built on the existing computer-use agent — no new remote-input
channel.

## Security model (must hold)

- **Off by default.** New setting in the Phone access card: "Allow phone to
  view this Mac's screen" (settings-catalog rules apply). Requires macOS Screen
  Recording permission; the card shows its state and a button that opens the
  right System Settings pane.
- Screen endpoints accept **only phone-access-helper-verified owner requests**
  (the T04/T04b trust: marker + secret + physical loopback). Not loopback
  callers in general, not relay, not API keys. Add an explicit predicate and
  tests for each rejected caller class.
- Every screen fetch is recorded in the existing Insights activity log
  (tamper-evident log from upstream) with the requesting device.
- While a phone is viewing, the Mac shows a small persistent indicator (e.g.
  a menu-bar or companion badge "Phone is viewing your screen") so it's never
  silent.
- No input injection endpoint: actions only go through the agent's normal
  computer-use tool path and its existing approval gate.

## Deliverables

1. `GET /phone/api/screen?display=main&max=1280` → JPEG (quality ~0.6) of the
   current screen via the existing `ScreenshotCaptureService`, downscaled,
   `Cache-Control: no-store`. Rate-limited (≥ 500 ms between frames per
   device). Clear JSON errors when disabled / permission missing.
2. Phone UI: a "Screen" tab/panel that polls the endpoint while visible
   (pauses when hidden), pinch-to-zoom/tap-to-enlarge, and an "Ask about this
   screen" composer that sends the message to a chosen agent **with computer
   use enabled** (list only such agents; explain if none). Show the agent's
   streamed reply and refresh the screenshot after each tool step completes.
3. Mac indicator while viewing (timeout ~5 s after the last frame).
4. Docs: Phone access section in `Resources/Guide/guide-settings.md` and
   `docs/MOBILE_PROTOCOL.md`.

## Tests

- Swift: trust predicate matrix (helper-verified owner ✓; loopback without
  marker ✗; relay ✗; API key ✗; setting off ✗), rate limiter, activity-log
  entry creation, indicator timeout logic.
- JS: polling lifecycle (visibility pause), agent filtering, refresh after
  tool steps (mocked fetch/stream).

Commit on your branch; write `fork/tasks/T13-phone-remote-screen.RESULT.md`
with a live checklist.
