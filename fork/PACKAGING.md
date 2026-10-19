# Fork packaging (Apple silicon)

From the repository root on a Mac with Xcode/Metal and Go available:

```bash
make fork-dmg
# Or, on a signer with an already configured Developer ID certificate:
make fork-dmg CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

The default is ad-hoc signing (`-`); it does not use a private signing key.
The signed lane requires the caller's existing certificate/key access. This
target never logs in, exports credentials, or submits for notarization.
`make app` retains its existing build/embed recipe.

Expected output is `build/fork/Osaurus-fork-<git short sha>.dmg`, a compressed
UDZO image with `Osaurus.app` and an Applications shortcut. Open the image and
drag the app to Applications. The filename identifies HEAD; uncommitted changes
are included and shown in the packaging log. Use a clean committed checkout for
release provenance.

The lane builds the CLI and plugin host, archives the Release app with install
stripping, embeds all three helpers, and stages the digest-verified sandbox
kernel with its provenance using the existing fetch script. DerivedData,
SourcePackages and the default kernel cache stay under `build/fork/`.
Only that lane's previous archive and staging directory are cleared. Go's
normal compiler/module caches are still used.

The Go helper uses `-trimpath -ldflags "-s -w"`. Packaging also builds an
unstripped comparison with the same target/signing identity, reports both byte
counts, and retains it at `build/fork/osaurus-ts-unstripped`. The CLI and plugin
host are stripped before signing, with before/after byte counts printed.
The final log reports allocated KiB for the bundle, MacOS, each helper,
Resources and DMG, plus the exact DMG byte size. These are measurements of that
build, not a comparison against the old 508 MB unarchived local baseline.

Code is signed inside-out with hardened runtime. The app, CLI and plugin host
use `App/osaurus/osaurus.entitlements`; nested frameworks retain their own
entitlements. The already signed Go helper is not re-signed after hashing.
`codesign --verify --deep --strict` must succeed before DMG creation.

## Helper pin

`make ts-helper` writes only the helper and ignored
`build/PhoneAccessHelper.xcconfig`. The project-level `App/PhoneAccess.xcconfig`
optionally includes that file for Debug and Release. The app's Info.plist expands
`OSAURUS_TS_HELPER_SHA256` into `OsaurusTSHelperSHA256`; no generated Swift source
is tracked or compiled. Direct Xcode builds can prepare it with `make ts-helper`
first, or supply the build setting explicitly for an already signed helper.

No-team builds read the pin from `Bundle.main` and reject absent, empty,
unexpanded, malformed or mismatched values. Runtime environment variables and
sidecars cannot supply it. Team-signed apps retain the valid-signature and
matching-Team-ID policy. Signing seals Info.plist. Replacing or re-signing a
development helper requires rebuilding the plist pin and sealing the app again.
The DMG lane passes the frozen helper hash explicitly to Xcode and checks it
against the archived plist and final helper bytes before packaging.

## Verification and host follow-up

```bash
scripts/test-phone-access-isolated.sh
scripts/test-phone-helper-integrity.sh
scripts/test-phone-helper-build-setting.sh
python3 scripts/test-fork-packaging.py
```

The packaging tests use fake build/sign/disk commands to exercise orchestration
and failure propagation. The integrity tests use real ad-hoc-signed fixture apps
and the actual Go helper, but do not start Tailscale. The build-setting test reads
real Xcode settings from a dependency-free project copy. None is full app proof.

All three Xcode invocations pass `ENABLE_CODE_COVERAGE=NO` and
`CLANG_COVERAGE_MAPPING=NO`. Packaging runs `xcrun size -m` on every shipped
Mach-O, writes `build/fork/size-m.txt`, and fails if `__LLVM_COV` appears. Inspect
the app directly as well:

```bash
APP=build/fork/dmg-root/Osaurus.app
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun size -m "$APP/Contents/MacOS/osaurus"
shasum -a 256 "$APP/Contents/Helpers/osaurus-ts"
/usr/libexec/PlistBuddy -c 'Print :OsaurusTSHelperSHA256' "$APP/Contents/Info.plist"
hdiutil verify "build/fork/Osaurus-fork-$(git rev-parse --short HEAD).dmg"
```

On the host, mount the DMG, copy the app, launch it, exercise Chat/Settings and
phone-helper startup/relaunch, CLI execution, plugin loading and sandbox setup.
Record actual bundle/component/DMG sizes, coverage output, signatures and live
results. For signed distribution, verify matching/mismatching helper teams and
the signed framework/XPC hierarchy. Those checks cannot be inferred from unit
tests or a successful archive.

Optional notarization, run by the signer after Developer ID packaging with an
already stored notarytool profile (never run by `make fork-dmg`):

```bash
DMG="build/fork/Osaurus-fork-$(git rev-parse --short HEAD).dmg"
xcrun notarytool submit "$DMG" --keychain-profile YOUR_EXISTING_PROFILE --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
```
