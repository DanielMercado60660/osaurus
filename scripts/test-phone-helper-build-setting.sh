#!/usr/bin/env bash
# Read real Xcode build settings in a dependency-free copy of the project.
# This proves xcconfig inheritance only, not compilation or app packaging.
set -euo pipefail
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROOF="$ROOT/build/t10/settings-proof"
python3 - "$ROOT" "$PROOF" <<'PY'
import pathlib, plistlib, shutil, subprocess, sys
root, proof = map(pathlib.Path, sys.argv[1:])
target = proof / 'App'
(target / 'osaurus').mkdir(parents=True, exist_ok=True)
raw = subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(root / 'App/osaurus.xcodeproj/project.pbxproj')])
project = plistlib.loads(raw)
for obj in project['objects'].values():
    for key in ['packageReferences', 'packageProductDependencies']:
        if key in obj: obj[key] = []
    if obj.get('isa') == 'PBXFrameworksBuildPhase': obj['files'] = []
path = target / 'osaurus.xcodeproj'
path.mkdir(exist_ok=True)
(path / 'project.pbxproj').write_bytes(plistlib.dumps(project))
# No local secrets are read/copied. The original Debug config refers to this.
(target / 'osaurus/Secrets.xcconfig').write_text('// Empty fixture\n')
shutil.copy(root / 'App/PhoneAccess.xcconfig', target)
(proof / 'build').mkdir(exist_ok=True)
(proof / 'build/PhoneAccessHelper.xcconfig').write_text('OSAURUS_TS_HELPER_SHA256 = ' + 'a' * 64 + '\n')
PY
for config in Debug Release; do
    xcodebuild -project "$PROOF/App/osaurus.xcodeproj" -target osaurus \
        -configuration "$config" -showBuildSettings > "$PROOF/$config.log" 2>&1
    grep -q "OSAURUS_TS_HELPER_SHA256 = $(printf 'a%.0s' {1..64})$" "$PROOF/$config.log"
    echo "PASS: $config inherits generated helper pin"
done
rm "$PROOF/build/PhoneAccessHelper.xcconfig"
xcodebuild -project "$PROOF/App/osaurus.xcodeproj" -target osaurus \
    -configuration Release -showBuildSettings > "$PROOF/missing.log" 2>&1
if grep -E 'OSAURUS_TS_HELPER_SHA256 = .+' "$PROOF/missing.log"; then
    echo 'FAIL: missing generated config has a nonempty pin' >&2
    exit 1
fi
echo 'PASS: unprepared Release build has no helper pin'
