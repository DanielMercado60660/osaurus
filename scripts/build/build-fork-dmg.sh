#!/usr/bin/env bash
# Local fork distribution lane. Does not export, notarize, or alter make app.
set -euo pipefail
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/fork"
DERIVED="$OUT/DerivedData"
ARCHIVE="$OUT/Osaurus.xcarchive"
STAGE="$OUT/dmg-root"
APP="$STAGE/Osaurus.app"
SHA="$(git rev-parse --short HEAD)"
DMG="$OUT/Osaurus-fork-$SHA.dmg"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/App/osaurus/osaurus.entitlements"
TIMESTAMP=--timestamp
if [[ "$IDENTITY" == - ]]; then TIMESTAMP=--timestamp=none; fi
for tool in go xcodebuild codesign hdiutil xcrun; do
    command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
mkdir -p "$OUT"
# Only disposable artifacts owned by this lane. Keep incremental compilation.
rm -rf "$ARCHIVE" "$STAGE"
mkdir -p "$STAGE"
package() {
    echo "Packaging source $(git rev-parse HEAD) (working-tree changes, if any, are included)"
    git status --short

    # Build both variants under the same environment for a real size comparison.
    echo "Measuring osaurus-ts before -s -w..."
    (cd helpers/osaurus-ts && GOOS=darwin GOARCH=arm64 go build -trimpath -o "$OUT/osaurus-ts-unstripped" .)
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$OUT/osaurus-ts-unstripped"
    GOOS=darwin GOARCH=arm64 TS_HELPER_SIGN_IDENTITY="$IDENTITY" ./scripts/build/build-ts-helper.sh
    test -x build/osaurus-ts
    echo "osaurus-ts bytes: before=$(stat -f %z "$OUT/osaurus-ts-unstripped") after=$(stat -f %z build/osaurus-ts)"
    PIN="$(shasum -a 256 build/osaurus-ts | awk '{print $1}')"
    # Freeze the signed helper for this archive; later make ts-helper invocations
    # cannot silently change the bytes being packaged.
    cp build/osaurus-ts "$OUT/osaurus-ts"

    COMMON=(
        -workspace osaurus.xcworkspace -configuration Release
        -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$OUT/SourcePackages"
        -skipPackagePluginValidation -skipMacroValidation
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
        "OSAURUS_TS_HELPER_SHA256=$PIN"
    )
    xcodebuild "${COMMON[@]}" -scheme osaurus-cli build
    xcodebuild "${COMMON[@]}" -scheme osaurus-plugin-host build
    xcodebuild "${COMMON[@]}" -scheme osaurus archive -archivePath "$ARCHIVE" \
        DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=all COPY_PHASE_STRIP=YES

    # Product case has varied between upstream archive/build lanes. Require exactly
    # one archived app rather than guessing a path or using stale DerivedData.
    shopt -s nullglob
    ARCHIVED_APPS=("$ARCHIVE"/Products/Applications/*.app)
    [[ ${#ARCHIVED_APPS[@]} == 1 ]] || { echo "Expected exactly one archived app" >&2; exit 1; }
    ditto "${ARCHIVED_APPS[0]}" "$APP"
    mkdir -p "$APP/Contents/Helpers"
    cp "$DERIVED/Build/Products/Release/osaurus-cli" "$APP/Contents/Helpers/osaurus"
    cp "$DERIVED/Build/Products/Release/osaurus-plugin-host" "$APP/Contents/Helpers/osaurus-plugin-host"
    cp "$OUT/osaurus-ts" "$APP/Contents/Helpers/osaurus-ts"
    chmod 755 "$APP/Contents/Helpers/"{osaurus,osaurus-plugin-host,osaurus-ts}
    rm -f "$APP/Contents/Helpers/osaurus-ts.sha256"
    for helper in osaurus osaurus-plugin-host; do
        path="$APP/Contents/Helpers/$helper"
        before="$(stat -f %z "$path")"
        xcrun strip -S -x "$path"
        echo "$helper bytes: before=$before after=$(stat -f %z "$path") (before final signing)"
    done
    SANDBOX_KERNEL_CACHE_DIR="${SANDBOX_KERNEL_CACHE_DIR:-$OUT/kernel-cache}" \
        ./scripts/build/fetch_sandbox_kernel.sh "$APP/Contents/Resources/SandboxRuntime"

    # Verify the build-setting expansion, before sealing the app. Never repair a
    # missing/mismatched pin by silently patching the packaged plist.
    PLIST_PIN="$(/usr/libexec/PlistBuddy -c 'Print :OsaurusTSHelperSHA256' "$APP/Contents/Info.plist")"
    [[ "$PLIST_PIN" == "$PIN" ]] || { echo "Archive Info.plist helper pin mismatch" >&2; exit 1; }

    # Sign inside-out, preserving nested frameworks' own entitlements. Do not use
    # --deep to sign: re-signing osaurus-ts would invalidate its already pinned hash.
    find "$APP/Contents" -type f -print0 > "$OUT/files.list"
    while IFS= read -r -d '' path; do
        if [[ "$path" != "$APP/Contents/Helpers/osaurus-ts" ]] && file -b "$path" | grep -q 'Mach-O'; then
            case "$path" in
                "$APP/Contents/Helpers/osaurus"|"$APP/Contents/Helpers/osaurus-plugin-host")
                    # These execute runtime/plugin code too: retain the existing
                    # disable-library-validation/virtualization app entitlements.
                    codesign --force --options runtime "$TIMESTAMP" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$path" ;;
                *)
                    codesign --force --options runtime "$TIMESTAMP" --preserve-metadata=entitlements --sign "$IDENTITY" "$path" ;;
            esac
        fi
    done < "$OUT/files.list"
    find "$APP/Contents" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0 > "$OUT/bundles.list"
    while IFS= read -r -d '' path; do
        codesign --force --options runtime "$TIMESTAMP" --preserve-metadata=entitlements --sign "$IDENTITY" "$path"
    done < "$OUT/bundles.list"
    codesign --force --options runtime "$TIMESTAMP" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    [[ "$(shasum -a 256 "$APP/Contents/Helpers/osaurus-ts" | awk '{print $1}')" == "$PLIST_PIN" ]] || {
        echo "Final helper bytes no longer match Info.plist" >&2; exit 1;
    }
    codesign --verify --deep --strict --verbose=2 "$APP"

    # Inspect every shipped Mach-O (including frameworks and helpers), retaining
    # the raw size -m output. A segment name in this report is a packaging failure.
    : > "$OUT/size-m.txt"
    while IFS= read -r -d '' path; do
        if file -b "$path" | grep -q 'Mach-O'; then
            echo "$path" >> "$OUT/size-m.txt"
            xcrun size -m "$path" >> "$OUT/size-m.txt"
        fi
    done < "$OUT/files.list"
    if grep -q '__LLVM_COV' "$OUT/size-m.txt"; then
        echo "ERROR: __LLVM_COV found; see $OUT/size-m.txt" >&2
        exit 1
    fi
    echo "Coverage check: no __LLVM_COV in shipped Mach-O files"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -ov -volname "Osaurus Fork" -srcfolder "$STAGE" -format UDZO "$DMG"
    codesign --force "$TIMESTAMP" --sign "$IDENTITY" "$DMG"
    hdiutil verify "$DMG"
    echo "Final allocated sizes (KiB):"
    du -sk "$APP" "$APP/Contents/MacOS" "$APP/Contents/Helpers/"* "$APP/Contents/Resources" "$DMG"
    echo "DMG bytes: $(stat -f %z "$DMG")"
    echo "Created $DMG (not notarized)"
}
package 2>&1 | tee "$OUT/package.log"
