# T20 — Extract an upstreamable "Talk mode" branch

Read `fork/tasks/CODEX_PREAMBLE.md` and **all of `AGENTS.md`** (upstream's PR
proof standards apply to this branch), then the RESULT files for T01, T03,
T03b, T06, T15, T16, T17.

## Goal

A clean branch `upstream/talk-mode` based on **`upstream/main`** (the original
osaurus repo; remote `upstream` already exists and is fetched) containing only
the realtime talk-mode feature, ready to propose upstream. No fork-only code.

## Include

- Voice plumbing (T01): incremental TTS stream, output level, STT events,
  assistant delta hook.
- Talk mode (T03 + T03b): controller, reducer, duplex AEC engine, hotkey,
  settings tab, composer toggle, captions, telemetry.
- Headless harness (T06): WAV-in / null-sink seams + `talk_bench` scripts. Move
  the scripts from `fork/metrics/` to `scripts/benchmark/talk/` (or the repo's
  existing benchmark location) and the docs into `docs/`.
- T16 per-stage telemetry + "Think before speaking".
- T17 Smart Turn.
- T15 FluidAudio 0.15.4 bump **as a separate, final commit** (upstream pinned
  `< 0.14.2` deliberately; the bump must stand alone so it can be dropped or
  split into its own PR without breaking the rest). Verify the branch also
  builds without that commit (talk mode should work on 0.14.1; only PocketTTS
  speed differs).

## Exclude

Avatar/companion code and hooks (`Services/Avatar`, `AnimatedAgentAvatarView`,
`publishAvatar`/`AvatarTalkEvent` calls in `TalkModeController`, T09 caption
sync), phone access/phone voice/screen (T04/T04b/T07/T11/T13/T13b/T14), "Make
it yours" (T05), memory budget (T12) **unless** a talk file depends on it — if
so, replace the dependency with the minimal neutral hook and note it, fork
packaging (T10), Mac-control (T08), `fork/` directory, fork Makefile changes
unrelated to talk.

## How

Start from `upstream/main`, bring files over from `fork/main` (cherry-picks or
file-level checkout + edits — whatever yields clean, reviewable commits), then
remove/neutralize excluded code. Organize as ~5–7 logical commits (plumbing,
talk core, settings/UI, harness, Smart Turn, telemetry/think setting, FluidAudio
bump). Each commit should build in principle; keep settings-catalog compliance
(AGENTS.md checklist) in every commit that adds a setting.

## Deliver

- Branch `upstream/talk-mode` committed in your worktree (create it from
  `upstream/main`; your worktree branch can be reset to it or you can create it
  inside the worktree — say which).
- `fork/tasks/T20-upstream-talk-pr.RESULT.md` **on the task branch, not on
  upstream/talk-mode**: commit list, what was neutralized and why, a file list,
  and a **draft PR description** following AGENTS.md's PR reporting rules
  (exact SHAs, model bundle, harness commands, raw numbers with denominators,
  what's PARTIAL/BLOCKED — e.g. acoustic latency and live UI proof). Use the
  measured numbers from `fork/LOG.md`, clearly labelled as fork-branch
  measurements that must be re-run on this branch.
Never push.
