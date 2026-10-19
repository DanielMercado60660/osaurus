#!/usr/bin/env bash
set -euo pipefail
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROOF="$ROOT/build/t07/isolated"
mkdir -p "$PROOF/Sources/OsaurusCore" "$PROOF/Tests/OsaurusCoreTests" "$ROOT/build/t07/module-cache"
cat > "$PROOF/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PhoneVoiceProof", platforms: [.macOS(.v15)], dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
], targets: [
    .target(name: "OsaurusCore", dependencies: [.product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio")]),
    .testTarget(name: "OsaurusCoreTests", dependencies: ["OsaurusCore", .product(name: "NIOEmbedded", package: "swift-nio")]),
])
SWIFT
cp "$ROOT/Packages/OsaurusCore/Networking/AudioSpeechWriter.swift" "$ROOT/Packages/OsaurusCore/Networking/AudioSpeechRequest.swift" "$PROOF/Sources/OsaurusCore/"
cp "$ROOT/Packages/OsaurusCore/Tests/Networking/AudioSpeechWriterTests.swift" "$ROOT/Packages/OsaurusCore/Tests/Networking/AudioSpeechTests.swift" "$PROOF/Tests/OsaurusCoreTests/"
CLANG_MODULE_CACHE_PATH="$ROOT/build/t07/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/t07/module-cache" \
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$ROOT/build/t07/test-root" OSU_MODELS_DIR="$ROOT/build/t07/empty-models" \
swift test --disable-keychain --disable-sandbox --package-path "$PROOF"
