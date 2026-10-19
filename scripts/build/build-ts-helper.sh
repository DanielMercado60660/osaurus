#!/usr/bin/env bash
# Generate the Info.plist build setting. No tracked source or runtime sidecar.
set -euo pipefail
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p build
PIN="build/PhoneAccessHelper.xcconfig"
# Clear stale trust before doing work that can fail (including signing).
printf 'OSAURUS_TS_HELPER_SHA256 =\n' > "$PIN"
DIGEST=
if command -v go >/dev/null 2>&1; then
    (cd helpers/osaurus-ts && go build -trimpath -ldflags "-s -w" -o ../../build/osaurus-ts .)
    # Default is ad-hoc and never accesses the login keychain. Distribution
    # builders may explicitly supply the same signing identity as the app.
    IDENTITY="${TS_HELPER_SIGN_IDENTITY:--}"
    TIMESTAMP=--timestamp
    if [[ "$IDENTITY" == - ]]; then TIMESTAMP=--timestamp=none; fi
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" build/osaurus-ts
    DIGEST="$(shasum -a 256 build/osaurus-ts | awk '{print $1}')"
else
    echo "Go not found; skipping osaurus-ts. Phone access will be unavailable."
    rm -f build/osaurus-ts
fi
# Remove obsolete sidecars so they cannot be mistaken for the trust source.
rm -f build/osaurus-ts.sha256 build/PhoneAccessBuildPin.swift
printf 'OSAURUS_TS_HELPER_SHA256 = %s\n' "$DIGEST" > "$PIN"
echo "Helper Info.plist build setting: $PIN"
