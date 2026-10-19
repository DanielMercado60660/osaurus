#!/usr/bin/env bash
# Executes only a Swift integrity checker, never the tailnet service. Ad-hoc
# signing uses no certificates/private keys and must not prompt for Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROOF="$ROOT/build/t04b/integrity"
CORE="$ROOT/Packages/OsaurusCore/Services/PhoneAccess"
mkdir -p "$PROOF/module-cache"
cp "$CORE/PhoneAccessBuildPin.swift" "$PROOF/original-pin.swift"
trap 'cp "$PROOF/original-pin.swift" "$CORE/PhoneAccessBuildPin.swift"' EXIT
make ts-helper
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
    "$CORE/PhoneAccessHelperIntegrity.swift" "$CORE/PhoneAccessBuildPin.swift" \
    "$PROOF/main.swift" -o "$PROOF/check"
cp build/osaurus-ts "$PROOF/helper"
chmod 755 "$PROOF/helper"
"$PROOF/check" "$PROOF/helper"
echo 'PASS: original helper accepted by compiled pin'
expect_rejected() {
    if "$PROOF/check" "$1"; then
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
# Even a sidecar containing the new digest cannot replace the compiled pin.
shasum -a 256 "$PROOF/helper" | awk '{print $1}' > "$PROOF/helper.sha256"
expect_rejected "$PROOF/helper"
echo 'PASS: tampering plus matching sidecar rejected on revalidation'
cat > "$PROOF/NilPin.swift" <<'SWIFT'
enum PhoneAccessBuildPin { static let sha256: String? = nil }
SWIFT
swiftc -module-cache-path "$PROOF/module-cache" \
    "$CORE/PhoneAccessHelperIntegrity.swift" "$PROOF/NilPin.swift" \
    "$PROOF/main.swift" -o "$PROOF/check-nil"
if "$PROOF/check-nil" "$ROOT/build/osaurus-ts"; then
    echo 'FAIL: missing compiled pin accepted' >&2
    exit 1
fi
echo 'PASS: missing compiled pin rejected'
