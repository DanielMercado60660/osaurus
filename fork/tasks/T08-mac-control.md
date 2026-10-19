# T08 — Mac control: fix open computer-use failure classes

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, `docs/COMPUTER_USE.md`, and
`docs/COMPUTER_USE_BONSAI_PRIORITY_GATE_2026-07-22.md` (failure classes
B1–B7, ~lines 200–260). Code: `Packages/OsaurusCore/ComputerUse/`
(`Tool/ComputerUseTool.swift`, `Loop/ComputerUseLoop.swift`,
`Driver/NativeMacDriver.swift`, `Perception/CaptureRouter.swift`,
`Policy/*`). Evals: `Packages/OsaurusEvals/Suites/ComputerUseLoop`,
`ComputerUse`, `ScreenContext`; deterministic floors in
`Packages/OsaurusEvals/Config/floors.json`.

First check the current source for whether each class below is already fixed
upstream (the doc is dated 2026-07-22; the code may have moved on). Only work
on what is still open, and say which were already fixed.

## B3 — localized / differently-cased app names don't resolve

"Open заметки" fails while "Заметки" works later. Make app resolution robust:
match against LaunchServices display names in the user's preferred languages
(`FileManager.displayName(atPath:)`, `Bundle.localizedInfoDictionary`
`CFBundleDisplayName`/`CFBundleName` for each preferred localization),
bundle id, executable name, case- and diacritic-insensitive, with a
deterministic tie-break. No hardcoded app-name lists. Unit tests with a fake
app catalog covering Russian/German/Japanese display names, casing, bundle id.

## B5 — successful mutations don't end the run (observation races delivery)

After typing/setting a value, the post-action observation is sampled before
the event is delivered and the AX value has settled ("Hello agai" vs
"Hello again"), so the model repeats the action. Add a settle step at the
input-completion → observation boundary: poll the target element's AX value
(or the focused element) until it is stable for N ms or matches the intended
text, bounded by a short timeout, before building the observation. No output
post-processing, no fake success. Deterministic test with a scripted fake AX
tree whose value updates after a delay; add a ScriptedOnly eval case in
`Suites/ComputerUseLoop` that fails without the fix and passes with it.

## B4 — scalar `target` / non-array `roles`

Per the doc the numeric root is fixed; the remainder is model output. Do
**not** add silent coercion. Instead make the validation error the model sees
precise and actionable (e.g. `target must be an object like {"mark": 13}; got
string "{'mark': 1}"`) so a retry succeeds; add a test for the message.

## Done

- Deterministic lane must stay green: describe the exact command
  (`make evals-deterministic`), even though it can't run in your sandbox.
- Commit on your branch; write `fork/tasks/T08-mac-control.RESULT.md` with
  class → status (already fixed / fixed here / left open) → tests.
