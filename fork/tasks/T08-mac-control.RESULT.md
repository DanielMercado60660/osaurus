# T08 — Mac control result

Status: **PARTIAL validation**. Scoped implementation and isolated checks are complete. Full app builds, the canonical deterministic eval lane, and live Release UI proof were not run, per `CODEX_PREAMBLE.md`'s sandbox handoff instructions. No release-readiness claim.

**Commit not created.** `git add -A` failed before staging with:

```text
fatal: Unable to create '<repo>/.git/worktrees/T08-mac-control/index.lock': Operation not permitted
```

The sandbox denied the worktree Git metadata write. All implementation, tests,
documentation, and this result remain in the worktree, unstaged. Complete the
commit outside the sandbox with `git add -A` and
`git commit -m "Fix localized Mac app lookup and computer-use recovery feedback"`.
No push, branch switch, or changes to another worktree were attempted.

Branch: `task/T08-mac-control`. Starting SHA: `8fb683302233da27a4622a3ccbd806dfe7cb1e65`. vMLX pin unchanged: `f9f5e0aa9e042f006ee6a948f28d835b3e065ea6`. No model was loaded; generation defaults/token rates are not applicable to these model-free checks. `~/AGENTS.md` was absent; repository instructions and the supplied instructions were read.

## Class → status → evidence

| Class | Source status | Changes and checks |
| --- | --- | --- |
| B3 localized app resolution | **Fixed here; live launch unverified** | Upstream only lowercased running-app names/IDs and searched literal English bundle paths for launches. Added one metadata catalog used for both running-app matching and launch. Case/diacritic-insensitive names, bundle IDs, executables, explicit paths; deterministic identity/name ranking and bundle-ID/path tie-break. Seven catalog tests pass, including Russian/German/Japanese fixtures, duplicate candidates, every preferred localization, and `.loctable`. Six read-only installed Notes bundle lookup controls pass. |
| B4 scalar target / non-array roles | **Feedback fixed here; numeric transport root already addressed upstream** | Existing strict validation and basic target hints were present. Added received type/value (bounded, JSON-escaped), concrete object/array examples, and legacy error-envelope roles hints. No coercion/schema/parser changes. 48 action-decode tests pass, including five new feedback/rejection cases and existing nested numeric mark tests. Actual model retry behavior remains unverified. |
| B5 observation races text delivery | **Already fixed upstream; regression coverage added here** | `ComputerUseLoop.settledVerificationSnapshot` already polls five times at 50 ms intervals after the first capture: exact text for wholesale edits, repeated value for append. Existing `testTextVerificationWaitsForSettledAXValue` already covers `Hello agai` → `Hello again`. Production loop was left unchanged. Added capture-scripted delivery to the eval driver, two tests covering immediate partial state and settled type/set-value/clear, and the ScriptedOnly `delayed-text-delivery.json` case. Isolated tests pass; disabling the existing settle guard only in the generated copy causes six expected assertion failures. Full eval-runner and live UI closure remain pending. |

B1, B2, B6, and B7 were read as context but are outside the three scoped changes. No new live closure is claimed for them.

## Files

- `Packages/OsaurusCore/ComputerUse/Driver/AppCatalog.swift`: Foundation metadata loading and pure resolver.
- `ComputerUse/Driver/Mac/InstalledAppCatalog.swift`: LaunchServices candidates, running apps, and standard installation-root discovery.
- `ComputerUse/Driver/Mac/Accessibility.swift`: resolve once, use the same URL for running-app activation and new launch.
- `ComputerUse/Model/AgentAction.swift`: actionable validation feedback.
- `Packages/OsaurusCore/Tests/ComputerUse/{Driver/AppCatalogTests,Model/AgentActionDecodeTests}.swift`.
- `Packages/OsaurusEvals/Sources/OsaurusEvalsKit/{EvalCase,ScriptedCUDriver}.swift`: optional `editCaptureValues` scene data; existing scenes retain immediate edits.
- `Packages/OsaurusEvals/Tests/OsaurusEvalsKitTests/DelayedTextDeliveryTests.swift` and `Suites/ComputerUseLoop/delayed-text-delivery.json`.
- `docs/COMPUTER_USE.md` and the loop suite README document the behavior.
- `fork/tasks/T08-mac-control-checks.py`: reproducible, dependency-free isolated check preparation. It extracts the real act/verification methods and scene schema; only the unrelated feed sink and UI localization helper are stubbed. It does **not** reproduce the complete loop, scorer, or app.

## Verification performed

From the worktree root:

```bash
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export CLANG_MODULE_CACHE_PATH="$PWD/build/T08-mac-control/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/T08-mac-control/module-cache"
python3 fork/tasks/T08-mac-control-checks.py
swift test --disable-sandbox --disable-keychain --package-path build/T08-mac-control/isolated
```

**57/57 XCTest tests passed**: 48 action-decode, seven catalog, two delayed-delivery tests (the latter exercise all three text mutation verbs). The helper also parsed all **30/30** loop scene JSON files and both new scripted action payloads. Fifteen scenes now contain scripted actions. This is isolated evidence, not a full `make test` or eval score.

Expected-failing negative control, followed by restoration and the passing full isolated run:

```bash
python3 fork/tasks/T08-mac-control-checks.py --without-settle
swift test --disable-sandbox --disable-keychain --package-path build/T08-mac-control/isolated \
  --filter DelayedTextDeliveryTests.testVerificationWaitsForExactTextWithoutRepeatingMutation
python3 fork/tasks/T08-mac-control-checks.py
swift test --disable-sandbox --disable-keychain --package-path build/T08-mac-control/isolated
```

The negative control exited **1**, with **one test / six assertion failures**, exposing `Hello agai` for type, set-value, and clear. The production file was never modified by that control.

Native catalog typecheck and read-only real bundle probe:

```bash
swiftc -disable-sandbox -typecheck -module-cache-path build/T08-mac-control/module-cache \
  Packages/OsaurusCore/ComputerUse/Driver/AppCatalog.swift \
  Packages/OsaurusCore/ComputerUse/Driver/Mac/InstalledAppCatalog.swift
swiftc -disable-sandbox -module-cache-path build/T08-mac-control/module-cache \
  Packages/OsaurusCore/ComputerUse/Driver/AppCatalog.swift build/T08-mac-control/main.swift \
  -o build/T08-mac-control/catalog-probe
build/T08-mac-control/catalog-probe
swiftc -frontend -parse \
  Packages/OsaurusCore/ComputerUse/Driver/Mac/Accessibility.swift \
  Packages/OsaurusCore/ComputerUse/Model/AgentAction.swift \
  Packages/OsaurusEvals/Sources/OsaurusEvalsKit/EvalCase.swift \
  Packages/OsaurusEvals/Sources/OsaurusEvalsKit/ScriptedCUDriver.swift
git diff --check
```

All exited **0**. The six probe queries (`заметки`, `ЗАМЕТКИ`, `NOTIZEN`, `メモ`, `COM.APPLE.NOTES`, `Notes`) resolved the installed Notes bundle with explicit Russian/German/Japanese language preferences. This read metadata only: no app opened and no preferences changed. The native catalog typecheck has one deprecation warning for `NSWorkspace.fullPath(forApplication:)`, retained for LaunchServices name lookup outside the scanned roots. The initial typecheck without a writable module-cache override failed on sandbox cache access; the commands above resolve that check-environment issue.

Local evidence (gitignored, no images):

| Path under `build/T08-mac-control/` | SHA-256 |
| --- | --- |
| `isolated-tests.log` | `f1b260d469bf2751b1130368dca7dd086fdfc4d772662bd440f506bcb10e99ee` |
| `no-settle-negative-control.log` | `4c20af8ddb1400f70146da0bdb6367d0bcb28d5228656e568769df2dc293cec1` |
| `catalog-probe.log` | `bdc64d7a8503eb7d21ea04b1bcc78a259e85ba735c8e49dd58f6063c0844c9c6` |

## Handoff / how to try it

The required canonical lane is **`make evals-deterministic`**. It was **not run** in this sandbox; floors were not changed. Run it outside the sandbox, plus the relevant core/eval test suites and applicable AgentLoop/AgentLoopFrontier lanes. Preserve the preamble's keychain-disabled package execution and Git credential environment when running those build lanes.

Build an isolated Release app outside the sandbox. In a custom agent with Computer Use enabled and the relevant language preferences, try `open` with Russian/German/Japanese names, casing variants, executable name, and bundle ID. Compare already-running and closed app cases. Try a disposable TextEdit document replacement to `Hello again`; inspect the exact post-action value, one mutation, terminal completion, unlocked input, and a follow-up turn. Exercise scalar `target` / `roles` retry feedback through a model. Record source/app pins, exact arguments, model/defaults, token/s, permission behavior, and full turn history for live acceptance.

Discovery is bounded to standard app roots plus LaunchServices name/ID candidates, running apps, and explicit paths; arbitrary nonstandard installations are not globally enumerated. Settling remains the upstream bounded AX heuristic and does not prove delivery after its timeout. Full app integration, full eval scores (including the new case through the real runner), and real launch/input/UI behavior remain **unverified**.
