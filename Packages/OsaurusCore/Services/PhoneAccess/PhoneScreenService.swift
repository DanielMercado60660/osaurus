import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class PhoneScreenService: ObservableObject {
    static let shared = PhoneScreenService()
    static let unusedLifetime: TimeInterval = 7 * 24 * 60 * 60
    @Published private(set) var allowed: Bool
    @Published private(set) var expiresAt: Date?
    private let defaults: UserDefaults
    private let trust: PhoneAccessTrust
    private let permission: @Sendable () -> Bool
    private let capture: @Sendable (Int) async throws -> Data
    private let auditAvailable: @MainActor () -> Bool
    private let audit: @MainActor (PhoneScreenAudit) async throws -> Void
    private let indicator: @MainActor (Bool) -> Void
    private let notify: @MainActor () -> Void
    private let now: @MainActor () -> TimeInterval
    private let date: @MainActor () -> Date
    private var limiter = PhoneScreenRateLimiter()
    private var rejectionAudit = PhoneScreenAuditThrottle()
    private var sessions: [String: PhoneScreenSession] = [:]
    private var viewing = PhoneScreenViewingState()
    private var expiry: Task<Void, Never>?
    private var unusedExpiry: Task<Void, Never>?
    private var revision = UUID()

    init(
        defaults: UserDefaults = .standard,
        trust: PhoneAccessTrust = .shared,
        permission: @escaping @Sendable () -> Bool = { SystemScreenshotPermissionChecker().hasScreenRecordingPermission() },
        capture: @escaping @Sendable (Int) async throws -> Data = { try await ScreenshotCaptureService.shared.capturePreviewJPEG(maxDimension: $0) },
        auditAvailable: @escaping @MainActor () -> Bool = { InsightsService.shared.durableStoreAvailable },
        audit: @escaping @MainActor (PhoneScreenAudit) async throws -> Void = { try await PhoneScreenActivityLogger.record($0) },
        indicator: @escaping @MainActor (Bool) -> Void = { PhoneScreenIndicator.shared.setVisible($0) },
        notify: @escaping @MainActor () -> Void = { PhoneScreenIndicator.notify() },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        date: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.defaults = defaults; self.trust = trust; self.permission = permission
        self.capture = capture; self.audit = audit; self.auditAvailable = auditAvailable
        self.indicator = indicator; self.notify = notify; self.now = now; self.date = date
        allowed = defaults.bool(forKey: "phoneAccess.allowScreenViewing")
        expiresAt = (defaults.object(forKey: "phoneAccess.screenLastUsed") as? Date)?.addingTimeInterval(Self.unusedLifetime)
        // Old indefinite grants have no timestamp and must be explicitly renewed.
        refreshAvailability()
        scheduleUnusedExpiry()
    }

    func setAllowed(_ value: Bool) {
        allowed = value && defaults.bool(forKey: "phoneAccess.enabled")
        defaults.set(allowed, forKey: "phoneAccess.allowScreenViewing")
        revision = UUID()
        if allowed { recordUse() }
        else {
            expiresAt = nil; defaults.removeObject(forKey: "phoneAccess.screenLastUsed")
            unusedExpiry?.cancel(); unusedExpiry = nil
            stopViewing()
        }
    }

    func refreshAvailability() {
        if allowed && (!defaults.bool(forKey: "phoneAccess.enabled") || expiresAt.map { date() >= $0 } ?? true) {
            setAllowed(false)
        }
    }

    private func recordUse() {
        let used = date()
        defaults.set(used, forKey: "phoneAccess.screenLastUsed")
        expiresAt = used.addingTimeInterval(Self.unusedLifetime)
        scheduleUnusedExpiry()
    }

    private func scheduleUnusedExpiry() {
        unusedExpiry?.cancel()
        guard allowed, let expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSince(date()))
        unusedExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshAvailability()
            self?.scheduleUnusedExpiry() // Re-arm if the wall clock moved backward.
        }
    }

    func stopViewing() {
        revision = UUID()
        expiry?.cancel(); expiry = nil; viewing.clear(); sessions.removeAll(); indicator(false)
    }

    private func noteFrame() {
        viewing.noteFrame(now: now())
        indicator(true)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.refreshIndicator()
        }
    }

    func refreshIndicator() {
        if !viewing.isViewing(now: now()) { indicator(false) }
    }

    func response(caller: PhoneScreenCaller, query: String?, method: String) async -> PhoneScreenResponse {
        // Defense in depth. HTTPHandler checks this on the NIO loop first.
        guard let device = caller.verifiedDevice(using: trust) else {
            return .error(403, "phone_owner_required", "Screen access requires the verified tailnet node owner.")
        }
        refreshAvailability()
        let result = await fetch(caller: caller, device: device, query: query, method: method)
        if result.status != 200, result.errorCode != "audit_unavailable",
            rejectionAudit.shouldRecord(device: device, now: now()) {
            do {
                try await audit(PhoneScreenAudit(deviceID: device, status: result.status,
                    bytes: 0, errorCode: result.errorCode, method: method))
            } catch { return auditFailure() }
        }
        return result
    }

    private func auditFailure() -> PhoneScreenResponse {
        stopViewing()
        return .error(503, "audit_unavailable", "Screen viewing stopped because the durable activity log is unavailable. Restore Insights storage and relaunch Osaurus before retrying.")
    }

    private func fetch(caller: PhoneScreenCaller, device: String, query: String?, method: String) async -> PhoneScreenResponse {
        guard method == "GET" else { return .error(405, "method_not_allowed", "Use GET for the screen preview.") }
        guard caller.mayView(enabled: allowed, using: trust) else {
            return .error(403, "screen_disabled", "On the Mac, enable Allow phone to view this Mac's screen in Server → Overview → Phone access.")
        }
        guard let options = PhoneScreenOptions.parse(query: query) else {
            return .error(400, "invalid_screen_options", "Use display=main and a positive integer max (capped at 1280).")
        }
        guard permission() else { return .error(403, "screen_permission_missing", "Grant Osaurus Screen Recording permission on the Mac, then retry. You may need to relaunch Osaurus.") }
        guard auditAvailable() else { return auditFailure() }
        guard limiter.begin(device: device, now: now()) else {
            return .error(429, "screen_rate_limited", "Wait at least 500 ms between frames; only one capture per device may be outstanding.")
        }
        defer { limiter.finish(device: device) }
        let startedRevision = revision
        sessions = sessions.filter { !$0.value.isNew(now: now()) }
        var session = sessions[device] ?? PhoneScreenSession(lastAudit: now())
        let newSession = sessions[device] == nil
        let needsNotification = session.lastFrame == nil
        // Await the committed row before touching pixels. Periodic rows summarize
        // the preceding interval, rather than claiming the current frame was sent.
        if newSession || now() - session.lastAudit >= 60 {
            do {
                try await audit(PhoneScreenAudit(deviceID: device, status: 200, bytes: session.bytes,
                    errorCode: nil, event: newSession ? "screen view started (device \(device))" : "screen view continued",
                    count: session.frames))
            } catch { return auditFailure() }
            session.lastAudit = now(); session.frames = 0; session.bytes = 0
            if startedRevision == revision { sessions[device] = session }
        }
        do {
            try Task.checkCancellation()
            refreshAvailability()
            guard startedRevision == revision, caller.mayView(enabled: allowed, using: trust) else {
                return .error(403, "screen_revoked", "Screen access changed before capture.")
            }
            guard auditAvailable() else { return auditFailure() }
            noteFrame() // Both indicators are visible even during slow capture.
            let jpeg = try await capture(options.maxDimension)
            try Task.checkCancellation()
            refreshAvailability()
            guard startedRevision == revision, caller.mayView(enabled: allowed, using: trust) else {
                return .error(403, "screen_revoked", "Screen access changed during capture. Reconnect or enable it on the Mac.")
            }
            guard auditAvailable() else { return auditFailure() }
            guard permission() else { return .error(403, "screen_permission_missing", "Screen Recording permission is no longer available.") }
            let idleGap = session.lastFrame.map { now() - $0 > 60 } ?? false
            session.lastFrame = now(); session.frames += 1; session.bytes += jpeg.count
            sessions[device] = session
            noteFrame(); recordUse()
            if needsNotification || idleGap { notify() }
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
                   dataClasses: event.bytes > 0 ? ["screen_image"] : [], details: event.details)
    }

    @MainActor static func record(_ event: PhoneScreenAudit) async throws {
        try await InsightsService.shared.logDurably(RequestLog(
            source: .httpAPI, method: event.method, path: "/phone/api/screen",
            statusCode: event.status, durationMs: event.durationMs, egress: egress(for: event)))
    }
}

/// Independent of chat/window visibility. Exists only while frames are being viewed.
@MainActor
private final class PhoneScreenIndicator {
    static let shared = PhoneScreenIndicator()
    private var item: NSStatusItem?
    private var panel: NSPanel?

    static func notify() {
        // current() raises an Objective-C exception in headless SwiftPM/CLI runs.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        // NotificationService owns the app's authorization and foreground delegate.
        // Delivery follows that existing permission; the overlay is unconditional.
        let content = UNMutableNotificationContent()
        content.title = "Phone is viewing your screen"
        content.body = "Disable screen viewing in Server → Overview → Phone access."
        center.add(UNNotificationRequest(identifier: "phone-screen-\(UUID())", content: content, trigger: nil))
    }
    func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil {
                let overlay = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 38),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                overlay.level = .screenSaver
                overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                overlay.hidesOnDeactivate = false
                overlay.ignoresMouseEvents = true
                overlay.isReleasedWhenClosed = false
                overlay.backgroundColor = .windowBackgroundColor
                overlay.hasShadow = true
                let label = NSTextField(labelWithString: "Phone is viewing your screen")
                label.alignment = .center
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.frame = NSRect(x: 8, y: 10, width: 284, height: 18)
                overlay.contentView?.addSubview(label)
                panel = overlay
            }
            // Follow the active display without activating a window or stealing focus.
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel?.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.maxY - 50))
            }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil); panel = nil
        }
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
