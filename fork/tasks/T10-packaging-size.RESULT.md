# T10 — Packaging and size

Status: **PARTIAL — implementation and isolated checks complete; commit blocked
by filesystem permissions; actual app archive/DMG and live proof unverified.**

## Source and commit

- Branch: `task/T10-packaging-size`.
- Unchanged HEAD: `a9042aab33ed5d35b88b6ab9e04c3088106dc48d`.
- No commit was created. Both staging and committing failed with:

  ```text
  fatal: Unable to create '/Users/danielmercado/osaurus-fork/.git/worktrees/T10-packaging-size/index.lock': Operation not permitted
  ```

- Changes remain unstaged in this worktree. No alternate index, metadata path,
  worktree, branch, permission workaround, or push was used.
- Tested implementation snapshot: 14 paths, including the deleted generated
  Swift file, in `build/t10/source-manifest.sha256` (excludes this RESULT).
  Manifest SHA-256:
  `1780ac12061eea4533509c6a06d12caace810d05f15e64f674773d3786fb3b0a`.
- Read preamble, AGENTS, spec, LOG baseline, Makefile, upstream archive script,
  helper builder and T04b RESULT. Referenced `~/AGENTS.md` is absent. No agents,
  logins, system installations or private-key signing were used.

## Built

1. `make fork-dmg` invokes the independent `scripts/build/build-fork-dmg.sh`
   lane. It builds arm64 Release CLI/plugin host, archives the app with install
   stripping, embeds all three helpers, stages the sandbox kernel through the
   existing verified fetcher, signs inside-out, verifies the bundle, creates a
   UDZO DMG with an Applications shortcut, signs/verifies the image, and reports
   component and image sizes. It defaults to ad-hoc signing; an explicit
   `CODESIGN_IDENTITY` selects Developer ID. Hardened runtime and the existing
   app entitlements are applied to the app, CLI and plugin host. Frameworks
   preserve their own entitlements. No notarization is performed.
2. The Go helper now builds with `-trimpath -ldflags "-s -w"`. Packaging builds
   a same-target unstripped comparison and prints its before/after byte counts.
   It also strips CLI/plugin host copies and prints their before/after counts.
3. Deleted `PhoneAccessBuildPin.swift`. `make ts-helper` generates ignored
   `build/PhoneAccessHelper.xcconfig`, included by project-level
   `App/PhoneAccess.xcconfig` in Debug and Release. `App/osaurus/Info.plist`
   expands `OSAURUS_TS_HELPER_SHA256` into `OsaurusTSHelperSHA256`. Runtime reads
   `Bundle.main`, preserving fail-closed validation and existing signed-team
   policy. No runtime environment or sidecar fallback exists. The DMG lane
   freezes signed helper bytes, passes their digest to Xcode, checks the
   expanded plist and checks the final hash after signing. It does not re-sign
   the pinned helper.
4. Every packaging Xcode invocation disables coverage with both required
   flags. The script writes `size -m` for all shipped Mach-O files and aborts
   before DMG creation on `__LLVM_COV`. Build, pin, signature and coverage
   failures propagate as nonzero exits.
5. `make app`'s recipe is byte-for-byte unchanged. Its existing `ts-helper`
   prerequisite now supplies the plist setting without changing tracked source.

Files: Makefile; `App/{PhoneAccess.xcconfig,osaurus/Info.plist,
osaurus.xcodeproj/project.pbxproj}`; the integrity service and phone tests;
removed generated Swift pin; `scripts/build/{build-ts-helper,build-fork-dmg}.sh`;
updated isolated/integrity test scripts; new
`scripts/test-phone-helper-build-setting.sh` and `scripts/test-fork-packaging.py`;
`fork/PACKAGING.md`; this RESULT.

## Verified here

Commands run from the worktree root. Evidence is ignored under `build/t10/`.
Go: `go1.26.2 darwin/arm64`; Swift: Apple Swift 6.4.

| Exact command | Result | Evidence |
| --- | --- | --- |
| `scripts/test-phone-access-isolated.sh` | **16/16 tests**, 2 suites. Unchanged production sources copied into a small package; unrelated integration types shimmed. Uses `--disable-keychain --disable-sandbox`, no model. | `swift.log`; package at `build/t04/isolated/` |
| `scripts/test-phone-helper-integrity.sh` | **11/11 checks**, actual Go helper and real ad-hoc-signed fixture apps. Valid pin accepted; writable files, symlink, tampering with matching sidecar, missing/empty/malformed/unexpanded/non-string pins rejected. Runtime environment cannot substitute a pin. Changing Info.plist invalidates the app signature. No helper network startup. | `integrity.log`; fixtures at `build/t04b/integrity/` |
| `scripts/test-phone-helper-build-setting.sh` | **3/3 checks**: real Xcode settings inherit generated pin in Debug/Release; absent generated config leaves no pin. Uses a dependency-free copy of project metadata and an empty Debug secrets fixture; no dependency resolution or app compilation. Xcode emitted simulator-service diagnostics but exited 0 and returned the asserted settings. | `settings.log`; `settings-proof/{Debug,Release,missing}.log` |
| `python3 scripts/test-fork-packaging.py` | **6/6 tests**: ad-hoc output layout/pin, Developer ID argument propagation, and refusal before DMG creation for bad pin, coverage, failed build and invalid signature. Build/sign/disk tools are **fake**, including signing that changes helper bytes; these results prove orchestration, not real distribution signing or a DMG. | `packaging-tests.log` |
| `make ts-helper` | PASS; signed stripped helper and xcconfig generated. `git status --porcelain` captured before/after and compared with `cmp build/t10/before-build.status build/t10/after-build.status`: identical. | `helper-build.log`, before/after status files |
| `PATH=/usr/bin:/bin make ts-helper` | PASS: missing-Go message, stale helper removed, empty build-setting value. Normal helper rebuilt afterward by the integrity test. | `no-go.log` |
| `bash -n scripts/build/build-fork-dmg.sh scripts/build/build-ts-helper.sh scripts/test-phone-helper-integrity.sh scripts/test-phone-access-isolated.sh scripts/test-phone-helper-build-setting.sh` | PASS, 5 shell scripts. | Exit 0 |
| `plutil -lint App/osaurus/Info.plist App/osaurus.xcodeproj/project.pbxproj` | PASS, 2 files. | `plutil.log` |
| `make -n fork-dmg` and `make -n app` | PASS dry runs; separate target and existing app lane. Additionally compared the complete `app: ts-helper` recipe against `git show HEAD:Makefile` in Python: identical. | `dmg-dry-run.log`, `app-dry-run.log` |
| `xcrun size -m build/osaurus-ts > build/t10/helper-size-m.txt` | PASS for **the real Go helper only**: no `__LLVM_COV`. Full app absence remains unverified. | `helper-size-m.txt` |
| `git diff --check` | PASS. | Exit 0 |

The first packaging test run encountered `/dev/fd/62: Operation not permitted`
from process-substitution logging. Replaced it with a normal pipeline and
explicit file lists; the final six tests pass. No sandbox relaxation was used.

### Actual helper sizes

The unstripped comparison was built with:

```bash
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
(cd helpers/osaurus-ts && go build -trimpath -o ../../build/t10/osaurus-ts-unstripped .)
codesign --force --options runtime --timestamp=none --sign - build/t10/osaurus-ts-unstripped
stat -f '%N %z bytes' build/t10/osaurus-ts-unstripped build/osaurus-ts
```

Both variants are arm64, ad-hoc signed with hardened runtime:

| Helper | Bytes |
| --- | ---: |
| Before `-s -w` | 31,469,712 |
| After `-s -w` | 21,661,936 |
| Reduction | **9,807,776 (31.2%)** |

Final helper SHA-256:
`0e192f9b642900ad0bd481e92c1b643224034436019f67657fe0c54389d7329a`.
CLI, plugin-host, app, Resources and DMG sizes are **not measured here**; their
before/after and final numbers will be printed by the real host packaging lane.
The old LOG's 508 MB unarchived local bundle is not a comparable shipped baseline.

## Host handoff / expected outputs

After normal Git metadata write access is available, stage the listed changes
plus this RESULT and commit on `task/T10-packaging-size`, for example:

```bash
git add -A
git -c commit.gpgsign=false commit -m "Add fork DMG packaging and move phone helper pin to Info.plist"
make fork-dmg
# Optional signer lane; needs the owner's existing certificate/key setup:
make fork-dmg CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

Expected artifacts:

- `build/fork/Osaurus-fork-<git short sha>.dmg`: compressed, signed image.
- `build/fork/dmg-root/Osaurus.app`: final signed app with CLI, plugin host,
  `osaurus-ts` and verified sandbox kernel/provenance.
- `build/fork/Osaurus.xcarchive`: Release archive before manual embedding.
- `build/fork/package.log`: source identity, before/after helper sizes,
  signature results, no-coverage result, final component sizes and DMG path.
- `build/fork/size-m.txt`: raw coverage-segment inspection.

See `fork/PACKAGING.md` for exact verification and optional signer-run
`notarytool submit` / `stapler` commands. No credentials are needed for the
default ad-hoc lane; notarization requires the signer's existing credentials.

## Unverified / not claimed

Per CODEX_PREAMBLE, no full app or full OsaurusCore dependency-graph build was
attempted in this sandbox. Claude's host lane must run the actual archive and
DMG build. The Release stripping result, all-app coverage absence, kernel fetch
in this lane, real nested framework/XPC signing, Developer ID/team matching,
DMG mounting/drag-install, installed CLI/plugin/sandbox operation, Chat/Settings
and phone startup/save/relaunch remain unverified. No actual DMG was produced.
No model was loaded; inference scores, generation defaults and token/s are not
applicable to these isolated checks. No runtime release-readiness claim is made.
The requested Git commit remains blocked as recorded above.
