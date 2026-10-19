#!/bin/bash
# Pure production policy + all committed RAM fixtures. No model downloads.
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_EVALS_SCRIPTED_ONLY=1
export OSAURUS_TEST_ROOT="$PWD/build/T12/test-root" OSU_MODELS_DIR="$PWD/build/T12/test-models"
export CLANG_MODULE_CACHE_PATH="$PWD/build/T12/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/T12/module-cache"
export T12_SUITES="$PWD/Packages/OsaurusEvals/Suites/RAMAdmission"
HARNESS="$PWD/build/T12/isolated"
mkdir -p "$HARNESS/Sources/OsaurusCore" "$HARNESS/Tests/Tests"
cat > "$HARNESS/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TalkMemoryProof", platforms: [.macOS(.v15)], targets: [
    .target(name: "OsaurusCore"), .testTarget(name: "Tests", dependencies: ["OsaurusCore"])])
SWIFT
for file in Services/Voice/TalkMemoryBudget.swift Services/ModelRuntime/AuxiliaryModelResidency.swift Models/Configuration/GPUMemoryBudget.swift Subagent/SubagentAdmission.swift Subagent/SubagentBatchAdmissionPlanner.swift Services/Context/SubagentAdmissionEvaluator.swift; do
    cp "Packages/OsaurusCore/$file" "$HARNESS/Sources/OsaurusCore/"
done
cat > "$HARNESS/Sources/OsaurusCore/Stubs.swift" <<'SWIFT'
// Only unrelated display/remote-limit types; production memory math unchanged.
enum ModelCompatibility { case compatible, tight, tooLarge, unknown }
struct ModelBatchCapacitySnapshot: Sendable, Equatable {}
enum SubagentBudgets { static let remoteParallelSpawnBounds = 1...32 }
SWIFT
cp Packages/OsaurusCore/Tests/Voice/TalkMemoryBudgetTests.swift "$HARNESS/Tests/Tests/"
cat > "$HARNESS/Tests/Tests/RAMFixturesTests.swift" <<'SWIFT'
import Foundation
import Testing
@testable import OsaurusCore
// Minimal decoding envelope only. Production eval runner is compiled in the
// full package lane; this isolated lane executes the same production policies.
private struct Fixture: Decodable {
    struct Expect: Decodable {
        struct Subagent: Decodable {
            struct RAM: Decodable {
                let scenario: SubagentAdmissionEvaluator.Scenario
                let expected: [SubagentAdmissionEvaluator.Observation]
            }
            struct Talk: Decodable {
                let facts: TalkMemoryBudget.Facts
                let expected: TalkMemoryBudget.Decision
            }
            let ramAdmission: RAM?
            let talkMemory: Talk?
        }
        let subagent: Subagent
    }
    let expect: Expect
}
struct RAMFixturesTests {
    @Test func allCommittedRAMFixtures() async throws {
        #expect(ProcessInfo.processInfo.environment["OSAURUS_EVALS_SCRIPTED_ONLY"] == "1")
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["T12_SUITES"]))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        #expect(files.count == 22)
        for file in files {
            let row = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file)).expect.subagent
            if let fixture = row.ramAdmission {
                let actual = await SubagentAdmissionEvaluator.run(fixture.scenario)
                #expect(actual == fixture.expected, "\(file.lastPathComponent): \(actual)")
            } else {
                let fixture = try #require(row.talkMemory)
                #expect(TalkMemoryBudget.assess(fixture.facts) == fixture.expected, "\(file.lastPathComponent)")
            }
            print("RAM fixture checked: \(file.lastPathComponent)")
        }
    }
}
SWIFT
python3 fork/tasks/T12-16gb-voice-budget.verify.py
swift test --disable-keychain --disable-sandbox --package-path "$HARNESS" \
    --cache-path "$PWD/build/T12/swiftpm-cache" --config-path "$PWD/build/T12/swiftpm-config" \
    --security-path "$PWD/build/T12/swiftpm-security" --jobs 4
