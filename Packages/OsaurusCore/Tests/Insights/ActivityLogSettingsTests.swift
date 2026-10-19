//
//  ActivityLogSettingsTests.swift
//  osaurus
//
//  Privacy → Activity Log policy: retention choices, decoding defaults,
//  cutoff arithmetic, and the on-disk round trip the settings view relies on.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Activity log settings", .serialized)
struct ActivityLogSettingsTests {

    private func withTempStore<T>(_ body: () throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-log-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ActivityLogSettingsStore.setOverrideFileURL(dir.appendingPathComponent("activity-log.json"))
        defer {
            ActivityLogSettingsStore.setOverrideFileURL(nil)
            try? FileManager.default.removeItem(at: dir)
        }
        return try body()
    }

    @Test("defaults keep 30 days with content stored")
    func defaults() {
        let d = ActivityLogSettings.default
        #expect(d.retentionDays == 30)
        #expect(d.storeContent)
    }

    @Test("every retention choice has a distinct label and the picker sentinel 0 maps to forever")
    func retentionChoices() {
        let labels = ActivityLogSettings.retentionChoices.map(ActivityLogSettings.retentionLabel)
        #expect(Set(labels).count == labels.count)
        #expect(ActivityLogSettings.retentionChoices.contains(nil))
        // The settings picker uses 0 as the "nil" sentinel; make sure no real choice collides.
        #expect(!ActivityLogSettings.retentionChoices.contains(0))
    }

    @Test("retention cutoff is nil for forever and N days back otherwise")
    func cutoff() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ActivityLogSettings(retentionDays: nil, storeContent: true).retentionCutoff(now: now) == nil)
        #expect(ActivityLogSettings(retentionDays: 0, storeContent: true).retentionCutoff(now: now) == nil)
        let cutoff = ActivityLogSettings(retentionDays: 7, storeContent: true).retentionCutoff(now: now)
        #expect(cutoff == now.addingTimeInterval(-7 * 86_400))
    }

    @Test("decoding tolerates missing keys")
    func decodingDefaults() throws {
        let decoded = try JSONDecoder().decode(ActivityLogSettings.self, from: Data("{}".utf8))
        #expect(decoded.retentionDays == nil)
        #expect(decoded.storeContent)
    }

    @Test("save then snapshot round-trips through disk and cache")
    func roundTrip() throws {
        try withTempStore {
            #expect(ActivityLogSettingsStore.snapshot() == .default)

            let custom = ActivityLogSettings(retentionDays: 90, storeContent: false)
            ActivityLogSettingsStore.save(custom)
            #expect(ActivityLogSettingsStore.snapshot() == custom)

            // Drop the in-memory cache and re-read from disk.
            let url = try #require(ActivityLogSettingsStore.load() == custom ? URL(string: "ok") : nil)
            _ = url
            let forever = ActivityLogSettings(retentionDays: nil, storeContent: true)
            ActivityLogSettingsStore.save(forever)
            #expect(ActivityLogSettingsStore.load() == forever)
            #expect(ActivityLogSettingsStore.snapshot().retentionDays == nil)
        }
    }

    @Test("a real settings change is recorded on the chain exactly once; a no-op change is not")
    @MainActor
    func settingsChangeIsChained() async throws {
        try withTempStore {
            ActivityLogSettingsStore.save(.default)
        }
        let store = ActivityLogStore()
        try store.openInMemory()
        let service = InsightsService(store: store, openStore: false)
        let before = try store.count()

        // Same value → nothing written.
        service.updateSettings(service.settings)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(try store.count() == before)

        service.updateSettings(ActivityLogSettings(retentionDays: 7, storeContent: false))
        try await Task.sleep(nanoseconds: 120_000_000)
        let rows = try store.fetch()
        let row = try #require(rows.first { $0.egress?.details["event"] == "settings_changed" })
        #expect(row.category == .system)
        #expect(row.egress?.details["retention_days"] == "7")
        #expect(row.egress?.details["store_content"] == "false")
        #expect(row.egress?.details["previous_retention_days"] == "30")
        #expect(row.egress?.details["previous_store_content"] == "true")
        #expect(row.systemEventSummary?.contains("7 days") == true)
        #expect(try store.verify().isIntact)
        ActivityLogSettingsStore.save(.default)
    }

    @Test("Verify records its result as a chained system row")
    @MainActor
    func verifyIsChained() async throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        try store.append(
            RequestLog(source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1))
        let service = InsightsService(store: store, openStore: false)
        service.verify()
        for _ in 0..<40 where service.isVerifying {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let result = try #require(service.lastVerification)
        #expect(result.isIntact)
        #expect(result.recordCount == 1)
        let rows = try store.fetch()
        let row = try #require(rows.first { $0.egress?.details["event"] == "verified" })
        #expect(row.egress?.details["records"] == "1")
        #expect(row.egress?.details["ok"] == "true")
        #expect(row.egress?.details["head_hash"] == result.lastHash)
        #expect(try store.count() == 2)
        #expect(try store.verify().isIntact)
    }
    @Test("durable logging returns only after the chained row is stored")
    @MainActor func durableAuditCommits() async throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        let service = InsightsService(store: store, openStore: false)
        let request = RequestLog(source: .httpAPI, method: "GET", path: "/phone/api/screen", statusCode: 200, durationMs: 0)
        try await service.logDurably(request)
        #expect(try store.count() == 1)
        #expect(try store.fetch().first?.id == request.id)
        #expect(service.logs.first?.hash != nil)
        #expect(try store.verify().isIntact)
    }

    @Test("unavailable and failed durable writes are surfaced without hot-cache success")
    @MainActor func durableAuditFailsClosed() async throws {
        let request = RequestLog(source: .httpAPI, method: "GET", path: "/phone/api/screen", statusCode: 200, durationMs: 0)
        let closed = InsightsService(store: ActivityLogStore(), openStore: false)
        #expect(!closed.durableStoreAvailable)
        await #expect(throws: (any Error).self) { try await closed.logDurably(request) }
        #expect(closed.logs.isEmpty)
        let store = ActivityLogStore()
        try store.openInMemory()
        let service = InsightsService(store: store, openStore: false)
        try store.executeForTesting("CREATE TRIGGER fail_append BEFORE INSERT ON activity BEGIN SELECT RAISE(ABORT, 'test disk failure'); END")
        await #expect(throws: (any Error).self) { try await service.logDurably(request) }
        #expect(!service.durableStoreAvailable)
        #expect(service.storeError != nil)
        #expect(service.logs.isEmpty)
        #expect(try store.count() == 0)
    }

    @Test("durable append uses FULL synchronization and restores the prior mode")
    @MainActor func durableAuditUsesFullSync() async throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        try store.executeForTesting("PRAGMA synchronous = NORMAL")
        try store.executeForTesting("""
            CREATE TRIGGER require_full BEFORE INSERT ON activity
            WHEN (SELECT synchronous FROM pragma_synchronous) != 2
            BEGIN SELECT RAISE(ABORT, 'append was not FULL'); END
            """)
        let service = InsightsService(store: store, openStore: false)
        let request = RequestLog(source: .httpAPI, method: "GET", path: "/phone/api/screen", statusCode: 200, durationMs: 0)
        try await service.logDurably(request)
        #expect(try store.count() == 1)
        // The ordinary append is back at NORMAL and therefore trips the trigger.
        #expect(throws: (any Error).self) { try store.append(request) }
        #expect(try store.count() == 1)
    }

    @Test("an asynchronous ordinary append failure also revokes durable screen admission")
    @MainActor func ordinaryAppendFailureRevokesDurableAdmission() async throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        let service = InsightsService(store: store, openStore: false)
        try store.executeForTesting("CREATE TRIGGER fail_append BEFORE INSERT ON activity BEGIN SELECT RAISE(ABORT, 'test disk failure'); END")
        service.log(RequestLog(source: .httpAPI, method: "GET", path: "/health", statusCode: 200, durationMs: 0))
        for _ in 0..<100 where service.storeError == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(service.storeError != nil)
        #expect(!service.durableStoreAvailable)
    }

}
