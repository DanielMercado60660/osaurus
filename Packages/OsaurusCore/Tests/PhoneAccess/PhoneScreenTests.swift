import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import OsaurusCore

private let screenSecret = String(repeating: "s", count: 64)
private func screenCaller() -> PhoneScreenCaller {
    PhoneScreenCaller(marker: "1", secret: screenSecret, deviceID: "node-1", physicalLoopback: true, relay: false, hasAuthorization: false)
}
private func screenTrust() -> PhoneAccessTrust {
    let trust = PhoneAccessTrust(); trust.replace(with: screenSecret); return trust
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
    func finish() { continuation?.resume(returning: Data([1, 2, 3])); continuation = nil }
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

@Suite("Phone screen")
struct PhoneScreenTests {
    @Test func trustMatrix() {
        let trust = screenTrust(), owner = screenCaller()
        #expect(owner.mayView(enabled: true, using: trust))
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
        let first = PhoneScreenService(defaults: defaults, indicator: { _ in })
        #expect(!first.allowed)
        first.setAllowed(true)
        #expect(PhoneScreenService(defaults: defaults, indicator: { _ in }).allowed)
        first.setAllowed(false)
        #expect(!PhoneScreenService(defaults: defaults, indicator: { _ in }).allowed)
    }

    @MainActor @Test func deniedRequestsAuditWithoutCapture() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { false },
            capture: { _ in Issue.record("denied request captured pixels"); return Data() },
            audit: { spy.record($0) }, indicator: { _ in })
        var caller = screenCaller(); caller.marker = nil
        #expect(await service.response(caller: caller, query: nil, method: "GET").errorCode == "phone_owner_required")
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").errorCode == "screen_disabled")
        service.setAllowed(true)
        #expect(await service.response(caller: screenCaller(), query: nil, method: "POST").status == 405)
        #expect(await service.response(caller: screenCaller(), query: "display=all", method: "GET").status == 400)
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").errorCode == "screen_permission_missing")
        #expect(spy.events.count == 5)
        #expect(spy.events[0].details["phone_device_id"] == "unverified")
        #expect(spy.events[1].deviceID == "node-1")
        #expect(spy.events.allSatisfy { $0.bytes == 0 })
        #expect(spy.events[2].method == "POST")
    }

    @MainActor @Test func frameCreatesMetadataOnlyAuditAndRateLimits() async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ScreenAuditSpy()
        var visible = false
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { max in #expect(max == 640); return Data([1, 2, 3]) },
            audit: { spy.record($0) }, indicator: { visible = $0 })
        service.setAllowed(true)
        let response = await service.response(caller: screenCaller(), query: "max=640", method: "GET")
        #expect(response.status == 200 && response.contentType == "image/jpeg")
        #expect(visible)
        #expect(spy.events.count == 1)
        #expect(spy.events[0].details == ["phone_device_id": "node-1", "display": "main", "screen_bytes": "3"])
        #expect(await service.response(caller: screenCaller(), query: nil, method: "GET").status == 429)
        #expect(spy.events.count == 2)
        service.setAllowed(false); #expect(!visible)
    }

    @MainActor @Test(arguments: [false, true]) func revokeDuringCapture(rotatingSecret: Bool) async throws {
        let name = "PhoneScreenTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let latch = ScreenCaptureLatch(), trust = screenTrust(), spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: trust, permission: { true },
            capture: { _ in await latch.capture() }, audit: { spy.record($0) }, indicator: { _ in })
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
        let latch = ScreenCaptureLatch(), spy = ScreenAuditSpy()
        let service = PhoneScreenService(defaults: defaults, trust: screenTrust(), permission: { true },
            capture: { _ in await latch.capture() }, audit: { spy.record($0) }, indicator: { _ in })
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
}
