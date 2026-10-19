import AppKit
import Combine
import Foundation

@MainActor
final class PhoneScreenService: ObservableObject {
    static let shared = PhoneScreenService()
    @Published private(set) var allowed: Bool
    private let defaults: UserDefaults
    private let trust: PhoneAccessTrust
    private let permission: @Sendable () -> Bool
    private let capture: @Sendable (Int) async throws -> Data
    private let audit: @Sendable (PhoneScreenAudit) -> Void
    private let indicator: @MainActor (Bool) -> Void
    private var limiter = PhoneScreenRateLimiter()
    private var viewing = PhoneScreenViewingState()
    private var expiry: Task<Void, Never>?
    private var revision = UUID()

    init(
        defaults: UserDefaults = .standard,
        trust: PhoneAccessTrust = .shared,
        permission: @escaping @Sendable () -> Bool = { SystemScreenshotPermissionChecker().hasScreenRecordingPermission() },
        capture: @escaping @Sendable (Int) async throws -> Data = { try await ScreenshotCaptureService.shared.capturePreviewJPEG(maxDimension: $0) },
        audit: @escaping @Sendable (PhoneScreenAudit) -> Void = { PhoneScreenActivityLogger.record($0) },
        indicator: @escaping @MainActor (Bool) -> Void = { PhoneScreenIndicator.shared.setVisible($0) }
    ) {
        self.defaults = defaults; self.trust = trust; self.permission = permission
        self.capture = capture; self.audit = audit; self.indicator = indicator
        allowed = defaults.bool(forKey: "phoneAccess.allowScreenViewing")
    }

    func setAllowed(_ value: Bool) {
        allowed = value
        defaults.set(value, forKey: "phoneAccess.allowScreenViewing")
        revision = UUID()
        if !value { stopViewing() }
    }

    func stopViewing() {
        revision = UUID()
        expiry?.cancel(); expiry = nil; viewing.clear(); indicator(false)
    }

    private func noteFrame() {
        viewing.noteFrame(now: ProcessInfo.processInfo.systemUptime)
        indicator(true)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            if !self.viewing.isViewing(now: ProcessInfo.processInfo.systemUptime) { self.indicator(false) }
        }
    }

    func response(caller: PhoneScreenCaller, query: String?, method: String) async -> PhoneScreenResponse {
        let started = ProcessInfo.processInfo.systemUptime
        let device = caller.verifiedDevice(using: trust)
        let result = await fetch(caller: caller, device: device, query: query, method: method)
        audit(PhoneScreenAudit(deviceID: device, status: result.status,
                               bytes: result.status == 200 ? result.body.count : 0, errorCode: result.errorCode,
                               method: method, durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000))
        return result
    }

    private func fetch(caller: PhoneScreenCaller, device: String?, query: String?, method: String) async -> PhoneScreenResponse {
        guard let device else { return .error(403, "phone_owner_required", "Screen access requires the verified phone helper and device identity.") }
        guard method == "GET" else { return .error(405, "method_not_allowed", "Use GET for the screen preview.") }
        guard caller.mayView(enabled: allowed, using: trust) else {
            return .error(403, "screen_disabled", "On the Mac, enable Allow phone to view this Mac's screen in Server → Overview → Phone access.")
        }
        guard let options = PhoneScreenOptions.parse(query: query) else {
            return .error(400, "invalid_screen_options", "Use display=main and a positive integer max (capped at 1280).")
        }
        guard permission() else { return .error(403, "screen_permission_missing", "Grant Osaurus Screen Recording permission on the Mac, then retry. You may need to relaunch Osaurus.") }
        guard limiter.begin(device: device, now: ProcessInfo.processInfo.systemUptime) else {
            return .error(429, "screen_rate_limited", "Wait at least 500 ms between frames; only one capture per device may be outstanding.")
        }
        defer { limiter.finish(device: device) }
        let startedRevision = revision
        // Show before capturing, including during a slow ScreenCaptureKit call.
        noteFrame()
        do {
            try Task.checkCancellation()
            let jpeg = try await capture(options.maxDimension)
            try Task.checkCancellation()
            // Revocation/restart or permission changes during capture discard the bytes.
            guard startedRevision == revision, caller.mayView(enabled: allowed, using: trust) else {
                return .error(403, "screen_revoked", "Screen access changed during capture. Reconnect or enable it on the Mac.")
            }
            guard permission() else { return .error(403, "screen_permission_missing", "Screen Recording permission is no longer available.") }
            noteFrame()
            return PhoneScreenResponse(status: 200, body: jpeg, contentType: "image/jpeg")
        } catch is CancellationError {
            return .error(499, "screen_cancelled", "Screen request was cancelled.")
        } catch ScreenshotCaptureError.missingScreenRecordingPermission {
            return .error(403, "screen_permission_missing", "Grant Osaurus Screen Recording permission on the Mac.")
        } catch {
            return .error(503, "screen_capture_failed", "The Mac could not capture the screen. Check Screen Recording permission and the active display, then retry.")
        }
    }
}

enum PhoneScreenActivityLogger {
    nonisolated static func egress(for event: PhoneScreenAudit) -> EgressInfo {
        EgressInfo(destinationLabel: "Phone screen preview", bytesSent: event.bytes,
                   dataClasses: event.status == 200 ? ["screen_image"] : [], details: event.details)
    }

    nonisolated static func record(_ event: PhoneScreenAudit) {
        InsightsService.logRequest(
            source: .httpAPI, method: event.method, path: "/phone/api/screen",
            statusCode: event.status, durationMs: event.durationMs,
            egress: egress(for: event)
        )
    }
}

/// Independent of chat/window visibility. Exists only while frames are being viewed.
@MainActor
private final class PhoneScreenIndicator {
    static let shared = PhoneScreenIndicator()
    private var item: NSStatusItem?
    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.title = "Phone is viewing your screen"
            status.button?.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Phone is viewing your screen")
            status.button?.imagePosition = .imageLeading
            status.button?.toolTip = "Disable screen viewing in Server → Overview → Phone access."
            item = status
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }
}
