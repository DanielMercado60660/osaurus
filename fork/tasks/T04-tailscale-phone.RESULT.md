# T04 — Phone access over Tailscale

Status: **PARTIAL — implementation and isolated checks complete; full build/live proof and commit blocked.**

## Source and environment

- Branch: `task/T04-tailscale-phone`; base HEAD: `5ecb0cbeee8306d295bbe77cf0309329ac5334a4`.
- Changes are **uncommitted**, not a tested release SHA. The exact 28-file implementation snapshot is recorded in `build/t04/source-manifest.sha256`; that manifest's SHA-256 is `d2f526eaecb4ad265fe90b8dcd639e16841929fbe645c1f7aa1cfbc82a08496c`. RESULT itself is excluded to avoid a circular hash.
- Existing vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`.
- Go 1.26.2, Apple Swift 6.4, macOS SDK 27.0. Helper dependency: `tailscale.com v1.94.2`, with `go.sum` checked into the proposed change.
- No model was loaded; model bundle, generation defaults, token/s, acoustic and inference scores are **not applicable/unproven**. No agent-loop implementation or sampling defaults were changed.
- Read worktree `AGENTS.md`. Its referenced `/Users/danielmercado/AGENTS.md` does not exist.
- No Tailscale process was brought up, no login was attempted, and no service/account authentication was performed. Network use was limited to Go/SwiftPM dependency resolution. No system software was installed; no push, remote change, branch switch, or other-worktree source edit was performed.

## Implemented files and behavior

- `helpers/osaurus-ts/{main.go,main_test.go,go.mod,go.sum}`: persistent userspace tsnet node named `osaurus-<short-hostname>`, NDJSON login/status/error events, certificate preflight plus HTTPS/HTTP fallback, MagicDNS/IP URL selection, reverse proxy to loopback, request-by-request WhoIs allowlist checks. An empty allowlist resolves to the node owner's login, and unknown ownership fails closed. Browser origin checks reject cross-site calls. Incoming credentials/forwarding headers and hop-by-hop capability-removal attempts are stripped before injecting the private launch capability. Parent stdin EOF or termination cancels the helper.
- `Services/PhoneAccess/PhoneAccessState.swift`: bounded status parsing, lifecycle state, and lock-protected launch-capability verification with a physical-loopback requirement.
- `Services/PhoneAccess/TailscalePhoneAccessService.swift`: default-off preferences, allowlist persistence, bundled helper SHA-256 verification, per-launch secret, process supervision, stale-output rejection, termination escalation, and serialized restart so two helpers cannot share node state concurrently. Uses the app's canonical support-data root (`OsaurusPaths.root()/phone-access`, normally `~/.osaurus/phone-access`, migrated from Application Support) with 0700 permissions. No runtime binary downloader or inherited Tailscale auth key.
- `Networking/ServerController.swift` and `AppDelegate.swift`: helper starts only when enabled and the local server has bound; stops on server stop/error, restart, and app termination.
- `Views/Settings/PhoneAccessSettingsCard.swift` and `ServerView.swift`: toggle, login link + QR, state/error, phone URL + QR, effective owner logins, editable allowlist and save. Search correctly selects Overview and scrolls to the card.
- `Models/Configuration/SettingsSearchIndex.swift`, `Tests/Configuration/SettingsSearchSelfFindProbe.swift`, `Resources/Guide/guide-settings.md`, `docs/MOBILE_PROTOCOL.md`: exact labels, matching anchors, inner navigation, distinction from Mobile pairing/public relay, and documentation.
- `Networking/HTTPHandler.swift` and `PhoneWebAssets.swift`: authenticated explicit `/phone` static routes; verified helper requests have owner trust, including when ordinary loopback trust is disabled. Physically-local-only configuration routes still exclude helper traffic. Static responses have CSP, nosniff and no-store; no arbitrary filesystem paths.
- `Resources/Phone/`: HTML/JS/CSS, manifest, 192/512 PNG icons and SVG, network-only service worker. Agent selection; streaming replies and successful-turn history; Stop; errors; safe basic Markdown; hold-to-talk transcription with review before Send; dark/light and iOS home-screen metadata. No CDN, frontend build step, cached chat data, or credentials in JavaScript. The server has `/audio/transcriptions` but no speech synthesis HTTP endpoint, so TTS playback is intentionally unavailable. HTTP fallback is text-only where browser secure-context rules prohibit recording/PWA installation.
- `Makefile`: `ts-helper` builds a local binary and SHA-256 sidecar; `app` embeds both in `Contents/Helpers`. Missing Go prints a clear skip message and app embedding removes stale copies. The digest is a local build pin intended to be sealed with the distributed app, not an independently published release digest.
- `Tests/PhoneAccess/PhoneAccessTests.swift`, `scripts/test-phone-access-isolated.sh`, `scripts/test-phone-web.mjs`: deterministic regression coverage and a reproducible dependency-light fallback lane.

Paths above without a prefix are under `Packages/OsaurusCore`, except helpers, Makefile, docs and scripts.

## Checks run

| Check | Result and evidence |
| --- | --- |
| `make ts-helper` | PASS; `build/osaurus-ts`, SHA-256 `46f427a8535de861905356750c074c22870a6ee88dbdede240a448a432c93245`; sidecar matches. `build/t04/go-build.log`. Binary was not started against a tailnet. |
| `go test ./...` in helper | PASS, 2/2 top-level tests; 9/9 named authorization subtests, plus two fail-closed configurations exercised inside the second test. `build/t04/go-test.log`. |
| `go test -race -v ./...` | PASS, same cases, no race reports. `build/t04/go-test-race.log`. |
| `go vet ./...` | PASS, no diagnostics. `build/t04/go-vet.log`. |
| `PATH=/usr/bin:/bin make ts-helper` | PASS missing-Go branch: explicit skip, exit 0. `build/t04/go-missing.log`. |
| `scripts/test-phone-access-isolated.sh` | PASS **12/12**: 5 PhoneAccessTests and 7 SettingsSearchSelfFindProbe tests. Production phone service, state, settings card, assets, catalog and search sources are copied unchanged; unrelated app integration types have explicit shims. This is type-check/unit evidence, not full app or UI proof. `build/t04/isolated-test.log`. Initial harness setup exposed missing shim types, which were added before the passing run. |
| `node --test scripts/test-phone-web.mjs` | PASS **7/7**: split UTF-8 streaming/history, truncated stream, HTTP errors, Stop, safe Markdown, new-chat reset, and hold-to-talk/transcript review. Uses a small DOM mock and mock fetch; no real browser/audio/model. `build/t04/phone-web-test.log`. |
| `node --check` on app and worker JS | PASS for both files. |
| `swiftc -frontend -parse` on changed HTTPHandler, ServerController, AppDelegate and ServerView | PASS syntax only. `build/t04/swift-parse.log`. Full type checking of these integration files remains blocked. |
| `git diff --check` | PASS. |
| `make -n app` with requested Xcode flags | PASS dry run, embedding commands present. `build/t04/make-app-dry-run.log`. This does not prove a built bundle. |

### Full build/test attempts — failed, not passing

1. `swift test --package-path Packages/OsaurusCore --filter 'PhoneAccessTests|SettingsSearchSelfFindProbe'` failed before tests with `sandbox-exec: sandbox_apply: Operation not permitted`. `build/t04/swift-test.log`.
2. Retried with `--disable-sandbox` as requested. It initially failed because the default Clang module cache was outside permitted write locations. `build/t04/swift-test-no-sandbox.log`.
3. Retried with `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` under this worktree. Source resolution succeeded; the run stalled on the Sparkle artifact and was interrupted after approximately four minutes. `build/t04/swift-test-cache.log`.
4. `swift build --disable-sandbox --package-path Packages/OsaurusCore` with the local caches completed dependency resolution and reached compilation, then failed compiling MLX Metal sources (exit 1, not the wrapper's 120-second timeout). `build/t04/swift-build-no-sandbox.log`.
5. Final filtered `swift test --disable-sandbox` with local caches failed at the same Metal dependency; **0 full-graph tests executed**. `build/t04/swift-test-final.log`.
6. Root cause confirmed by `xcrun metal --version`: `cannot execute tool 'metal' due to missing Metal Toolchain`. `build/t04/metal-version.log`. The suggested component download was **not** run because system software installation is forbidden.
7. Release `xcodebuild` was attempted with all requested flags: `-skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`. Both relative/absolute workspace attempts reported “is not a workspace file”; project fallback reached dependency resolution and failed `sandbox_apply`. Xcode additionally reported an installed CoreSimulator/framework version mismatch. Logs: `build/t04/xcodebuild.log`, `xcodebuild-absolute.log`, `xcodebuild-project.log`.

A fresh Release app was not produced or launched. Actual `make app` embedding/signing, Settings clicks/save/relaunch, real browser rendering, microphone permission/recording, model/tool completion, cancellation at runtime, and tailnet transport are **unproven**. The existing make-app sandbox-kernel downloader was not run under the module-only network constraint. Full model/eval lanes (including AgentLoop/AgentLoopFrontier) were not run; no scores are claimed for them.

## Commit blocker

Attempted normal `git add` on the implementation files. Git failed:

```
fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T04-tailscale-phone/index.lock': Operation not permitted
```

Evidence: `build/t04/git-add.log`. This worktree's Git metadata is outside the permitted write roots. There is no allowed approval escalation in this session. The requested commit therefore could not be created; changes remain unstaged in this worktree. No workaround modified another repository's metadata or branch. Once the environment permits this worktree's index/object/ref writes, stage the implementation and this RESULT file and commit on `task/T04-tailscale-phone` (do not push).

## How to try it after resolving build prerequisites

1. From this worktree, use the existing supported Xcode + Metal toolchain and Go. Run the full filtered Swift tests above and `make ts-helper`.
2. Build `make app XCODEBUILD_FLAGS='-skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='` in an environment where the existing app prerequisites are available. Ensure the final app signature seals the embedded binary and digest. Launch an isolated development app.
3. Open **Server → Overview → Phone access over Tailscale**. Enable **Phone access**. Only the human owner should press **Sign in to Tailscale** and complete the browser login.
4. With the phone already on the same tailnet, scan the phone URL QR. Choose an agent and send a message. For hold-to-talk, enable tailnet HTTPS certificates, prepare the Mac's transcription model, and grant browser microphone permission. Review the transcript before Send.
5. To admit additional owners, enter exact comma-separated Tailscale login names and press **Save allowed logins**. Empty restores the authenticating node owner's login. To stop exposure, disable **Phone access**; state is retained for reuse.

## Required manual/live checklist — not attempted

- [ ] Fresh isolated Release build; helper digest verified; final app signature valid; missing/tampered helper fails closed.
- [ ] Fresh preferences default off; no tsnet helper/listener before enabling; the app's ordinary server stays loopback unless independently configured otherwise.
- [ ] Search every new label from another Server tab; land on Overview, scroll/glow, toggle, edit/save, navigate away/back, and relaunch to verify persistence.
- [ ] Human login URL/button/QR works; node name is correct; persisted node reconnects after relaunch without re-login.
- [ ] Default owner phone can load `/phone`, list agents including the built-in agent, and run multi-turn streaming chat. Record model bundle, actual generation defaults, token/s, clean reasoning/tool boundaries and final completion.
- [ ] Non-allowlisted tailnet user and unknown/failed WhoIs get 403 on every asset/API request. Explicit additional login succeeds; removing it and saving immediately revokes access, including existing connections.
- [ ] Forged launch headers from a LAN connection, invalid/old launch secrets, cross-origin browser requests and hop-by-hop header nominations do not gain owner trust. Verify valid helper access with ordinary loopback trust both on and off; physically-local-only admin config remains inaccessible through the helper.
- [ ] HTTPS certificate issuance and MagicDNS URL work; missing certificates produce a working HTTP URL and visible secure-context limitation. MagicDNS-disabled tailnet uses an IP URL.
- [ ] iOS Safari light/dark, keyboard, safe-area layout, QR scan, Add to Home Screen/icons, reload, agent selection, long replies and Markdown are visually usable. No private chat is cached by the worker.
- [ ] Hold/release microphone in iOS Safari transcribes actual recorded audio; denied permission, unsupported context, failed transcription, and Stop unlock the composer; no audio tracks remain running. TTS is absent because there is no speech endpoint.
- [ ] A real tool turn completes with exact args/result grounding, a second tool call after history, settled cards/Stop/input and a follow-up turn. Grant only the newly exercised tool kind's first-use “Always Allow” in the isolated agent per AGENTS.md; verify persistence.
- [ ] Stop a streaming turn; interrupt network; retry; confirm correct visible error and no incomplete assistant turn inserted into history.
- [ ] Save allowlist repeatedly, change server port, restart server, disable during login/certificate acquisition/streaming, terminate/crash app, and verify no orphan helper, overlapping node-state owners, stale URL, or surviving launch capability. Unexpected helper exit must show failure and allow off/on retry.
- [ ] Run affected full regression/eval lanes and re-run this matrix on the final committed source before calling the feature release-ready.
