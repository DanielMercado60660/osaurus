import Foundation

/// Screen access deliberately does not use general loopback/owner API trust.
struct PhoneScreenCaller: Sendable {
    var marker: String?
    var secret: String?
    var deviceID: String?
    var physicalLoopback: Bool
    var relay: Bool
    var hasAuthorization: Bool
    var secureChannel: Bool = false
    var login: String? = nil

    func verifiedDevice(using trust: PhoneAccessTrust) -> String? {
        guard marker == "1", !relay, !hasAuthorization, !secureChannel,
            trust.accepts(secret, physicalLoopback: physicalLoopback), trust.acceptsOwner(login),
            let deviceID, !deviceID.isEmpty, deviceID.utf8.count <= 256,
            deviceID.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { return nil }
        return deviceID
    }

    func mayView(enabled: Bool, using trust: PhoneAccessTrust) -> Bool {
        enabled && verifiedDevice(using: trust) != nil
    }
}

struct PhoneScreenOptions: Equatable, Sendable {
    let maxDimension: Int

    static func parse(query: String?) -> Self? {
        guard query?.removingPercentEncoding != nil || query == nil,
            let components = URLComponents(string: "http://phone.invalid/?" + (query ?? "")),
            components.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        guard items.allSatisfy({ ["display", "max"].contains($0.name) }),
            Set(items.map(\.name)).count == items.count,
            items.first(where: { $0.name == "display" }).map({ $0.value == "main" }) ?? true
        else { return nil }
        let raw = items.first(where: { $0.name == "max" })
        guard raw == nil || raw?.value.flatMap(Int.init).map({ $0 > 0 }) == true else { return nil }
        return Self(maxDimension: min(raw?.value.flatMap(Int.init) ?? 1280, 1280))
    }
}

/// Monotonic times; one outstanding capture per device, at least 500 ms apart.
struct PhoneScreenRateLimiter {
    private var last: [String: TimeInterval] = [:]
    private var inFlight: Set<String> = []

    mutating func begin(device: String, now: TimeInterval) -> Bool {
        last = last.filter { now - $0.value < 60 || inFlight.contains($0.key) }
        guard !inFlight.contains(device), last[device].map({ now - $0 >= 0.5 }) ?? true else { return false }
        last[device] = now
        inFlight.insert(device)
        return true
    }

    mutating func finish(device: String) { inFlight.remove(device) }
}

struct PhoneScreenViewingState {
    private(set) var lastFrame: TimeInterval?
    mutating func noteFrame(now: TimeInterval) { lastFrame = now }
    mutating func clear() { lastFrame = nil }
    func isViewing(now: TimeInterval) -> Bool {
        lastFrame.map { now >= $0 && now - $0 < 5 } ?? false
    }
}

struct PhoneScreenResponse: Sendable {
    let status: Int
    let body: Data
    let contentType: String
    var errorCode: String? = nil

    static func error(_ status: Int, _ code: String, _ message: String) -> Self {
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
        return Self(status: status, body: body, contentType: "application/json; charset=utf-8", errorCode: code)
    }
}

/// Metadata only: screen bytes and launch secrets must never enter Insights.
struct PhoneScreenAudit: Equatable, Sendable {
    let deviceID: String?
    let status: Int
    let bytes: Int
    let errorCode: String?
    var method: String = "GET"
    var durationMs: Double = 0
    var event: String = "screen request rejected"
    var count: Int = 1
    var details: [String: String] {
        var result = ["phone_device_id": deviceID ?? "unverified", "display": "main", "screen_bytes": String(bytes)]
        result["event"] = event
        result["request_count"] = String(count)
        if let errorCode { result["error_code"] = errorCode }
        return result
    }
}

/// Per-device rejection rows, including 429s, are bounded independently of captures.
struct PhoneScreenAuditThrottle {
    private var last: [String: TimeInterval] = [:]
    mutating func shouldRecord(device: String, now: TimeInterval) -> Bool {
        last = last.filter { now - $0.value < 60 }
        guard last[device] == nil else { return false }
        last[device] = now
        return true
    }
}

struct PhoneScreenSession {
    var lastFrame: TimeInterval?
    var lastAudit: TimeInterval
    var frames = 0
    var bytes = 0
    func isNew(now: TimeInterval) -> Bool { now - (lastFrame ?? lastAudit) > 60 }
}

/// One process-wide counter/timer, never one task or main-actor hop per rejection.
/// The lock also bounds bursts arriving on different NIO event loops.
final class PhoneScreenRejections: @unchecked Sendable {
    static let shared = PhoneScreenRejections { count in
        Task { @MainActor in
            try? await PhoneScreenActivityLogger.record(PhoneScreenAudit(
                deviceID: nil, status: 403, bytes: 0, errorCode: "phone_owner_required",
                event: "rejected \(count) unverified screen requests", count: count))
        }
    }
    private let lock = NSLock()
    private var count = 0
    private var scheduled = false
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let emit: @Sendable (Int) -> Void
    init(schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: $0)
    }, emit: @escaping @Sendable (Int) -> Void) {
        self.schedule = schedule; self.emit = emit
    }
    func reject() {
        lock.lock()
        count = count == Int.max ? count : count + 1
        let needsTimer = !scheduled
        scheduled = true
        lock.unlock()
        if needsTimer { schedule { [self] in flush() } }
    }
    private func flush() {
        lock.lock()
        let total = count; count = 0; scheduled = false
        lock.unlock()
        if total > 0 { emit(total) }
    }
}
