import Foundation
import Testing
@testable import OsaurusCore

@Suite("Phone access")
struct PhoneAccessTests {
    @Test func statusParsing() {
        #expect(
            PhoneAccessStatus.parse(#"{"type":"login_url","value":"https://login.tailscale.com/a/123"}"#)?.type
                == "login_url"
        )
        #expect(PhoneAccessStatus.parse(#"{"type":"running","value":"http://mac.tail.ts.net/phone"}"#) != nil)
        for line in [
            "not json", #"{"type":"unknown","value":"x"}"#, #"{"type":"error"}"#,
            #"{"type":"login_url","value":"file:///etc/passwd"}"#,
            #"{"type":"running","value":"https://user:pass@host/phone"}"#,
            String(repeating: "x", count: 16_385),
        ] {
            #expect(PhoneAccessStatus.parse(line) == nil)
        }
    }

    @Test func lifecycle() {
        var state = PhoneAccessState()
        let running = PhoneAccessStatus(type: "running", value: "https://mac.tail.ts.net/phone")
        state.receive(running); #expect(state.phase == .stopped)
        state.start(); #expect(state.phase == .starting)
        state.receive(.init(type: "login_url", value: "https://login.tailscale.com/a/1"))
        #expect(state.phase == .needsLogin)
        state.receive(.init(type: "owner_login", value: "owner@example.com"))
        state.receive(.init(type: "dns_name", value: "mac.tail.ts.net"))
        state.receive(running)
        #expect(state.phase == .running && state.loginURL == nil)
        #expect(state.ownerLogin == "owner@example.com")
        state.receive(.init(type: "login_url", value: "https://login.tailscale.com/a/stale"))
        #expect(state.phase == .running)
        state.receive(.init(type: "error", value: "failed"))
        #expect(state.phase == .failed && state.phoneURL == nil)
        state.receive(running); #expect(state.phase == .failed)
        state.stop(); #expect(state == PhoneAccessState())
        state.start(); state.receive(running); #expect(state.phase == .running)
    }

    @Test func trustRequiresLiveCapabilityAndLoopback() {
        let trust = PhoneAccessTrust(), first = String(repeating: "a", count: 64),
            next = String(repeating: "b", count: 64)
        #expect(!trust.accepts(first, physicalLoopback: true))
        trust.replace(with: first)
        #expect(trust.accepts(first, physicalLoopback: true))
        #expect(!trust.accepts(first, physicalLoopback: false))
        #expect(!trust.accepts(nil, physicalLoopback: true))
        #expect(!trust.accepts(next, physicalLoopback: true))
        trust.replace(with: next)
        #expect(!trust.accepts(first, physicalLoopback: true))
        trust.replace(with: nil)
        #expect(!trust.accepts(next, physicalLoopback: true))
    }

    @Test @MainActor func preferencesDefaultOffAndPersist() throws {
        let name = "PhoneAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = TailscalePhoneAccessService(defaults: defaults)
        #expect(!service.enabled)
        service.saveAllowedLogins(" Owner@Example.com,\n second@example.com ")
        #expect(service.allowedLogins == "owner@example.com,second@example.com")
        service.setEnabled(true)  // No server: no helper or network can launch.
        #expect(service.state.phase == .failed)
        let relaunched = TailscalePhoneAccessService(defaults: defaults)
        #expect(relaunched.enabled && relaunched.allowedLogins == service.allowedLogins)
        service.setEnabled(false)
        #expect(service.state.phase == .stopped)
    }

    @Test func deviceStatusParsing() throws {
        let event = try #require(PhoneAccessStatus.parse(
            #"{"type":"device","device":{"stableID":"n123","name":"Phone","login":"owner@example.com","allowed":false}}"#
        ))
        #expect(event.device?.stableID == "n123")
        #expect(event.device?.allowed == false)
        #expect(PhoneAccessStatus.parse(
            #"{"type":"device","device":{"stableID":"tagged","name":"Node","login":"","allowed":false}}"#
        ) != nil)
        for invalid in [
            #"{"type":"device"}"#,
            #"{"type":"device","device":{"stableID":"","name":"Phone","login":"owner","allowed":true}}"#,
            #"{"type":"device","device":{"stableID":"a,b","name":"Phone","login":"owner","allowed":true}}"#,
            #"{"type":"device","device":{"stableID":"a","name":"Phone","login":"owner"}}"#,
        ] { #expect(PhoneAccessStatus.parse(invalid) == nil) }
    }

    @Test @MainActor func deviceRestrictionsAndDiscoveriesPersist() throws {
        let name = "PhoneDevicesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = TailscalePhoneAccessService(defaults: defaults)
        #expect(!service.restrictDevices && service.allowedDeviceIDs.isEmpty && service.devices.isEmpty)
        let denied = PhoneAccessDevice(stableID: "n123", name: "Phone", login: "owner", allowed: false)
        service.recordDevice(denied)
        service.recordDevice(denied)
        #expect(service.devices.count == 1)
        service.saveDeviceRestrictions(true, selectedIDs: ["n123"])
        let updated = PhoneAccessDevice(stableID: "n123", name: "Renamed phone", login: "owner", allowed: true)
        service.recordDevice(updated)
        let relaunched = TailscalePhoneAccessService(defaults: defaults)
        #expect(relaunched.restrictDevices && relaunched.allowedDeviceIDs == ["n123"])
        #expect(relaunched.devices == [updated])
        relaunched.saveDeviceRestrictions(true, selectedIDs: [])
        let locked = TailscalePhoneAccessService(defaults: defaults)
        #expect(locked.restrictDevices && locked.allowedDeviceIDs.isEmpty)
        locked.saveDeviceRestrictions(false, selectedIDs: ["n123"])
        #expect(!TailscalePhoneAccessService(defaults: defaults).restrictDevices)
    }

    @Test func developmentDigestFailsClosed() {
        let digest = String(repeating: "a", count: 64)
        #expect(PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(digest, expected: digest))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(digest, expected: nil))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(digest, expected: ""))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(digest, expected: "$(OSAURUS_TS_HELPER_SHA256)"))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(digest, expected: digest.uppercased()))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(digest, expected: String(repeating: "b", count: 64)))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest("bad", expected: "bad"))
        #expect(!PhoneAccessHelperIntegrity.acceptsDevelopmentDigest(String(repeating: "z", count: 64), expected: String(repeating: "z", count: 64)))
    }

    @Test func helperRejectsUnsafeFilesBeforeSignatureCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        try Data("test".utf8).write(to: helper)
        for mode in [0o775, 0o757, 0o777, 0o644] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: helper.path)
            #expect(throws: PhoneAccessHelperIntegrity.IntegrityError.self) {
                try PhoneAccessHelperIntegrity.validate(helper: helper)
            }
        }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        #expect(throws: PhoneAccessHelperIntegrity.IntegrityError.self) {
            try PhoneAccessHelperIntegrity.validate(helper: link)
        }
    }

    @Test func bundledWebRoutes() throws {
        for route in [
            "/phone", "/phone/", "/phone/app.js", "/phone/style.css", "/phone/manifest.webmanifest", "/phone/icon.svg",
            "/phone/icon-192.png", "/phone/icon-512.png", "/phone/sw.js", "/phone/voice.js", "/phone/capabilities",
        ] {
            #expect(PhoneWebAssets.asset(for: route) != nil, "Missing \(route)")
        }
        #expect(PhoneWebAssets.asset(for: "/phone/../../Package.swift") == nil)
        let capabilities = try #require(PhoneWebAssets.asset(for: "/phone/capabilities"))
        #expect(String(decoding: capabilities.body, as: UTF8.self).contains(#""speech":true"#))
    }
}
