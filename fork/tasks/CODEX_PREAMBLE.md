# Read first: how Codex tasks run in this fork

- You work in a dedicated git worktree on branch `task/<id>`. Only modify
  files inside it. Never push, never touch other branches/worktrees/remotes,
  never install system software, never log in to anything.
- **Builds:** the full app build and `swift test` on `Packages/OsaurusCore`
  do not work inside your sandbox (nested `sandbox-exec`, Metal toolchain,
  Xcode workspace access). Don't spend more than ~10 minutes fighting this.
  Claude builds and tests your branch outside the sandbox after you finish.
  Useful checks you *can* do: `swiftc -typecheck` on isolated files with
  stubs, a small throwaway SwiftPM package under `build/<task>/` (gitignored)
  that copies the pure-logic files and their tests, `go test` for Go code.
- **Never trigger keychain prompts.** All dependencies are public. Always pass
  `--disable-keychain` to `swift build` / `swift test` / `swift package`, and
  export `GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=` before any command
  that may fetch packages, so git never asks the macOS keychain for GitHub
  credentials (that pops a password dialog on the owner's screen).
- Put pure logic (reducers, parsers, chunkers, state machines) in files with no
  app-singleton dependencies so they can be tested in isolation.
- **Commit** your work on your branch when done (`git add -A` the files you
  changed, clear message). If committing fails, leave the changes in place and
  say so in the RESULT file.
- Write `fork/tasks/<id>.RESULT.md`: what you built, files, how to try it,
  what you verified and how (exact commands + counts), and what is unverified.
  Be plain and honest; "not verified" is fine, invented results are not.
