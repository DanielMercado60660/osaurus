#!/usr/bin/env bash
# Real signed fixture bundles + production integrity code; never starts tsnet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROOF="$ROOT/build/t04b/integrity"
CORE="$ROOT/Packages/OsaurusCore/Services/PhoneAccess"
mkdir -p "$PROOF/module-cache"
TS_HELPER_SIGN_IDENTITY=- make ts-helper
PIN="$(shasum -a 256 build/osaurus-ts | awk '{print $1}')"
cat > "$PROOF/main.swift" <<'SWIFT'
import Foundation
let helper = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    try PhoneAccessHelperIntegrity.validate(helper: helper)
    print("accepted")
} catch {
    print("rejected: \(error.localizedDescription)")
    exit(1)
}
SWIFT
swiftc -module-cache-path "$PROOF/module-cache" \
    "$CORE/PhoneAccessHelperIntegrity.swift" "$PROOF/main.swift" -o "$PROOF/check"
make_checker() {
    local name="$1" value="$2" app="$PROOF/$1.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$PROOF/check" "$app/Contents/MacOS/check"
    python3 - "$app/Contents/Info.plist" "$name" "$value" <<'PY'
import plistlib, sys
value = sys.argv[3]
info = dict(CFBundleExecutable='check', CFBundleIdentifier='test.phone.' + sys.argv[2], CFBundlePackageType='APPL')
if value != 'missing':
    info['OsaurusTSHelperSHA256'] = 123 if value == 'number' else value
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(info, f)
PY
    codesign --force --sign - "$app"
    codesign --verify --strict "$app"
}
make_checker pinned "$PIN"
CHECK="$PROOF/pinned.app/Contents/MacOS/check"
cp build/osaurus-ts "$PROOF/helper"
chmod 755 "$PROOF/helper"
"$CHECK" "$PROOF/helper"
echo 'PASS: original helper accepted by signed Info.plist pin'
expect_rejected() {
    if "$CHECK" "$1"; then
        echo "FAIL: expected rejection for $1" >&2
        exit 1
    fi
}
chmod 775 "$PROOF/helper"
expect_rejected "$PROOF/helper"
echo 'PASS: group-writable rejected'
chmod 757 "$PROOF/helper"
expect_rejected "$PROOF/helper"
echo 'PASS: world-writable rejected'
chmod 755 "$PROOF/helper"
ln -sf helper "$PROOF/link"
expect_rejected "$PROOF/link"
echo 'PASS: symlink rejected'
printf 'tampered' >> "$PROOF/helper"
shasum -a 256 "$PROOF/helper" | awk '{print $1}' > "$PROOF/helper.sha256"
expect_rejected "$PROOF/helper"
echo 'PASS: tampering plus matching sidecar rejected on revalidation'
for invalid in missing empty malformed unexpanded number; do
    case "$invalid" in
        empty) value= ;;
        malformed) value=bad ;;
        unexpanded) value='$(OSAURUS_TS_HELPER_SHA256)' ;;
        *) value="$invalid" ;;
    esac
    make_checker "$invalid" "$value"
    CHECK="$PROOF/$invalid.app/Contents/MacOS/check"
    # A runtime environment variable/sidecar cannot provide the missing pin.
    export OSAURUS_TS_HELPER_SHA256="$PIN"
    expect_rejected "$ROOT/build/osaurus-ts"
    unset OSAURUS_TS_HELPER_SHA256
    echo "PASS: $invalid Info.plist pin rejected despite runtime environment"
done
# Prove the plist trust source is sealed, independently of helper validation.
/usr/libexec/PlistBuddy -c 'Set :OsaurusTSHelperSHA256 bad' "$PROOF/pinned.app/Contents/Info.plist"
if codesign --verify --strict "$PROOF/pinned.app"; then
    echo 'FAIL: changed Info.plist retained a valid signature' >&2
    exit 1
fi
echo 'PASS: changing the plist invalidates the app signature'
