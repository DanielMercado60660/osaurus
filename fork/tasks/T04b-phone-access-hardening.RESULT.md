# T04b — Phone access security hardening

Status: **PARTIAL — F1–F6 implemented and isolated checks passed; commit blocked by sandbox; full app/live proof unverified.**

## Source and commit status

- Branch: `task/T04b-phone-access-hardening`.
- Unchanged base HEAD: `25d90003a785df62238ec8db73cee2c03389da8b`.
- The tested implementation is **uncommitted**, not a tested release SHA. Its 21-file source snapshot, excluding this RESULT, is recorded in `build/t04b/source-manifest.sha256`. Manifest SHA-256: `e291b4f5f814312a16425d94b912f03fcdf15b9174ef22dd270481f3959ac115`.
- `git add -A -- <implementation files>` and `git -c commit.gpgsign=false commit -m "Harden Tailscale phone access authorization and helper launch"` both failed with:

  ```text
  fatal: Unable to create '<repo>/.git/worktrees/T04b-phone-access-hardening/index.lock': Operation not permitted
  ```

  The working files remain in place, unstaged. No alternate metadata/index, branch, worktree, or permission workaround was used. Diagnostic recorded in `build/t04b/commit-failure.txt`. Once normal Git metadata access is available, stage these changes plus this RESULT and commit on this branch; do not push.
- vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`. Tailscale remains `v1.94.2`.
- No model was loaded; model bundle, generation defaults, token/s and inference/eval scores are not applicable to the isolated checks and remain unproven for live phone use.
- Read preamble, repository AGENTS, task spec and T04 RESULT. Referenced `~/AGENTS.md` is absent. No subagents, login, system software installation, public posting or push occurred. The only executed helper startup cases exited before tsnet initialization.

## Findings → implementation → evidence

| Finding | Implementation | Tests and limits |
| --- | --- | --- |
| **F1: DNS rebinding / CORS** | Helper builds an allowset from all certificate domains, Self DNS name, short MagicDNS name, and node IPv4/IPv6 addresses. Lowercases Host, strips port/brackets and canonicalizes IPs; unknown hosts receive 421 even when Origin matches the attacker host. Fetch metadata must be absent, `same-origin` or `none`; explicit empty, duplicate and unknown values fail closed. Existing login/origin checks and capability/header scrubbing remain. HTTPHandler returns no CORS headers for phone-marker requests, including when server origins contain `*`. | Go tests cover rebinding, all legitimate name/address forms, case, ports, IPv6, same-site/cross-site and malformed fetch metadata. Added full HTTP regression `phoneMarkerSuppressesCORSRegardlessOfConfiguredOrigins` for GET/OPTIONS against empty/wildcard/explicit origins. That integration test is syntax-checked but **not executed** here; full graph/live CORS proof pending. |
| **F2: per-device access** | Optional restriction flag plus selected WhoIs StableIDs; defaults off. Both login and device policies must pass. Restriction-on with no selection denies all. NDJSON device events contain StableID, name, login and allowed/denied state; successful admission is reported before long responses finish. Nodes lacking a login can be shown as denied but never login-authorized. Swift persists discoveries, selection and restriction flag. Settings list devices and save/restart the helper; explain every-device login trust and recommend a tailnet ACL. Catalog, anchors, self-find probes, guide and protocol updated. | Go device cases cover default all-devices, selected device, another device on same login, empty selection, no login, missing ID and disallowed login. Swift tests cover status parsing, deduplication, rename/status updates, preference reconstruction, empty restriction selection and disabling restrictions. Three new catalog labels pass self-find probes. Actual Settings clicks/save/relaunch and multi-device WhoIs proof pending. |
| **F3: helper integrity** | Reads the running app's signing identity with Security APIs. A team-signed app requires `SecStaticCodeCreateWithPath` / strict `SecStaticCodeCheckValidity` success and a matching helper Team ID. No-team development builds use a SHA-256 compiled into Swift, never a runtime sidecar. Refuses symlinks, non-executables and group/world-writable files. Validates again immediately before `Process.run()`. Build script signs helper before hashing; `make app` generates the pin before CLI/app compilation. | Six executable checker cases passed against the actual built Go binary: original accepted; group-write, world-write, symlink, tampering with matching replacement sidecar, and nil compiled pin rejected. Swift digest/unsafe-file tests passed. Real Team ID matching/mismatch and final signed app packaging remain **unverified**; no private signing key was accessed. Revalidation narrows but does not eliminate the path-to-exec race; it is the spec's immediate-revalidation option. |
| **F4: launch secret** | Swift writes the launch capability as stdin's first line after starting the child. Go accepts a bounded complete printable line, then retains the same buffered reader for parent EOF detection. Secret removed from child environment. | Go parser tests: valid, short, EOF without newline, empty, oversized, control and whitespace lines; preserves buffered remainder. Actual helper rejects an environment-only secret with an error status/nonzero exit before network startup. Parent lifetime behavior over a live tsnet session remains unverified. |
| **F5: transport/name/link clarity** | Corrects the header comment to acknowledge host UDP WireGuard socket. Calls `envknob.Setenv("TS_DISABLE_PORTMAPPER", "true")` before tsnet startup. Persists a random `osaurus-<6 hex>` name in mode-0600 `node-name` under the locked state directory. Markdown links display the parsed destination host, including port, via `textContent`; malformed URLs become text. | Verified knob support in cached v1.94.2 `net/portmapper/portmapper.go` (registration and disable branch) and `envknob/envknob.go` (`Setenv` refreshes registered values). Go name generation/persistence/permissions/corruption checks pass. Web tests cover visible destination host, misleading userinfo, malformed URLs and safe text rendering. Actual network port-mapping behavior and CT issuance were not exercised. |
| **F6: shared state lock** | Holds nonblocking exclusive `flock` on the opened state directory for the helper lifetime. A conflict returns exactly `another Osaurus instance is using phone access`; main emits an error event and exits nonzero. Lock closes after tsnet closes; no lock inode unlink. | Go contention/release/reacquisition passes. A real helper subprocess with the directory already locked emitted the exact error and exited nonzero without creating node state or starting tsnet. |

## Files

Paths are relative to this worktree:

- `helpers/osaurus-ts/main.go`, `main_test.go`: authorization, device events, stdin protocol, portmapper knob, private name and state lock.
- `Packages/OsaurusCore/Services/PhoneAccess/{PhoneAccessState,TailscalePhoneAccessService,PhoneAccessHelperIntegrity,PhoneAccessBuildPin}.swift`: device persistence/status, launch protocol and integrity validation.
- `Packages/OsaurusCore/Views/Settings/PhoneAccessSettingsCard.swift`, `Models/Configuration/SettingsSearchIndex.swift`, `Tests/Configuration/SettingsSearchSelfFindProbe.swift`: controls, anchors and catalog/probes.
- `Packages/OsaurusCore/Networking/HTTPHandler.swift`, `Tests/Networking/CORSHandlerTests.swift`: phone CORS suppression and integration regression.
- `Packages/OsaurusCore/Tests/PhoneAccess/PhoneAccessTests.swift`: isolated Swift regressions.
- `Packages/OsaurusCore/Resources/Phone/phone-app.js`, `scripts/test-phone-web.mjs`: visible link hosts and DOM regressions.
- `Makefile`, `scripts/build/build-ts-helper.sh`: pre-compilation helper build/sign/hash and sidecar removal.
- `scripts/test-phone-access-isolated.sh`: isolated lane now explicitly disables SwiftPM Keychain use and Git credential prompts.
- `scripts/test-phone-helper-integrity.sh`, `scripts/test-phone-helper-startup.py`: reproducible binary-level negative checks, without a tailnet login.
- `Packages/OsaurusCore/Resources/Guide/guide-settings.md`, `docs/MOBILE_PROTOCOL.md`: settings, trust and build behavior.

## Verification commands and counts

Run from worktree root unless noted. Raw evidence is gitignored under `build/t04b/`; hashes are in `build/t04b/evidence-manifest.sha256`.

| Exact command | Result | Evidence |
| --- | --- | --- |
| `go test -race -v ./...` (cwd `helpers/osaurus-ts`) | PASS: **8/8 top-level tests, 41/41 named subtests**, no race diagnostics. Additional table assertions are inside those tests. | `go-race.log` |
| `go vet ./...` (same cwd) | PASS, exit 0, no diagnostics. | `go-vet.log` |
| `scripts/test-phone-access-isolated.sh` | PASS: **16/16 tests** (9 phone access, 7 catalog/search). Copies unchanged production service/state/integrity/card/catalog sources; unrelated app types are shimmed. Full app integration is not implied. | `swift.log`; isolated package under `build/t04/isolated/` |
| `node --test scripts/test-phone-web.mjs` | PASS: **8/8 tests**, mock DOM/fetch/audio; no browser/model. | `web.log` |
| `scripts/test-phone-helper-integrity.sh` | PASS: **6/6 checks** with actual helper bytes and native Security/CryptoKit calls. Builds the helper, compiles the checker and restores the prior pin source on exit. | `integrity.log`, `integrity/` |
| `python3 scripts/test-phone-helper-startup.py` | PASS: **2/2 negative startup checks**, actual binary, no tsnet startup. | `startup.log` |
| `make ts-helper` | PASS; Go build, ad-hoc signing, compiled Swift pin generation. Generated digest matches helper bytes. Helper SHA-256: `e2f8a782d68cdb37ecbee212492c92e660597bb49969ec4e470d963d4b4f8309`. | `helper-build.log`, `helper.sha256` |
| `PATH=/usr/bin:/bin make ts-helper` | PASS, explicit missing-Go message and nil development pin; stale helper removed. Normal helper build restored afterward. | `no-go.log` |
| `swiftc -frontend -parse Packages/OsaurusCore/Networking/HTTPHandler.swift Packages/OsaurusCore/Tests/Networking/CORSHandlerTests.swift` | PASS syntax only. | `swift-parse.log` |
| `node --check Packages/OsaurusCore/Resources/Phone/phone-app.js` | PASS. | Exit 0 |
| `bash -n scripts/build/build-ts-helper.sh scripts/test-phone-access-isolated.sh scripts/test-phone-helper-integrity.sh` | PASS. | Exit 0 |
| `make -n app` | PASS dry run: helper/pin generation precedes CLI/app compilation, embeds binary without sidecar. Does not prove an app build. | `app-dry-run.log` |
| `git diff --check` | PASS before commit attempt. | Exit 0 |

One intermediate Swift compilation failed because `SecCodeCopySigningInformation` requires `SecStaticCode`, not `SecCode`. Corrected by using `SecCodeCopyStaticCode`; final Swift and executable integrity checks passed. Initial diagnostic retained in `build/t04b/swift-initial-error.log`.

The checked-in/default `PhoneAccessBuildPin.swift` is restored to **nil** in this source snapshot, rather than storing an architecture-specific local build digest. `make ts-helper` intentionally rewrites this source before compilation. The generated source must be compiled with the matching helper; do not replace or re-sign a development helper after compiling its digest. The nil value fails closed if that preparation is skipped. The isolated Swift suite was rerun with the final nil-default source.

## How to try and complete live proof outside the sandbox

1. Use this worktree and a supported Xcode/Metal toolchain. Follow `CODEX_PREAMBLE.md` credential rules: set `GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=` and pass `--disable-keychain` to SwiftPM commands.
2. Run the commands above. Run the full filtered core tests, including `PhoneAccessTests`, `SettingsSearchSelfFindProbe` and `CORSHandlerTests`, with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a fresh `OSAURUS_TEST_ROOT`, and an empty `OSU_MODELS_DIR`.
3. Build an isolated development app with `make app` and the established development signing flags. This now builds/hashes the helper before compiling Swift. For team-signed distribution, explicitly set `TS_HELPER_SIGN_IDENTITY` to the app's signing identity and seal the final app bundle after embedding; test matching and mismatching teams.
4. Open **Server → Overview → Phone access over Tailscale**. Search all three new labels and verify navigation/highlighting. Let the human owner complete login if needed. Verify the random persisted name and phone URL.
5. Open the URL on two devices of the same allowed login and on a disallowed login. Confirm device names/StableIDs and latest outcomes appear. Enable **Restrict access to selected devices**, select only one, and **Save device restrictions**. Verify only that selected device can make fresh requests; selecting a device never admits a disallowed login. Save an empty selection to deny all; turn restrictions off and save to restore per-login device access.
6. Navigate away/back and relaunch; confirm settings/discovery persistence and effective runtime policy. Exercise existing streams during saves/restarts, and verify revocation closes them. Test rebinding Host, fetch metadata and CORS on actual HTTP fallback and HTTPS paths.
7. Verify Markdown destination-host labels in Safari, live multi-turn chat/tool completion and Stop, helper EOF shutdown, and a second app instance's lock failure. Preserve model/defaults/token/s and all required UI evidence before making release-readiness claims.

## Unverified / not claimed

Per the task preamble, full app/SwiftPM MLX builds were not retried in this sandbox; they are assigned to the outside-sandbox build lane. No fresh Release app was built or launched. Full core/HTTP CORS integration tests, live Settings controls/save/relaunch, team-signed identity cases, macOS app embedding/signing, real WhoIs/tailnet/HTTPS/HTTP transport, shutdown during live streams, actual UDP mapping, CT naming and iOS rendering remain unverified. No AgentLoop/AgentLoopFrontier or model eval scores are claimed. Implementation and isolated evidence do **not** establish release readiness. The requested commit is also blocked as documented above.
