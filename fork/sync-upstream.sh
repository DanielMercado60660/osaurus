#!/usr/bin/env bash
# Merge the latest upstream osaurus into a sync branch off fork/main, then build
# and run the deterministic evals. Leaves fork/main untouched; fast-forward it
# yourself after reviewing: git checkout fork/main && git merge --ff-only sync/upstream
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

git fetch upstream main
echo "upstream commits not in fork/main: $(git rev-list --count fork/main..upstream/main)"
git switch -C sync/upstream fork/main
if ! git merge --no-edit upstream/main; then
  echo "Merge conflicts — resolve, commit, then rerun with SKIP_MERGE=1." >&2
  echo "Usual hotspots: Resources/Guide/guide-settings.md (both sides add sections: keep both)," >&2
  echo "Tests/Configuration/SettingsSearchSelfFindProbe.swift and SettingsSearchIndex.swift (keep both rows)," >&2
  echo "Networking/HTTPHandler.swift (fork routes: /phone, /phone/api/screen, /v1/audio/speech)." >&2
  exit 1
fi

make app XCODEBUILD_FLAGS="-skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="
swift build --disable-keychain --build-system native --package-path Packages/OsaurusEvals --product osaurus-evals
rc=0
for name in $(make -s -p 2>/dev/null | sed -n 's/^EVALS_DETERMINISTIC_SUITES *:*= *//p' | head -1); do
  OSAURUS_EVALS_SCRIPTED_ONLY=1 OSAURUS_EVALS_DISABLE_WARMUP=1 \
    swift run --disable-keychain --build-system native --skip-build --package-path Packages/OsaurusEvals \
    osaurus-evals run --suite "Packages/OsaurusEvals/Suites/$name" --fail-on-floor >/dev/null 2>&1 \
    && echo "PASS $name" || { echo "FAIL $name"; rc=1; }
done
exit $rc
