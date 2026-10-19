# T10 — Packaging and size

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, `fork/LOG.md` (baseline
numbers), `Makefile`, `scripts/build/build_arm64.sh`,
`scripts/build/build-ts-helper.sh`, and the T04b RESULT (helper pin design).

## Goals

1. **Installable fork build**: `make fork-dmg` produces
   `build/fork/Osaurus-fork-<git short sha>.dmg` that a person can open and
   drag to Applications: Release archive (so the app binary is stripped like
   upstream's shipped build), CLI + plugin host + `osaurus-ts` embedded,
   sandbox kernel staged (reuse the existing fetch script), signed with
   `CODESIGN_IDENTITY` if set (Developer ID, hardened runtime, the existing
   entitlements) or ad-hoc (`-`) otherwise, then a compressed DMG via
   `hdiutil`. Print the final bundle size, DMG size and per-component sizes
   (`Contents/MacOS`, `Helpers/*`, `Resources`). No notarization (needs
   credentials); document the command a signer would run. Must not change
   `make app`.
2. **Strip helpers**: build `osaurus-ts` with `-trimpath -ldflags "-s -w"` and
   strip the CLI helper in the DMG path; report before/after sizes.
3. **Helper pin without a tracked generated file**: today `make ts-helper`
   rewrites `Packages/OsaurusCore/Services/PhoneAccess/PhoneAccessBuildPin.swift`
   (tracked) which dirties git and forces recompiles. Move the ad-hoc-build pin
   to an Info.plist key injected from a build setting (e.g.
   `OSAURUS_TS_HELPER_SHA256` → `OsaurusTSHelperSHA256` in the app's Info.plist,
   covered by the app's code signature) and read it at runtime; keep fail-closed
   when absent. Remove the generated Swift file. Make sure the T04b integrity
   tests are updated accordingly.
4. **Coverage**: the Makefile already passes `ENABLE_CODE_COVERAGE=NO
   CLANG_COVERAGE_MAPPING=NO`; make the DMG path do the same and verify with
   `size -m` that no `__LLVM_COV` segment is present (document the check).

## Done

Commit on your branch; write `fork/tasks/T10-packaging-size.RESULT.md` with
the commands, the expected outputs, and what you could/couldn't run in the
sandbox (Claude will run the real build).
