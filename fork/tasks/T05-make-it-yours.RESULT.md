# T05 — Make it yours

Status: **PARTIAL — implementation committed and isolated checks pass; full-app build and live UI/runtime proof remain BLOCKED in this sandbox.**

Implementation commit: `0b50bbbd608129192b0c967096eca6f7e79555ca` on `task/T05-make-it-yours`.
Base: `a5f44656ef7e848c52c4dcaccd3bdc980192a24f`.
This RESULT is a separate documentation commit; no implementation changed after the checks.
vMLX pin remains `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
No live model bundle or generation defaults were exercised. Model/eval scores, token/s, physical footprint, and acoustic latency are **not measured**.

## Built

- A post-onboarding **Make it yours** card in local empty chats, including while the initial chat model is downloading. Remote-agent empty states do not offer local setup. Visibility is derived from onboarding state, persistent dismissal, and current prerequisites, rather than separate completion flags.
- **Talk to it** requests microphone permission on click, merges the clicked agent into the existing talk configuration, and starts the existing Parakeet and PocketTTS preparation paths. The shared coordinator and existing managers survive leaving/dismissing the card. Repeated download requests are deduplicated by the managers. Selected Parakeet version, TTS provider/voice, other enabled agents, and other talk settings are preserved. New installs already default to on-device PocketTTS. Setup does not start capture or a chat turn.
- Talk shows **⌃⌥⌘T**, per-model preparation status, and combined progress when measurable. Parakeet currently exposes no intermediate progress, so preparation is indeterminate while Parakeet runs; after it completes, PocketTTS progress contributes to an equal-weight two-model progress bar. Compilation is indeterminate too. No invented byte percentage. Model errors retain their underlying message; permission denial explains recovery; persistence failures show the real write error. The same primary button retries.
- **Show your companion** writes the existing avatar preference and applies the floating overlay immediately. **Reach it from your phone** resolves `server.phoneAccess` from the settings catalog, selects its Overview destination, requests the matching landing highlight, and opens Management. It never enables the phone service or starts login. Phone completion requires the actual service to be running; starting, login-needed, and failure states remain visible.
- **Not now** persists globally in UserDefaults. **Conversation → Appearance → Show Make it yours** restores the card. This new setting has its exact catalog title, matching anchor, guide entry, and self-find probe. Card shortcuts reuse existing settings IDs; their exact action labels are searchable aliases, with probes for every label. Existing destination titles remain unchanged.
- Notification categories/delegate are still configured at launch. Authorization is gated by a pure policy and attempted once per process, after onboarding is complete. The first-run call occurs in AppDelegate after the onboarding window closes, including its farewell animation. Previously completed users retain the launch-time request. No onboarding step or model recommendation changed.
- Talk Mode's open settings editor now refreshes on configuration notifications, so enabling an agent from another chat window is not overwritten by its next edit. The configuration store exposes a throwing save for inline setup errors while preserving its existing toast-based API.

## Files

Paths below are relative to `Packages/OsaurusCore/` unless marked otherwise.

New:

- `Services/Setup/MakeItYoursState.swift` — pure readiness/progress/visibility and dismissal preference key.
- `Services/Setup/MakeItYoursSetup.swift` — shared click-time permission/configuration/download coordination.
- `Services/Setup/NotificationAuthorizationPolicy.swift` — pure notification deferral decision.
- `Views/Chat/MakeItYoursCard.swift` — three status/action rows and catalog-driven phone navigation.
- `Tests/Setup/MakeItYoursStateTests.swift` — state, progress, failure/retry, current-agent, dismissal, and notification policy coverage.
- `scripts/test-make-it-yours-isolated.sh` (repo-relative) — reproducible dependency-free unit/type-check harness.

Updated:

- `Views/Chat/ChatEmptyState.swift` — mounts the card for local chats.
- `Views/Settings/ChatSettingsView.swift` — restore/visibility toggle.
- `Views/Voice/TalkModeSettingsTab.swift` — external configuration refresh.
- `Models/Voice/TalkModeConfigurationStore.swift` — throwing save path.
- `Services/NotificationService.swift`, `AppDelegate.swift` — deferred authorization.
- `Models/Configuration/SettingsSearchIndex.swift`, `Tests/Configuration/SettingsSearchSelfFindProbe.swift`, `Resources/Guide/guide-settings.md` — catalog, aliases, probes, and usage documentation.

## Verification

1. **PASS: 19/19 tests in 3 suites, 0 failures.**

   ```sh
   scripts/test-make-it-yours-isolated.sh > build/T05/isolated.log 2>&1
   ```

   Ten card-state tests, two notification-policy tests (one has two cases), and seven existing settings self-find tests. Production setup state, coordinator, card, configuration/store, and catalog/search sources are copied unchanged. Unrelated app services are explicitly inert shims. This type-checks the new card/coordinator and proves the pure decisions/search behavior; it does **not** prove real permissions, downloads, audio, or app integration. Dismissal testing uses a unique UserDefaults suite and removes its domain afterward; it is not a live-app relaunch test.

   The script sets credential suppression, keychain-disabled mode, empty model/test roots, and module caches under `build/T05`. Its exact Swift invocation is:

   ```sh
   swift test --disable-keychain --disable-sandbox --package-path "$PWD/build/T05/isolated" \
     --cache-path "$PWD/build/T05/swiftpm-cache" \
     --config-path "$PWD/build/T05/swiftpm-config" \
     --security-path "$PWD/build/T05/swiftpm-security" --jobs 4
   ```

2. **PASS: 45/45 tests in 9 suites, 0 failures**, including type-checking the changed Talk Mode settings editor/store against the existing T03 shims:

   ```sh
   python3 fork/tasks/T03-talk-mode.verify.py --run > build/T05/talk-regression-command.log 2>&1
   ```

   Raw test log: `build/t03-proof/isolated.log`. This is the existing reducer/stream/chunker/processor/configuration/catalog harness, not a full app or acoustic test. Its seven catalog tests overlap the first lane; the two counts are not 64 distinct tests. The script's exact command (with its isolated credential/cache environment) is:

   ```sh
   swift test --disable-keychain --disable-sandbox --build-system native \
     --package-path "$PWD/build/t03-harness" --cache-path "$PWD/build/swiftpm-cache" \
     --config-path "$PWD/build/swiftpm-config" --security-path "$PWD/build/swiftpm-security" --jobs 4
   ```

3. **PASS:** `swiftc -frontend -parse` on all **13 touched Swift files** (file list in `build/T05/parse.log`); `bash -n scripts/test-make-it-yours-isolated.sh`; `git diff --check` and `git diff --cached --check`. Reproduce parsing against the implementation commit with:

   ```sh
   swiftc -frontend -parse $(git diff-tree --no-commit-id --name-only -r \
     0b50bbbd608129192b0c967096eca6f7e79555ca | rg '\.swift$')
   ```

4. **BLOCKED: integrated focused tests, exit 1; 0 tests executed.**

   ```sh
   export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
   export OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$PWD/build/T05/test-root"
   export OSU_MODELS_DIR="$PWD/build/T05/test-models"
   export CLANG_MODULE_CACHE_PATH="$PWD/build/T05/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/T05/module-cache"
   swift test --disable-keychain --package-path Packages/OsaurusCore \
     --filter 'MakeItYours|NotificationAuthorizationPolicy|SettingsSearchSelfFindProbe' \
     > build/T05/integrated.log 2>&1
   ```

   Manifest evaluation failed: `sandbox-exec: sandbox_apply: Operation not permitted`. Per the task preamble, no prolonged full-graph workaround was attempted.

5. **BLOCKED: fresh Release build, exit 66; no app built or launched.** With the credential-suppression environment above:

   ```sh
   xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Release \
     -derivedDataPath build/T05/ReleaseDerivedData -skipPackagePluginValidation \
     -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
     build -quiet > build/T05/release-build.log 2>&1
   ```

   Xcode reported `'osaurus.xcworkspace' is not a workspace file` before app compilation. No system software installation or login was attempted.

## How to try / outstanding live proof

Build this commit outside the sandbox using the normal isolated Release app lane. With fresh app preferences, complete the unchanged welcome/create-agent/configure-AI flow. Confirm no notification prompt appears over those steps or the farewell animation; confirm the prompt occurs after the window closes. Also check an already-completed user at launch and an onboarding version upgrade.

In an empty local chat, click each card action. For Talk, grant microphone permission, observe real downloads and errors/retry, and verify cached models are reused. Switch agents while permission is pending: only the clicked agent should become enabled. Leave/reopen chat and dismiss the card during downloads. Open Talk Mode settings beforehand, enable an agent from chat, then edit another setting and verify the enabled-agent list survives navigation and relaunch. Test permission denial/recovery, download failure, and configuration-write failure.

Once preparation completes, use ⌃⌥⌘T or the talk button for real multi-turn speech, clean reasoning/tool completion, Stop/input unlock, and a follow-up. Check configured microphone/input source, provider/voice overrides, silence/echo/barge-in settings, model loading/cancellation, and ordinary voice controls. The card prepares software prerequisites; it cannot prove microphone hardware, remote-provider reachability, or a working conversation from cached-file/readiness state.

Verify the companion appears, can be disabled again through its existing setting, and persists on relaunch. Click phone setup from another Management tab and verify Overview scroll/glow without silently enabling access. Complete the Tailscale login manually, then verify the card's starting/login/error/running states and an actual phone conversation. Check Not now across windows/relaunch, restore via Show Make it yours, and automatic hiding when all three rows are ready. Search every new action/setting label and visually check narrow-window layout and accessibility.

These live UI/persistence/audio/phone rows, the under-one-minute clicking target, and full OsaurusEvals lanes are **unverified**. No AgentLoop/AgentLoopFrontier or model-runtime score is claimed. A fresh full build, full regression/eval requirements, and the applicable live matrix remain required before release readiness.

## Evidence and commit notes

All raw artifacts are local and ignored; no screenshots were added to Git.

| Artifact | SHA-256 |
| --- | --- |
| `build/T05/isolated.log` | `7169ff5d831a0428fc054d26c4e5ef0fd0a9564fa815df56adf4e63a201a3157` |
| `build/t03-proof/isolated.log` | `982a1597dd781c08275dcbe5f22965b5c8c400272088dd95c1552510ea59d931` |
| `build/T05/integrated.log` | `ed311673f7b8c0cd2001095e77b19256fe4812d04bbbbcc79af581d2e1f57ade` |
| `build/T05/release-build.log` | `95413d4f83341fc722a50f543bf8b1db51ea60b4917350ddd9e35bebadc3fa9b` |
| `build/T05/parse.log` | `69185ae4d30e0ffd0a68c0d2ee56926533ba3e9364e834c8c979138f994f8925` |

An initial path-specific staging command hit an index-lock sandbox denial; plain `git add -A` and `git commit` succeeded. No push, branch switch, remote change, dependency addition, other-worktree source edit, helper agent, or keychain prompt. The referenced `~/AGENTS.md` was absent; repository AGENTS, preamble, spec, and T02–T04 RESULT files were read.
