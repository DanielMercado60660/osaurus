#!/usr/bin/env bash
# Real Insights facade, hash-chain store and models; system SQLite replaces
# SQLCipher only for this plaintext/in-memory proof. No app/keychain dependencies.
set -euo pipefail
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROOF="$ROOT/build/T13b/audit-isolated"
CORE="$ROOT/Packages/OsaurusCore"
mkdir -p "$PROOF/Sources/OsaurusCore" "$PROOF/Sources/OsaurusSQLCipher" "$PROOF/Tests/OsaurusCoreTests" "$PROOF/module-cache" "$PROOF/test-root"
cat > "$PROOF/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PhoneScreenAuditProof", platforms: [.macOS(.v15)], targets: [
    .systemLibrary(name: "OsaurusSQLCipher"),
    .target(name: "OsaurusCore", dependencies: ["OsaurusSQLCipher"]),
    .testTarget(name: "OsaurusCoreTests", dependencies: ["OsaurusCore"]),
])
SWIFT
cat > "$PROOF/Sources/OsaurusSQLCipher/module.modulemap" <<'MAP'
module OsaurusSQLCipher [system] { header "shim.h" link "sqlite3" export * }
MAP
cat > "$PROOF/Sources/OsaurusSQLCipher/shim.h" <<'C'
#include <sqlite3.h>
C
cp "$CORE/Managers/InsightsService.swift" "$CORE/Storage/ActivityLogStore.swift" \
   "$CORE/Models/Chat/RequestLog.swift" "$CORE/Models/Insights/ActivityFilter.swift" \
   "$CORE/Models/Insights/ActivityLogSettings.swift" "$PROOF/Sources/OsaurusCore/"
cp "$CORE/Tests/Insights/ActivityLogSettingsTests.swift" "$CORE/Tests/Insights/ActivityLogStoreTests.swift" "$PROOF/Tests/OsaurusCoreTests/"
cat > "$PROOF/Sources/OsaurusCore/IntegrationShims.swift" <<'SWIFT'
import Foundation
import OsaurusSQLCipher
func L(_ text: String) -> String { text }
enum ToolRegistry { static let agentChannelToolNames: Set<String> = [] }
enum AgentManager { static func agentDisplayName(for id: UUID) -> String? { nil } }
enum RemoteProviderManager { static func providerDisplayName(for id: UUID) -> String? { nil } }
enum ChatExecutionContext {
    static let currentAgentId: UUID? = nil
    static let currentSessionId: String? = nil
}
enum WireTransportProbe { struct PrivacyOutcome { let applied: Bool; let redactedCount: Int } }
enum OsaurusPaths {
    static func activity() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]!) }
    static func activityLogDatabaseFile() -> URL { activity().appendingPathComponent("activity.sqlite") }
    static func activityLogHeadFile() -> URL { activity().appendingPathComponent("activity.head") }
    static func activityLogConfigFile() -> URL { activity().appendingPathComponent("settings.json") }
    static func ensureExistsSilent(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}
enum StorageMutationGate { static func blockingAwaitNotMutating() {} }
enum StorageRecoveryService { enum Store: String { case activityLog } }
struct PersistenceHealth: Sendable {
    static let shared = PersistenceHealth()
    func recordDatabaseOpenFailure(subsystem: String, error: any Error, path: String) {}
}
struct OsaurusDatabaseHandle: Sendable {
    init(name: String, exec: @escaping @Sendable (String) -> Void, closer: @escaping @Sendable () -> Void, reopener: @escaping @Sendable () -> Void) {}
    static func register(_ handle: Self) {}
    static func deregister(name: String) {}
}
enum EncryptedSQLiteError: Error { case open }
enum EncryptedSQLiteOpener {
    static func open(path: String, key: Data?, applyPerfPragmas: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw EncryptedSQLiteError.open }
        if applyPerfPragmas { sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL", nil, nil, nil) }
        return db
    }
}
enum OsaurusStorageOpener {
    static func open(path: String) throws -> OpaquePointer { try EncryptedSQLiteOpener.open(path: path, key: nil, applyPerfPragmas: true) }
}
SWIFT
CLANG_MODULE_CACHE_PATH="$PROOF/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PROOF/module-cache" \
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$PROOF/test-root" OSU_MODELS_DIR="$PROOF/empty-models" \
swift test --disable-keychain --disable-sandbox --package-path "$PROOF"
