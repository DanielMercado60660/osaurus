# T14 — Phone model picker

Status: implementation complete; **PARTIAL verification**. Automated phone DOM/protocol checks pass. No live app or browser proof is claimed.

## Built

- The selected agent's effective model (falling back to its default when the effective field is absent) appears below the agent picker. Tap it to open a native modal dialog.
- The dialog fetches `GET /models/picker` without caching, groups by `tab_title`, and preserves host order with favorites first within each group. Unavailable bundles are disabled with a generic host-availability reason (the current DTO supplies no detailed reason). Image models are also disabled because `/run` only supports chat.
- Selection sends `PUT /agents/{id}/model` and uses the returned `effective_model`. Save errors remain visible and retryable. A 404 closes the dialog and hides model controls for that agent for the page session; editable built-ins are not excluded preemptively.
- HTTP or in-band SSE no-model failures show an inline Choose a model action. After saving, Resend last message explicitly retries the same user message with successful history, without adding duplicate user bubbles or automatically starting a run. Other failures before any visible answer remove the empty assistant bubble while retaining the error in status.
- New chat, agent changes, and newer messages invalidate old retries. Late catalog responses cannot reopen or repopulate a closed dialog. Saving blocks competing selection/navigation; Escape/Close work when not saving.
- Native buttons/dialog, accessible names, status announcements, focus indication/return, wrapping text, bounded dialog width/height, and existing light/dark variables are used. No libraries, inline scripts, inline event attributes, or new asset routes were added.

## Files

- `Packages/OsaurusCore/Resources/Phone/phone-app.js`: picker, model save, failure recovery and retry lifecycle.
- `Packages/OsaurusCore/Resources/Phone/phone-index.html`: model control and labeled dialog.
- `Packages/OsaurusCore/Resources/Phone/phone-style.css`: picker layout, wrapping and focus styling.
- `Packages/OsaurusCore/Resources/Guide/guide-settings.md`: phone model selection/retry instructions. This edits the existing agent default through the existing endpoint, without introducing a new persisted setting or changing Mac Management labels/navigation.
- `scripts/test-phone-web.mjs`: DOM mock extensions and 13 added regression tests.

## Verified

Base checkout: `69544adbc376ec38299df30a9e03a49480e9125f`, branch `task/T14-phone-model-picker`.

Commands:

```sh
node --test scripts/test-phone-web.mjs
node --check Packages/OsaurusCore/Resources/Phone/phone-app.js
git diff --check
```

Results: **58/58 tests pass**, 0 failures, 0 skipped (45 existing + 13 new); syntax and whitespace checks exit 0. Tests cover grouping/stable favorite order, disabled choices, current model and authoritative save result, HTTP/SSE recovery, explicit resend/history, 404 hiding, editable built-ins, catalog/save errors, stale requests/actions, cancellation, empty effective models, and Chat/Screen selection. All fetches are mocked; no models, account access, or Keychain operations were used.

Raw output: `build/T14-phone-model-picker/phone-web-tests.log` (local, gitignored).

Tested source SHA-256:

```text
36b14bb1adfd958f1483e0c831f1ee9614b88000f6d1f17c70ec0bfd63d27e56  phone-app.js
49549df56ce6e66bebcc1693db4cb16751d5b725d5019bc420a413b0a9f96d54  phone-index.html
8f4092bbeaee5098e3896b543eceda42189692dbb24b908c10860b5f08013322  phone-style.css
495c6ec93a3035a1b21924896bc7d72eed3fcacadb93b82d833d1e78b949d015  scripts/test-phone-web.mjs
```

## Try / outstanding proof

1. Build the branch outside this sandbox as directed by `CODEX_PREAMBLE.md`, enable Phone access in an isolated profile, and open `/phone`.
2. Select an agent without a default model and send a message. Choose a model from its inline recovery action, verify group/favorite order and disabled explanations, then tap Resend last message. Verify a completed reply, unlocked composer, and a follow-up turn with history.
3. Change the model using the header control; navigate between agents and Chat/Screen. Reload the phone and relaunch the Mac app to verify server persistence and actual runtime selection. Exercise a built-in that returns 404 and confirm its control disappears; also exercise the editable Orchestrator.
4. Check at 320 px in light/dark mode, including long model/provider names, touch scrolling, VoiceOver, keyboard focus trapping, Escape, and focus return. Test live catalog/save errors and Stop before a reply.

Not verified: rendered 320 px layout, actual native dialog behavior/accessibility, browser CSP enforcement, real Tailscale/API integration, app persistence/relaunch, model generation/token rate, or full app/Swift/eval lanes. Computer-use browser discovery returned `No browser is available`; local Playwright/Puppeteer were unavailable. Full app builds and Swift tests were deferred per the task preamble's documented sandbox limitations. The referenced `~/AGENTS.md` was absent. These checks are necessary before release proof; source and mocked tests alone do not establish it.

## Commit blocked by sandbox

Attempted to stage the six changed files and run:

```sh
git commit -m "Add phone model picker and no-model retry recovery"
```

Both `git add` and `git commit` failed with exit 128:

```text
fatal: Unable to create '<repo>/.git/worktrees/T14-phone-model-picker/index.lock': Operation not permitted
```

The shared worktree Git metadata lies outside this task's writable roots. No commit was created, no other branches/worktrees/remotes were changed, and all six files remain in this worktree for the host-side commit. Approval escalation is unavailable in this session.
