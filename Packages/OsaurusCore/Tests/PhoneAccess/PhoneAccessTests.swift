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

    @Test func bundledWebRoutes() throws {
        for route in [
            "/phone", "/phone/", "/phone/app.js", "/phone/style.css", "/phone/manifest.webmanifest", "/phone/icon.svg",
            "/phone/icon-192.png", "/phone/icon-512.png", "/phone/sw.js", "/phone/capabilities",
        ] {
            #expect(PhoneWebAssets.asset(for: route) != nil, "Missing \(route)")
        }
        #expect(PhoneWebAssets.asset(for: "/phone/../../Package.swift") == nil)
        let capabilities = try #require(PhoneWebAssets.asset(for: "/phone/capabilities"))
        #expect(String(decoding: capabilities.body, as: UTF8.self).contains(#""speech":false"#))
    }
}
