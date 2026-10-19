import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import OsaurusCore

private let screenSecret = String(repeating: "s", count: 64)
private func screenCaller() -> PhoneScreenCaller {
    PhoneScreenCaller(marker: "1", secret: screenSecret, deviceID: "node-1", physicalLoopback: true, relay: false, hasAuthorization: false, login: "owner@example.com")
}
private func screenTrust() -> PhoneAccessTrust {
    let trust = PhoneAccessTrust(); trust.replace(with: screenSecret); trust.setOwnerLogin("owner@example.com"); return trust
}
private final class ScreenAuditSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PhoneScreenAudit] = []
    func record(_ event: PhoneScreenAudit) { lock.lock(); defer { lock.unlock() }; entries.append(event) }
    var events: [PhoneScreenAudit] { lock.lock(); defer { lock.unlock() }; return entries }
}
private actor ScreenCaptureLatch {
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var started = false
    func capture() async -> Data { started = true; return await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: Data([1, 2, 3])); continuation = nil; started = false }
}

private struct DeniedScreenPermission: ScreenshotPermissionChecking {
    func hasScreenRecordingPermission() -> Bool { false }
}
private actor UnexpectedScreenCapture: ScreenshotImageCapturing {
    private(set) var calls = 0
    func capture(includeCursor: Bool) async throws -> ScreenshotImage {
        calls += 1
        return ScreenshotImage(pngData: Data(), width: 1, height: 1, displayID: nil)
    }
}

private final class RejectionScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []
    private var totals: [Int] = []
    func schedule(_ work: @escaping @Sendable () -> Void) { lock.lock(); defer { lock.unlock() }; callbacks.append(work) }
    func emit(_ count: Int) { lock.lock(); defer { lock.unlock() }; totals.append(count) }
    var pending: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    var emitted: [Int] { lock.lock(); defer { lock.unlock() }; return totals }
    func fire() {
        lock.lock(); let work = callbacks.removeFirst(); lock.unlock()
        work()
    }
}

@Suite("Phone screen")
struct PhoneScreenTests {
    @Test func trustMatrix() {
        let trust = screenTrust(), owner = screenCaller()
        #expect(owner.mayView(enabled: true, using: trust))
        var upper = owner; upper.login = "OWNER@EXAMPLE.COM"
        #expect(upper.mayView(enabled: true, using: trust))
        let unknownOwner = PhoneAccessTrust(); unknownOwner.replace(with: screenSecret)
        #expect(owner.verifiedDevice(using: unknownOwner) == nil)
        #expect(!owner.mayView(enabled: false, using: trust))
        var cases: [PhoneScreenCaller] = []
        var caller = owner; caller.marker = nil; cases.append(caller)
        caller = owner; caller.marker = "0"; cases.append(caller)
        caller = owner; caller.secret = nil; cases.append(caller)
        caller = owner; caller.secret = String(repeating: "x", count: 64); cases.append(caller)
        caller = owner; caller.physicalLoopback = false; cases.append(caller)
        caller = owner; caller.relay = true; cases.append(caller)
        caller = owner; caller.hasAuthorization = true; cases.append(caller)
        caller = owner; caller.secureChannel = true; cases.append(caller)
        caller = owner; caller.marker = nil; caller.secret = nil; cases.append(caller) // ordinary loopback
        caller.hasAuthorization = true; cases.append(caller) // API key alone
        caller = owner; caller.login = nil; cases.append(caller)
        caller = owner; caller.login = "other@example.com"; cases.append(caller)
        caller = owner; caller.login = "owner@example.com,other@example.com"; cases.append(caller)
        caller = owner; caller.deviceID = nil; cases.append(caller)
        caller = owner; caller.deviceID = ""; cases.append(caller)
        caller = owner; caller.deviceID = "forged\nnode"; cases.append(caller)
        caller = owner; caller.deviceID = String(repeating: "a", count: 257); cases.append(caller)
        for rejected in cases { #expect(!rejected.mayView(enabled: true, using: trust)) }
        trust.replace(with: nil)
        #expect(!owner.mayView(enabled: true, using: trust))
    }

    @Test func options() {
        #expect(PhoneScreenOptions.parse(query: nil)?.maxDimension == 1280)
        #expect(PhoneScreenOptions.parse(query: "display=main&max=640")?.maxDimension == 640)
        #expect(PhoneScreenOptions.parse(query: "max=9000")?.maxDimension == 1280)
        for query in ["display=other", "display", "max=0", "max=-1", "max=x", "max", "max=1&max=2", "extra=1", "max=%ZZ", "max=12#hidden"] {
            #expect(PhoneScreenOptions.parse(query: query) == nil)
        }
    }

    @Test func rateLimitAndOutstandingCapture() {
        var limiter = PhoneScreenRateLimiter()
        func admit(device: String, now: TimeInterval) -> Bool { limiter.begin(device: device, now: now) }
        #expect(admit(device: "a", now: 0))
        #expect(!admit(device: "a", now: 2)) // still in flight
        #expect(admit(device: "b", now: 0))
        limiter.finish(device: "a")
        #expect(!admit(device: "a", now: 0.499))
        #expect(admit(device: "a", now: 0.5))
        limiter.finish(device: "a")
        #expect(admit(device: "a", now: 61)) // prunes idle device entries
        #expect(!admit(device: "b", now: 61)) // preserves outstanding devices
    }

    @Test func indicatorTimeout() {
        var state = PhoneScreenViewingState()
        #expect(!state.isViewing(now: 0))
        state.noteFrame(now: 10)
        #expect(state.isViewing(now: 14.999))
        #expect(!state.isViewing(now: 15))
        state.noteFrame(now: 14)
        #expect(state.isViewing(now: 18.999))
        #expect(!state.isViewing(now: 19))
        state.clear(); #expect(!state.isViewing(now: 14))
    }

    @MainActor @Test func defaultOffAndPersistence() throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let first = PhoneScreenService(defaults: defaults, indicator: { _ in }, notify: {})
        #expect(!first.allowed)
        first.setAllowed(true)
        #expect(PhoneScreenService(defaults: defaults, indicator: { _ in }, notify: {}).allowed)
        first.setAllowed(false)
        #expect(!PhoneScreenService(defaults: defaults, indicator: { _ in }, notify: {}).allowed)
    }

    @MainActor @Test func deniedRequestsAuditWithoutCapture() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { false },
            capture: { _ in Issue.record("denied request captured pixels"); return Data() },
            auditAvailable: { true }, audit: { spy.record($0) }, indicator: { _ in }, notify: {})
        var caller = screenCaller(); caller.marker = nil
        #expect(await service.response(caller: caller, query: nil, method: "GET").errorCode == "phone_owner_required")
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").errorCode == "screen_disabled")
        service.setAllowed(true)
        #expect(await service.response(caller: screenCaller(), query: nil, method: "POST").status == 405)
        #expect(await service.response(caller: screenCaller(), query: "display=all", method: "GET").status == 400)
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").errorCode == "screen_permission_missing")
        #expect(spy.events.count == 1)
        #expect(spy.events[0].deviceID == "node-1")
        #expect(spy.events.allSatisfy { $0.bytes == 0 })
        #expect(spy.events[0].errorCode == "screen_disabled")
    }

    @MainActor @Test func frameCreatesMetadataOnlyAuditAndRateLimits() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let spy = ScreenAuditSpy()
        var visible = false
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { max in #expect(max == 640); return Data([1, 2, 3]) },
            auditAvailable: { true }, audit: { spy.record($0) }, indicator: { visible = $0 }, notify: {})
        service.setAllowed(true)
        let response = await service.response(caller: screenCaller(), query: "max=640", method: "GET")
        #expect(response.status == 200 && response.contentType == "image/jpeg")
        #expect(visible)
        #expect(spy.events.count == 1)
        #expect(spy.events[0].event == "screen view started (device node-1)")
        #expect(spy.events[0].bytes == 0) // durable start precedes capture
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 429)
        #expect(spy.events.count == 2)
        service.setAllowed(false); #expect(!visible)
    }

    @MainActor @Test(arguments: [false, true]) func revokeDuringCapture(rotatingSecret: Bool) async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let latch = ScreenCaptureLatch(), trust = screenTrust(), spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: trust, permission: { true },
            capture: { _ in await latch.capture() }, auditAvailable: { true }, audit: { spy.record($0) }, indicator: { _ in }, notify: {})
        service.setAllowed(true)
        let task = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        if rotatingSecret { trust.replace(with: String(repeating: "x", count: 64)) }
        else { service.setAllowed(false); service.setAllowed(true) } // off/on cannot revive an old frame
        await latch.finish()
        #expect(await task.value.errorCode == "screen_revoked")
        #expect(spy.events.first?.bytes == 0)
        service.stopViewing()
    }

    @MainActor @Test func cancelledCaptureDoesNotReturnPixels() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let latch = ScreenCaptureLatch(), spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in await latch.capture() }, auditAvailable: { true }, audit: { spy.record($0) }, indicator: { _ in }, notify: {})
        service.setAllowed(true)
        let task = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        task.cancel(); await latch.finish()
        #expect(await task.value.errorCode == "screen_cancelled")
        #expect(spy.events.first?.bytes == 0)
        service.stopViewing()
    }

    @Test func capturePreviewReusesPermissionGate() async throws {
        let capturer = UnexpectedScreenCapture()
        let service = ScreenshotCaptureService(permissionChecker: DeniedScreenPermission(), capturer: capturer)
        await #expect(throws: ScreenshotCaptureError.missingScreenRecordingPermission) {
            try await service.capturePreviewJPEG(maxDimension: 1280)
        }
        #expect(await capturer.calls == 0)
    }

    @Test func activityEntryNamesDeviceWithoutStoringPixels() {
        let event = PhoneScreenAudit(deviceID: "node-123", status: 200, bytes: 1234, errorCode: nil)
        let egress = PhoneScreenActivityLogger.egress(for: event)
        #expect(egress.destinationLabel == "Phone screen preview")
        #expect(egress.bytesSent == 1234)
        #expect(egress.dataClasses == ["screen_image"])
        #expect(egress.details["phone_device_id"] == "node-123")
        let denied = PhoneScreenActivityLogger.egress(for: PhoneScreenAudit(
            deviceID: nil, status: 403, bytes: 0, errorCode: "phone_owner_required"))
        #expect(denied.dataClasses.isEmpty)
        #expect(denied.details["phone_device_id"] == "unverified")
        #expect(denied.details["error_code"] == "phone_owner_required")
    }

    @Test func jpegDownscalesAndPreservesAspectRatio() throws {
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage()), png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let jpeg = try ScreenshotCaptureService.previewJPEG(from: png as Data, maxDimension: 640)
        let decoded = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(thumbnail.width == 640 && thumbnail.height == 320)
        #expect(throws: (any Error).self) { try ScreenshotCaptureService.previewJPEG(from: Data(), maxDimension: 100) }
    }
    @Test func unverifiedBurstSchedulesOneAggregateAcrossThreads() {
        let scheduler = RejectionScheduler()
        let counter = PhoneScreenRejections(schedule: { scheduler.schedule($0) }, emit: { scheduler.emit($0) })
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in counter.reject() }
        #expect(scheduler.pending == 1)
        #expect(scheduler.emitted.isEmpty)
        scheduler.fire()
        #expect(scheduler.emitted == [10_000])
        counter.reject(); counter.reject()
        #expect(scheduler.pending == 1)
        scheduler.fire()
        #expect(scheduler.emitted == [10_000, 2])
    }

    @MainActor @Test func framesCoalesceAndNotifyAfterIdleGap() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let spy = ScreenAuditSpy()
        var clock: TimeInterval = 0
        var notifications = 0
        var visible = false
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in
                #expect(!spy.events.isEmpty) // durable start completed before first capture
                return Data([1, 2, 3])
            }, auditAvailable: { true }, audit: { spy.record($0) }, indicator: { visible = $0 },
            notify: { notifications += 1 }, now: { clock })
        service.setAllowed(true)
        for tick in 0..<120 {
            clock = Double(tick) / 2
            #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 200)
        }
        #expect(spy.events.count == 1)
        #expect(notifications == 1)
        clock = 60
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 200)
        #expect(spy.events.count == 2)
        #expect(spy.events[1].event == "screen view continued")
        #expect(spy.events[1].count == 120 && spy.events[1].bytes == 360)
        clock = 64.999; service.refreshIndicator(); #expect(visible)
        clock = 65; service.refreshIndicator(); #expect(!visible)
        clock = 121
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 200)
        #expect(notifications == 2 && visible)
        #expect(spy.events.count == 3 && spy.events[2].event.contains("started"))
        service.stopViewing(); #expect(!visible)
    }

    @MainActor @Test func rateLimitAuditIsBoundedPerDevice() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let spy = ScreenAuditSpy(), latch = ScreenCaptureLatch()
        var clock: TimeInterval = 0
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in await latch.capture() }, auditAvailable: { true }, audit: { spy.record($0) },
            indicator: { _ in }, notify: {}, now: { clock })
        service.setAllowed(true)
        let request = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        for _ in 0..<1000 {
            #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 429)
        }
        #expect(spy.events.filter { $0.status == 429 }.count == 1)
        clock = 60
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 429)
        #expect(spy.events.filter { $0.status == 429 }.count == 2)
        await latch.finish()
        #expect(await request.value.status == 200)
        service.stopViewing()
    }

    @MainActor @Test func auditUnavailableOrAppendFailurePreventsCapture() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        for available in [false, true] {
            var writes = 0
            var visible = false
            let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
                capture: { _ in Issue.record("capture preceded durable audit"); return Data() },
                auditAvailable: { available }, audit: { _ in writes += 1; throw CocoaError(.fileWriteUnknown) },
                indicator: { visible = $0 }, notify: { Issue.record("failed frame notified") })
            service.setAllowed(true)
            let response = await service.response(caller: screenCaller(), query: nil, method: "GET")
            #expect(response.status == 503 && response.errorCode == "audit_unavailable")
            #expect(writes == (available ? 1 : 0))
            #expect(!visible)
        }
    }

    @MainActor @Test func periodicAppendFailureStopsSession() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        var clock: TimeInterval = 0
        var writes = 0
        var visible = false
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in Data([1]) }, auditAvailable: { true },
            audit: { _ in writes += 1; if writes == 2 { throw CocoaError(.fileWriteUnknown) } },
            indicator: { visible = $0 }, notify: {}, now: { clock })
        service.setAllowed(true)
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 200)
        clock = 60
        let response = await service.response(caller: screenCaller(), query: nil, method: "GET")
        #expect(response.status == 503 && response.errorCode == "audit_unavailable")
        #expect(!visible)
    }

    @MainActor @Test func auditLossDuringCaptureDiscardsPixels() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let latch = ScreenCaptureLatch()
        var available = true
        var visible = false
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in await latch.capture() }, auditAvailable: { available }, audit: { _ in },
            indicator: { visible = $0 }, notify: { Issue.record("discarded frame notified") })
        service.setAllowed(true)
        let request = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        available = false
        await latch.finish()
        #expect(await request.value.errorCode == "audit_unavailable")
        #expect(!visible)
    }

    @MainActor @Test func auditMustFinishBeforeCaptureAndRechecksRevocation() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let latch = ScreenCaptureLatch()
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in Issue.record("captured while audit pending or after revocation"); return Data() },
            auditAvailable: { true }, audit: { event in if event.status == 200 { _ = await latch.capture() } }, indicator: { _ in }, notify: {})
        service.setAllowed(true)
        let request = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        service.setAllowed(false)
        await latch.finish()
        #expect(await request.value.errorCode == "screen_revoked")
    }

    @MainActor @Test func sevenDayExpiryRefreshesOnlyAfterSuccessfulUseAndResetsWithPhone() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in Data([1]) }, auditAvailable: { true }, audit: { _ in }, indicator: { _ in }, notify: {}, date: { date })
        service.setAllowed(true)
        let originalExpiry = try #require(service.expiresAt)
        date = date.addingTimeInterval(86_400)
        var untrusted = screenCaller(); untrusted.login = "guest"
        #expect(await service.response(caller: untrusted, query: nil, method: "GET").status == 403)
        #expect(service.expiresAt == originalExpiry)
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 200)
        #expect(service.expiresAt == date.addingTimeInterval(7 * 86_400))
        date = try #require(service.expiresAt).addingTimeInterval(-1)
        service.refreshAvailability(); #expect(service.allowed)
        date = date.addingTimeInterval(1)
        service.refreshAvailability(); #expect(!service.allowed)
        #expect(!defaults.bool(forKey: "phoneAccess.allowScreenViewing"))
        service.setAllowed(true)
        let phone = TailscalePhoneAccessService(defaults: defaults, screen: { service })
        phone.setEnabled(false)
        service.refreshAvailability()
        #expect(!service.allowed && service.expiresAt == nil)
        #expect(defaults.object(forKey: "phoneAccess.screenLastUsed") == nil)
        #expect(!PhoneScreenService(defaults: defaults, indicator: { _ in }, notify: {}, date: { date }).allowed)
    }

    @MainActor @Test func legacyAndExpiredGrantsFailClosedOnRelaunch() throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        defaults.set(true, forKey: "phoneAccess.allowScreenViewing")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!PhoneScreenService(defaults: defaults, indicator: { _ in }, notify: {}, date: { date }).allowed)
        defaults.set(true, forKey: "phoneAccess.allowScreenViewing")
        defaults.set(date.addingTimeInterval(-7 * 86_400), forKey: "phoneAccess.screenLastUsed")
        #expect(!PhoneScreenService(defaults: defaults, indicator: { _ in }, notify: {}, date: { date }).allowed)
    }

    @MainActor @Test func repeatedCaptureFailuresDoNotFloodSessionStartRows() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        var clock: TimeInterval = 0
        let spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in throw CocoaError(.fileReadUnknown) }, auditAvailable: { true }, audit: { spy.record($0) },
            indicator: { _ in }, notify: { Issue.record("failed capture notified") }, now: { clock })
        service.setAllowed(true)
        for tick in 0..<120 {
            clock = Double(tick) / 2
            #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").errorCode == "screen_capture_failed")
        }
        #expect(spy.events.count == 2) // one start + one rejected-request row
        #expect(spy.events.filter { $0.event.contains("started") }.count == 1)
        service.stopViewing()
    }

    @MainActor @Test func slowCaptureNotifiesAfterGapBetweenSuccessfulFrames() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "phoneAccess.enabled")
        let latch = ScreenCaptureLatch()
        var clock: TimeInterval = 0
        var notifications = 0
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in await latch.capture() }, auditAvailable: { true }, audit: { _ in },
            indicator: { _ in }, notify: { notifications += 1 }, now: { clock })
        service.setAllowed(true)
        let first = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        await latch.finish()
        #expect(await first.value.status == 200)
        #expect(notifications == 1)
        clock = 0.5
        let second = Task { await service.response(caller: screenCaller(), query: nil, method: "GET") }
        while !(await latch.started) { await Task.yield() }
        clock = 61
        await latch.finish()
        #expect(await second.value.status == 200)
        #expect(notifications == 2)
        service.stopViewing()
    }

}
