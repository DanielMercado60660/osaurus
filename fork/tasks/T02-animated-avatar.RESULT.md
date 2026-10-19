# T02 — Animated agent avatar

Status: **PARTIAL implementation / BLOCKED full-app validation and commit**.

Branch: `task/T02-animated-avatar`.
Base source SHA: `d901d09e4078b4aec81a714be81b7b67e8d86d68`.
The working-tree changes are the tested source; `build/T02/source-sha256.txt`
records their hashes. vMLX remains pinned to
`f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`. No model was loaded and no
inference/generation-default, token/s, or model-runtime claims are made.

## Implemented and how to enable

Open **Settings → Conversation → Appearance → Show animated avatar** (off by
default). The setting applies immediately, restores at app launch, enables the
floating companion, and swaps empty-chat heroes to the animated character.
Disabling it restores the existing static/custom avatar path. Drag the panel to
move it; click it to focus the last active agent chat (or create that agent's
chat when none is open). Position uses native window frame persistence and
recovers if a saved display is disconnected.

The procedural dinosaur has a muzzle, dorsal plates, tail, tiny arms, belly,
randomized blinks, breathing, listening ring, upward thinking gaze/orbiting
dots, level-driven jaw/mouth, and an error pose. It uses `AgentMascot.color`
(the actual property name in this checkout, rather than the spec's `tint`).
The renderer protocol consumes only mood, color, time and Reduce Motion.

State precedence is speaking > listening > thinking > error > idle, with
elapsed-time exponential attack/release smoothing. Thinking reads the active
window's session and stops at the current user turn's first visible answer;
previous replies cannot suppress a new thinking pose. The sampler never
starts recording or TTS. The panel follows the last focused window, and local
empty states resolve their own hosting window. Remote empty states use an idle
pose because remote host audio is unavailable.

Animation is requested at 30 fps while speaking, 10 fps otherwise. Reduce
Motion pauses the timeline while retaining a simple level-driven mouth.
Window occlusion/minimization and view removal stop sampling and animation;
hiding the panel destroys its hosting view. Mouse tracking was optional and is
not implemented.

**T01 integration remains intentionally pending:**
`DefaultAvatarAudioLevelSource.outputLevel` returns zero with the one-line
`TODO(T01)` for `TTSService.shared.outputLevel`. Playback state already reads
`playingMessageId`. No fake lip-sync amplitude is generated. Actual audio lip
sync is not claimed before T01 merges.

## Files

Added (relative to `Packages/OsaurusCore/`):

- `Services/Avatar/AvatarMood.swift` — inputs, mood, pure reducer.
- `Services/Avatar/AvatarStateModel.swift` — injectable audio adapter and live source projection.
- `Services/Avatar/AvatarOverlayWindowService.swift` — panel, preference, click/drag and saved position.
- `Views/Agent/AnimatedAgentAvatarView.swift` — Canvas renderer, timeline, renderer seam, cycling five-mood preview.
- `Views/Agent/LiveAgentAvatarView.swift` — cancellable sampling and narrow AppKit visibility bridge.
- `Tests/Avatar/AvatarMoodReducerTests.swift` — seven tests for precedence, smoothing, transitions, invalid values and model injection.

Changed:

- `AppDelegate.swift` — restore the optional overlay at startup.
- `Views/Chat/ChatEmptyState.swift` — conditional animated heroes, static fallback.
- `Views/Settings/ChatSettingsView.swift` — toggle and matching landing anchor.
- `Models/Configuration/SettingsSearchIndex.swift` — exact UI title, aliases, path and disambiguation.
- `Resources/Guide/guide-settings.md` — setting path, behavior and pending T01 integration.
- `Tests/Configuration/SettingsSearchSelfFindProbe.swift` — exact on-screen label.
- `fork/tasks/T02-animated-avatar.RESULT.md` — this report (repo-relative).

No edits to `TTSService.swift`, `SpeechService.swift`, `ChatView.swift`, package
manifests, dependency pins, remotes, other branches or other worktrees. No push,
software installation, external agent, or model service was used. Network use
was limited to resolving existing SwiftPM dependencies/artifacts. The referenced
`~/AGENTS.md` was absent; repository `AGENTS.md` and the task spec were read.

## Validation commands and results

All logs and temporary proof artifacts are under ignored `build/T02/`; no
screenshots were added to Git. Test roots were placed under this worktree
instead of `/tmp/osaurus-test*` to honor the worktree-only write constraint.

Environment for full-package test attempts:

```sh
export OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1
export OSAURUS_TEST_ROOT="$PWD/build/T02/test-root"
export OSU_MODELS_DIR="$PWD/build/T02/test-models"
```

1. `swift test --package-path Packages/OsaurusCore --filter Avatar`
   failed before tests: `sandbox-exec: sandbox_apply: Operation not permitted`.
   **0 tests executed** (`swift-test-avatar.log`).
2. Retried with `--disable-sandbox`; manifest compilation encountered a protected
   system Clang module-cache path. **0 tests executed**
   (`swift-test-avatar-no-sandbox.log`).
3. Redirected both `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE`
   to `$PWD/build/T02/module-cache`, and used `--cache-path
   "$PWD/build/T02/spm-cache"`. Source resolution succeeded, but Foundation
   artifact downloads stalled; two attempts were interrupted (exit 130) before
   retrying with exact cached artifacts (`swift-test-avatar-local-cache.log`,
   `swift-test-final-retry.log`). Existing Sentry 9.15.0 archives were copied
   read-only from the user's package cache into this worktree. Sparkle 2.9.2
   was fetched from its exact SwiftPM manifest URL using `curl --location
   --fail --max-time 45`; SHA-256 matched the manifest:
   `b83e37436774556ed055e0244b297ef2c790e0737393bf65bf495fcbba6eed65`.
   No dependency version was changed.
4. Final full-package retry:

   ```sh
   CLANG_MODULE_CACHE_PATH="$PWD/build/T02/module-cache" \
   SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/T02/module-cache" \
   swift test --disable-sandbox --cache-path "$PWD/build/T02/spm-cache" \
     --package-path Packages/OsaurusCore -Xswiftc -disable-sandbox \
     --filter 'Avatar|SettingsSearchSelfFindProbe'
   ```

   **FAILED, 0 tests executed** (`swift-test-resolved.log`, exit 1). Dependencies
   resolved and the build reached MLX Metal kernels, then `CompileMetalFile`
   failed for `steel_attention.metal` and `searchsorted.metal`. Direct diagnosis
   with `xcrun metal --version` reports: **missing Metal Toolchain**
   (`metal-version.log`). Installing it is outside the user's authorization.
5. The separate settings probe command using `--filter
   SettingsSearchSelfFindProbe --scratch-path "$PWD/build/T02/settings-build"`
   also failed at dependency manifest module-cache permissions before tests
   (`swift-test-settings.log`). The corrected combined retry in step 4 includes
   both requested filters.
6. Required app command:

   ```sh
   xcodebuild -workspace osaurus.xcworkspace -scheme osaurus \
     -configuration Debug -derivedDataPath build/DerivedData \
     -skipPackagePluginValidation -skipMacroValidation build -quiet
   ```

   **FAILED** (exit 66, `xcodebuild-debug.log`): Xcode reported the workspace was
   not a workspace file, with filesystem-event and outdated CoreSimulator
   diagnostics. An absolute-path retry reproduced it. A project-based fallback
   reached package resolution but failed on `sandbox_apply`
   (`xcodebuild-project.log`, exit 74). Follow-up option experiments were
   rejected by xcodebuild (exit 64); these are retained in
   `xcodebuild-no-manifest-sandbox.log` and `xcodebuild-final-retry.log`.
   A final valid project retry with `XBS_DISABLE_SANDBOXED_BUILDS=YES`,
   worktree-local cache paths, and `-clonedSourcePackagesDirPath` also failed
   on manifest `sandbox_apply` (exit 74, `xcodebuild-project-final.log`).
   Every xcodebuild invocation included both required skip-validation flags.
7. **Isolated fallback proof: 14/14 tests pass, 0 failures**
   (`focused-proof-final.log`): seven new Avatar reducer/model tests and all
   seven existing settings self-find tests, including the new control label.

   ```sh
   CLANG_MODULE_CACHE_PATH="$PWD/build/T02/module-cache" \
   SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/T02/module-cache" \
   swift test --disable-sandbox --package-path build/T02/FocusedProof \
     -Xswiftc -disable-sandbox
   ```

   This temporary, dependency-free package copies the actual avatar sources,
   test files, settings index, search matcher, ManagementTab and AppleApp.
   Unrelated app/service types are stubbed; localization returns English keys.
   It proves the reducer, catalog search and new-source compilation, **not
   Osaurus integration or the full Avatar-filter suite**. Swift 6 type-checking
   also passed with those stubs. An initial actor-isolated default argument
   error was fixed before the final rerun. Full source and test copies remain
   in `build/T02/FocusedProof` for inspection.
8. Rendered the actual Canvas renderer in all five moods using `ImageRenderer`;
   visually inspected `build/T02/avatar-moods.png`. This is offscreen visual
   evidence, not live app evidence. `git diff --check` passed.

## CPU measurement and remaining live proof

**Visible-idle CPU: BLOCKED / not established.** An optimized isolated probe
hosted the actual `LiveAgentAvatarView` in a 180×190 floating NSPanel, with
stubbed app services and `getrusage(RUSAGE_SELF)` snapshots after warm-up. It
attempted a 15-second visible interval and a 15-second hidden interval.
`cpu-proof.log` records GUI-service connection errors and
`visible=true occlusionVisible=false`; therefore the purported visible interval
was actually occluded/paused. Its 0.000355 CPU seconds over 15.981 seconds and
hidden 0.000165 CPU seconds over 15 seconds **must not be used as visible-panel
CPU performance evidence**. A `ps` measurement attempt was sandbox-denied.
The probe exited cleanly. No negligible-visible-CPU claim is made.

A fresh full Release app, settings click/search landing, toggle on/off,
navigation away/back, relaunch persistence, panel drag/click, real microphone
and TTS states, and complete/follow-up chat turns remain unverified because the
full build and GUI proof environment are blocked. No AgentLoop or model eval
was run; this change reads presentation state and does not alter those loops.
The actual playback meter needs T01, as explicitly required by the spec.

## Commit

**BLOCKED.** Staging the task files failed:

```
fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T02-animated-avatar/index.lock': Operation not permitted
```

The linked worktree's Git metadata is outside the sandbox's writable roots.
Staging the RESULT and `git commit -m "Add optional animated agent avatar and
floating companion"` both reproduced the same lock error (`git-result-stage.log`,
`git-commit.log`). **No commit was created.** No index redirection, alternate
repository, remote change, or other-worktree write was attempted. Changes remain in this worktree on the original branch.
